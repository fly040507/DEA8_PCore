import pcore3_pkg::*;

// Attention scheduler with one current Matrix descriptor and one lookahead
// descriptor.  Matrix timing is driven by descriptor acceptance and completion
// handshakes; VPU/SFU latency is represented only by done tokens.
// Completion contract (all context fields echoed unchanged):
// QK_POST: all score/row-state inputs for ALPHA_EXP are visible.
// ALPHA_EXP: the complete alpha generation is visible to P_EXP/SCALE.
// P_EXP: probability production for this generation is complete.
// P_POST: final PBUF pair was ACCEPTED and its bank is committed.
// OACC_SCALE: final accumulator update was ACCEPTED/committed.
// RECIP: all reciprocals are visible to AFIN. AFIN: final outputs committed.
// Done never means merely issuing the last request. Hold valid/context until
// ready, one in-flight command per VPU/SFU, in-order Matrix completions.
// tail_launch_ready must connect to the Matrix wrapper: descriptor acceptance
// grants prefetch only, while this level grants final-PV execution.
module dea8_attention_scheduler_v4 #(
  parameter int BLOCKS=KV_BLOCKS,
  // Full architectural tail slot. Descriptor acceptance/prefetch is separate
  // from launch permission; local RAM latency is not subtracted from this slot.
  parameter int TAIL_SCALE_SLOT_CYCLES=ATTN_NOMINAL_SLOT,
  parameter bit STREAM_P_POST=0
) (
  input logic clk,reset,clear,
  input logic start_valid, output logic start_ready,busy,
  input logic [2:0] start_head,
  input logic [EPOCH_BITS-1:0] start_epoch,
  output logic done_valid, input logic done_ready,
  output logic matrix_valid, input logic matrix_ready,
  output matrix_cmd_t matrix_cmd,
  output logic tail_launch_ready,
  input logic matrix_done_valid, output logic matrix_done_ready,
  input matrix_cmd_t matrix_done,
  output logic vpu_valid, input logic vpu_ready,
  output vpu_cmd_t vpu_cmd,
  input logic vpu_done_valid, output logic vpu_done_ready,
  input vpu_cmd_t vpu_done,
  output logic sfu_valid, input logic sfu_ready,
  output sfu_cmd_t sfu_cmd,
  input logic sfu_done_valid, output logic sfu_done_ready,
  input sfu_cmd_t sfu_done
);
  localparam int MATRIX_JOBS=2*BLOCKS;
  localparam int INDEX_BITS=(MATRIX_JOBS<2)?1:$clog2(MATRIX_JOBS+1);
  localparam int TAIL_BITS=(TAIL_SCALE_SLOT_CYCLES<2)?1:$clog2(TAIL_SCALE_SLOT_CYCLES+1);

  logic active_q,afin_done_q,tail_guard_q;
  logic [INDEX_BITS-1:0] matrix_index_q;
  logic [INDEX_BITS-1:0] matrix_completed_q;
  logic vpu_hold_q,sfu_hold_q;
  vpu_cmd_t vpu_held_q;
  sfu_cmd_t sfu_held_q;
  logic [TAIL_BITS-1:0] tail_remaining_q;
  logic [2:0] head_q;
  logic [EPOCH_BITS-1:0] epoch_q;

  logic [BLOCKS-1:0] qk_pending_q,alpha_pending_q,p_exp_pending_q;
  logic [BLOCKS-1:0] p_post_pending_q,scale_pending_q;
  logic [BLOCKS-1:0] p_ready_q,scale_ready_q;
  logic [BLOCKS-1:0] pv_committed_q,p_post_armed_q;
  logic [BLOCKS-1:0] p_exp_done_q;
  logic recip_pending_q,afin_pending_q;
  logic vpu_busy_q,sfu_busy_q;
  vpu_cmd_t vpu_inflight_q;
  sfu_cmd_t sfu_inflight_q;
  logic [5:0] vpu_pick,sfu_pick;
  logic vpu_pick_qk,vpu_pick_p,vpu_pick_scale,vpu_pick_afin;
  logic sfu_pick_alpha,sfu_pick_p,sfu_pick_recip;
  logic matrix_allowed;

  function automatic matrix_cmd_t make_matrix_cmd(input int unsigned index);
    matrix_cmd_t c;
    int unsigned block;
    c='0;c.mode=MAT_ATTENTION;c.m_rows=ROWS;c.result_last=1;
    c.epoch=epoch_q;c.head=head_q;c.job_last=(index==MATRIX_JOBS-1);
    if(index==0) begin
      c.op=MATRIX_QK;block=0;
    end else if(index==MATRIX_JOBS-1) begin
      c.op=MATRIX_PV;block=BLOCKS-1;
    end else if(index[0]) begin
      c.op=MATRIX_QK;block=(index+1)/2;
    end else begin
      c.op=MATRIX_PV;block=index/2-1;
    end
    c.block_id=6'(block);
    c.a_id=(c.op==MATRIX_PV)?LOGICAL_ID_BITS'(block):'0;
    c.b_id=LOGICAL_ID_BITS'(block*ATTN_K_TILES);
    c.out_tile=(c.op==MATRIX_PV)?TILE_BITS'(block):TILE_BITS'(0);
    c.acc_sel=(c.op==MATRIX_PV)?ACC_OACC:(block[0]?ACC_FACC_B:ACC_FACC_A);
    c.add_old=(c.op==MATRIX_PV)&&(block!=0);
    c.exp_fold=(c.op==MATRIX_QK)?-4:0;
    return c;
  endfunction

  assign start_ready=!reset&&!clear&&!active_q;
  assign busy=active_q;
  assign done_valid=!reset&&!clear&&active_q&&afin_done_q;
  assign matrix_done_ready=!reset&&!clear&&active_q&&(matrix_completed_q<matrix_index_q);
  assign vpu_done_ready=!reset&&!clear&&active_q&&vpu_busy_q;
  assign sfu_done_ready=!reset&&!clear&&active_q&&sfu_busy_q;
  assign tail_launch_ready=!reset&&!clear&&active_q&&tail_guard_q&&
    tail_remaining_q==0&&p_ready_q[BLOCKS-1]&&scale_ready_q[BLOCKS-1];

  always_comb begin
    matrix_cmd=make_matrix_cmd(matrix_index_q);
    matrix_allowed=1'b0;
    if(matrix_index_q<MATRIX_JOBS) begin
      if(matrix_index_q==MATRIX_JOBS-1)
        matrix_allowed=tail_guard_q;
      else if(matrix_index_q<2 || matrix_index_q[0]) matrix_allowed=1'b1;
      else begin
        int pv_block;
        pv_block=matrix_index_q/2-1;
        matrix_allowed=p_ready_q[pv_block]&&((pv_block==0)||scale_ready_q[pv_block]);
      end
    end
  end
  assign matrix_valid=!reset&&!clear&&active_q&&matrix_allowed&&(matrix_index_q<MATRIX_JOBS);

  always_comb begin
    vpu_pick='0;vpu_pick_qk=0;vpu_pick_p=0;vpu_pick_scale=0;vpu_pick_afin=0;
    for(int i=0;i<BLOCKS;i++) begin
      if(!vpu_pick_qk&&qk_pending_q[i]&&
         (!STREAM_P_POST||i==0||p_exp_done_q[i-1])) begin vpu_pick=i;vpu_pick_qk=1;end
      if(!vpu_pick_p&&!vpu_pick_qk&&p_post_pending_q[i]) begin vpu_pick=i;vpu_pick_p=1;end
      if(!vpu_pick_scale&&!vpu_pick_qk&&!vpu_pick_p&&scale_pending_q[i]&&
         (!STREAM_P_POST||(i>0&&pv_committed_q[i-1]))) begin
        vpu_pick=i;vpu_pick_scale=1;
      end
    end
    vpu_pick_afin=afin_pending_q&&!vpu_pick_qk&&!vpu_pick_p&&!vpu_pick_scale;
    vpu_cmd='0;vpu_cmd.epoch=epoch_q;vpu_cmd.head=head_q;
    vpu_cmd.block_id=vpu_pick;vpu_cmd.facc_bank=vpu_pick[0];
    vpu_cmd.sbuf_bank=vpu_pick[0];vpu_cmd.pbuf_bank=vpu_pick[0];
    vpu_cmd.alpha_bank=vpu_pick[0];
    if(vpu_pick_qk) vpu_cmd.op=VPU_QK_POST;
    else if(vpu_pick_p) vpu_cmd.op=VPU_P_POST;
    else if(vpu_pick_scale) vpu_cmd.op=VPU_OACC_SCALE;
    else vpu_cmd.op=VPU_AFIN;
    vpu_valid=active_q&&!vpu_busy_q&&(vpu_pick_qk||vpu_pick_p||vpu_pick_scale||vpu_pick_afin);
    if(vpu_hold_q) begin vpu_cmd=vpu_held_q;vpu_valid=active_q&&!vpu_busy_q;end
    if(reset||clear) vpu_valid=0;
  end

  always_comb begin
    sfu_pick='0;sfu_pick_alpha=0;sfu_pick_p=0;sfu_pick_recip=0;
    for(int i=0;i<BLOCKS;i++) begin
      if(!sfu_pick_alpha&&alpha_pending_q[i]&&
         (!STREAM_P_POST||i<2||(p_ready_q[i-2]&&scale_ready_q[i-2]))) begin sfu_pick=i;sfu_pick_alpha=1;end
      if(!sfu_pick_p&&!sfu_pick_alpha&&p_exp_pending_q[i]&&
         (!STREAM_P_POST||p_post_armed_q[i])) begin sfu_pick=i;sfu_pick_p=1;end
    end
    sfu_pick_recip=recip_pending_q&&!sfu_pick_alpha&&!sfu_pick_p;
    sfu_cmd='0;sfu_cmd.epoch=epoch_q;sfu_cmd.head=head_q;sfu_cmd.block_id=sfu_pick;
    sfu_cmd.sbuf_bank=sfu_pick[0];sfu_cmd.alpha_bank=sfu_pick[0];
    if(sfu_pick_alpha) sfu_cmd.op=SFU_ALPHA_EXP;
    else if(sfu_pick_p) sfu_cmd.op=SFU_P_EXP;
    else sfu_cmd.op=SFU_RECIP;
    sfu_valid=active_q&&!sfu_busy_q&&(sfu_pick_alpha||sfu_pick_p||sfu_pick_recip);
    if(sfu_hold_q) begin sfu_cmd=sfu_held_q;sfu_valid=active_q&&!sfu_busy_q;end
    if(reset||clear) sfu_valid=0;
  end

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      active_q<=0;afin_done_q<=0;matrix_index_q<=0;tail_remaining_q<=0;tail_guard_q<=0;
      matrix_completed_q<=0;vpu_hold_q<=0;sfu_hold_q<=0;vpu_held_q<='0;sfu_held_q<='0;
      head_q<=0;epoch_q<=0;qk_pending_q<='0;alpha_pending_q<='0;
      p_exp_pending_q<='0;p_post_pending_q<='0;scale_pending_q<='0;
      p_ready_q<='0;scale_ready_q<='0;scale_ready_q[0]<=1;
      pv_committed_q<='0;p_post_armed_q<='0;
      p_exp_done_q<='0;
      recip_pending_q<=0;afin_pending_q<=0;vpu_busy_q<=0;sfu_busy_q<=0;
      vpu_inflight_q<='0;sfu_inflight_q<='0;
    end else begin
      if(tail_remaining_q!=0) tail_remaining_q<=tail_remaining_q-1'b1;

      if(start_valid&&start_ready) begin
        active_q<=1;afin_done_q<=0;matrix_index_q<=0;tail_guard_q<=0;
        matrix_completed_q<=0;vpu_hold_q<=0;sfu_hold_q<=0;
        head_q<=start_head;epoch_q<=start_epoch;tail_remaining_q<=0;
        qk_pending_q<='0;alpha_pending_q<='0;p_exp_pending_q<='0;
        p_post_pending_q<='0;scale_pending_q<='0;p_ready_q<='0;
        scale_ready_q<='0;scale_ready_q[0]<=1;
        pv_committed_q<='0;p_post_armed_q<='0;
        p_exp_done_q<='0;
        recip_pending_q<=0;afin_pending_q<=0;vpu_busy_q<=0;sfu_busy_q<=0;
      end

      if(matrix_valid&&matrix_ready) begin
        matrix_index_q<=matrix_index_q+1'b1;
      end
      if(matrix_done_valid&&matrix_done_ready) begin
        matrix_completed_q<=matrix_completed_q+1'b1;
        if(matrix_done.op==MATRIX_QK) qk_pending_q[matrix_done.block_id]<=1;
        if(matrix_done.op==MATRIX_PV) pv_committed_q[matrix_done.block_id]<=1;
        if(matrix_done.op==MATRIX_PV&&matrix_done.block_id==BLOCKS-2) begin
          tail_remaining_q<=TAIL_BITS'(TAIL_SCALE_SLOT_CYCLES-1);
          // Include the commit edge in the full guard. With preloaded A/B,
          // final PV issue follows GUARD+1 edges after this commit, independent
          // of the prefetch startup latency. Slow sources may extend the wait.
          tail_guard_q<=1;
        end
        if(matrix_done.op==MATRIX_PV&&matrix_done.block_id==BLOCKS-1)
          recip_pending_q<=1;
      end

      if(vpu_valid&&!vpu_ready&&!vpu_hold_q) begin vpu_hold_q<=1;vpu_held_q<=vpu_cmd;end
      if(sfu_valid&&!sfu_ready&&!sfu_hold_q) begin sfu_hold_q<=1;sfu_held_q<=sfu_cmd;end
      if(vpu_valid&&vpu_ready) begin
        vpu_hold_q<=0;
        vpu_busy_q<=1;vpu_inflight_q<=vpu_cmd;
        case(vpu_cmd.op)
          VPU_QK_POST: qk_pending_q[vpu_cmd.block_id]<=0;
          VPU_P_POST: begin
            p_post_pending_q[vpu_cmd.block_id]<=0;
            p_post_armed_q[vpu_cmd.block_id]<=1;
          end
          VPU_OACC_SCALE: scale_pending_q[vpu_cmd.block_id]<=0;
          VPU_AFIN: afin_pending_q<=0;
          default: ;
        endcase
      end
      if(vpu_done_valid&&vpu_done_ready) begin
        vpu_busy_q<=0;
        case(vpu_done.op)
          VPU_QK_POST: alpha_pending_q[vpu_done.block_id]<=1;
          VPU_P_POST: p_ready_q[vpu_done.block_id]<=1;
          VPU_OACC_SCALE: scale_ready_q[vpu_done.block_id]<=1;
          VPU_AFIN: afin_done_q<=1;
          default: ;
        endcase
      end

      if(sfu_valid&&sfu_ready) begin
        sfu_hold_q<=0;
        sfu_busy_q<=1;sfu_inflight_q<=sfu_cmd;
        case(sfu_cmd.op)
          SFU_ALPHA_EXP: alpha_pending_q[sfu_cmd.block_id]<=0;
          SFU_P_EXP: p_exp_pending_q[sfu_cmd.block_id]<=0;
          SFU_RECIP: recip_pending_q<=0;
          default: ;
        endcase
      end
      if(sfu_done_valid&&sfu_done_ready) begin
        sfu_busy_q<=0;
        case(sfu_done.op)
          SFU_ALPHA_EXP: begin
            p_exp_pending_q[sfu_done.block_id]<=1;
            if(STREAM_P_POST) p_post_pending_q[sfu_done.block_id]<=1;
            if(sfu_done.block_id!=0) scale_pending_q[sfu_done.block_id]<=1;
          end
          SFU_P_EXP: begin
            p_exp_done_q[sfu_done.block_id]<=1;
            if(!STREAM_P_POST) p_post_pending_q[sfu_done.block_id]<=1;
          end
          SFU_RECIP: afin_pending_q<=1;
          default: ;
        endcase
      end
      if(done_valid&&done_ready) begin active_q<=0;afin_done_q<=0;end
    end
  end

  // The context checks catch a VPU/SFU implementation returning the wrong
  // generation while allowing any legal latency.
  // synthesis translate_off
  always @(posedge clk) if(!reset&&!clear&&active_q) begin
    if(matrix_done_valid&&(!matrix_done_ready||matrix_done!==make_matrix_cmd(matrix_completed_q)))
      $fatal(1,"Attention Matrix completion context mismatch");
    if(vpu_done_valid&&!vpu_busy_q) $fatal(1,"Attention VPU unsolicited completion");
    if(sfu_done_valid&&!sfu_busy_q) $fatal(1,"Attention SFU unsolicited completion");
    if(vpu_done_valid&&vpu_done_ready&&vpu_done!==vpu_inflight_q)
      $fatal(1,"Attention VPU completion context mismatch");
    if(sfu_done_valid&&sfu_done_ready&&sfu_done!==sfu_inflight_q)
      $fatal(1,"Attention SFU completion context mismatch");
  end
  initial begin
    if(BLOCKS<2||BLOCKS>64) $fatal(1,"Attention scheduler requires 2..64 blocks");
    if(TAIL_SCALE_SLOT_CYCLES<1) $fatal(1,"Tail slot must be positive");
  end
  // synthesis translate_on
endmodule
