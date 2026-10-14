import pcore_pkg::*;

// One complete Attention job. Matrix time is measured from true first S0,
// never from descriptor acceptance. Data fences and unit retirement differ.
module dea8_attention_scheduler (
  input logic clk,reset,clear,start_valid,output logic start_ready,
  input pcore_job_t context_job,input job_token_t context_token,
  input logic [ROW_COUNT_BITS-1:0] context_rows,
  output logic matrix_valid,input logic matrix_ready,output compute_job_t matrix_job,
  input logic matrix_done,output logic matrix_done_ready,input compute_job_t matrix_completed,
  input logic issue_valid,input pair_meta_t issue_meta,
  output logic launch_allow,input pair_meta_t launch_meta,
  output logic v_offer_valid,input logic v_offer_ready,output unit_cmd_t v_offer,
  output logic f_offer_valid,input logic f_offer_ready,output unit_cmd_t f_offer,
  input logic v_active,v_running,f_active,f_running,
  input unit_cmd_t v_current,f_current,
  output logic v_grant,f_grant,
  input logic v_retired,f_retired,input unit_cmd_t v_completed,f_completed,
  input logic p_fence,scale_fence,input logic [5:0] p_fence_block,scale_fence_block,
  input logic q_released,o_acquired,o_complete,input logic units_idle,
  output logic q_release_request,o_acquire_request,
  output logic done,protocol_error,
  output logic [15:0] slot_cycles,output logic [6:0] matrix_started,matrix_retired
);
  localparam int MATRIX_JOBS=2*KV_BLOCKS;
  logic active,finished;
  logic [6:0] offered;
  logic [15:0] elapsed;
  logic [14:0] v_sequence,f_sequence;
  logic [KV_BLOCKS-1:0] qk_ready,pv_ready,qk_issued,qk_done,alpha_issued,alpha_done;
  logic [KV_BLOCKS-1:0] exp_issued,exp_done,p_issued,p_done,scale_issued,scale_done,p_ready,scaled;
  logic recip_issued,recip_done,afin_issued,afin_done;
  logic v_hold,f_hold,v_pick,f_pick;
  unit_cmd_t v_held,f_held,v_candidate,f_candidate;
  logic [5:0] vb,fb;
  unit_function_e vf,ff;
  function automatic int block_for(input int i);
    if(i==0)return 0;
    if(i==MATRIX_JOBS-1)return KV_BLOCKS-1;
    return i%2?(i+1)/2:i/2-1;
  endfunction
  function automatic logic is_pv(input int i);return i!=0&&(i==MATRIX_JOBS-1||i%2==0);endfunction
  function automatic logic [$bits(compute_job_t)-1:0] make_work(input int i,
    input pcore_job_t parent,input job_token_t token,input logic [ROW_COUNT_BITS-1:0] row_count);
    logic pv;int b;pv=is_pv(i);b=block_for(i);
    return {token,SEQ_BITS'(i),row_count,MATRIX_TILE_COUNT_BITS'(ATTN_K_TILES),
      MAT_ATTENTION,(pv?ROLE_V:ROLE_K),6'(b),parent.epoch,parent.head,TILE_BITS'(0),
      (pv?ACC_OACC:(b%2?ACC_FACC_B:ACC_FACC_A)),(pv&&b!=0),pv,
      EXP_FOLD_BITS'(pv?0:-4),6'd0};
  endfunction
  assign slot_cycles=16'(ATTN_K_TILES*(pairs_for_rows(context_rows)<B_LOAD_GROUPS?B_LOAD_GROUPS:pairs_for_rows(context_rows))+12);
  assign start_ready=!active&&!reset&&!clear&&!protocol_error;
  assign matrix_job=make_work(offered,context_job,context_token,context_rows);
  assign matrix_valid=active&&offered<MATRIX_JOBS&&offered<matrix_started+2&&!protocol_error;
  assign matrix_done_ready=active&&matrix_retired<offered&&!protocol_error;
  always_comb begin
    int b;b=block_for(matrix_started);
    launch_allow=active&&launch_meta.token==context_token&&launch_meta.work_seq==matrix_started&&
      (matrix_started==0||int'(elapsed)+1>=(matrix_started==MATRIX_JOBS-1?2*int'(slot_cycles):int'(slot_cycles)));
    if(is_pv(matrix_started))launch_allow&=p_ready[b]&&(b==0||scaled[b]||(scale_fence&&scale_fence_block==b));
    v_grant=0;f_grant=0;
    if(v_active)case(v_current.function_id)
      UNIT_QK_POST:v_grant=qk_ready[v_current.block_id];
      UNIT_P_POST:v_grant=alpha_done[v_current.block_id];
      UNIT_OACC_SCALE:v_grant=v_current.block_id>0&&pv_ready[v_current.block_id-1]&&
        (v_current.block_id==KV_BLOCKS-1?int'(elapsed)+1>=int'(slot_cycles):
          (matrix_started>=2*v_current.block_id+2||
            issue_valid&&issue_meta.role==ROLE_K&&issue_meta.block_id==v_current.block_id+1&&issue_meta.tile_idx==0&&issue_meta.pair_idx==0));
      UNIT_AFIN_QUANT:v_grant=recip_done&&pv_ready[KV_BLOCKS-1]&&o_acquired;
      default:;
    endcase
    if(f_active)case(f_current.function_id)
      UNIT_ALPHA_EXP:f_grant=qk_done[f_current.block_id];
      UNIT_P_EXP:f_grant=alpha_done[f_current.block_id]&&v_running&&v_current.function_id==UNIT_P_POST&&
        v_current.block_id==f_current.block_id;
      UNIT_RECIP:f_grant=pv_ready[KV_BLOCKS-1];
      default:;
    endcase
    v_pick=0;f_pick=0;vb=0;fb=0;vf=UNIT_QK_POST;ff=UNIT_ALPHA_EXP;
    // Prepare Scale as soon as P/L is committed, before PV relinquishes OACC.
    for(int b=1;b<KV_BLOCKS;b++)if(!v_pick&&p_ready[b]&&!scale_issued[b])begin v_pick=1;vb=6'(b);vf=UNIT_OACC_SCALE;end
    for(int b=0;b<KV_BLOCKS;b++)if(!v_pick&&qk_ready[b]&&!qk_issued[b]&&(b==0||exp_done[b-1]))begin v_pick=1;vb=6'(b);vf=UNIT_QK_POST;end
    for(int b=0;b<KV_BLOCKS;b++)if(!v_pick&&alpha_done[b]&&!p_issued[b])begin v_pick=1;vb=6'(b);vf=UNIT_P_POST;end
    if(!v_pick&&recip_done&&!afin_issued)begin v_pick=1;vb=KV_BLOCKS-1;vf=UNIT_AFIN_QUANT;end
    for(int b=0;b<KV_BLOCKS;b++)if(!f_pick&&qk_done[b]&&!alpha_issued[b])begin f_pick=1;fb=6'(b);ff=UNIT_ALPHA_EXP;end
    for(int b=0;b<KV_BLOCKS;b++)if(!f_pick&&alpha_done[b]&&!exp_issued[b])begin f_pick=1;fb=6'(b);ff=UNIT_P_EXP;end
    if(!f_pick&&pv_ready[KV_BLOCKS-1]&&!recip_issued)begin f_pick=1;fb=KV_BLOCKS-1;ff=UNIT_RECIP;end
    v_candidate='0;v_candidate.token={context_token[31:16],v_sequence,1'b0};v_candidate.parent_token=context_token;
    v_candidate.function_id=vf;v_candidate.rows=context_rows;v_candidate.block_id=vb;
    v_candidate.profile_id=context_job.profile_id;v_candidate.profile_version=context_job.profile_version;
    v_candidate.output_version=context_job.output_version;v_candidate.scan_pair_major=vf==UNIT_OACC_SCALE;
    f_candidate=v_candidate;f_candidate.token={context_token[31:16],f_sequence,1'b1};
    f_candidate.function_id=ff;f_candidate.block_id=fb;f_candidate.scan_pair_major=0;
    v_offer=v_hold?v_held:v_candidate;f_offer=f_hold?f_held:f_candidate;
  end
  assign v_offer_valid=active&&(v_hold||v_pick)&&!protocol_error;
  assign f_offer_valid=active&&(f_hold||f_pick)&&!protocol_error;
  assign q_release_request=active&&qk_ready[KV_BLOCKS-1]&&!q_released;
  assign o_acquire_request=active&&q_released&&!o_acquired;
  assign done=finished&&!protocol_error;
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      active<=0;finished<=0;offered<=0;matrix_started<=0;matrix_retired<=0;elapsed<=0;
      v_sequence<=1;f_sequence<=0;v_hold<=0;f_hold<=0;protocol_error<=0;
      qk_ready<=0;pv_ready<=0;qk_issued<=0;qk_done<=0;alpha_issued<=0;alpha_done<=0;
      exp_issued<=0;exp_done<=0;p_issued<=0;p_done<=0;scale_issued<=0;scale_done<=0;p_ready<=0;scaled<=0;
      recip_issued<=0;recip_done<=0;afin_issued<=0;afin_done<=0;
    end else begin
      if(active&&elapsed!=16'hffff)elapsed<=elapsed+1'b1;
      if(start_valid&&start_ready)begin
        active<=context_rows!=0;finished<=context_rows==0;offered<=0;matrix_started<=0;matrix_retired<=0;elapsed<=0;
        v_sequence<=1;f_sequence<=0;v_hold<=0;f_hold<=0;
        qk_ready<=0;pv_ready<=0;qk_issued<=0;qk_done<=0;alpha_issued<=0;alpha_done<=0;
        exp_issued<=0;exp_done<=0;p_issued<=0;p_done<=0;scale_issued<=0;scale_done<=0;p_ready<=0;scaled<=0;
        recip_issued<=0;recip_done<=0;afin_issued<=0;afin_done<=0;
      end
      if(matrix_valid&&matrix_ready)offered<=offered+1'b1;
      if(issue_valid&&issue_meta.tile_idx==0&&issue_meta.pair_idx==0)begin
        if(issue_meta.work_seq!=matrix_started||!launch_allow)protocol_error<=1;
        else begin matrix_started<=matrix_started+1'b1;elapsed<=0;end
      end
      if(matrix_done&&matrix_done_ready)begin
        if(matrix_completed!==make_work(matrix_retired,context_job,context_token,context_rows))protocol_error<=1;
        else begin
          matrix_retired<=matrix_retired+1'b1;
          if(matrix_completed.role==ROLE_K)qk_ready[matrix_completed.block_id]<=1;
          else pv_ready[matrix_completed.block_id]<=1;
        end
      end
      if(p_fence)begin if(p_fence_block>=KV_BLOCKS)protocol_error<=1;else p_ready[p_fence_block]<=1;end
      if(scale_fence)begin if(scale_fence_block==0||scale_fence_block>=KV_BLOCKS)protocol_error<=1;else scaled[scale_fence_block]<=1;end
      if(v_offer_valid&&!v_offer_ready&&!v_hold)begin v_hold<=1;v_held<=v_offer;end
      if(f_offer_valid&&!f_offer_ready&&!f_hold)begin f_hold<=1;f_held<=f_offer;end
      if(v_offer_valid&&v_offer_ready)begin
        v_hold<=0;v_sequence<=v_sequence+1'b1;
        case(v_offer.function_id)
          UNIT_QK_POST:qk_issued[v_offer.block_id]<=1;
          UNIT_P_POST:p_issued[v_offer.block_id]<=1;
          UNIT_OACC_SCALE:scale_issued[v_offer.block_id]<=1;
          UNIT_AFIN_QUANT:afin_issued<=1;
          default:protocol_error<=1;
        endcase
      end
      if(f_offer_valid&&f_offer_ready)begin
        f_hold<=0;f_sequence<=f_sequence+1'b1;
        case(f_offer.function_id)
          UNIT_ALPHA_EXP:alpha_issued[f_offer.block_id]<=1;
          UNIT_P_EXP:exp_issued[f_offer.block_id]<=1;
          UNIT_RECIP:recip_issued<=1;
          default:protocol_error<=1;
        endcase
      end
      if(v_retired)case(v_completed.function_id)
        UNIT_QK_POST:qk_done[v_completed.block_id]<=1;
        UNIT_P_POST:p_done[v_completed.block_id]<=1;
        UNIT_OACC_SCALE:scale_done[v_completed.block_id]<=1;
        UNIT_AFIN_QUANT:afin_done<=1;
        default:protocol_error<=1;
      endcase
      if(f_retired)case(f_completed.function_id)
        UNIT_ALPHA_EXP:alpha_done[f_completed.block_id]<=1;
        UNIT_P_EXP:exp_done[f_completed.block_id]<=1;
        UNIT_RECIP:recip_done<=1;
        default:protocol_error<=1;
      endcase
      if(active&&matrix_retired==MATRIX_JOBS&&afin_done&&recip_done&&o_complete&&units_idle)begin
        active<=0;finished<=1;
      end
    end
  end
endmodule
