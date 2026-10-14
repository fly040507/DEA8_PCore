`timescale 1ns/1ps
import pcore_pkg::*;
import dea8_tile_link_pkg::*;
module tb_dynamic_seven_jobs;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,completion_valid,completion_ready=0,busy,flush_request;
  pcore_job_t job='0;pcore_completion_t completion;
  logic [2:0] flush_ack=3'b111;
  logic attn_normal_acc_out_ready=0;
  logic profile_begin_valid=0,profile_begin_ready,profile_wr_valid=0,profile_wr_ready;
  logic profile_commit_valid=0,profile_commit_ready;
  logic [ROW_COUNT_BITS-1:0] profile_begin_rows=0,profile_wr_index=0,profile_wr_original=0;
  logic [15:0] profile_begin_id=7,profile_begin_version=1;
  logic unit_profile_valid=0,unit_profile_ready,unit_profile_out_valid,unit_profile_out_ready=0;
  job_token_t unit_profile_token=0;logic [ROW_COUNT_BITS-1:0] unit_profile_index=0,unit_profile_out_index,unit_profile_original;
  logic source_work_valid,source_work_ready=0;compute_job_t source_work;
  pcore_job_t source_context;
  logic a_desc_valid=0,a_desc_ready,a_in_valid=0,a_in_ready,b_desc_valid=0,b_desc_ready;
  a_slot_desc_t a_desc='0;a3_beat_t a_in='0;b_packet_desc_t b_desc='0;
  logic [1:0] hbm_valid=0,hbm_ready;logic [1:0][B_BEAT_BITS/2-1:0] hbm_data=0;
  b_beat_tag_t hbm_tag[0:1];
  logic unit_cmd_valid,unit_cmd_ready=0,unit_armed_valid=0,unit_armed_ready,unit_go_valid,unit_go_ready=0;
  unit_cmd_t unit_cmd;job_token_t unit_armed_token=0,unit_go_token;
  logic unit_rd_valid=0,unit_rd_ready,unit_out_valid,unit_out_ready=0;
  pair_read_t unit_rd='0;pair_reply_t unit_out_reply;
  logic unit_wr_valid=0,unit_wr_ready,unit_done_valid=0,unit_done_ready,unit_done_error=0;
  local_write_t unit_wr='0;job_token_t unit_done_token=0;
  unit_function_e unit_done_function=UNIT_ROPE_QUANT;
  logic unit_quant_valid=0,unit_quant_ready;
  kv_quant_t unit_quant='0;
  logic kv_hdr_valid,kv_hdr_ready=1,kv_out_valid,kv_out_ready=1,kv_out_last;
  logic kv_commit_valid=0,kv_commit_ready;
  tile_header_t kv_hdr;tile_commit_t kv_commit='0;logic [ROW_BITS-1:0] kv_out;
  logic protocol_error,qoz_complete,issue_valid,psum_valid,commit_valid;
  pair_meta_t issue_meta,commit_meta;mxu_rsp_t psum_rsp;acc_write_t commit_write;
  logic local_import_valid=0,local_import_ready,local_import_wr_valid=0,local_import_wr_ready;
  local_object_t local_import_object='0;job_token_t local_import_token=32'hf0000001;
  local_write_t local_import_wr='0;
  logic reduce_hdr_valid,reduce_hdr_ready=0,reduce_out_valid,reduce_out_ready=0,reduce_out_last;
  tile_header_t reduce_hdr;logic [TILE*FP_BITS-1:0] reduce_out;
  logic function_cmd_valid,function_cmd_ready=0,function_armed_valid=0,function_armed_ready;
  logic function_go_valid,function_go_ready=0,function_data_valid,function_data_ready=0;
  logic function_result_valid=0,function_result_ready,function_done_valid=0,function_done_ready,function_done_error=0;
  unit_cmd_t function_cmd;fp16_stream_t function_data,function_result='0;
  job_token_t function_armed_token=0,function_go_token,function_done_token=0;
  unit_function_e function_done_function=UNIT_GELU;
  logic kv_in_valid=0,kv_in_ready;logic [511:0] kv_in_data=0;b_beat_tag_t kv_in_tag='0;
  logic unit_ws_valid=0,unit_ws_ready,unit_ws_out_valid,unit_ws_out_ready=0;
  workspace_req_t unit_ws='0;workspace_rsp_t unit_ws_out;
  logic function_ws_valid=0,function_ws_ready,function_ws_out_valid,function_ws_out_ready=0;
  sfu_workspace_req_t function_ws='0;sfu_workspace_rsp_t function_ws_out;
  logic unit_acc_valid=0,unit_acc_ready,unit_acc_out_valid,unit_acc_out_ready,unit_acc_wr_valid=0,unit_acc_wr_ready;
  unit_acc_read_t unit_acc='0;unit_acc_reply_t unit_acc_out;unit_acc_write_t unit_acc_wr='0;
  logic function_exp_valid,function_exp_ready,unit_p_valid,unit_p_ready=0;
  fp4_stream_t function_exp,unit_p;
  pcore_top dut(.*);

  int attn_cycle=0,attn_jobs=0,attn_works=0,attn_issues=0,attn_commits=0,attn_qk_count=0,attn_pv_count=0,attn_v_commands=0,attn_f_commands=0;
  int attn_first_cycle[0:109],attn_last_cycle[0:109],attn_accept_cycle,attn_finish_cycle,attn_nontrivial_alpha=0;
  bit attn_agents=0,attn_exp_stream=0;
  bit attn_qk_stream=0;
  unit_cmd_t attn_qk_cmd;
  workspace_req_t attn_score_q;
  logic attn_score_valid=0,attn_score_ready;
  int attn_score_requests=0,attn_score_writes=0;
  logic [31:0] attn_qk_old_m[ROWS],attn_qk_m_new[ROWS],attn_qk_aa_new[ROWS];
  logic [31:0] attn_alpha_cache[0:1][0:ROWS-1];
  int attn_alpha_cache_block[0:1];
  job_token_t attn_parent_token;
  qvec16_t attn_q[0:15][0:ROWS-1],attn_p_gold[0:54][0:ROWS-1],attn_o_gold[0:15][0:ROWS-1];
  logic [31:0] attn_qk_gold[0:54][0:ROWS-1][0:15],attn_oacc_gold[0:ROWS-1][0:255];
  logic [31:0] attn_max_gold[0:ROWS-1],attn_l_gold[0:ROWS-1],attn_alpha_gold[0:54][0:ROWS-1];
  logic [31:0] attn_sf_m[0:ROWS-1];
  logic [31:0] attn_partial[0:2][0:PAIRS*TILE-1][0:1][0:15];
  logic [2:0] attn_exp_pipe_valid=0;fp4_stream_t attn_exp_pipe[0:2];logic [2:0] attn_exp_pipe_ready;
  unit_cmd_t attn_sf_current;
  bit attn_transform_stream=0,attn_transform_final=0;
  unit_cmd_t attn_transform_cmd;
  logic [31:0] attn_transform_factor[ROWS];
  logic [1:0] attn_transform_valid=0,attn_transform_ready;
  unit_acc_write_t attn_transform_pipe[0:1];
  int attn_transform_count=0,attn_transform_requests=0;
  logic [DEQACC_PIPE_STAGES-1:0] attn_c_expected_valid=0;
  acc_write_t attn_c_expected[0:DEQACC_PIPE_STAGES-1];
  pair_meta_t attn_c_meta[0:DEQACC_PIPE_STAGES-1];
  logic [31:0] gold[0:63][0:ROWS-1][0:TILE-1];
  qvec16_t local_gold[0:QOZ_Z_TILES-1][0:ROWS-1];
  logic [31:0] gu_gold[0:1][0:QOZ_Z_TILES-1][0:ROWS-1][0:TILE-1];
  int function_commands=0,gu_overlap=0;
  int reduce_tiles=0,reduce_words=0;
  logic [ROW_BITS-1:0] qgold[0:QOZ_Q_TILES-1][0:ROWS-1];
  int rows=0,seed=0,cycles=0,jobs=0,work_count=0,issue_count=0,psum_count=0,commit_count=0;
  int command_count=0,pair_reads=0,quant_writes=0,overlap=0,compute_overlap=0,profile_checks=0;
  int total_issues=0,total_commits=0,start_cycle=0,negative_checks=0;
  bit stressed=0,allow_error=0,run_agents=0;
  job_token_t parent_token=0;
  logic [ROW_BITS-1:0] kv_gold[0:1][0:V_GROUPS*TILE-1];
  int kv_headers=0,kv_words=0,kv_commits=0,kv_cases=0,identity_checks=0;
  int accept_cycle=0,first_completion_cycle=0;
  function automatic int original(input int r);return (r*13+7)%ROWS;endfunction
  function automatic int av(input int kt,row,k);
    if(job.op==OP_O_PROJ||job.op==OP_DOWN_PROJ)return int'($signed(local_gold[kt][row].data[k*INT_BITS+:INT_BITS]));
    return int'($signed(8'((job.op==OP_GU?kt/2:kt)*31+row*17+k*11+seed*23)));
  endfunction
  function automatic int bv(input int nt,kt,k,n);return int'($signed(8'(nt*7+kt*13+k*29+n*19+seed*3)));endfunction
  function automatic int ea(input int kt,row);
    if(job.op==OP_O_PROJ||job.op==OP_DOWN_PROJ)return int'(local_gold[kt][row].scale);
    return job.op==OP_GU?123+(kt/2+row)%3:130+(kt+row)%4;
  endfunction
  function automatic int eb(input int nt,kt,n);return job.op==OP_GU?122+(nt+kt+n)%3:129+(nt+kt+n)%5;endfunction
  function automatic logic [31:0] gelu(input logic [31:0] g);
    real x,t;x=real32(g);
    if(x>8.0)return g;if(x< -8.0)return 32'd0;
    t=$sqrt(2.0/3.141592653589793)*(x+0.044715*x*x*x);
    return bits(0.5*x*(2.0/(1.0+$exp(-2.0*t))));
  endfunction
  function automatic logic [31:0] dq(input int signed dot,input int ae,be);
    logic [31:0] mag;int lead;mag=dot<0?-dot:dot;lead=0;
    for(int i=0;i<32;i++)if(mag[i])lead=i;
    return fp32_legacy_ref_pkg::pack_scaled32(dot<0,mag<<(31-lead),ae+be-266+lead,mag==0,0);
  endfunction
  function automatic logic [31:0] bits(input real x);shortreal s;s=x;return $shortrealtobits(s);endfunction
  function automatic real real32(input logic [31:0] x);return real'($bitstoshortreal(x));endfunction
  function automatic logic [ROW_BITS-1:0] quant(input logic [TILE-1:0][31:0] x);
    real mx,step,v,f;int e,b,q;logic [DATA_BITS-1:0] data;
    mx=0;for(int n=0;n<TILE;n++)begin v=real32(x[n]);if(v<0)v=-v;if(v>mx)mx=v;end
    step=2.0**(-133);e=0;while(e<254&&mx>127.0*step)begin step*=2.0;e++;end
    data=0;for(int n=0;n<TILE;n++)begin
      v=real32(x[n])/step;b=int'($floor(v));f=v-real'(b);q=b+int'(f>0.5||(f==0.5&&b%2!=0));
      if(q>127)q=127;if(q< -128)q=-128;data[n*INT_BITS+:INT_BITS]=8'(q);
    end
    return {data,8'(e)};
  endfunction
  task automatic rope(input logic [TILE-1:0][31:0] a,b,input int nt,row,
    output logic [TILE-1:0][31:0] x,y);
    real angle;logic [31:0] c,s,p,q;
    for(int n=0;n<TILE;n++)begin
      angle=(int'(job.position_base)+(job.op==OP_K_PROJ?row:original(row)))*
        (10000.0**(-2.0*((job.op==OP_K_PROJ?int'(job.kv_column_base0):nt*TILE)+n)/256.0));
      c=bits($cos(angle));s=bits($sin(angle));
      p=bits(real32(a[n])*real32(c));q=bits(real32(b[n])*real32(s));q[31]=!q[31];
      x[n]=fp32_legacy_ref_pkg::fp32_add(p,q);
      p=bits(real32(b[n])*real32(c));q=bits(real32(a[n])*real32(s));
      y[n]=fp32_legacy_ref_pkg::fp32_add(p,q);
    end
  endtask
  function automatic logic [B_BEAT_BITS-1:0] word_b(input compute_job_t w,input b_packet_desc_t d,input int idx);
    logic [B_BEAT_BITS-1:0] data;int kt,g;data=0;
    if(idx==0)begin
      for(int t=0;t<B_PACKET_MAX_TILES;t++)for(int n=0;n<TILE;n++)
        data[(t*TILE+n)*SCALE_BITS+:SCALE_BITS]=8'(eb(w.nt,d.first_tile+t,n));
    end else begin
      kt=d.first_tile+(idx-1)/B_LOAD_GROUPS;g=(idx-1)%B_LOAD_GROUPS;
      for(int c=0;c<B_LOAD_COLS;c++)for(int k=0;k<TILE;k++)
        data[c*DATA_BITS+k*INT_BITS+:INT_BITS]=8'(bv(w.nt,kt,k,g*B_LOAD_COLS+c));
    end
    return data;
  endfunction
  function automatic logic [$bits(b_beat_tag_t)-1:0] tag_b(input b_packet_desc_t d,input int idx);
    return {d.token,d.work_seq,d.packet_seq,B_BEAT_INDEX_BITS'(idx),(idx==B_PACKET_MAX_TILES*B_LOAD_GROUPS)};
  endfunction
  task automatic produce_a(input compute_job_t w);
    a_slot_desc_t d;a3_beat_t a;
    for(int kt=0;kt<64;kt++)begin
      @(negedge clk);d='0;d.token=w.token;d.work_seq=w.work_seq;d.first_tile=SEQ_BITS'(kt);
      d.first_tile=SEQ_BITS'(job.op==OP_GU?2*kt:kt);
      d.occurrence_seq=SEQ_BITS'(kt);d.m_rows=w.m_rows;d.uses=job.op==OP_GU?2:1;a_desc=d;a_desc_valid=1;
      do @(posedge clk);while(!a_desc_ready);@(negedge clk);a_desc_valid=0;
      for(int g=0;g<(rows+A_INPUT_ROWS-1)/A_INPUT_ROWS;g++)begin
        a='0;a.token=w.token;a.work_seq=w.work_seq;a.occurrence_seq=SEQ_BITS'(kt);
        a.group_idx=A_GROUP_BITS'(g);a.row_valid=a_group_mask(rows,g);
        for(int r=0;r<A_INPUT_ROWS;r++)begin
          a.row[r].scale=8'(ea(job.op==OP_GU?2*kt:kt,g*A_INPUT_ROWS+r));
          for(int k=0;k<TILE;k++)a.row[r].data[k*INT_BITS+:INT_BITS]=8'(av(job.op==OP_GU?2*kt:kt,g*A_INPUT_ROWS+r,k));
        end
        if(stressed&&g%5==2)begin a_in_valid=0;@(negedge clk);end
        a_in=a;a_in_valid=1;do @(posedge clk);while(!a_in_ready);@(negedge clk);
      end
      a_in_valid=0;
    end
  endtask
  task automatic produce_pc(input compute_job_t w,input b_packet_desc_t d,input int pc);
    logic [B_BEAT_BITS-1:0] data;
    for(int i=0;i<=B_PACKET_MAX_TILES*B_LOAD_GROUPS;i++)begin
      @(negedge clk);
      if(stressed&&(i+pc)%5==2)begin hbm_valid[pc]=0;repeat(pc+1)@(negedge clk);end
      data=word_b(w,d,i);hbm_data[pc]=data[pc*(B_BEAT_BITS/2)+:B_BEAT_BITS/2];hbm_tag[pc]=tag_b(d,i);hbm_valid[pc]=1;
      do @(posedge clk);while(!hbm_ready[pc]);
    end
    @(negedge clk);hbm_valid[pc]=0;
  endtask
  task automatic produce_b(input compute_job_t w);
    b_packet_desc_t d;
    for(int kt=0;kt<int'(w.tiles);kt+=B_PACKET_MAX_TILES)begin
      @(negedge clk);d='0;d.token=w.token;d.work_seq=w.work_seq;d.source=B_HBM;d.mode=w.mode;
      d.role=w.role;d.first_tile=SEQ_BITS'(kt);d.packet_seq=SEQ_BITS'(kt/B_PACKET_MAX_TILES);
      b_desc=d;b_desc_valid=1;do @(posedge clk);while(!b_desc_ready);
      @(negedge clk);b_desc_valid=0;fork produce_pc(w,d,0);produce_pc(w,d,1);join
    end
  endtask
  initial forever begin
    compute_job_t w;
    @(negedge clk);
    if(run_agents&&job.op!=OP_ATTENTION&&source_work_valid)begin
      source_work_ready=1;@(posedge clk);w=source_work;
      if(w.work_seq!=work_count||w.nt!=(job.op==OP_Q_PROJ?work_count/2+(work_count%2)*8:work_count)||
        w.tiles!=(job.op==OP_O_PROJ?16:(job.op==OP_DOWN_PROJ?32:(job.op==OP_GU?128:64)))||
        w.m_rows!=rows||w.acc_sel!=(job.op==OP_GU?ACC_FACC_A:acc_sel_e'(work_count%2))||source_context!==job)$fatal(1,"Work geometry/canonical/bank/context");
      if(work_count==0)parent_token=w.token;else if(w.token!=parent_token)$fatal(1,"Q changed parent token");
      work_count++;@(negedge clk);source_work_ready=0;
      if(job.op==OP_O_PROJ||job.op==OP_DOWN_PROJ)produce_b(w);
      else fork produce_a(w);produce_b(w);join
    end
  end
  initial forever begin
    unit_cmd_t c;pair_reply_t reply;
    logic [ROW_BITS-1:0] qa[0:ROWS-1],qb[0:ROWS-1];
    logic [TILE-1:0][31:0] x,y,ga,gb,gx,gy;
    local_write_t wr;int ori;
    @(negedge clk);
    if(run_agents&&job.op!=OP_ATTENTION&&unit_cmd_valid)begin
      unit_cmd_ready=1;@(posedge clk);c=unit_cmd;
      if(job.op==OP_GU)begin
        @(negedge clk);unit_cmd_ready=0;run_gu_unit(c);
      end else if(job.op!=OP_Q_PROJ)begin
        @(negedge clk);unit_cmd_ready=0;run_kv_unit(c);
      end else begin
      if(c.nt0!=command_count||c.nt1!=command_count+8||c.rows!=rows||c.parent_token!=parent_token||
        c.function_id!=UNIT_ROPE_QUANT)$fatal(1,"Q unit descriptor");
      command_count++;@(negedge clk);unit_cmd_ready=0;
      repeat(2)@(negedge clk);unit_armed_token=c.token;unit_armed_valid=1;
      @(posedge clk);if(!unit_armed_ready)$fatal(1,"Q unit armed rejected");
      @(negedge clk);unit_armed_valid=0;unit_go_ready=1;
      do @(posedge clk);while(!unit_go_valid);
      if(unit_go_token!=c.token)$fatal(1,"Q go identity");
      @(negedge clk);unit_go_ready=0;
      for(int r=0;r<rows;r++)begin
        unit_profile_token=c.token;unit_profile_index=ROW_COUNT_BITS'(r);unit_profile_valid=1;
        do @(posedge clk);while(!unit_profile_ready);
        @(negedge clk);unit_profile_valid=0;unit_profile_out_ready=1;
        do @(posedge clk);while(!unit_profile_out_valid);
        ori=unit_profile_original;if(ori!=original(r)||unit_profile_out_index!=r)$fatal(1,"Q original row profile");
        profile_checks++;@(negedge clk);unit_profile_out_ready=0;
        unit_rd.token=c.token;unit_rd.row=ROW_COUNT_BITS'(r);unit_rd_valid=1;
        do @(posedge clk);while(!unit_rd_ready);
        @(negedge clk);unit_rd_valid=0;
        if(stressed&&r%3==1)repeat(3)@(negedge clk);
        unit_out_ready=1;do @(posedge clk);while(!unit_out_valid);reply=unit_out_reply;
        if(reply.request.token!=c.token||reply.request.row!=r)$fatal(1,"Q Pair reply identity");
        for(int n=0;n<TILE;n++)begin
          if(reply.data[0][n]!==gold[c.nt0][r][n]||reply.data[1][n]!==gold[c.nt1][r][n])$fatal(1,"Q Pair actual FP32 operand");
          ga[n]=gold[c.nt0][r][n];gb[n]=gold[c.nt1][r][n];
        end
        pair_reads++;@(negedge clk);unit_out_ready=0;
        rope(reply.data[0],reply.data[1],c.nt0,r,x,y);qa[r]=quant(x);qb[r]=quant(y);
        rope(ga,gb,c.nt0,r,gx,gy);qgold[c.nt0][r]=quant(gx);qgold[c.nt1][r]=quant(gy);
      end
      for(int h=0;h<2;h++)for(int r=0;r<rows;r+=ROW_LANES)begin
        wr='0;wr.token=c.token;wr.kind=LOCAL_Q;wr.content_version=c.output_version;wr.tile=h?c.nt1:c.nt0;
        for(int i=0;i<ROW_LANES;i++)if(r+i<rows)begin wr.mask[i]=1;wr.row[i]=ROW_COUNT_BITS'(r+i);wr.entry[i]=h?qb[r+i]:qa[r+i];end
        if(stressed&&r%6==0)repeat(2)@(negedge clk);
        unit_wr=wr;unit_wr_valid=1;do @(posedge clk);while(!unit_wr_ready);quant_writes++;
        @(negedge clk);unit_wr_valid=0;
      end
      unit_done_token=c.token;unit_done_function=c.function_id;unit_done_valid=1;
      @(posedge clk);if(!unit_done_ready)$fatal(1,"Q unit done rejected");
      @(negedge clk);unit_done_valid=0;
      end
    end
  end
  task automatic run_gu_unit(input unit_cmd_t c);
    pair_reply_t reply;logic [TILE-1:0][31:0] z,gz;
    qvec16_t q[0:ROWS-1];local_write_t wr;
    if(c.function_id!=UNIT_GU_MUL_QUANT||c.nt0!=command_count||c.nt1!=c.nt0||c.rows!=rows||c.parent_token!=parent_token)$fatal(1,"GU VPU descriptor");
    command_count++;repeat(2)@(negedge clk);unit_armed_token=c.token;unit_armed_valid=1;
    do @(posedge clk);while(!unit_armed_ready);@(negedge clk);unit_armed_valid=0;unit_go_ready=1;
    do @(posedge clk);while(!unit_go_valid);@(negedge clk);unit_go_ready=0;
    for(int r=0;r<rows;r++)begin
      unit_out_ready=1;do @(posedge clk);while(!unit_out_valid);reply=unit_out_reply;
      if(reply.request.token!=c.token||reply.request.row!=r)$fatal(1,"GU join token/row");
      for(int n=0;n<TILE;n++)begin
        if(reply.data[0][n]!==gelu(gu_gold[0][c.nt0][r][n])||reply.data[1][n]!==gu_gold[1][c.nt0][r][n])$fatal(1,"GU actual GELU/Up join");
        z[n]=bits(real32(reply.data[0][n])*real32(reply.data[1][n]));
        gz[n]=bits(real32(gelu(gu_gold[0][c.nt0][r][n]))*real32(gu_gold[1][c.nt0][r][n]));
      end
      q[r]=quant(z);local_gold[c.nt0][r]=quant(gz);pair_reads++;
      @(negedge clk);unit_out_ready=0;if(stressed&&r%9==3)repeat(2)@(negedge clk);
    end
    for(int r=0;r<rows;r+=ROW_LANES)begin
      wr='0;wr.token=c.token;wr.kind=LOCAL_Z;wr.content_version=c.output_version;wr.tile=c.nt0;
      for(int h=0;h<ROW_LANES;h++)if(r+h<rows)begin wr.mask[h]=1;wr.row[h]=ROW_COUNT_BITS'(r+h);wr.entry[h]=q[r+h];end
      unit_wr=wr;unit_wr_valid=1;do @(posedge clk);while(!unit_wr_ready);quant_writes++;
      @(negedge clk);unit_wr_valid=0;
    end
    unit_done_token=c.token;unit_done_function=c.function_id;unit_done_valid=1;
    @(posedge clk);if(!unit_done_ready)$fatal(1,"GU VPU done refused");@(negedge clk);unit_done_valid=0;
  endtask
  initial forever begin
    unit_cmd_t c;fp16_stream_t g,result;
    @(negedge clk);
    if(run_agents&&job.op==OP_GU&&function_cmd_valid)begin
      function_cmd_ready=1;@(posedge clk);c=function_cmd;
      if(c.function_id!=UNIT_GELU||c.nt0!=function_commands||c.rows!=rows||c.parent_token!=parent_token)$fatal(1,"GU SFU descriptor");
      function_commands++;@(negedge clk);function_cmd_ready=0;
      repeat(3)@(negedge clk);function_armed_token=c.token;function_armed_valid=1;
      do @(posedge clk);while(!function_armed_ready);@(negedge clk);function_armed_valid=0;function_go_ready=1;
      do @(posedge clk);while(!function_go_valid);@(negedge clk);function_go_ready=0;
      for(int r=0;r<rows;r++)begin
        function_data_ready=1;do @(posedge clk);while(!function_data_valid);g=function_data;
        if(g.row!=r||g.token!=c.token||g.mask!='1||g.last!=(r==rows-1))$fatal(1,"GU Gate stream identity");
        result=g;for(int n=0;n<TILE;n++)begin
          if(g.data[n]!==gu_gold[0][c.nt0][r][n])$fatal(1,"GU actual Gate final accumulation");
          result.data[n]=gelu(g.data[n]);
        end
        @(negedge clk);function_data_ready=0;
        // Four SFU lanes service sixteen values, plus two pipeline cycles.
        repeat(TILE/4+2)@(negedge clk);
        function_result=result;function_result_valid=1;
        do @(posedge clk);while(!function_result_ready);@(negedge clk);function_result_valid=0;
      end
      repeat(3)@(negedge clk);function_done_token=c.token;function_done_function=c.function_id;function_done_valid=1;
      @(posedge clk);if(!function_done_ready)$fatal(1,"GU SFU done refused");@(negedge clk);function_done_valid=0;
    end
  end
  task automatic run_kv_unit(input unit_cmd_t c);
    pair_reply_t reply;kv_quant_t packet;
    qvec16_t qa[0:ROWS-1],qb[0:ROWS-1];
    logic [TILE-1:0][31:0] x,y,gx,gy,ga,gb;
    int count,nt,r,col;
    if(c.parent_token!=parent_token||c.rows!=ROWS||!c.identity_rows||
       c.function_id!=(job.op==OP_K_PROJ?UNIT_ROPE_QUANT:UNIT_V_QUANT)||
       c.nt0!=(job.op==OP_K_PROJ?0:command_count)||c.nt1!=(job.op==OP_K_PROJ?1:command_count)||
       c.column_base0!=(c.nt0==0?job.kv_column_base0:job.kv_column_base1)||
       c.column_base1!=(job.op==OP_K_PROJ?job.kv_column_base1:c.column_base0))$fatal(1,"KV unit coordinates/identity");
    command_count++;
    repeat(3)@(negedge clk);unit_armed_token=c.token;unit_armed_valid=1;
    @(posedge clk);if(!unit_armed_ready)$fatal(1,"KV armed refused");
    @(negedge clk);unit_armed_valid=0;unit_go_ready=1;
    do @(posedge clk);while(!unit_go_valid);
    if(unit_go_token!=c.token)$fatal(1,"KV go token");
    @(negedge clk);unit_go_ready=0;
    count=job.op==OP_K_PROJ?ROWS:V_PACKETS_PER_TILE;
    for(int j=0;j<count;j++)begin
      if(job.op==OP_K_PROJ)begin
        unit_profile_valid=1;unit_profile_token=c.token;unit_profile_index=ROW_COUNT_BITS'(j);
        do @(posedge clk);while(!unit_profile_ready);
        @(negedge clk);unit_profile_valid=0;unit_profile_out_ready=1;
        do @(posedge clk);while(!unit_profile_out_valid);
        if(unit_profile_original!=j||unit_profile_out_index!=j)$fatal(1,"K identity map depends on dynamic profile");
        identity_checks++;@(negedge clk);unit_profile_out_ready=0;
      end
      unit_rd.token=c.token;unit_rd.row=ROW_COUNT_BITS'(j);unit_rd_valid=1;
      do @(posedge clk);while(!unit_rd_ready);
      @(negedge clk);unit_rd_valid=0;
      if(stressed&&j%4==1)repeat(3)@(negedge clk);
      unit_out_ready=1;do @(posedge clk);while(!unit_out_valid);reply=unit_out_reply;
      if(reply.request.token!=c.token||reply.request.row!=j)$fatal(1,"KV Pair response metadata");
      for(int n=0;n<TILE;n++)begin
        if(job.op==OP_K_PROJ)begin ga[n]=gold[0][j][n];gb[n]=gold[1][j][n];end
        else begin
          r=j/(TILE/ROW_LANES)*TILE+n;col=j%(TILE/ROW_LANES)*ROW_LANES;
          ga[n]=r<ROWS?gold[c.nt0][r][col]:0;gb[n]=r<ROWS?gold[c.nt0][r][col+1]:0;
        end
        if(reply.data[0][n]!==ga[n]||reply.data[1][n]!==gb[n])$fatal(1,"KV actual Pair operands/transpose j=%0d n=%0d",j,n);
      end
      pair_reads++;@(negedge clk);unit_out_ready=0;
      if(job.op==OP_K_PROJ)begin
        rope(reply.data[0],reply.data[1],0,j,x,y);qa[j]=quant(x);qb[j]=quant(y);
        rope(ga,gb,0,j,gx,gy);
      end else begin qa[j]=quant(reply.data[0]);qb[j]=quant(reply.data[1]);gx=ga;gy=gb;end
      begin
        qvec16_t g0,g1;g0=quant(gx);g1=quant(gy);
        if(job.op==OP_K_PROJ)begin
          kv_gold[0][j]={g0.scale,g0.data};kv_gold[1][j]={g1.scale,g1.data};
        end else begin kv_gold[c.nt0][j*2]={g0.scale,g0.data};kv_gold[c.nt0][j*2+1]={g1.scale,g1.data};end
      end
    end
    for(int h=0;h<(job.op==OP_K_PROJ?2:1);h++)for(int j=0;j<(job.op==OP_K_PROJ?PAIRS:V_PACKETS_PER_TILE);j++)begin
      packet='0;packet.token=c.token;packet.tile=job.op==OP_K_PROJ?TILE_BITS'(h):c.nt0;
      packet.index=6'(j);packet.mask=job.op==OP_K_PROJ?row_mask_for_rows(ROWS,j):2'b11;
      packet.token_mask='1;packet.last=j==(job.op==OP_K_PROJ?PAIRS-1:V_PACKETS_PER_TILE-1);
      for(int i=0;i<ROW_LANES;i++)if(packet.mask[i])packet.entry[i]=job.op==OP_K_PROJ?
        (h?qb[j*ROW_LANES+i]:qa[j*ROW_LANES+i]):(i?qb[j]:qa[j]);
      if(job.op==OP_V_PROJ)for(int i=0;i<TILE;i++)packet.token_mask[i]=j/(TILE/ROW_LANES)*TILE+i<ROWS;
      unit_quant=packet;unit_quant_valid=1;do @(posedge clk);while(!unit_quant_ready);
      quant_writes++;@(negedge clk);unit_quant_valid=0;
    end
    unit_done_token=c.token;unit_done_function=c.function_id;unit_done_valid=1;
    @(posedge clk);if(!unit_done_ready)$fatal(1,"KV unit done refused");
    @(negedge clk);unit_done_valid=0;
  endtask
  initial forever begin
    tile_header_t h;int words;
    @(negedge clk);
    if(run_agents&&job.op!=OP_Q_PROJ&&kv_hdr_valid)begin
      kv_hdr_ready=0;h=kv_hdr;
      repeat(4)begin @(negedge clk);if(!kv_hdr_valid||kv_hdr!==h)$fatal(1,"KV header hold");end
      if(h.transfer_id!=job.transfer_context||h.transfer_epoch!=job.transfer_epoch||
         h.destination_id!=job.data_context||h.rows!=ROWS||h.columns!=TILE||h.source_id!=job.core_id||
         h.tile_seq!=kv_headers||h.column_base!=(kv_headers==0?job.kv_column_base0:job.kv_column_base1)||
         h.kind!=(job.op==OP_K_PROJ?TILE_K:TILE_V)||h.layout!=(job.op==OP_K_PROJ?LAYOUT_K_ROWS:LAYOUT_V_GROUPS)||
         h.reserved!=0||h.token_origin!=0)$fatal(1,"KV header identity/coordinates");
      kv_hdr_ready=1;@(posedge clk);@(negedge clk);kv_hdr_ready=0;kv_headers++;
      words=job.op==OP_K_PROJ?ROWS:V_GROUPS*TILE;
      for(int i=0;i<words;i++)begin
        logic [ROW_BITS-1:0] held;
        kv_out_ready=0;while(!kv_out_valid)@(negedge clk);held=kv_out;
        if(i%7==3)repeat(3)begin @(negedge clk);if(!kv_out_valid||kv_out!==held||kv_out_last!=(i==words-1))$fatal(1,"KV data hold");end
        if(kv_out!==kv_gold[h.tile_seq][i]||kv_out_last!=(i==words-1))$fatal(1,"KV numerical INT8/scale/last nt=%0d word=%0d got=%h expected=%h",h.tile_seq,i,kv_out,kv_gold[h.tile_seq][i]);
        kv_out_ready=1;@(posedge clk);kv_words++;@(negedge clk);kv_out_ready=0;
      end
      repeat(43)begin @(negedge clk);if(completion_valid||!dut.output_stage.sender.busy)$fatal(1,"KV completed/reused before commit");end
      kv_commit='0;kv_commit.transfer_id=h.transfer_id;kv_commit.transfer_epoch=h.transfer_epoch;
      kv_commit.source_id=h.source_id;kv_commit.tile_seq=h.tile_seq;kv_commit_valid=1;
      @(posedge clk);if(!kv_commit_ready)$fatal(1,"KV commit refused");
      kv_commits++;@(negedge clk);kv_commit_valid=0;
    end
  end
  always @(posedge clk)begin
    int dot,row,nt,kt;logic [31:0] expected;
    cycles++;
    if(run_agents&&cycles%20000==0)$display("CONTROL_PROGRESS cycle=%0d op=%0d M=%0d works=%0d commits=%0d VPU=%0d SFU=%0d",cycles,job.op,rows,work_count,commit_count,command_count,function_commands);
    if(job_valid&&job_ready)begin accept_cycle=cycles;first_completion_cycle=0;end
    if(completion_valid&&first_completion_cycle==0)first_completion_cycle=cycles;
    if(!reset&&!flush_request&&issue_valid)begin
      issue_count++;total_issues++;if(dut.post.unit_running)compute_overlap++;
      if(job.op==OP_GU&&dut.post.unit_running)gu_overlap++;
    end
    if(!reset&&!flush_request&&dut.matrix_busy&&dut.post.unit_running)overlap++;
    #1;
    if(!reset&&!flush_request&&job.op==OP_ATTENTION&&commit_valid)begin total_commits++;end
    if(protocol_error&&!allow_error)$fatal(1,"Q top fault matrix=%b scheduler=%b reader=%b post=%b pair=%b memory=%b",dut.matrix_error,dut.scheduler_error,dut.reader_error,dut.post_error,dut.post.pair_error,dut.memory_error);
    if(!reset&&!flush_request&&job.op!=OP_ATTENTION&&psum_valid)begin
      nt=psum_rsp.meta.nt;kt=psum_rsp.meta.tile_idx;
      if(psum_rsp.meta.token!=parent_token||psum_rsp.row_valid!=row_mask_for_rows(rows,psum_rsp.meta.pair_idx))$fatal(1,"Q Psum metadata");
      for(int r=0;r<ROW_LANES;r++)for(int n=0;n<TILE;n++)begin
        row=int'(psum_rsp.meta.pair_idx)*ROW_LANES+r;dot=0;
        if(row<rows)for(int k=0;k<TILE;k++)dot+=av(kt,row,k)*bv(nt,kt,k,n);
        if(psum_rsp.psum[r][n]!==32'(dot)||psum_rsp.e_stat[n]!=eb(nt,kt,n)||
          psum_rsp.e_stream[r]!=(row<rows?ea(kt,row):0))$fatal(1,"Q Psum/scale");
      end
      psum_count++;
    end
    if(!reset&&!flush_request&&job.op!=OP_ATTENTION&&commit_valid)begin
      nt=commit_meta.nt;kt=commit_meta.tile_idx;
      if(commit_meta.add_old!=(job.op==OP_GU?kt>=2:kt!=0)||
        commit_meta.final_k!=(job.op==OP_GU?kt>=126:kt==(job.op==OP_O_PROJ?15:(job.op==OP_DOWN_PROJ?31:63)))||commit_meta.token!=parent_token||
        commit_write.sel!=acc_sel_e'(job.op==OP_GU?kt%2:int'(commit_meta.work_seq)%2))$fatal(1,"Commit metadata");
      for(int r=0;r<ROW_LANES;r++)if(commit_write.row_valid[r])for(int n=0;n<TILE;n++)begin
        row=int'(commit_meta.pair_idx)*ROW_LANES+r;dot=0;for(int k=0;k<TILE;k++)dot+=av(kt,row,k)*bv(nt,kt,k,n);
        expected=dq(dot,ea(kt,row),eb(nt,kt,n));
        if(job.op==OP_GU)begin if(kt>=2)expected=fp32_legacy_ref_pkg::fp32_add(gu_gold[kt%2][nt][row][n],expected);end
        else if(kt!=0)expected=fp32_legacy_ref_pkg::fp32_add(gold[nt][row][n],expected);
        if(commit_write.data[r][n]!==expected)$fatal(1,"Q FP32 ordered accumulation nt=%0d kt=%0d row=%0d n=%0d",nt,kt,row,n);
        if(job.op==OP_GU)gu_gold[kt%2][nt][row][n]=expected;else gold[nt][row][n]=expected;
      end
      commit_count++;total_commits++;
    end
  end
  task automatic flush;
    @(negedge clk);clear=1;run_agents=0;
    @(negedge clk);clear=0;
    while(flush_request)@(negedge clk);
    repeat(2)@(negedge clk);
    if(busy||protocol_error||qoz_complete)$fatal(1,"Q top flush");
  endtask
  task automatic seed_local(input local_kind_e kind);
    local_object_t o;local_write_t w;
    o='0;o.kind=kind;o.content_version=9;o.data_context=55;o.profile_id=7;o.profile_version=1;o.m_rows=ROW_COUNT_BITS'(rows);
    @(negedge clk);local_import_object=o;local_import_valid=1;
    @(posedge clk);if(!local_import_ready)$fatal(1,"Local import object refused");
    @(negedge clk);local_import_valid=0;
    for(int nt=0;nt<(kind==LOCAL_O?16:32);nt++)for(int r=0;r<rows;r+=A_INPUT_ROWS)begin
      w='0;w.token=local_import_token;w.kind=kind;w.content_version=9;w.tile=TILE_BITS'(nt);
      for(int h=0;h<A_INPUT_ROWS;h++)if(r+h<rows)begin
        qvec16_t q;q='0;q.scale=8'(130+(nt+r+h)%4);
        for(int k=0;k<TILE;k++)q.data[k*INT_BITS+:INT_BITS]=8'(nt*31+(r+h)*17+k*11);
        local_gold[nt][r+h]=q;w.mask[h]=1;w.row[h]=ROW_COUNT_BITS'(r+h);w.entry[h]=q;
      end
      local_import_wr=w;local_import_wr_valid=1;@(posedge clk);if(!local_import_wr_ready)$fatal(1,"Local import payload refused");
      @(negedge clk);local_import_wr_valid=0;
    end
    if(!qoz_complete)$fatal(1,"Local import incomplete");
  endtask
  task automatic run_local_projection(input pcore_op_e op,input int m,input bit linked=0);
    if(!linked)begin flush();configure(m);end
    stressed=1;seed=jobs;
    work_count=0;issue_count=0;psum_count=0;commit_count=0;command_count=0;reduce_tiles=0;reduce_words=0;
    if(m!=0&&!linked)seed_local(op==OP_O_PROJ?LOCAL_O:LOCAL_Z);
    for(int nt=0;nt<64;nt++)for(int r=0;r<ROWS;r++)for(int n=0;n<TILE;n++)gold[nt][r][n]=0;
    @(negedge clk);job='0;job.op=op;job.job_id=16'(jobs+1);job.profile_id=7;job.profile_version=1;
    job.data_context=55;job.input_version=op==OP_O_PROJ?4:9;job.transfer_context=19;job.transfer_epoch=22;
    run_agents=1;job_valid=1;@(posedge clk);if(!job_ready)$fatal(1,"Local Projection job refused");
    @(negedge clk);job_valid=0;complete_check(PCORE_OK,m==0);run_agents=0;
    if(work_count!=(m==0?0:64)||issue_count!=(op==OP_O_PROJ?1024:2048)*pairs_for_rows(m)||
      psum_count!=issue_count||commit_count!=issue_count||reduce_tiles!=(m==0?0:64)||reduce_words!=64*m||
      dut.qoz_active||command_count!=0)$fatal(1,"Local Projection completion counts/release");
    $display("CASE LOCAL_PROJECTION op=%0d M=%0d works=%0d commits=%0d FP32_rows=%0d accept_to_completion_cycles=%0d",op,m,work_count,commit_count,reduce_words,first_completion_cycle-accept_cycle);
    jobs++;
  endtask
  task automatic run_gu(input int m);
    int address;logic [ROW_BITS-1:0] actual;
    rows=m;stressed=1;seed=jobs;
    work_count=0;issue_count=0;psum_count=0;commit_count=0;command_count=0;function_commands=0;pair_reads=0;quant_writes=0;
    for(int nt=0;nt<32;nt++)for(int r=0;r<ROWS;r++)for(int n=0;n<TILE;n++)for(int h=0;h<2;h++)gu_gold[h][nt][r][n]=0;
    @(negedge clk);job='0;job.op=OP_GU;job.job_id=16'(jobs+1);job.profile_id=7;job.profile_version=1;
    job.data_context=55;job.output_version=9;run_agents=1;job_valid=1;
    @(posedge clk);if(!job_ready)$fatal(1,"GU Job refused");@(negedge clk);job_valid=0;
    complete_check(PCORE_OK,m==0);run_agents=0;
    if(work_count!=(m==0?0:32)||issue_count!=4096*pairs_for_rows(m)||commit_count!=issue_count||psum_count!=issue_count||
      command_count!=(m==0?0:32)||function_commands!=command_count||pair_reads!=32*m)$fatal(1,"GU job counts");
    if(m!=0)begin
      if(!qoz_complete||dut.qoz_object.kind!=LOCAL_Z||dut.post.pair_active)$fatal(1,"GU Z region incomplete");
      for(int nt=0;nt<32;nt++)for(int r=0;r<m;r++)begin
        address=nt*A_ROW_GROUPS+r/A_INPUT_ROWS;
        case(r%A_INPUT_ROWS)
          0:actual=dut.memory.qoz.storage.banks[0].mem[address];
          1:actual=dut.memory.qoz.storage.banks[1].mem[address];
          2:actual=dut.memory.qoz.storage.banks[2].mem[address];
        endcase
        if(actual!==local_gold[nt][r])$fatal(1,"GU numerical Z/scale nt=%0d row=%0d",nt,r);
      end
    end
    $display("CASE GU M=%0d works=%0d commits=%0d VPU_commands=%0d SFU_commands=%0d accept_to_completion_cycles=%0d",m,work_count,commit_count,command_count,function_commands,first_completion_cycle-accept_cycle);
    jobs++;
  endtask
  initial forever begin
    tile_header_t h;
    @(negedge clk);
    if(run_agents&&(job.op==OP_O_PROJ||job.op==OP_DOWN_PROJ)&&reduce_hdr_valid)begin
      h=reduce_hdr;
      repeat(3)begin @(negedge clk);if(reduce_hdr!==h||!reduce_hdr_valid)$fatal(1,"Reduce header hold");end
      if(h.rows!=rows||h.tile_seq!=reduce_tiles||h.column_base!=reduce_tiles*TILE||h.layout!=LAYOUT_FP_ROWS||
        h.kind!=(job.op==OP_O_PROJ?TILE_O:TILE_DOWN)||h.transfer_epoch!=job.transfer_epoch)$fatal(1,"Reduce header context");
      reduce_hdr_ready=1;@(posedge clk);@(negedge clk);reduce_hdr_ready=0;
      for(int r=0;r<rows;r++)begin
        logic [TILE*FP_BITS-1:0] held;
        while(!reduce_out_valid)@(negedge clk);held=reduce_out;
        if(stressed&&r%7==3)repeat(3)begin @(negedge clk);if(!reduce_out_valid||reduce_out!==held)$fatal(1,"Reduce row hold");end
        for(int n=0;n<TILE;n++)if(reduce_out[n*FP_BITS+:FP_BITS]!==gold[h.tile_seq][r][n])$fatal(1,"Reduce actual partial nt=%0d row=%0d col=%0d",h.tile_seq,r,n);
        if(reduce_out_last!=(r==rows-1))$fatal(1,"Reduce last row");
        reduce_out_ready=1;@(posedge clk);reduce_words++;@(negedge clk);reduce_out_ready=0;
      end
      reduce_tiles++;
    end
  end
  task automatic run_kv(input pcore_op_e op,input int profile_m,input bit preserve_q);
    logic [ROW_BITS-1:0] saved,actual;int address;
    if(preserve_q)begin
      if(!qoz_complete)$fatal(1,"KV fixture Q not live");saved=dut.memory.qoz.storage.banks[0].mem[0];
    end
    rows=ROWS;seed=jobs;stressed=1;
    work_count=0;issue_count=0;psum_count=0;commit_count=0;command_count=0;pair_reads=0;quant_writes=0;
    kv_headers=0;kv_words=0;kv_commits=0;
    for(int nt=0;nt<2;nt++)for(int r=0;r<ROWS;r++)for(int n=0;n<TILE;n++)gold[nt][r][n]=0;
    @(negedge clk);job='0;job.op=op;job.job_id=16'(jobs+1);job.user_tag=32'hcc000000+32'(jobs);
    job.position_base=17;job.kv_column_base0=48;job.kv_column_base1=op==OP_K_PROJ?176:64;
    job.feature_context=42;job.transfer_context=16'(jobs+33);job.data_context=16'(jobs+70);
    job.transfer_epoch=16'h7788;
    job.profile_id=7;job.profile_version=1;job.output_version=16'(jobs+1);
    run_agents=1;job_valid=1;@(posedge clk);if(!job_ready)$fatal(1,"KV Job refused");
    @(negedge clk);job_valid=0;complete_check(PCORE_OK,0);run_agents=0;
    if(completion.rows!=ROWS||work_count!=2||issue_count!=128*PAIRS||psum_count!=issue_count||commit_count!=issue_count||
       command_count!=(op==OP_K_PROJ?1:2)||pair_reads!=(op==OP_K_PROJ?ROWS:2*V_PACKETS_PER_TILE)||
       kv_headers!=2||kv_commits!=2||kv_words!=(op==OP_K_PROJ?2*ROWS:2*V_GROUPS*TILE)||dut.post.pair_active)
      $fatal(1,"KV complete work/post/output counts");
    if(preserve_q)begin
      actual=dut.memory.qoz.storage.banks[0].mem[0];
      if(actual!==saved||!qoz_complete)$fatal(1,"KV damaged live QOZ");
      for(int nt=0;nt<16;nt++)begin
        address=nt*A_ROW_GROUPS;
        if(dut.memory.qoz.storage.banks[0].mem[address]!==qgold[nt][0])$fatal(1,"KV changed QOZ Tile");
      end
    end else if(qoz_complete||dut.qoz_active)$fatal(1,"KV acquired a QOZ region");
    $display("CASE KV_PROJECTION op=%0d profile_M=%0d effective_rows=51 works=%0d commits=%0d KV_words=%0d accept_to_completion_cycles=%0d live_Q_preserved=%0d",op,profile_m,work_count,commit_count,kv_words,first_completion_cycle-accept_cycle,preserve_q);
    jobs++;kv_cases++;
  endtask
  task automatic configure(input int m);
    rows=m;
    @(negedge clk);profile_begin_rows=ROW_COUNT_BITS'(m);profile_begin_valid=1;
    @(posedge clk);if(!profile_begin_ready)$fatal(1,"Q profile begin");
    @(negedge clk);profile_begin_valid=0;
    for(int r=0;r<m;r++)begin
      profile_wr_index=ROW_COUNT_BITS'(r);profile_wr_original=ROW_COUNT_BITS'(original(r));profile_wr_valid=1;
      @(posedge clk);if(!profile_wr_ready)$fatal(1,"Q profile write");@(negedge clk);
    end
    profile_wr_valid=0;profile_commit_valid=1;
    @(posedge clk);if(!profile_commit_ready)$fatal(1,"Q profile commit");
    @(negedge clk);profile_commit_valid=0;
  endtask
  task automatic submit;
    @(negedge clk);job='0;job.op=OP_Q_PROJ;job.job_id=16'(jobs+1);job.user_tag=32'hacc00000+32'(jobs);
    job.profile_id=7;job.profile_version=1;job.position_base=10;job.output_version=16'(jobs+1);
    job.data_context=55;job_valid=1;
    @(posedge clk);if(!job_ready)$fatal(1,"Q external job");@(negedge clk);job_valid=0;
  endtask
  task automatic complete_check(input pcore_status_e status,input bit empty);
    pcore_completion_t c;
    while(!completion_valid)@(negedge clk);c=completion;
    if(c.status!=status||c.empty!=empty||c.job_id!=job.job_id||c.user_tag!=job.user_tag)$fatal(1,"Q final completion");
    repeat(4)begin @(negedge clk);if(completion!==c||!completion_valid||job_ready)$fatal(1,"Q completion changed under backpressure");end
    completion_ready=1;@(negedge clk);completion_ready=0;
  endtask
  task automatic run_q(input int m,input bit stress);
    logic [ROW_BITS-1:0] actual;int address;
    rows=m;seed=jobs;stressed=stress;
    work_count=0;issue_count=0;psum_count=0;commit_count=0;command_count=0;pair_reads=0;quant_writes=0;
    for(int nt=0;nt<16;nt++)for(int r=0;r<ROWS;r++)begin qgold[nt][r]=0;for(int n=0;n<TILE;n++)gold[nt][r][n]=0;end
    run_agents=1;start_cycle=cycles;submit();complete_check(PCORE_OK,m==0);run_agents=0;
    if(issue_count!=1024*pairs_for_rows(m)||psum_count!=issue_count||commit_count!=issue_count||
      work_count!=(m==0?0:16)||command_count!=(m==0?0:8)||pair_reads!=8*m)
      $fatal(1,"Q complete counts M=%0d work=%0d issues=%0d units=%0d",m,work_count,issue_count,command_count);
    if(m!=0)begin
      if(!qoz_complete||dut.post.pair_active)$fatal(1,"Q completed before store/Pair fences");
      for(int nt=0;nt<16;nt++)for(int r=0;r<m;r++)begin
        address=nt*A_ROW_GROUPS+r/A_INPUT_ROWS;
        case(r%A_INPUT_ROWS)
          0:actual=dut.memory.qoz.storage.banks[0].mem[address];
          1:actual=dut.memory.qoz.storage.banks[1].mem[address];
          2:actual=dut.memory.qoz.storage.banks[2].mem[address];
        endcase
        if(actual!==qgold[nt][r])$fatal(1,"QOZ actual INT8/scale at canonical nt=%0d row=%0d",nt,r);
      end
      // Rejections remain covered by the isolated Q regression.
    end else if(qoz_complete||dut.qoz_active)$fatal(1,"Empty Q created a region");
    $display("CASE Q_PROJECTION M=%0d stress=%0d matrix_works=%0d issues=%0d commits=%0d unit_commands=%0d quant_beats=%0d cycles_with_done_hold=%0d",m,stress,work_count,issue_count,commit_count,command_count,quant_writes,cycles-start_cycle);
    jobs++;
  endtask
  function automatic logic [31:0] attn_mul(input logic [31:0] a,b);return bits(real32(a)*real32(b));endfunction
  function automatic logic [31:0] attn_dq(input int dot,input int ea,eb,fold);
    logic [31:0] mag;int lead;mag=dot<0?-dot:dot;lead=0;
    for(int i=0;i<32;i++)if(mag[i])lead=i;
    return fp32_legacy_ref_pkg::pack_scaled32(dot<0,mag<<(31-lead),ea+eb+fold-266+lead,mag==0,0);
  endfunction
  function automatic int attn_bval(input compute_job_t w,input int t,k,n);
    return int'($signed(8'(w.block_id*7+t*13+k*5+n*11+(w.role==ROLE_V?3:0))));
  endfunction
  function automatic int attn_bscale(input compute_job_t w,input int t,n);return 123+(w.block_id+t+n)%3;endfunction
  function automatic logic [ROW_BITS-1:0] attn_quantize(input logic [15:0][31:0] x);
    real mx,step,v,f;int e,b,qv;logic [127:0] data;
    mx=0;for(int n=0;n<16;n++)begin v=real32(x[n]);if(v<0)v=-v;if(v>mx)mx=v;end
    step=2.0**(-133);e=0;while(e<254&&mx>127*step)begin step*=2;e++;end
    data=0;for(int n=0;n<16;n++)begin
      v=real32(x[n])/step;b=int'($floor(v));f=v-b;qv=b+int'(f>0.5||(f==0.5&&b%2!=0));
      if(qv>127)qv=127;if(qv< -128)qv=-128;data[n*8+:8]=8'(qv);
    end
    return {data,8'(e)};
  endfunction
  function automatic logic [15:0] attn_mask16(input int base,limit);
    logic [15:0] result;for(int i=0;i<16;i++)result[i]=base+i<limit;return result;
  endfunction
  function automatic logic [3:0] attn_mask4(input int base,limit);
    logic [3:0] result;for(int i=0;i<4;i++)result[i]=base+i<limit;return result;
  endfunction

  // A three-stage, four-lane SFU model, with elastic output and real workspace
  // reads. It cannot produce more than four exponentials in a clock.
  assign attn_exp_pipe_ready[2]=!attn_exp_pipe_valid[2]||function_exp_ready;
  assign attn_exp_pipe_ready[1]=!attn_exp_pipe_valid[1]||attn_exp_pipe_ready[2];
  assign attn_exp_pipe_ready[0]=!attn_exp_pipe_valid[0]||attn_exp_pipe_ready[1];
  assign function_exp_valid=attn_exp_stream&&attn_exp_pipe_valid[2];
  assign function_exp=attn_exp_pipe[2];
  always @(posedge clk)begin
    fp4_stream_t entry;
    if(reset||clear||!attn_exp_stream)attn_exp_pipe_valid<=0;
    else begin
      for(int s=2;s>0;s--)if(attn_exp_pipe_ready[s])begin attn_exp_pipe_valid[s]<=attn_exp_pipe_valid[s-1];attn_exp_pipe[s]<=attn_exp_pipe[s-1];end
      if(attn_exp_pipe_ready[0])begin
        attn_exp_pipe_valid[0]<=function_ws_out_valid&&function_ws_out_ready;
        if(function_ws_out_valid&&function_ws_out_ready)begin
          if(function_ws_out.kind!=WS_SCORE||function_ws_out.token!=attn_sf_current.token)$fatal(1,"SFU Score response identity");
          entry='0;entry.token=attn_sf_current.token;entry.row=function_ws_out.index;entry.group_id=function_ws_out.group_id;entry.mask=4'hf;
          entry.last=int'(entry.row)==rows-1&&entry.group_id==3;
          for(int n=0;n<4;n++)entry.data[n]=bits($exp(real32(function_ws_out.data[n])-real32(attn_sf_m[entry.row])));
          attn_exp_pipe[0]<=entry;
        end
      end
    end
  end

  // Two pipeline registers model the external 32-lane FP32 multiplier. One
  // reply is consumed only when the elastic pipeline can retain it.
  assign attn_transform_ready[1]=!attn_transform_valid[1]||(attn_transform_final?unit_wr_ready:unit_acc_wr_ready);
  assign attn_transform_ready[0]=!attn_transform_valid[0]||attn_transform_ready[1];
  assign unit_acc_out_ready=attn_qk_stream?attn_score_ready:(attn_transform_stream?attn_transform_ready[0]:attn_normal_acc_out_ready);
  assign attn_score_ready=!attn_score_valid||unit_ws_ready;
  always @(negedge clk)if(attn_qk_stream)begin
    unit_acc={attn_qk_cmd.token,(attn_qk_cmd.block_id[0]?ACC_FACC_B:ACC_FACC_A),PAIR_BITS'(attn_score_requests),TILE_BITS'(0)};
    unit_acc_valid=attn_score_requests<pairs_for_rows(rows);unit_ws=attn_score_q;unit_ws_valid=attn_score_valid;
  end
  always @(posedge clk)begin
    workspace_req_t entry;logic [1:0][15:0][31:0] data;real mx;
    if(reset||clear||!attn_qk_stream)begin attn_score_valid<=0;attn_score_requests<=0;attn_score_writes<=0;end
    else begin
      if(unit_acc_valid&&unit_acc_ready)attn_score_requests<=attn_score_requests+1;
      if(unit_ws_valid&&unit_ws_ready)attn_score_writes<=attn_score_writes+1;
      if(attn_score_ready)begin
        attn_score_valid<=unit_acc_out_valid&&unit_acc_out_ready;
        if(unit_acc_out_valid&&unit_acc_out_ready)begin
          if(unit_acc_out.request.token!=attn_qk_cmd.token)$fatal(1,"QK post read token");
          data=unit_acc_out.data;
          for(int h=0;h<2;h++)if(unit_acc_out.mask[h])begin
            int r;r=2*int'(unit_acc_out.request.pair_idx)+h;mx=-1.0e30;
            for(int n=0;n<16;n++)begin
              if(data[h][n]!==attn_qk_gold[attn_qk_cmd.block_id][r][n])$fatal(1,"QK accumulated score mismatch");
              if((int'(attn_qk_cmd.block_id)*16+n+r)%37==0)data[h][n]=32'hff800000;
              if(real32(data[h][n])>mx)mx=real32(data[h][n]);
              attn_qk_gold[attn_qk_cmd.block_id][r][n]=data[h][n];
            end
            attn_qk_m_new[r]=bits(mx>real32(attn_qk_old_m[r])?mx:real32(attn_qk_old_m[r]));
            attn_qk_aa_new[r]=bits(real32(attn_qk_old_m[r])-real32(attn_qk_m_new[r]));attn_max_gold[r]=attn_qk_m_new[r];
          end
          entry={attn_qk_cmd.token,WS_SCORE,attn_qk_cmd.block_id[0],1'b1,attn_qk_cmd.block_id,
            ROW_COUNT_BITS'(2*int'(unit_acc_out.request.pair_idx)),2'b0,16'hffff,unit_acc_out.mask,data};
          attn_score_q<=entry;
        end
      end
    end
  end
  always @(negedge clk)if(attn_transform_stream)begin
    local_write_t wr;unit_acc_write_t value;unit_acc_read_t req;
    req={attn_transform_cmd.token,ACC_OACC,PAIR_BITS'(attn_transform_requests/16),TILE_BITS'(attn_transform_requests%16)};
    unit_acc=req;unit_acc_valid=attn_transform_requests<pairs_for_rows(rows)*16;
    value=attn_transform_pipe[1];
    if(attn_transform_final)begin
      wr='0;wr.token=attn_transform_cmd.token;wr.kind=LOCAL_O;wr.content_version=job.output_version;
      wr.tile=TILE_BITS'(value.payload.addr%16);wr.mask=A_INPUT_ROWS'(value.payload.row_valid);
      for(int h=0;h<2;h++)begin
        wr.row[h]=ROW_COUNT_BITS'(2*(int'(value.payload.addr)/16)+h);wr.entry[h]=attn_quantize(value.payload.data[h]);
      end
      unit_wr=wr;unit_wr_valid=attn_transform_valid[1];
    end else begin unit_acc_wr=value;unit_acc_wr_valid=attn_transform_valid[1];end
  end
  always @(posedge clk)begin
    unit_acc_write_t wr;
    if(reset||clear||!attn_transform_stream)begin attn_transform_valid<=0;attn_transform_count<=0;attn_transform_requests<=0;end
    else begin
      if(unit_acc_valid&&unit_acc_ready)attn_transform_requests<=attn_transform_requests+1;
      if(attn_transform_valid[1]&&(attn_transform_final?unit_wr_ready:unit_acc_wr_ready))begin
        attn_transform_count<=attn_transform_count+1;
        for(int h=0;h<2;h++)if(attn_transform_pipe[1].payload.row_valid[h])begin
          int row,nt;row=2*(int'(attn_transform_pipe[1].payload.addr)/16)+h;nt=attn_transform_pipe[1].payload.addr%16;
          if(attn_transform_final)attn_o_gold[nt][row]=attn_quantize(attn_transform_pipe[1].payload.data[h]);
          else for(int n=0;n<16;n++)attn_oacc_gold[row][nt*16+n]=attn_transform_pipe[1].payload.data[h][n];
        end
      end
      if(attn_transform_ready[1])begin attn_transform_valid[1]<=attn_transform_valid[0];attn_transform_pipe[1]<=attn_transform_pipe[0];end
      if(attn_transform_ready[0])begin
        attn_transform_valid[0]<=unit_acc_out_valid&&unit_acc_out_ready;
        if(unit_acc_out_valid&&unit_acc_out_ready)begin
          wr='0;wr.token=attn_transform_cmd.token;wr.payload.sel=ACC_OACC;
          wr.payload.addr=10'(int'(unit_acc_out.request.pair_idx)*16+int'(unit_acc_out.request.nt));wr.payload.row_valid=unit_acc_out.mask;
          if(wr.payload.addr!=attn_transform_count+int'(attn_transform_valid[0])+int'(attn_transform_valid[1]))$fatal(1,"Pair-major OACC order");
          for(int h=0;h<2;h++)if(unit_acc_out.mask[h])begin
            int row,nt;row=2*int'(unit_acc_out.request.pair_idx)+h;nt=unit_acc_out.request.nt;
            for(int n=0;n<16;n++)begin
              if(unit_acc_out.data[h][n]!==attn_oacc_gold[row][nt*16+n])$fatal(1,"OACC before transform mismatch b=%0d r=%0d n=%0d",attn_transform_cmd.block_id,row,nt*16+n);
              wr.payload.data[h][n]=attn_mul(unit_acc_out.data[h][n],attn_transform_factor[row]);
            end
          end
          attn_transform_pipe[0]<=wr;
        end
      end
    end
  end

  task automatic attn_vws_write(input unit_cmd_t c,input workspace_kind_e kind,input int index,
    input logic [15:0] mask,input logic [1:0] rowmask,input logic [1:0][15:0][31:0] data);
    workspace_req_t req;
    req={c.token,kind,c.block_id[0],1'b1,c.block_id,ROW_COUNT_BITS'(index),2'b0,mask,rowmask,data};
    if(req.token!==c.token)$fatal(1,"Workspace TB constructor lost token");
    unit_ws=req;unit_ws_valid=1;do @(posedge clk);while(!unit_ws_ready);
    @(negedge clk);unit_ws_valid=0;
  endtask
  task automatic attn_vws_read(input unit_cmd_t c,input workspace_kind_e kind,input int index,
    output logic [15:0][31:0] data);
    workspace_req_t req;req='0;req.token=c.token;req.block_id=c.block_id;req.bank=c.block_id[0];req.kind=kind;
    req.index=ROW_COUNT_BITS'(index);req.mask=attn_mask16(index,rows);req.row_mask=1;
    @(negedge clk);unit_ws=req;unit_ws_valid=1;
    do @(posedge clk);while(!unit_ws_ready);@(negedge clk);unit_ws_valid=0;unit_ws_out_ready=1;
    do @(posedge clk);while(!unit_ws_out_valid);
    if(unit_ws_out.token!=c.token||unit_ws_out.kind!=kind||unit_ws_out.index!=index)$fatal(1,"VPU workspace identity");
    data=unit_ws_out.data[0];@(negedge clk);unit_ws_out_ready=0;
  endtask
  task automatic attn_fws_read(input unit_cmd_t c,input workspace_kind_e kind,input int index,
    output logic [3:0][31:0] data);
    sfu_workspace_req_t req;req='0;req.token=c.token;req.block_id=c.block_id;req.bank=c.block_id[0];
    req.kind=kind;req.index=ROW_COUNT_BITS'(index);req.mask=attn_mask4(index,rows);
    @(negedge clk);function_ws=req;function_ws_valid=1;
    do @(posedge clk);while(!function_ws_ready);@(negedge clk);function_ws_valid=0;function_ws_out_ready=1;
    do @(posedge clk);while(!function_ws_out_valid);
    if(function_ws_out.token!=c.token||function_ws_out.kind!=kind||function_ws_out.index!=index)$fatal(1,"SFU workspace identity");
    data=function_ws_out.data;@(negedge clk);function_ws_out_ready=0;
  endtask
  task automatic attn_fws_write(input unit_cmd_t c,input workspace_kind_e kind,input int index,input logic [3:0][31:0] data);
    sfu_workspace_req_t req;
    req={c.token,kind,c.block_id[0],1'b1,c.block_id,ROW_COUNT_BITS'(index),2'b0,attn_mask4(index,rows),data};
    function_ws=req;function_ws_valid=1;do @(posedge clk);while(!function_ws_ready);
    @(negedge clk);function_ws_valid=0;
  endtask
  task automatic attn_acc_read(input unit_cmd_t c,input acc_sel_e sel,input int pair_idx,nt,output unit_acc_reply_t response);
    unit_acc_read_t req;req='0;req.token=c.token;req.sel=sel;req.pair_idx=PAIR_BITS'(pair_idx);req.nt=TILE_BITS'(nt);
    @(negedge clk);unit_acc=req;unit_acc_valid=1;do @(posedge clk);while(!unit_acc_ready);
    @(negedge clk);unit_acc_valid=0;attn_normal_acc_out_ready=1;do @(posedge clk);while(!unit_acc_out_valid);
    response=unit_acc_out;if(response.request!==req)$fatal(1,"Attention ACC read identity");
    @(negedge clk);attn_normal_acc_out_ready=0;
  endtask
  task automatic attn_quant_write(input unit_cmd_t c,input local_kind_e kind,input int nt,row,
    input logic [1:0] mask,input qvec16_t a,b);
    local_write_t wr;
    wr={c.token,kind,(kind==LOCAL_P?c.block_id[0]:1'b0),
      (kind==LOCAL_P?16'(int'(c.block_id)+1):job.output_version),TILE_BITS'(nt),
      {ROW_COUNT_BITS'(0),ROW_COUNT_BITS'(row+1),ROW_COUNT_BITS'(row)},A_INPUT_ROWS'(mask),{qvec16_t'('0),b,a}};
    unit_wr=wr;unit_wr_valid=1;do @(posedge clk);while(!unit_wr_ready);@(negedge clk);unit_wr_valid=0;
  endtask

  task automatic attn_qk_post(input unit_cmd_t c);
    logic [15:0][31:0] old_m;logic [1:0][15:0][31:0] data;
    for(int r=0;r<rows;r+=16)begin
      attn_vws_read(c,WS_M,r,old_m);
      for(int i=0;i<16&&r+i<rows;i++)begin
        if(old_m[i]!==attn_max_gold[r+i])$fatal(1,"Old row max mismatch");attn_qk_old_m[r+i]=old_m[i];
      end
    end
    @(negedge clk);attn_qk_cmd=c;attn_qk_stream=1;
    while(attn_score_writes<pairs_for_rows(rows))@(negedge clk);
    attn_qk_stream=0;unit_acc_valid=0;unit_ws_valid=0;
    for(int r=0;r<rows;r+=16)begin
      data='0;for(int i=0;i<16&&r+i<rows;i++)data[0][i]=attn_qk_m_new[r+i];
      attn_vws_write(c,WS_M,r,attn_mask16(r,rows),1,data);
      data='0;for(int i=0;i<16&&r+i<rows;i++)data[0][i]=attn_qk_aa_new[r+i];
      attn_vws_write(c,WS_AA,r,attn_mask16(r,rows),1,data);
    end
  endtask
  task automatic attn_p_post(input unit_cmd_t c);
    logic [31:0] old_l[ROWS],alpha[ROWS],new_l[ROWS];logic [15:0][31:0] data;
    logic [15:0][31:0] p_row[ROWS];bit ready_row[ROWS];fp4_stream_t entry;
    logic [1:0][15:0][31:0] wrdata;
    for(int r=0;r<rows;r++)ready_row[r]=0;
    for(int r=0;r<rows;r+=16)begin
      attn_vws_read(c,WS_ALPHA,r,data);for(int i=0;i<16&&r+i<rows;i++)begin alpha[r+i]=data[i];attn_alpha_cache[c.block_id[0]][r+i]=data[i];end
      attn_vws_read(c,WS_L,r,data);for(int i=0;i<16&&r+i<rows;i++)begin
        old_l[r+i]=data[i];if(data[i]!==attn_l_gold[r+i])$fatal(1,"Old row sum mismatch");
      end
    end
    attn_alpha_cache_block[c.block_id[0]]=c.block_id;
    fork
      begin
        @(negedge clk);unit_p_ready=1;
        for(int i=0;i<rows*4;i++)begin
          do @(posedge clk);while(!unit_p_valid);entry=unit_p;
          if(entry.token!=c.token||entry.row!=i/4||entry.group_id!=i%4||entry.last!=(i==rows*4-1))$fatal(1,"P stream ordering");
          for(int n=0;n<4;n++)begin
            if(entry.data[n]!==bits($exp(real32(attn_qk_gold[c.block_id][i/4][4*(i%4)+n])-real32(attn_max_gold[i/4]))))$fatal(1,"P exp data mismatch");
            p_row[i/4][4*(i%4)+n]=entry.data[n];
          end
          if(i%4==3)begin
            logic [31:0] sum;sum=0;for(int n=0;n<16;n++)sum=fp32_legacy_ref_pkg::fp32_add(sum,p_row[i/4][n]);
            new_l[i/4]=fp32_legacy_ref_pkg::fp32_add(attn_mul(alpha[i/4],old_l[i/4]),sum);
            attn_p_gold[c.block_id][i/4]=attn_quantize(p_row[i/4]);ready_row[i/4]=1;
          end
          @(negedge clk);
        end
        unit_p_ready=0;
      end
      begin
        for(int r=0;r<rows;r++)begin
          while(!ready_row[r])@(negedge clk);
          attn_quant_write(c,LOCAL_P,0,r,1,attn_p_gold[c.block_id][r],qvec16_t'('0));
        end
      end
    join
    for(int r=0;r<rows;r+=16)begin
      wrdata='0;for(int i=0;i<16&&r+i<rows;i++)begin wrdata[0][i]=new_l[r+i];attn_l_gold[r+i]=new_l[r+i];end
      attn_vws_write(c,WS_L,r,attn_mask16(r,rows),1,wrdata);
    end
  endtask
  task automatic attn_oacc_transform(input unit_cmd_t c,input bit final_output);
    logic [15:0][31:0] data;
    if(final_output)for(int r=0;r<rows;r+=16)begin
      attn_vws_read(c,WS_RECIP,r,data);for(int i=0;i<16&&r+i<rows;i++)attn_transform_factor[r+i]=data[i];
    end else begin
      if(attn_alpha_cache_block[c.block_id[0]]!=c.block_id)$fatal(1,"VPU cached alpha generation mismatch");
      for(int r=0;r<rows;r++)attn_transform_factor[r]=attn_alpha_cache[c.block_id[0]][r];
    end
    @(negedge clk);attn_transform_cmd=c;attn_transform_final=final_output;attn_transform_stream=1;
    while(attn_transform_count<pairs_for_rows(rows)*16)@(negedge clk);
    attn_transform_stream=0;unit_acc_valid=0;attn_normal_acc_out_ready=0;unit_acc_wr_valid=0;unit_wr_valid=0;
  endtask

  initial forever begin
    compute_job_t w;b_packet_desc_t d;logic [511:0] data;b_beat_tag_t tag;
    bit accepted[8];
    @(negedge clk);
    if(attn_agents&&source_work_valid)begin
      source_work_ready=1;@(posedge clk);w=source_work;
      if(w.work_seq!=attn_works||w.mode!=MAT_ATTENTION||w.tiles!=16||w.m_rows!=rows||source_context!==job)
        $fatal(1,"Attention normalized job geometry seq=%0d/%0d mode=%0d tiles=%0d rows=%0d/%0d context_match=%0d packed=%h",w.work_seq,attn_works,w.mode,w.tiles,w.m_rows,rows,source_context===job,w);
      if(attn_works==0)attn_parent_token=w.token;else if(w.token!=attn_parent_token)$fatal(1,"Attention parent identity");
      attn_works++;@(negedge clk);source_work_ready=0;
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
                for(int b=0;b<2;b++)for(int n=0;n<16;n++)data[(b*16+n)*8+:8]=8'(attn_bscale(w,2*p+b,n));
                data[511-:B_PACKET_BITS]=B_PACKET_BITS'(descriptor);
              end else for(int c=0;c<4;c++)for(int k=0;k<16;k++)
                data[c*128+k*8+:8]=8'(attn_bval(w,2*p+(i-1)/4,k,((i-1)%4)*4+c));
              tag={w.token,w.work_seq,SEQ_BITS'(p),B_BEAT_INDEX_BITS'(i),(i==8)};
              kv_in_data=data;kv_in_tag=tag;kv_in_valid=1;do @(posedge clk);while(!kv_in_ready);@(negedge clk);
            end
          end
          kv_in_valid=0;
        end
      join
    end
  end
  initial forever begin
    unit_cmd_t c;
    @(negedge clk);
    if(attn_agents&&unit_cmd_valid)begin
      unit_cmd_ready=1;@(posedge clk);c=unit_cmd;attn_v_commands++;
      @(negedge clk);unit_cmd_ready=0;unit_armed_valid=1;unit_armed_token=c.token;
      do @(posedge clk);while(!unit_armed_ready);@(negedge clk);unit_armed_valid=0;unit_go_ready=1;
      do @(posedge clk);while(!unit_go_valid);if(unit_go_token!=c.token)$fatal(1,"VPU go token");
      @(negedge clk);unit_go_ready=0;
      case(c.function_id)
        UNIT_QK_POST:attn_qk_post(c);
        UNIT_P_POST:attn_p_post(c);
        UNIT_OACC_SCALE:attn_oacc_transform(c,0);
        UNIT_AFIN_QUANT:attn_oacc_transform(c,1);
        default:$fatal(1,"Unexpected Attention VPU function");
      endcase
      repeat(2)@(negedge clk);unit_done_token=c.token;unit_done_function=c.function_id;unit_done_valid=1;
      do @(posedge clk);while(!unit_done_ready);@(negedge clk);unit_done_valid=0;
    end
  end
  initial forever begin
    unit_cmd_t c;logic [3:0][31:0] data,outdata;
    @(negedge clk);
    if(attn_agents&&function_cmd_valid)begin
      function_cmd_ready=1;@(posedge clk);c=function_cmd;attn_f_commands++;
      @(negedge clk);function_cmd_ready=0;function_armed_valid=1;function_armed_token=c.token;
      do @(posedge clk);while(!function_armed_ready);@(negedge clk);function_armed_valid=0;function_go_ready=1;
      do @(posedge clk);while(!function_go_valid);if(function_go_token!=c.token)$fatal(1,"SFU go token");
      @(negedge clk);function_go_ready=0;attn_sf_current=c;
      if(c.function_id==UNIT_P_EXP)begin
        for(int r=0;r<rows;r+=4)begin attn_fws_read(c,WS_M,r,data);for(int i=0;i<4&&r+i<rows;i++)attn_sf_m[r+i]=data[i];end
        attn_exp_stream=1;
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
              @(negedge clk);function_ws_out_ready=attn_exp_pipe_ready[0];
              @(posedge clk);if(function_exp_valid&&function_exp_ready)emitted++;
            end
            @(negedge clk);function_ws_out_ready=0;attn_exp_stream=0;
          end
        join
      end else if(c.function_id==UNIT_ALPHA_EXP||c.function_id==UNIT_RECIP)begin
        logic [31:0] computed[ROWS];
        fork
          begin
            sfu_workspace_req_t req;
            for(int r=0;r<rows;r+=4)begin
              req='0;req.token=c.token;req.block_id=c.block_id;req.bank=c.block_id[0];req.kind=c.function_id==UNIT_ALPHA_EXP?WS_AA:WS_L;
              req.index=ROW_COUNT_BITS'(r);req.mask=attn_mask4(r,rows);
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
                if(c.function_id==UNIT_ALPHA_EXP)begin attn_alpha_gold[c.block_id][r+i]=computed[r+i];if(computed[r+i]!=32'h3f800000&&c.block_id!=0)attn_nontrivial_alpha++;end
              end
              @(negedge clk);
            end
            function_ws_out_ready=0;
          end
        join
        repeat(2)@(negedge clk);
        for(int r=0;r<rows;r+=4)begin
          outdata=0;for(int i=0;i<4&&r+i<rows;i++)outdata[i]=computed[r+i];
          attn_fws_write(c,c.function_id==UNIT_ALPHA_EXP?WS_ALPHA:WS_RECIP,r,outdata);
        end
      end else $fatal(1,"Unexpected Attention SFU function");
      repeat(2)@(negedge clk);function_done_token=c.token;function_done_function=c.function_id;function_done_valid=1;
      do @(posedge clk);while(!function_done_ready);@(negedge clk);function_done_valid=0;
    end
  end

  always @(posedge clk)begin
    compute_job_t w;int addr,dot,row;logic [31:0] x;qvec16_t activation;acc_write_t expected;
    attn_cycle++;
    if(reset||clear||job.op!=OP_ATTENTION)attn_c_expected_valid=0;
    if(!reset&&!clear&&job.op==OP_ATTENTION)begin
      if(attn_agents&&attn_cycle%2000==0)$display("ATTENTION_STATE attn_cycle=%0d M=%0d attn_works=%0d attn_issues=%0d attn_commits=%0d VPU=%0d SFU=%0d",attn_cycle,rows,attn_works,attn_issues,attn_commits,attn_v_commands,attn_f_commands);
      for(int i=DEQACC_PIPE_STAGES-1;i>0;i--)begin
        attn_c_expected_valid[i]=attn_c_expected_valid[i-1];attn_c_expected[i]=attn_c_expected[i-1];attn_c_meta[i]=attn_c_meta[i-1];
      end
      attn_c_expected_valid[0]=psum_valid;
      if(protocol_error)$fatal(1,"Attention PCore protocol error attn_cycle=%0d work=%0d",attn_cycle,attn_works);
      if(issue_valid)begin
        attn_issues++;
        if(issue_meta.tile_idx==0&&issue_meta.pair_idx==0)begin
          attn_first_cycle[issue_meta.work_seq]=attn_cycle;
          if(issue_meta.role==ROLE_K)attn_qk_count++;else attn_pv_count++;
          $display("ATTENTION_PROGRESS M=%0d work=%0d role=%0d block=%0d first_S0=%0d",rows,issue_meta.work_seq,issue_meta.role,issue_meta.block_id,attn_cycle);
        end
      end
      if(psum_valid)begin
        w='0;w.block_id=psum_rsp.meta.block_id;w.role=psum_rsp.meta.role;
        addr=w.role==ROLE_V?int'(psum_rsp.meta.pair_idx)*16+int'(psum_rsp.meta.nt):int'(psum_rsp.meta.pair_idx);
        expected='0;expected.sel=psum_rsp.meta.acc_sel;expected.addr=10'(addr);expected.row_valid=psum_rsp.row_valid;
        for(int h=0;h<2;h++)if(psum_rsp.row_valid[h])begin
          row=2*int'(psum_rsp.meta.pair_idx)+h;
          activation=w.role==ROLE_K?attn_q[psum_rsp.meta.tile_idx][row]:attn_p_gold[w.block_id][row];
          if(psum_rsp.e_stream[h]!==activation.scale)$fatal(1,"Attention activation scale alignment");
          for(int n=0;n<16;n++)begin
            dot=0;for(int k=0;k<16;k++)dot+=int'($signed(activation.data[k*8+:8]))*attn_bval(w,psum_rsp.meta.tile_idx,k,n);
            if(psum_rsp.psum[h][n]!==32'(dot)||psum_rsp.e_stat[n]!=attn_bscale(w,psum_rsp.meta.tile_idx,n))$fatal(1,"QK/PV integer dot mismatch");
            x=attn_dq(dot,activation.scale,attn_bscale(w,psum_rsp.meta.tile_idx,n),$signed(psum_rsp.meta.exp_fold));
            if(psum_rsp.meta.add_old)x=fp32_legacy_ref_pkg::fp32_add(w.role==ROLE_V?attn_oacc_gold[row][int'(psum_rsp.meta.nt)*16+n]:attn_partial[psum_rsp.meta.acc_sel][addr][h][n],x);
            attn_partial[psum_rsp.meta.acc_sel][addr][h][n]=x;
            expected.data[h][n]=x;
            if(w.role==ROLE_V)attn_oacc_gold[row][int'(psum_rsp.meta.nt)*16+n]=x;
            else if(psum_rsp.meta.final_k)attn_qk_gold[w.block_id][row][n]=x;
          end
        end
        attn_c_expected[0]=expected;attn_c_meta[0]=psum_rsp.meta;
      end
      #1;
      if(commit_valid!==attn_c_expected_valid[DEQACC_PIPE_STAGES-1])$fatal(1,"Attention DEQACC latency mismatch");
      if(commit_valid)begin
        attn_commits++;if(commit_meta.last)attn_last_cycle[commit_meta.work_seq]=attn_cycle;
        if(commit_meta!==attn_c_meta[DEQACC_PIPE_STAGES-1]||commit_write.sel!==attn_c_expected[DEQACC_PIPE_STAGES-1].sel||
          commit_write.addr!==attn_c_expected[DEQACC_PIPE_STAGES-1].addr||commit_write.row_valid!==attn_c_expected[DEQACC_PIPE_STAGES-1].row_valid)$fatal(1,"Attention C identity mismatch");
        for(int h=0;h<2;h++)if(commit_write.row_valid[h])for(int n=0;n<16;n++)
          if(commit_write.data[h][n]!==attn_c_expected[DEQACC_PIPE_STAGES-1].data[h][n])$fatal(1,"Attention FP32 attn_partial commit mismatch");
      end
    end
  end
  task automatic attn_run_attention(input int m);
    local_object_t object;local_write_t wr;int interval,minimum_gap,maximum_gap;
    rows=m;attn_works=0;attn_issues=0;attn_commits=0;attn_qk_count=0;attn_pv_count=0;attn_v_commands=0;attn_f_commands=0;attn_nontrivial_alpha=0;
    job='0;job.op=OP_ATTENTION;job.job_id=16'(jobs+1);job.profile_id=7;job.profile_version=1;job.data_context=55;job.input_version=3;job.output_version=4;
    object='0;object.kind=LOCAL_Q;object.content_version=3;object.data_context=55;object.profile_id=7;object.profile_version=1;object.m_rows=ROW_COUNT_BITS'(m);
    for(int r=0;r<m;r++)begin attn_max_gold[r]=32'hff800000;attn_l_gold[r]=0;for(int n=0;n<256;n++)attn_oacc_gold[r][n]=0;end
    for(int t=0;t<16;t++)for(int r=0;r<m;r++)attn_q[t][r]=qvec16_t'(qgold[t][r]);
    run_agents=1;attn_agents=1;job_valid=1;@(posedge clk);if(!job_ready)$fatal(1,"Attention parent Job refused");attn_accept_cycle=attn_cycle;
    @(negedge clk);job_valid=0;while(!completion_valid)@(negedge clk);attn_finish_cycle=attn_cycle;
    if(completion.status!=PCORE_OK||completion.empty!=(m==0)||completion.rows!=m)$fatal(1,"Attention completion status");
    if(attn_works!=(m==0?0:110)||attn_issues!=110*16*pairs_for_rows(m)||attn_commits!=attn_issues||attn_qk_count!=(m==0?0:55)||attn_pv_count!=attn_qk_count)$fatal(1,"Full 55 block counts");
    if(m!=0)begin
      if(!qoz_complete||dut.qoz_object.kind!=LOCAL_O||dut.pbuf_active!=0)$fatal(1,"Attention memory retirement");
      for(int t=0;t<16;t++)for(int r=0;r<m;r++)begin
        logic [ROW_BITS-1:0] actual;int address;address=(t+16)*A_ROW_GROUPS+r/3;
        case(r%3)
          0:actual=dut.memory.qoz.storage.banks[0].mem[address];
          1:actual=dut.memory.qoz.storage.banks[1].mem[address];
          2:actual=dut.memory.qoz.storage.banks[2].mem[address];
        endcase
        if(actual!==attn_o_gold[t][r])$fatal(1,"AFIN QOZ result mismatch");
      end
      if(attn_nontrivial_alpha==0)$fatal(1,"Non-unit alpha coverage missing");
      interval=16*(pairs_for_rows(m)<4?4:pairs_for_rows(m))+12;
      minimum_gap=32'h7fffffff;maximum_gap=0;
      for(int i=1;i<110;i++)begin
        if(attn_first_cycle[i]<attn_last_cycle[i-1])$fatal(1,"Next block before old C retirement");
        if(i==109&&attn_first_cycle[i]-attn_first_cycle[i-1]<2*interval)$fatal(1,"PV53/PV54 empty slot missing");
        if(i>=3&&i<109)begin
          int gap;gap=attn_first_cycle[i]-attn_first_cycle[i-1];
          if(gap<minimum_gap)minimum_gap=gap;if(gap>maximum_gap)maximum_gap=gap;
          if(gap>interval+2)$fatal(1,"Steady block interval exceeds target margin M=%0d gap=%0d target=%0d",m,gap,interval);
        end
      end
      $display("CASE ATTENTION M=%0d attn_works=110 attn_commits=%0d parent_cycles=%0d target_slot=%0d steady_min=%0d steady_max=%0d PV53_to_PV54=%0d tail=%0d nonunit_alpha=%0d",m,attn_commits,attn_finish_cycle-attn_accept_cycle,interval,minimum_gap,maximum_gap,attn_first_cycle[109]-attn_first_cycle[108],attn_finish_cycle-attn_last_cycle[109],attn_nontrivial_alpha);
    end
    run_agents=0;attn_agents=0;completion_ready=1;@(negedge clk);completion_ready=0;attn_jobs++;
  endtask

  bit verify_sequence=0;
  always @(posedge clk)if(verify_sequence&&clear)$fatal(1,"Seven-job chain must not clear");
  initial begin
    int m;
    repeat(32)@(negedge clk);reset=0;
    if(!$value$plusargs("M=%d",m))m=11;
    if(m<0||m>51)$fatal(1,"Invalid seven-job M");
    configure(m);verify_sequence=1;
    run_kv(OP_K_PROJ,m,0);
    run_kv(OP_V_PROJ,m,0);
    run_q(m,0);
    attn_run_attention(m);jobs++;
    for(int t=0;t<16;t++)for(int r=0;r<m;r++)local_gold[t][r]=attn_o_gold[t][r];
    run_local_projection(OP_O_PROJ,m,1);
    run_gu(m);
    run_local_projection(OP_DOWN_PROJ,m,1);
    if(jobs!=7||total_issues!=6656+9952*pairs_for_rows(m)||total_commits!=total_issues||dut.qoz_active||dut.pbuf_active!=0)
      $fatal(1,"Seven-job chain completion/count/storage mismatch");
    $display("tb_dynamic_seven_jobs PASS M=%0d jobs=7 psums=%0d commits=%0d no_clear=1 Q_to_Attention_to_O=1 GU_Z_to_Down=1 exact_counts=1 external_units_TB=1",m,total_issues,total_commits);
    $finish;
  end
  initial begin #5000000;$fatal(1,"Seven-job watchdog");end
endmodule

