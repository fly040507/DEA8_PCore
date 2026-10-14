`timescale 1ns/1ps
import pcore_pkg::*;
import dea8_tile_link_pkg::*;
module tb_dynamic_q_projection #(parameter bit TEST_KV=0);
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,completion_valid,completion_ready=0,busy,flush_request;
  pcore_job_t job='0;pcore_completion_t completion;
  logic [2:0] flush_ack=3'b111;
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
  pcore_top dut(.*);

  logic [31:0] gold[0:QOZ_Q_TILES-1][0:ROWS-1][0:TILE-1];
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
  function automatic int av(input int kt,row,k);return int'($signed(8'(kt*31+row*17+k*11+seed*23)));endfunction
  function automatic int bv(input int nt,kt,k,n);return int'($signed(8'(nt*7+kt*13+k*29+n*19+seed*3)));endfunction
  function automatic int ea(input int kt,row);return 130+(kt+row)%4;endfunction
  function automatic int eb(input int nt,kt,n);return 129+(nt+kt+n)%5;endfunction
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
      d.occurrence_seq=SEQ_BITS'(kt);d.m_rows=w.m_rows;d.uses=1;a_desc=d;a_desc_valid=1;
      do @(posedge clk);while(!a_desc_ready);@(negedge clk);a_desc_valid=0;
      for(int g=0;g<(rows+A_INPUT_ROWS-1)/A_INPUT_ROWS;g++)begin
        a='0;a.token=w.token;a.work_seq=w.work_seq;a.occurrence_seq=SEQ_BITS'(kt);
        a.group_idx=A_GROUP_BITS'(g);a.row_valid=a_group_mask(rows,g);
        for(int r=0;r<A_INPUT_ROWS;r++)begin
          a.row[r].scale=8'(ea(kt,g*A_INPUT_ROWS+r));
          for(int k=0;k<TILE;k++)a.row[r].data[k*INT_BITS+:INT_BITS]=8'(av(kt,g*A_INPUT_ROWS+r,k));
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
    for(int kt=0;kt<64;kt+=B_PACKET_MAX_TILES)begin
      @(negedge clk);d='0;d.token=w.token;d.work_seq=w.work_seq;d.source=B_HBM;d.mode=MAT_PROJECTION;
      d.role=ROLE_WEIGHT;d.first_tile=SEQ_BITS'(kt);d.packet_seq=SEQ_BITS'(kt/B_PACKET_MAX_TILES);
      b_desc=d;b_desc_valid=1;do @(posedge clk);while(!b_desc_ready);
      @(negedge clk);b_desc_valid=0;fork produce_pc(w,d,0);produce_pc(w,d,1);join
    end
  endtask
  initial forever begin
    compute_job_t w;
    @(negedge clk);
    if(run_agents&&source_work_valid)begin
      source_work_ready=1;@(posedge clk);w=source_work;
      if(w.work_seq!=work_count||w.nt!=(job.op==OP_Q_PROJ?work_count/2+(work_count%2)*8:work_count)||w.tiles!=64||
        w.m_rows!=rows||w.acc_sel!=acc_sel_e'(work_count%2)||source_context!==job)$fatal(1,"Q work geometry/canonical/bank/context");
      if(work_count==0)parent_token=w.token;else if(w.token!=parent_token)$fatal(1,"Q changed parent token");
      work_count++;@(negedge clk);source_work_ready=0;
      fork produce_a(w);produce_b(w);join
    end
  end
  initial forever begin
    unit_cmd_t c;pair_reply_t reply;
    logic [ROW_BITS-1:0] qa[0:ROWS-1],qb[0:ROWS-1];
    logic [TILE-1:0][31:0] x,y,ga,gb,gx,gy;
    local_write_t wr;int ori;
    @(negedge clk);
    if(run_agents&&unit_cmd_valid)begin
      unit_cmd_ready=1;@(posedge clk);c=unit_cmd;
      if(job.op!=OP_Q_PROJ)begin
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
    if(job_valid&&job_ready)begin accept_cycle=cycles;first_completion_cycle=0;end
    if(completion_valid&&first_completion_cycle==0)first_completion_cycle=cycles;
    if(!reset&&!flush_request&&issue_valid)begin
      issue_count++;total_issues++;if(dut.post.unit_running)compute_overlap++;
    end
    if(!reset&&!flush_request&&dut.matrix_busy&&dut.post.unit_running)overlap++;
    #1;
    if(protocol_error&&!allow_error)$fatal(1,"Q top fault matrix=%b scheduler=%b reader=%b post=%b pair=%b memory=%b",dut.matrix_error,dut.scheduler_error,dut.reader_error,dut.post_error,dut.post.pair_error,dut.memory_error);
    if(!reset&&!flush_request&&psum_valid)begin
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
    if(!reset&&!flush_request&&commit_valid)begin
      nt=commit_meta.nt;kt=commit_meta.tile_idx;
      if(commit_meta.add_old!=(kt!=0)||commit_meta.final_k!=(kt==63)||commit_meta.token!=parent_token||
        commit_write.sel!=acc_sel_e'(int'(commit_meta.work_seq)%2))$fatal(1,"Q commit metadata");
      for(int r=0;r<ROW_LANES;r++)if(commit_write.row_valid[r])for(int n=0;n<TILE;n++)begin
        row=int'(commit_meta.pair_idx)*ROW_LANES+r;dot=0;for(int k=0;k<TILE;k++)dot+=av(kt,row,k)*bv(nt,kt,k,n);
        expected=dq(dot,ea(kt,row),eb(nt,kt,n));
        if(kt!=0)expected=fp32_legacy_ref_pkg::fp32_add(gold[nt][row][n],expected);
        if(commit_write.data[r][n]!==expected)$fatal(1,"Q FP32 ordered accumulation nt=%0d kt=%0d row=%0d n=%0d",nt,kt,row,n);
        gold[nt][row][n]=expected;
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
  task automatic run_kv(input pcore_op_e op,input int profile_m,input bit preserve_q);
    logic [ROW_BITS-1:0] saved,actual;int address;
    if(!preserve_q)begin flush();configure(profile_m);end
    else begin
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
    job.data_context=16'(jobs+1);job_valid=1;
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
    flush();configure(m);seed=jobs;stressed=stress;
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
      profile_begin_valid=1;repeat(2)begin @(posedge clk);if(profile_begin_ready)$fatal(1,"Live QOZ allowed profile replacement");end
      @(negedge clk);profile_begin_valid=0;
      submit();complete_check(PCORE_PRECONDITION,0);negative_checks++;
    end else if(qoz_complete||dut.qoz_active)$fatal(1,"Empty Q created a region");
    $display("CASE Q_PROJECTION M=%0d stress=%0d matrix_works=%0d issues=%0d commits=%0d unit_commands=%0d quant_beats=%0d cycles_with_done_hold=%0d",m,stress,work_count,issue_count,commit_count,command_count,quant_writes,cycles-start_cycle);
    jobs++;
  endtask
  initial begin
    repeat(32)@(negedge clk);reset=0;
    if(TEST_KV)begin
      run_kv(OP_K_PROJ,0,0);run_kv(OP_V_PROJ,11,0);run_q(1,0);
      run_kv(OP_K_PROJ,1,1);run_kv(OP_V_PROJ,1,1);
      run_kv(OP_K_PROJ,1,1);run_kv(OP_K_PROJ,1,1);
      if(identity_checks!=4*ROWS||kv_cases!=6||compute_overlap==0)$fatal(1,"KV identity/overlap coverage");
      $display("tb_dynamic_kv_projection PASS KV_jobs=%0d Q_fixture_jobs=1 psums=%0d commits=%0d identity_reads=%0d live_Q_preserved=4 delayed_commits=12 K_to_V_to_K_to_K_no_clear=1",kv_cases,total_issues,total_commits,identity_checks);
      $finish;
    end
    run_q(0,0);run_q(1,0);run_q(11,1);run_q(51,0);
    if(overlap==0||compute_overlap==0||profile_checks!=8*(1+11+51))$fatal(1,"Q overlap/profile coverage");
    $display("tb_dynamic_q_projection PASS jobs=%0d geometry_Mx1024_1024x256=1 psums=%0d commits=%0d noncontinuous_profile_reads=%0d matrix_post_overlap=%0d actual_issue_post_overlap=%0d busy_qoz_rejections=%0d",jobs,total_issues,total_commits,profile_checks,overlap,compute_overlap,negative_checks);
    $finish;
  end
  initial begin #5000000;$fatal(1,"Q projection watchdog");end
endmodule

module tb_dynamic_kv_projection;
  tb_dynamic_q_projection #(.TEST_KV(1)) scenario();
endmodule
