`timescale 1ns/1ps
import pcore_pkg::*;
import dea8_tile_link_pkg::*;

// Only external producers and non-matrix arithmetic are behavioural. Every
// QK/PV partial, ACC access and Q/P/O payload traverses the actual PCore RTL.
module tb_dynamic_attention;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,completion_valid,completion_ready=0,busy,flush_request;
  pcore_job_t job='0;pcore_completion_t completion;logic [2:0] flush_ack=7;
  logic profile_begin_valid=0,profile_begin_ready,profile_wr_valid=0,profile_wr_ready,profile_commit_valid=0,profile_commit_ready;
  logic [ROW_COUNT_BITS-1:0] profile_begin_rows=0,profile_wr_index=0,profile_wr_original=0;
  logic [15:0] profile_begin_id=7,profile_begin_version=1;
  logic unit_profile_valid=0,unit_profile_ready,unit_profile_out_valid,unit_profile_out_ready=1;
  job_token_t unit_profile_token=0;logic [ROW_COUNT_BITS-1:0] unit_profile_index=0,unit_profile_out_index,unit_profile_original;
  logic source_work_valid,source_work_ready=0;compute_job_t source_work;pcore_job_t source_context;
  logic a_desc_valid=0,a_desc_ready,a_in_valid=0,a_in_ready,b_desc_valid=0,b_desc_ready;
  a_slot_desc_t a_desc='0;a3_beat_t a_in='0;b_packet_desc_t b_desc='0;
  logic [1:0] hbm_valid=0,hbm_ready;logic [1:0][255:0] hbm_data=0;b_beat_tag_t hbm_tag[0:1];
  logic kv_in_valid=0,kv_in_ready;logic [511:0] kv_in_data=0;b_beat_tag_t kv_in_tag='0;
  logic unit_cmd_valid,unit_cmd_ready=0,unit_armed_valid=0,unit_armed_ready,unit_go_valid,unit_go_ready=0;
  unit_cmd_t unit_cmd;job_token_t unit_armed_token=0,unit_go_token;
  logic unit_rd_valid=0,unit_rd_ready,unit_out_valid,unit_out_ready=0;
  pair_read_t unit_rd='0;pair_reply_t unit_out_reply;
  logic unit_wr_valid=0,unit_wr_ready,unit_done_valid=0,unit_done_ready,unit_done_error=0;
  local_write_t unit_wr='0;job_token_t unit_done_token=0;unit_function_e unit_done_function=UNIT_QK_POST;
  logic unit_quant_valid=0,unit_quant_ready;kv_quant_t unit_quant='0;
  logic kv_hdr_valid,kv_hdr_ready=1,kv_out_valid,kv_out_ready=1,kv_out_last,kv_commit_valid=0,kv_commit_ready;
  tile_header_t kv_hdr;tile_commit_t kv_commit='0;logic [ROW_BITS-1:0] kv_out;
  logic reduce_hdr_valid,reduce_hdr_ready=1,reduce_out_valid,reduce_out_ready=1,reduce_out_last;
  tile_header_t reduce_hdr;logic [511:0] reduce_out;
  logic local_import_valid=0,local_import_ready,local_import_wr_valid=0,local_import_wr_ready;
  local_object_t local_import_object='0;job_token_t local_import_token=32'hf0000001;local_write_t local_import_wr='0;
  logic function_cmd_valid,function_cmd_ready=0,function_armed_valid=0,function_armed_ready,function_go_valid,function_go_ready=0;
  logic function_data_valid,function_data_ready=1,function_result_valid=0,function_result_ready;
  fp16_stream_t function_data,function_result='0;unit_cmd_t function_cmd;
  job_token_t function_armed_token=0,function_go_token,function_done_token=0;
  logic function_done_valid=0,function_done_ready,function_done_error=0;unit_function_e function_done_function=UNIT_ALPHA_EXP;
  logic unit_ws_valid=0,unit_ws_ready,unit_ws_out_valid,unit_ws_out_ready=0;
  workspace_req_t unit_ws='0;workspace_rsp_t unit_ws_out;
  logic function_ws_valid=0,function_ws_ready,function_ws_out_valid,function_ws_out_ready=0;
  sfu_workspace_req_t function_ws='0;sfu_workspace_rsp_t function_ws_out;
  logic unit_acc_valid=0,unit_acc_ready,unit_acc_out_valid,unit_acc_out_ready,unit_acc_wr_valid=0,unit_acc_wr_ready;
  logic normal_acc_out_ready=0;
  unit_acc_read_t unit_acc='0;unit_acc_reply_t unit_acc_out;unit_acc_write_t unit_acc_wr='0;
  logic function_exp_valid,function_exp_ready,unit_p_valid,unit_p_ready=0;
  fp4_stream_t function_exp,unit_p;
  logic protocol_error,qoz_complete,issue_valid,psum_valid,commit_valid;
  pair_meta_t issue_meta,commit_meta;mxu_rsp_t psum_rsp;acc_write_t commit_write;
  pcore_top dut(.*);

  int rows=0,cycle=0,jobs=0,works=0,issues=0,commits=0,qk_count=0,pv_count=0,v_commands=0,f_commands=0;
  int first_cycle[0:109],last_cycle[0:109],accept_cycle,finish_cycle,nontrivial_alpha=0;
  bit agents=0,exp_stream=0,allow_error=0;
  bit qk_stream=0;
  unit_cmd_t qk_cmd;
  workspace_req_t score_q;
  logic score_valid=0,score_ready;
  int score_requests=0,score_writes=0;
  logic [31:0] qk_old_m[ROWS],qk_m_new[ROWS],qk_aa_new[ROWS];
  logic [31:0] alpha_cache[0:1][0:ROWS-1];
  int alpha_cache_block[0:1];
  job_token_t parent_token;
  qvec16_t q[0:15][0:ROWS-1],p_gold[0:54][0:ROWS-1],o_gold[0:15][0:ROWS-1];
  logic [31:0] qk_gold[0:54][0:ROWS-1][0:15],oacc_gold[0:ROWS-1][0:255];
  logic [31:0] max_gold[0:ROWS-1],l_gold[0:ROWS-1],alpha_gold[0:54][0:ROWS-1];
  logic [31:0] sf_m[0:ROWS-1];
  logic [31:0] partial[0:2][0:PAIRS*TILE-1][0:1][0:15];
  logic [2:0] exp_pipe_valid=0;fp4_stream_t exp_pipe[0:2];logic [2:0] exp_pipe_ready;
  unit_cmd_t sf_current;
  bit transform_stream=0,transform_final=0;
  unit_cmd_t transform_cmd;
  logic [31:0] transform_factor[ROWS];
  logic [1:0] transform_valid=0,transform_ready;
  unit_acc_write_t transform_pipe[0:1];
  int transform_count=0,transform_requests=0;
  logic [DEQACC_PIPE_STAGES-1:0] c_expected_valid=0;
  acc_write_t c_expected[0:DEQACC_PIPE_STAGES-1];
  pair_meta_t c_meta[0:DEQACC_PIPE_STAGES-1];
  function automatic logic [31:0] bits(input real x);shortreal s;s=x;return $shortrealtobits(s);endfunction
  function automatic real real32(input logic [31:0] x);return real'($bitstoshortreal(x));endfunction
  function automatic logic [31:0] mul(input logic [31:0] a,b);return bits(real32(a)*real32(b));endfunction
  function automatic logic [31:0] dq(input int dot,input int ea,eb,fold);
    logic [31:0] mag;int lead;mag=dot<0?-dot:dot;lead=0;
    for(int i=0;i<32;i++)if(mag[i])lead=i;
    return fp32_legacy_ref_pkg::pack_scaled32(dot<0,mag<<(31-lead),ea+eb+fold-266+lead,mag==0,0);
  endfunction
  function automatic int bval(input compute_job_t w,input int t,k,n);
    return int'($signed(8'(w.block_id*7+t*13+k*5+n*11+(w.role==ROLE_V?3:0))));
  endfunction
  function automatic int bscale(input compute_job_t w,input int t,n);return 123+(w.block_id+t+n)%3;endfunction
  function automatic logic [ROW_BITS-1:0] quantize(input logic [15:0][31:0] x);
    real mx,step,v,f;int e,b,qv;logic [127:0] data;
    mx=0;for(int n=0;n<16;n++)begin v=real32(x[n]);if(v<0)v=-v;if(v>mx)mx=v;end
    step=2.0**(-133);e=0;while(e<254&&mx>127*step)begin step*=2;e++;end
    data=0;for(int n=0;n<16;n++)begin
      v=real32(x[n])/step;b=int'($floor(v));f=v-b;qv=b+int'(f>0.5||(f==0.5&&b%2!=0));
      if(qv>127)qv=127;if(qv< -128)qv=-128;data[n*8+:8]=8'(qv);
    end
    return {data,8'(e)};
  endfunction
  function automatic logic [15:0] mask16(input int base,limit);
    logic [15:0] result;for(int i=0;i<16;i++)result[i]=base+i<limit;return result;
  endfunction
  function automatic logic [3:0] mask4(input int base,limit);
    logic [3:0] result;for(int i=0;i<4;i++)result[i]=base+i<limit;return result;
  endfunction

  // A three-stage, four-lane SFU model, with elastic output and real workspace
  // reads. It cannot produce more than four exponentials in a clock.
  assign exp_pipe_ready[2]=!exp_pipe_valid[2]||function_exp_ready;
  assign exp_pipe_ready[1]=!exp_pipe_valid[1]||exp_pipe_ready[2];
  assign exp_pipe_ready[0]=!exp_pipe_valid[0]||exp_pipe_ready[1];
  assign function_exp_valid=exp_stream&&exp_pipe_valid[2];
  assign function_exp=exp_pipe[2];
  always @(posedge clk)begin
    fp4_stream_t entry;
    if(reset||clear||!exp_stream)exp_pipe_valid<=0;
    else begin
      for(int s=2;s>0;s--)if(exp_pipe_ready[s])begin exp_pipe_valid[s]<=exp_pipe_valid[s-1];exp_pipe[s]<=exp_pipe[s-1];end
      if(exp_pipe_ready[0])begin
        exp_pipe_valid[0]<=function_ws_out_valid&&function_ws_out_ready;
        if(function_ws_out_valid&&function_ws_out_ready)begin
          if(function_ws_out.kind!=WS_SCORE||function_ws_out.token!=sf_current.token)$fatal(1,"SFU Score response identity");
          entry='0;entry.token=sf_current.token;entry.row=function_ws_out.index;entry.group_id=function_ws_out.group_id;entry.mask=4'hf;
          entry.last=int'(entry.row)==rows-1&&entry.group_id==3;
          for(int n=0;n<4;n++)entry.data[n]=bits($exp(real32(function_ws_out.data[n])-real32(sf_m[entry.row])));
          exp_pipe[0]<=entry;
        end
      end
    end
  end

  // Two pipeline registers model the external 32-lane FP32 multiplier. One
  // reply is consumed only when the elastic pipeline can retain it.
  assign transform_ready[1]=!transform_valid[1]||(transform_final?unit_wr_ready:unit_acc_wr_ready);
  assign transform_ready[0]=!transform_valid[0]||transform_ready[1];
  assign unit_acc_out_ready=qk_stream?score_ready:(transform_stream?transform_ready[0]:normal_acc_out_ready);
  assign score_ready=!score_valid||unit_ws_ready;
  always @(negedge clk)if(qk_stream)begin
    unit_acc={qk_cmd.token,(qk_cmd.block_id[0]?ACC_FACC_B:ACC_FACC_A),PAIR_BITS'(score_requests),TILE_BITS'(0)};
    unit_acc_valid=score_requests<pairs_for_rows(rows);unit_ws=score_q;unit_ws_valid=score_valid;
  end
  always @(posedge clk)begin
    workspace_req_t entry;logic [1:0][15:0][31:0] data;real mx;
    if(reset||clear||!qk_stream)begin score_valid<=0;score_requests<=0;score_writes<=0;end
    else begin
      if(unit_acc_valid&&unit_acc_ready)score_requests<=score_requests+1;
      if(unit_ws_valid&&unit_ws_ready)score_writes<=score_writes+1;
      if(score_ready)begin
        score_valid<=unit_acc_out_valid&&unit_acc_out_ready;
        if(unit_acc_out_valid&&unit_acc_out_ready)begin
          if(unit_acc_out.request.token!=qk_cmd.token)$fatal(1,"QK post read token");
          data=unit_acc_out.data;
          for(int h=0;h<2;h++)if(unit_acc_out.mask[h])begin
            int r;r=2*int'(unit_acc_out.request.pair_idx)+h;mx=-1.0e30;
            for(int n=0;n<16;n++)begin
              if(data[h][n]!==qk_gold[qk_cmd.block_id][r][n])$fatal(1,"QK accumulated score mismatch");
              if((int'(qk_cmd.block_id)*16+n+r)%37==0)data[h][n]=32'hff800000;
              if(real32(data[h][n])>mx)mx=real32(data[h][n]);
              qk_gold[qk_cmd.block_id][r][n]=data[h][n];
            end
            qk_m_new[r]=bits(mx>real32(qk_old_m[r])?mx:real32(qk_old_m[r]));
            qk_aa_new[r]=bits(real32(qk_old_m[r])-real32(qk_m_new[r]));max_gold[r]=qk_m_new[r];
          end
          entry={qk_cmd.token,WS_SCORE,qk_cmd.block_id[0],1'b1,qk_cmd.block_id,
            ROW_COUNT_BITS'(2*int'(unit_acc_out.request.pair_idx)),2'b0,16'hffff,unit_acc_out.mask,data};
          score_q<=entry;
        end
      end
    end
  end
  always @(negedge clk)if(transform_stream)begin
    local_write_t wr;unit_acc_write_t value;unit_acc_read_t req;
    req={transform_cmd.token,ACC_OACC,PAIR_BITS'(transform_requests/16),TILE_BITS'(transform_requests%16)};
    unit_acc=req;unit_acc_valid=transform_requests<pairs_for_rows(rows)*16;
    value=transform_pipe[1];
    if(transform_final)begin
      wr='0;wr.token=transform_cmd.token;wr.kind=LOCAL_O;wr.content_version=job.output_version;
      wr.tile=TILE_BITS'(value.payload.addr%16);wr.mask=A_INPUT_ROWS'(value.payload.row_valid);
      for(int h=0;h<2;h++)begin
        wr.row[h]=ROW_COUNT_BITS'(2*(int'(value.payload.addr)/16)+h);wr.entry[h]=quantize(value.payload.data[h]);
      end
      unit_wr=wr;unit_wr_valid=transform_valid[1];
    end else begin unit_acc_wr=value;unit_acc_wr_valid=transform_valid[1];end
  end
  always @(posedge clk)begin
    unit_acc_write_t wr;
    if(reset||clear||!transform_stream)begin transform_valid<=0;transform_count<=0;transform_requests<=0;end
    else begin
      if(unit_acc_valid&&unit_acc_ready)transform_requests<=transform_requests+1;
      if(transform_valid[1]&&(transform_final?unit_wr_ready:unit_acc_wr_ready))begin
        transform_count<=transform_count+1;
        for(int h=0;h<2;h++)if(transform_pipe[1].payload.row_valid[h])begin
          int row,nt;row=2*(int'(transform_pipe[1].payload.addr)/16)+h;nt=transform_pipe[1].payload.addr%16;
          if(transform_final)o_gold[nt][row]=quantize(transform_pipe[1].payload.data[h]);
          else for(int n=0;n<16;n++)oacc_gold[row][nt*16+n]=transform_pipe[1].payload.data[h][n];
        end
      end
      if(transform_ready[1])begin transform_valid[1]<=transform_valid[0];transform_pipe[1]<=transform_pipe[0];end
      if(transform_ready[0])begin
        transform_valid[0]<=unit_acc_out_valid&&unit_acc_out_ready;
        if(unit_acc_out_valid&&unit_acc_out_ready)begin
          wr='0;wr.token=transform_cmd.token;wr.payload.sel=ACC_OACC;
          wr.payload.addr=10'(int'(unit_acc_out.request.pair_idx)*16+int'(unit_acc_out.request.nt));wr.payload.row_valid=unit_acc_out.mask;
          if(wr.payload.addr!=transform_count+int'(transform_valid[0])+int'(transform_valid[1]))$fatal(1,"Pair-major OACC order");
          for(int h=0;h<2;h++)if(unit_acc_out.mask[h])begin
            int row,nt;row=2*int'(unit_acc_out.request.pair_idx)+h;nt=unit_acc_out.request.nt;
            for(int n=0;n<16;n++)begin
              if(unit_acc_out.data[h][n]!==oacc_gold[row][nt*16+n])$fatal(1,"OACC before transform mismatch b=%0d r=%0d n=%0d",transform_cmd.block_id,row,nt*16+n);
              wr.payload.data[h][n]=mul(unit_acc_out.data[h][n],transform_factor[row]);
            end
          end
          transform_pipe[0]<=wr;
        end
      end
    end
  end

  task automatic vws_write(input unit_cmd_t c,input workspace_kind_e kind,input int index,
    input logic [15:0] mask,input logic [1:0] rowmask,input logic [1:0][15:0][31:0] data);
    workspace_req_t req;
    req={c.token,kind,c.block_id[0],1'b1,c.block_id,ROW_COUNT_BITS'(index),2'b0,mask,rowmask,data};
    if(req.token!==c.token)$fatal(1,"Workspace TB constructor lost token");
    unit_ws=req;unit_ws_valid=1;do @(posedge clk);while(!unit_ws_ready);
    @(negedge clk);unit_ws_valid=0;
  endtask
  task automatic vws_read(input unit_cmd_t c,input workspace_kind_e kind,input int index,
    output logic [15:0][31:0] data);
    workspace_req_t req;req='0;req.token=c.token;req.block_id=c.block_id;req.bank=c.block_id[0];req.kind=kind;
    req.index=ROW_COUNT_BITS'(index);req.mask=mask16(index,rows);req.row_mask=1;
    @(negedge clk);unit_ws=req;unit_ws_valid=1;
    do @(posedge clk);while(!unit_ws_ready);@(negedge clk);unit_ws_valid=0;unit_ws_out_ready=1;
    do @(posedge clk);while(!unit_ws_out_valid);
    if(unit_ws_out.token!=c.token||unit_ws_out.kind!=kind||unit_ws_out.index!=index)$fatal(1,"VPU workspace identity");
    data=unit_ws_out.data[0];@(negedge clk);unit_ws_out_ready=0;
  endtask
  task automatic fws_read(input unit_cmd_t c,input workspace_kind_e kind,input int index,
    output logic [3:0][31:0] data);
    sfu_workspace_req_t req;req='0;req.token=c.token;req.block_id=c.block_id;req.bank=c.block_id[0];
    req.kind=kind;req.index=ROW_COUNT_BITS'(index);req.mask=mask4(index,rows);
    @(negedge clk);function_ws=req;function_ws_valid=1;
    do @(posedge clk);while(!function_ws_ready);@(negedge clk);function_ws_valid=0;function_ws_out_ready=1;
    do @(posedge clk);while(!function_ws_out_valid);
    if(function_ws_out.token!=c.token||function_ws_out.kind!=kind||function_ws_out.index!=index)$fatal(1,"SFU workspace identity");
    data=function_ws_out.data;@(negedge clk);function_ws_out_ready=0;
  endtask
  task automatic fws_write(input unit_cmd_t c,input workspace_kind_e kind,input int index,input logic [3:0][31:0] data);
    sfu_workspace_req_t req;
    req={c.token,kind,c.block_id[0],1'b1,c.block_id,ROW_COUNT_BITS'(index),2'b0,mask4(index,rows),data};
    function_ws=req;function_ws_valid=1;do @(posedge clk);while(!function_ws_ready);
    @(negedge clk);function_ws_valid=0;
  endtask
  task automatic acc_read(input unit_cmd_t c,input acc_sel_e sel,input int pair_idx,nt,output unit_acc_reply_t response);
    unit_acc_read_t req;req='0;req.token=c.token;req.sel=sel;req.pair_idx=PAIR_BITS'(pair_idx);req.nt=TILE_BITS'(nt);
    @(negedge clk);unit_acc=req;unit_acc_valid=1;do @(posedge clk);while(!unit_acc_ready);
    @(negedge clk);unit_acc_valid=0;normal_acc_out_ready=1;do @(posedge clk);while(!unit_acc_out_valid);
    response=unit_acc_out;if(response.request!==req)$fatal(1,"Attention ACC read identity");
    @(negedge clk);normal_acc_out_ready=0;
  endtask
  task automatic quant_write(input unit_cmd_t c,input local_kind_e kind,input int nt,row,
    input logic [1:0] mask,input qvec16_t a,b);
    local_write_t wr;
    wr={c.token,kind,(kind==LOCAL_P?c.block_id[0]:1'b0),
      (kind==LOCAL_P?16'(int'(c.block_id)+1):job.output_version),TILE_BITS'(nt),
      {ROW_COUNT_BITS'(0),ROW_COUNT_BITS'(row+1),ROW_COUNT_BITS'(row)},A_INPUT_ROWS'(mask),{qvec16_t'('0),b,a}};
    unit_wr=wr;unit_wr_valid=1;do @(posedge clk);while(!unit_wr_ready);@(negedge clk);unit_wr_valid=0;
  endtask

  task automatic qk_post(input unit_cmd_t c);
    logic [15:0][31:0] old_m;logic [1:0][15:0][31:0] data;
    for(int r=0;r<rows;r+=16)begin
      vws_read(c,WS_M,r,old_m);
      for(int i=0;i<16&&r+i<rows;i++)begin
        if(old_m[i]!==max_gold[r+i])$fatal(1,"Old row max mismatch");qk_old_m[r+i]=old_m[i];
      end
    end
    @(negedge clk);qk_cmd=c;qk_stream=1;
    while(score_writes<pairs_for_rows(rows))@(negedge clk);
    qk_stream=0;unit_acc_valid=0;unit_ws_valid=0;
    for(int r=0;r<rows;r+=16)begin
      data='0;for(int i=0;i<16&&r+i<rows;i++)data[0][i]=qk_m_new[r+i];
      vws_write(c,WS_M,r,mask16(r,rows),1,data);
      data='0;for(int i=0;i<16&&r+i<rows;i++)data[0][i]=qk_aa_new[r+i];
      vws_write(c,WS_AA,r,mask16(r,rows),1,data);
    end
  endtask
  task automatic p_post(input unit_cmd_t c);
    logic [31:0] old_l[ROWS],alpha[ROWS],new_l[ROWS];logic [15:0][31:0] data;
    logic [15:0][31:0] p_row[ROWS];bit ready_row[ROWS];fp4_stream_t entry;
    logic [1:0][15:0][31:0] wrdata;
    for(int r=0;r<rows;r++)ready_row[r]=0;
    for(int r=0;r<rows;r+=16)begin
      vws_read(c,WS_ALPHA,r,data);for(int i=0;i<16&&r+i<rows;i++)begin alpha[r+i]=data[i];alpha_cache[c.block_id[0]][r+i]=data[i];end
      vws_read(c,WS_L,r,data);for(int i=0;i<16&&r+i<rows;i++)begin
        old_l[r+i]=data[i];if(data[i]!==l_gold[r+i])$fatal(1,"Old row sum mismatch");
      end
    end
    alpha_cache_block[c.block_id[0]]=c.block_id;
    fork
      begin
        @(negedge clk);unit_p_ready=1;
        for(int i=0;i<rows*4;i++)begin
          do @(posedge clk);while(!unit_p_valid);entry=unit_p;
          if(entry.token!=c.token||entry.row!=i/4||entry.group_id!=i%4||entry.last!=(i==rows*4-1))$fatal(1,"P stream ordering");
          for(int n=0;n<4;n++)begin
            if(entry.data[n]!==bits($exp(real32(qk_gold[c.block_id][i/4][4*(i%4)+n])-real32(max_gold[i/4]))))$fatal(1,"P exp data mismatch");
            p_row[i/4][4*(i%4)+n]=entry.data[n];
          end
          if(i%4==3)begin
            logic [31:0] sum;sum=0;for(int n=0;n<16;n++)sum=fp32_legacy_ref_pkg::fp32_add(sum,p_row[i/4][n]);
            new_l[i/4]=fp32_legacy_ref_pkg::fp32_add(mul(alpha[i/4],old_l[i/4]),sum);
            p_gold[c.block_id][i/4]=quantize(p_row[i/4]);ready_row[i/4]=1;
          end
          @(negedge clk);
        end
        unit_p_ready=0;
      end
      begin
        for(int r=0;r<rows;r++)begin
          while(!ready_row[r])@(negedge clk);
          quant_write(c,LOCAL_P,0,r,1,p_gold[c.block_id][r],qvec16_t'('0));
        end
      end
    join
    for(int r=0;r<rows;r+=16)begin
      wrdata='0;for(int i=0;i<16&&r+i<rows;i++)begin wrdata[0][i]=new_l[r+i];l_gold[r+i]=new_l[r+i];end
      vws_write(c,WS_L,r,mask16(r,rows),1,wrdata);
    end
  endtask
  task automatic oacc_transform(input unit_cmd_t c,input bit final_output);
    logic [15:0][31:0] data;
    if(final_output)for(int r=0;r<rows;r+=16)begin
      vws_read(c,WS_RECIP,r,data);for(int i=0;i<16&&r+i<rows;i++)transform_factor[r+i]=data[i];
    end else begin
      if(alpha_cache_block[c.block_id[0]]!=c.block_id)$fatal(1,"VPU cached alpha generation mismatch");
      for(int r=0;r<rows;r++)transform_factor[r]=alpha_cache[c.block_id[0]][r];
    end
    @(negedge clk);transform_cmd=c;transform_final=final_output;transform_stream=1;
    while(transform_count<pairs_for_rows(rows)*16)@(negedge clk);
    transform_stream=0;unit_acc_valid=0;normal_acc_out_ready=0;unit_acc_wr_valid=0;unit_wr_valid=0;
  endtask

  initial forever begin : transport_agent
    compute_job_t w;b_packet_desc_t d;logic [511:0] data;b_beat_tag_t tag;
    bit accepted[8];
    @(negedge clk);
    if(agents&&source_work_valid)begin
      source_work_ready=1;@(posedge clk);w=source_work;
      if(w.work_seq!=works||w.mode!=MAT_ATTENTION||w.tiles!=16||w.m_rows!=rows||source_context!==job)
        $fatal(1,"Attention normalized job geometry seq=%0d/%0d mode=%0d tiles=%0d rows=%0d/%0d context_match=%0d packed=%h",w.work_seq,works,w.mode,w.tiles,w.m_rows,rows,source_context===job,w);
      if(works==0)parent_token=w.token;else if(w.token!=parent_token)$fatal(1,"Attention parent identity");
      works++;@(negedge clk);source_work_ready=0;
      for(int p=0;p<8;p++)accepted[p]=0;
      fork
        begin
          b_packet_desc_t descriptor;
          for(int p=0;p<8;p++)begin
            descriptor={w.token,w.work_seq,SEQ_BITS'(p),SEQ_BITS'(2*p),B_KVB,MAT_ATTENTION,w.role,w.block_id};
            b_desc=descriptor;b_desc_valid=1;do @(posedge clk);while(!b_desc_ready);
            accepted[p]=1;@(negedge clk);
          end
          b_desc_valid=0;
        end
        begin
          b_packet_desc_t descriptor;
          for(int p=0;p<8;p++)begin
            while(!accepted[p])@(negedge clk);
            descriptor={w.token,w.work_seq,SEQ_BITS'(p),SEQ_BITS'(2*p),B_KVB,MAT_ATTENTION,w.role,w.block_id};
            for(int i=0;i<=8;i++)begin
              data=0;
              if(i==0)begin
                for(int b=0;b<2;b++)for(int n=0;n<16;n++)data[(b*16+n)*8+:8]=8'(bscale(w,2*p+b,n));
                data[511-:B_PACKET_BITS]=B_PACKET_BITS'(descriptor);
              end else for(int c=0;c<4;c++)for(int k=0;k<16;k++)
                data[c*128+k*8+:8]=8'(bval(w,2*p+(i-1)/4,k,((i-1)%4)*4+c));
              tag={w.token,w.work_seq,SEQ_BITS'(p),B_BEAT_INDEX_BITS'(i),(i==8)};
              kv_in_data=data;kv_in_tag=tag;kv_in_valid=1;do @(posedge clk);while(!kv_in_ready);@(negedge clk);
            end
          end
          kv_in_valid=0;
        end
      join
    end
  end
  initial forever begin : vector_agent
    unit_cmd_t c;
    @(negedge clk);
    if(agents&&unit_cmd_valid)begin
      unit_cmd_ready=1;@(posedge clk);c=unit_cmd;v_commands++;
      @(negedge clk);unit_cmd_ready=0;unit_armed_valid=1;unit_armed_token=c.token;
      do @(posedge clk);while(!unit_armed_ready);@(negedge clk);unit_armed_valid=0;unit_go_ready=1;
      do @(posedge clk);while(!unit_go_valid);if(unit_go_token!=c.token)$fatal(1,"VPU go token");
      @(negedge clk);unit_go_ready=0;
      case(c.function_id)
        UNIT_QK_POST:qk_post(c);
        UNIT_P_POST:p_post(c);
        UNIT_OACC_SCALE:oacc_transform(c,0);
        UNIT_AFIN_QUANT:oacc_transform(c,1);
        default:$fatal(1,"Unexpected Attention VPU function");
      endcase
      repeat(2)@(negedge clk);unit_done_token=c.token;unit_done_function=c.function_id;unit_done_valid=1;
      do @(posedge clk);while(!unit_done_ready);@(negedge clk);unit_done_valid=0;
    end
  end
  initial forever begin : function_agent
    unit_cmd_t c;logic [3:0][31:0] data,outdata;
    @(negedge clk);
    if(agents&&function_cmd_valid)begin
      function_cmd_ready=1;@(posedge clk);c=function_cmd;f_commands++;
      @(negedge clk);function_cmd_ready=0;function_armed_valid=1;function_armed_token=c.token;
      do @(posedge clk);while(!function_armed_ready);@(negedge clk);function_armed_valid=0;function_go_ready=1;
      do @(posedge clk);while(!function_go_valid);if(function_go_token!=c.token)$fatal(1,"SFU go token");
      @(negedge clk);function_go_ready=0;sf_current=c;
      if(c.function_id==UNIT_P_EXP)begin
        for(int r=0;r<rows;r+=4)begin fws_read(c,WS_M,r,data);for(int i=0;i<4&&r+i<rows;i++)sf_m[r+i]=data[i];end
        exp_stream=1;
        fork
          begin
            sfu_workspace_req_t req;
            for(int r=0;r<rows;r++)for(int g=0;g<4;g++)begin
              req='0;req.token=c.token;req.kind=WS_SCORE;req.bank=c.block_id[0];req.block_id=c.block_id;
              req.index=ROW_COUNT_BITS'(r);req.group_id=2'(g);req.mask=15;
              @(negedge clk);function_ws=req;function_ws_valid=1;do @(posedge clk);while(!function_ws_ready);
            end
            @(negedge clk);function_ws_valid=0;
          end
          begin
            int emitted;emitted=0;
            while(emitted<4*rows)begin
              @(negedge clk);function_ws_out_ready=exp_pipe_ready[0];
              @(posedge clk);if(function_exp_valid&&function_exp_ready)emitted++;
            end
            @(negedge clk);function_ws_out_ready=0;exp_stream=0;
          end
        join
      end else if(c.function_id==UNIT_ALPHA_EXP||c.function_id==UNIT_RECIP)begin
        logic [31:0] computed[ROWS];
        fork
          begin
            sfu_workspace_req_t req;
            for(int r=0;r<rows;r+=4)begin
              req='0;req.token=c.token;req.block_id=c.block_id;req.bank=c.block_id[0];req.kind=c.function_id==UNIT_ALPHA_EXP?WS_AA:WS_L;
              req.index=ROW_COUNT_BITS'(r);req.mask=mask4(r,rows);
              @(negedge clk);function_ws=req;function_ws_valid=1;do @(posedge clk);while(!function_ws_ready);
            end
            @(negedge clk);function_ws_valid=0;
          end
          begin
            @(negedge clk);function_ws_out_ready=1;
            for(int r=0;r<rows;r+=4)begin
              do @(posedge clk);while(!function_ws_out_valid);
              if(function_ws_out.token!=c.token||function_ws_out.index!=r)$fatal(1,"SFU statistic pipeline identity");
              for(int i=0;i<4&&r+i<rows;i++)begin
                computed[r+i]=bits(c.function_id==UNIT_ALPHA_EXP?$exp(real32(function_ws_out.data[i])):1.0/real32(function_ws_out.data[i]));
                if(c.function_id==UNIT_ALPHA_EXP)begin alpha_gold[c.block_id][r+i]=computed[r+i];if(computed[r+i]!=32'h3f800000&&c.block_id!=0)nontrivial_alpha++;end
              end
              @(negedge clk);
            end
            function_ws_out_ready=0;
          end
        join
        repeat(2)@(negedge clk);
        for(int r=0;r<rows;r+=4)begin
          outdata=0;for(int i=0;i<4&&r+i<rows;i++)outdata[i]=computed[r+i];
          fws_write(c,c.function_id==UNIT_ALPHA_EXP?WS_ALPHA:WS_RECIP,r,outdata);
        end
      end else $fatal(1,"Unexpected Attention SFU function");
      repeat(2)@(negedge clk);function_done_token=c.token;function_done_function=c.function_id;function_done_valid=1;
      do @(posedge clk);while(!function_done_ready);@(negedge clk);function_done_valid=0;
    end
  end

  always @(posedge clk)begin
    compute_job_t w;int addr,dot,row;logic [31:0] x;qvec16_t activation;acc_write_t expected;
    cycle++;
    if(reset||clear)c_expected_valid=0;
    if(!reset&&!clear)begin
      if(agents&&cycle%2000==0)$display("ATTENTION_STATE cycle=%0d M=%0d works=%0d issues=%0d commits=%0d VPU=%0d SFU=%0d",cycle,rows,works,issues,commits,v_commands,f_commands);
      for(int i=DEQACC_PIPE_STAGES-1;i>0;i--)begin
        c_expected_valid[i]=c_expected_valid[i-1];c_expected[i]=c_expected[i-1];c_meta[i]=c_meta[i-1];
      end
      c_expected_valid[0]=psum_valid;
      if(protocol_error&&!allow_error)$fatal(1,"Attention PCore protocol error cycle=%0d work=%0d",cycle,works);
      if(issue_valid)begin
        issues++;
        if(issue_meta.tile_idx==0&&issue_meta.pair_idx==0)begin
          first_cycle[issue_meta.work_seq]=cycle;
          if(issue_meta.role==ROLE_K)qk_count++;else pv_count++;
          $display("ATTENTION_PROGRESS M=%0d work=%0d role=%0d block=%0d first_S0=%0d",rows,issue_meta.work_seq,issue_meta.role,issue_meta.block_id,cycle);
        end
      end
      if(psum_valid)begin
        w='0;w.block_id=psum_rsp.meta.block_id;w.role=psum_rsp.meta.role;
        addr=w.role==ROLE_V?int'(psum_rsp.meta.pair_idx)*16+int'(psum_rsp.meta.nt):int'(psum_rsp.meta.pair_idx);
        expected='0;expected.sel=psum_rsp.meta.acc_sel;expected.addr=10'(addr);expected.row_valid=psum_rsp.row_valid;
        for(int h=0;h<2;h++)if(psum_rsp.row_valid[h])begin
          row=2*int'(psum_rsp.meta.pair_idx)+h;
          activation=w.role==ROLE_K?q[psum_rsp.meta.tile_idx][row]:p_gold[w.block_id][row];
          if(psum_rsp.e_stream[h]!==activation.scale)$fatal(1,"Attention activation scale alignment");
          for(int n=0;n<16;n++)begin
            dot=0;for(int k=0;k<16;k++)dot+=int'($signed(activation.data[k*8+:8]))*bval(w,psum_rsp.meta.tile_idx,k,n);
            if(psum_rsp.psum[h][n]!==32'(dot)||psum_rsp.e_stat[n]!=bscale(w,psum_rsp.meta.tile_idx,n))$fatal(1,"QK/PV integer dot mismatch");
            x=dq(dot,activation.scale,bscale(w,psum_rsp.meta.tile_idx,n),$signed(psum_rsp.meta.exp_fold));
            if(psum_rsp.meta.add_old)x=fp32_legacy_ref_pkg::fp32_add(w.role==ROLE_V?oacc_gold[row][int'(psum_rsp.meta.nt)*16+n]:partial[psum_rsp.meta.acc_sel][addr][h][n],x);
            partial[psum_rsp.meta.acc_sel][addr][h][n]=x;
            expected.data[h][n]=x;
            if(w.role==ROLE_V)oacc_gold[row][int'(psum_rsp.meta.nt)*16+n]=x;
            else if(psum_rsp.meta.final_k)qk_gold[w.block_id][row][n]=x;
          end
        end
        c_expected[0]=expected;c_meta[0]=psum_rsp.meta;
      end
      #1;
      if(commit_valid!==c_expected_valid[DEQACC_PIPE_STAGES-1])$fatal(1,"Attention DEQACC latency mismatch");
      if(commit_valid)begin
        commits++;if(commit_meta.last)last_cycle[commit_meta.work_seq]=cycle;
        if(commit_meta!==c_meta[DEQACC_PIPE_STAGES-1]||commit_write.sel!==c_expected[DEQACC_PIPE_STAGES-1].sel||
          commit_write.addr!==c_expected[DEQACC_PIPE_STAGES-1].addr||commit_write.row_valid!==c_expected[DEQACC_PIPE_STAGES-1].row_valid)$fatal(1,"Attention C identity mismatch");
        for(int h=0;h<2;h++)if(commit_write.row_valid[h])for(int n=0;n<16;n++)
          if(commit_write.data[h][n]!==c_expected[DEQACC_PIPE_STAGES-1].data[h][n])$fatal(1,"Attention FP32 partial commit mismatch");
      end
    end
  end
  task automatic run_attention(input int m);
    local_object_t object;local_write_t wr;int interval,minimum_gap,maximum_gap;
    @(negedge clk);clear=1;agents=0;repeat(3)@(negedge clk);clear=0;
    rows=m;works=0;issues=0;commits=0;qk_count=0;pv_count=0;v_commands=0;f_commands=0;nontrivial_alpha=0;
    profile_begin_rows=ROW_COUNT_BITS'(m);profile_begin_valid=1;do @(posedge clk);while(!profile_begin_ready);
    @(negedge clk);profile_begin_valid=0;
    for(int r=0;r<m;r++)begin profile_wr_index=ROW_COUNT_BITS'(r);profile_wr_original=ROW_COUNT_BITS'((r*13+7)%51);profile_wr_valid=1;
      do @(posedge clk);while(!profile_wr_ready);@(negedge clk);end
    profile_wr_valid=0;profile_commit_valid=1;do @(posedge clk);while(!profile_commit_ready);@(negedge clk);profile_commit_valid=0;
    job='0;job.op=OP_ATTENTION;job.job_id=16'(jobs+1);job.profile_id=7;job.profile_version=1;job.data_context=55;job.input_version=3;job.output_version=4;
    object='0;object.kind=LOCAL_Q;object.content_version=3;object.data_context=55;object.profile_id=7;object.profile_version=1;object.m_rows=ROW_COUNT_BITS'(m);
    for(int r=0;r<m;r++)begin max_gold[r]=32'hff800000;l_gold[r]=0;for(int n=0;n<256;n++)oacc_gold[r][n]=0;end
    if(m!=0)begin
      local_import_object=object;local_import_valid=1;do @(posedge clk);while(!local_import_ready);@(negedge clk);local_import_valid=0;
      for(int t=0;t<16;t++)for(int g=0;g<(m+2)/3;g++)begin
        wr='0;wr.token=local_import_token;wr.kind=LOCAL_Q;wr.content_version=3;wr.tile=TILE_BITS'(t);wr.mask=a_group_mask(m,g);
        for(int h=0;h<3;h++)if(wr.mask[h])begin
          int r;r=3*g+h;wr.row[h]=ROW_COUNT_BITS'(r);q[t][r].scale=8'(122+(t+r)%3);
          for(int k=0;k<16;k++)q[t][r].data[k*8+:8]=8'(t*31+r*17+k*11+23);
          wr.entry[h]=q[t][r];
        end
        local_import_wr=wr;local_import_wr_valid=1;do @(posedge clk);while(!local_import_wr_ready);@(negedge clk);
      end
      local_import_wr_valid=0;
    end
    agents=1;job_valid=1;@(posedge clk);if(!job_ready)$fatal(1,"Attention parent Job refused");accept_cycle=cycle;
    @(negedge clk);job_valid=0;while(!completion_valid)@(negedge clk);finish_cycle=cycle;
    if(completion.status!=PCORE_OK||completion.empty!=(m==0)||completion.rows!=m)$fatal(1,"Attention completion status");
    if(works!=(m==0?0:110)||issues!=110*16*pairs_for_rows(m)||commits!=issues||qk_count!=(m==0?0:55)||pv_count!=qk_count)$fatal(1,"Full 55 block counts");
    if(m!=0)begin
      if(!qoz_complete||dut.qoz_object.kind!=LOCAL_O||dut.pbuf_active!=0)$fatal(1,"Attention memory retirement");
      for(int t=0;t<16;t++)for(int r=0;r<m;r++)begin
        logic [ROW_BITS-1:0] actual;int address;address=(t+16)*A_ROW_GROUPS+r/3;
        case(r%3)
          0:actual=dut.memory.qoz.storage.banks[0].mem[address];
          1:actual=dut.memory.qoz.storage.banks[1].mem[address];
          2:actual=dut.memory.qoz.storage.banks[2].mem[address];
        endcase
        if(actual!==o_gold[t][r])$fatal(1,"AFIN QOZ result mismatch");
      end
      if(nontrivial_alpha==0)$fatal(1,"Non-unit alpha coverage missing");
      interval=16*(pairs_for_rows(m)<4?4:pairs_for_rows(m))+12;
      minimum_gap=32'h7fffffff;maximum_gap=0;
      for(int i=1;i<110;i++)begin
        if(first_cycle[i]<last_cycle[i-1])$fatal(1,"Next block before old C retirement");
        if(i==109&&first_cycle[i]-first_cycle[i-1]<2*interval)$fatal(1,"PV53/PV54 empty slot missing");
        if(i>=3&&i<109)begin
          int gap;gap=first_cycle[i]-first_cycle[i-1];
          if(gap<minimum_gap)minimum_gap=gap;if(gap>maximum_gap)maximum_gap=gap;
          if(gap>interval+2)$fatal(1,"Steady block interval exceeds target margin M=%0d gap=%0d target=%0d",m,gap,interval);
        end
      end
      $display("CASE ATTENTION M=%0d works=110 commits=%0d parent_cycles=%0d target_slot=%0d steady_min=%0d steady_max=%0d PV53_to_PV54=%0d tail=%0d nonunit_alpha=%0d",m,commits,finish_cycle-accept_cycle,interval,minimum_gap,maximum_gap,first_cycle[109]-first_cycle[108],finish_cycle-last_cycle[109],nontrivial_alpha);
    end
    agents=0;completion_ready=1;@(negedge clk);completion_ready=0;jobs++;
  endtask
  initial begin : main
    int selected_m;
    repeat(32)@(negedge clk);reset=0;
    if($value$plusargs("M=%d",selected_m))begin
      if(selected_m<0||selected_m>51)$fatal(1,"Invalid diagnostic M");run_attention(selected_m);
    end else begin run_attention(0);run_attention(1);run_attention(11);run_attention(51);end
    $display("tb_dynamic_attention PASS jobs=%0d 55_QK_55_PV=1 real_KVB_QOZ_PBUF_ACC=1 nonunit_alpha=1 AFIN=1 simulation_only=1",jobs);$finish;
  end
  initial begin #3000000;$fatal(1,"Full Attention watchdog");end
endmodule
