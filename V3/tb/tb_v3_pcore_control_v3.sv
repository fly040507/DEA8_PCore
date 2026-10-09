`timescale 1ns/1ps
import pcore3_pkg::*;
import pcore_control_pkg::*;
import fp32_legacy_ref_pkg::*;

// 7 Job environment for one PCore instance, K -> V -> Q -> Attention -> O -> G-U -> Down.
// The DUT, matrix, QOZ and workspace storage are real RTL; only the external
// services are models. One agent implementation serves three TB modes:
//   TB_FUNCTIONAL   strict golden checks, legacy completion corners and the
//                   legacy fixed sink duty cycle.
//   TB_PERFORMANCE  no artificial stall at all; target VPU32/SFU4 throughput,
//                   II=1 channels, fixed service latency.
//   TB_STRESS       the same throughput model with random bubbles.
module tb_v3_pcore_control_v3 #(
  parameter bit MANUAL=0,
  parameter int VPU_LANES=32,
  parameter int SFU_LANES=4,
  parameter int VPU_CMD_LAT=6,
  parameter int VPU_DONE_LAT=7,
  parameter int SFU_CMD_LAT=6,
  parameter int SFU_DONE_LAT=8,
  parameter int ROPE_LAT=8,
  parameter int ACC_RD_LAT=2,
  parameter int WORK_RD_LAT=1,
  parameter int ATTN_SLOT=434
);
  typedef enum {TB_FUNCTIONAL=0,TB_PERFORMANCE=1,TB_STRESS=2} tb_mode_e;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,done_valid,done_ready=0,busy,protocol_error;
  control_job_t job;control_completion_t done;
  logic [1:0] active_adapter;
  logic flush_valid,vpu_flush_ack=1,sfu_flush_ack=1;
  logic xbc_valid=0,xbc_ready,hbm_valid=0,hbm_ready,kv_valid=0,kv_ready;
  xbc4_t xbc_entry;b2_t hbm_entry,kv_entry;
  logic vector_valid,vector_ready=1,vector_done_valid=0,vector_done_ready;
  control_command_t vector_cmd;control_unit_done_t vector_done;
  logic function_valid,function_ready=1,function_done_valid=0,function_done_ready;
  control_command_t function_cmd;control_unit_done_t function_done;
  logic vector_data_valid,vector_data_ready=0,function_data_valid,function_data_ready=0;
  control_fp_data_t vector_data,function_data,function_result;
  logic function_result_valid=0,function_result_ready;
  logic vector_result_valid=0,vector_result_ready;control_quant_result_t vector_result;
  logic vector_mem_valid=0,vector_mem_ready,vector_mem_out_valid,vector_mem_out_ready=0;
  control_memory_req_t vector_mem_req;control_memory_rsp_t vector_mem_out;
  logic function_mem_valid=0,function_mem_ready,function_mem_out_valid,function_mem_out_ready=0;
  control_memory_req_t function_mem_req;control_memory_rsp_t function_mem_out;
  logic rope_req_valid=0,rope_req_ready,rope_sfu_valid,rope_sfu_ready=1;
  control_rope_req_t rope_req,rope_sfu_req;
  logic rope_sfu_out_valid=0,rope_sfu_out_ready,rope_out_valid,rope_out_ready=0;
  control_rope_rsp_t rope_sfu_out,rope_out;
  logic kv_out_valid,kv_out_ready=1,reduce_out_valid,reduce_out_ready=1;
  collective_packet_t kv_out,reduce_out;
  logic acc_rd_valid=0,acc_rd_ready,acc_data_valid,acc_data_ready=0;
  acc_sel_e acc_rd_sel;logic [9:0] acc_rd_addr;
  control_token_t acc_token;
  logic [15:0][31:0] acc_even,acc_odd;
  logic acc_wr_valid=0,acc_wr_ready;acc_write_t acc_wr;
  logic qoz_complete;qoz_region_req_t qoz_region;
  logic ext_qoz_region_valid=0,ext_qoz_region_ready,ext_qoz_wr_valid=0,ext_qoz_wr_ready;
  qoz_region_req_t ext_qoz_region;post_result_t ext_qoz_wr;logic [15:0] ext_qoz_context=16'h1234;
  logic gu_prefetch_valid,gu_prefetch_ready=1;logic [5:0] gu_prefetch_n;
  int cycle=0,job_start,issues[7],sent[7],commands[7],outputs[7],completed=0;
  int matrix_jobs=0,allowed_n=0;
  tb_mode_e mode;bit perf;bit hold_result=0;
  // Keep reference storage independent of the interface struct layout.
  logic [$bits(qvec16_t)-1:0] qgold[16][51],ogold[16][51],zgold[32][51];
  logic [$bits(qvec16_t)-1:0] kgold[2][51],vgold[2][32],pgold[55][51];
  logic [15:0][31:0] score[55][51],alpha[55][51];
  logic [31:0] m[51],lsum[51],recip[51];
  logic [31:0] reduced_gold[7][51],attention_gold[51];
  logic [15:0][31:0] scratch0[51],scratch1[51];
  bit kv_stall=0,reduce_stall=0;collective_packet_t kv_hold,reduce_hold;
  bit vector_stall=0,function_stall=0;control_command_t vector_hold,function_hold;
  bit agents_enabled=1,allow_fault=0,hold_kv=0,hold_reduce=0;
  bit stress=0,corners=0;
  int seed=1;
  logic [31:0] random_state[20];
  longint coverage[24];
  int barrier_hits[7],function_commands=0,done_wait[7];
  int lifecycle_reads=0,lifecycle_releases=0,lifecycle_o_acquires=0,pv54_commits=0;
  bit q_released=0;
  bit acc_stall=0,vm_stall=0,fm_stall=0,rope_stall=0;
  logic [1023:0] acc_hold;
  control_memory_rsp_t vm_hold,fm_hold;
  control_rope_rsp_t rope_hold;
  int kv_tail_hold=0,reduce_tail_hold=0;
  bit kv_tail_seen=0,reduce_tail_seen=0;
  // Pipelined external service channels: request queues are presented II=1,
  // responses are released LAT cycles after the request was accepted.
  typedef struct packed {acc_sel_e sel;logic [9:0] addr;} acc_rd_item_t;
  acc_rd_item_t acc_rd_q[$];
  acc_write_t acc_wr_q[$];
  control_memory_req_t vm_req_q[$],fm_req_q[$];
  control_rope_req_t rope_req_q[$];
  int acc_age[$],vm_age[$],fm_age[$],rope_age[$];
  logic [1023:0] acc_rsp_q[$];
  control_memory_rsp_t vm_rsp_q[$],fm_rsp_q[$];
  control_rope_rsp_t rope_rsp_q[$];
  control_rope_rsp_t rope_sfu_rsp_q[$];
  // Performance accounting.
  int job_accept_cyc[7],first_issue_cyc[7],last_issue_cyc[7],done_cyc[7];
  int last_post_cyc[7],last_egress_cyc[7];
  int vstage_start,vstage_end,fstage_start,fstage_end,stage_dur_max[32];
  int scale_cycles=0,scale_margin_min=1000000;
  int attn_start[1024],attn_start_n,attn_qk_commits=0,attn_pv_commits=0;
  int fpace_n=0,fpace_ref=0;
  string mode_name;
  dea8_pcore_control_v3 #(.PCORE_ID(3'd2)) dut(.*);

  function automatic int random_limit(input int channel,maximum);
    logic [31:0] x;
    x=random_state[channel];x^=x<<13;x^=x>>17;x^=x<<5;
    random_state[channel]=x;
    return int'(x%32'(maximum+1));
  endfunction
  task automatic delay_cycles(input int channel,maximum,counter);
    int count;
    count=stress?random_limit(channel,maximum):0;
    coverage[counter]+=count;
    repeat(count)@(negedge clk);
  endtask
  // Fixed target-hardware pipeline latency in FUNCTIONAL/PERFORMANCE, random in STRESS.
  task automatic stage_delay(input int fixed,input int channel,maximum,counter);
    if(stress)delay_cycles(channel,maximum,counter);
    else if(fixed>0)repeat(fixed)@(negedge clk);
  endtask
  task automatic source_gap(input int channel,counter);
    if(stress&&random_limit(channel,15)==0)delay_cycles(channel,7,counter);
  endtask
  task automatic barrier_wait(input int op);
    if(corners)begin
      barrier_hits[op]++;
      repeat(32)begin @(negedge clk);if(done_valid||!busy)$fatal(1,"early completion at barrier op=%0d",op);end
    end
  endtask

  // ---------------- channel primitives ----------------
  function automatic int resp_extra(input int channel);
    return stress?random_limit(channel,3):0;
  endfunction
  task automatic acc_rd_issue(input acc_sel_e sel,input int addr);
    acc_rd_item_t it;
    it.sel=sel;it.addr=10'(addr);acc_rd_q.push_back(it);
  endtask
  task automatic acc_wr_issue(input int addr,input logic [15:0][31:0] a,b);
    acc_write_t w;
    w='0;w.sel=ACC_OACC;w.addr=10'(addr);w.row_valid=row_mask(addr%PAIRS);
    w.data[0]=a;w.data[1]=b;acc_wr_q.push_back(w);
  endtask
  task automatic vm_issue(input control_command_t c,input control_buffer_e buf_id,input bit bank,
    input int index,input bit write,input logic [15:0][31:0] data);
    control_memory_req_t req;
    req='0;req.token=c.token;req.buffer_id=buf_id;req.index=6'(index);req.bank=bank;req.write=write;
    req.mask=buf_id==WORK_SCORE?'1:16'b1;req.data=data;vm_req_q.push_back(req);
  endtask
  task automatic vm_stat_write(input control_command_t c,input control_buffer_e buffer_id,
    input int index,input logic [15:0][31:0] data);
    control_memory_req_t request_item;
    request_item='0;request_item.token=c.token;request_item.buffer_id=buffer_id;
    request_item.index=6'(index);request_item.write=1;request_item.data=data;
    for(int i=0;i<TILE;i++)request_item.mask[i]=(index+i<ROWS);
    vm_req_q.push_back(request_item);
  endtask
  task automatic fm_issue(input control_command_t c,input control_buffer_e buf_id,input bit bank,
    input int index,input bit write,input logic [15:0][31:0] data);
    control_memory_req_t req;
    req='0;req.token=c.token;req.buffer_id=buf_id;req.index=6'(index);req.bank=bank;req.write=write;
    req.mask=buf_id==WORK_SCORE?'1:16'b1;req.data=data;fm_req_q.push_back(req);
  endtask
  task automatic acc_collect(output logic [15:0][31:0] a,b);
    logic [1023:0] payload;
    while(acc_rsp_q.size()==0)@(negedge clk);
    payload=acc_rsp_q.pop_front();{b,a}=payload;
  endtask
  task automatic vm_collect(output control_memory_rsp_t r);
    while(vm_rsp_q.size()==0)@(negedge clk);
    r=vm_rsp_q.pop_front();
  endtask
  task automatic fm_collect(output control_memory_rsp_t r);
    while(fm_rsp_q.size()==0)@(negedge clk);
    r=fm_rsp_q.pop_front();
  endtask
  task automatic rope_collect(output control_rope_rsp_t r);
    while(rope_rsp_q.size()==0)@(negedge clk);
    r=rope_rsp_q.pop_front();
  endtask
  // Unit completion drains only that unit's channels. SFU workspace traffic
  // may continue independently while the VPU returns its completion token.
  task automatic drain_vector_channels;
    while(acc_rd_q.size()||acc_wr_q.size()||vm_req_q.size()||rope_req_q.size()||
          acc_age.size()||vm_age.size()||rope_age.size()||
          acc_rsp_q.size()||vm_rsp_q.size()||rope_rsp_q.size()||rope_sfu_rsp_q.size())
      @(negedge clk);
  endtask
  task automatic drain_function_channels;
    while(fm_req_q.size()||fm_age.size()||fm_rsp_q.size())@(negedge clk);
  endtask
  // SFU4 / VPU32 release budget: lane throughput, not latency, limits the stream.
  task automatic pace_beat(input int values,input int lanes);
    int due;
    @(negedge clk);
    fpace_n++;
    due=fpace_ref+((fpace_n*values)+lanes-1)/lanes;
    while(cycle<due)@(negedge clk);
  endtask

  function automatic logic [31:0] bits(input real x);shortreal s;s=x;return $shortrealtobits(s);endfunction
  function automatic real real32(input logic [31:0] x);return real'($bitstoshortreal(x));endfunction
  function automatic logic [31:0] mul32(input logic [31:0] a,b);return bits(real32(a)*real32(b));endfunction
  function automatic int aint(input int row);return row%3-1;endfunction
  function automatic qvec16_t qv(input int x);qvec16_t v;v.scale=128;for(int i=0;i<TILE;i++)v.data[i*8+:8]=8'(x);return v;endfunction
  function automatic qvec16_t quant(input logic [15:0][31:0] x);
    real mx,step,v,f;int e,b,q;qvec16_t out;
    mx=0;for(int i=0;i<TILE;i++)begin v=real32(x[i]);if(v<0)v=-v;if(v>mx)mx=v;end
    step=2.0**(-133);e=0;
    while(e<254&&mx>127.0*step)begin step*=2.0;e++;end
    out='0;out.scale=8'(e);
    for(int i=0;i<TILE;i++)begin
      v=real32(x[i])/step;b=int'($floor(v));f=v-real'(b);
      q=b+int'(f>0.5||(f==0.5&&(b%2)!=0));if(q>127)q=127;if(q< -128)q=-128;
      out.data[i*8+:8]=8'(q);
    end
    return out;
  endfunction
  function automatic int feature(input pcore_op_e op,input int n);
    return op==OP_Q_PROJ?n/2+(n%2)*8:n;
  endfunction
  function automatic int bint(input pcore_op_e op,input int n,col,input bit up);
    if(op==OP_GU)return up?2:1;
    if(op==OP_Q_PROJ||op==OP_K_PROJ||op==OP_V_PROJ)return 1+(feature(op,n)*TILE+col)%3;
    return 1;
  endfunction
  function automatic logic [31:0] dot_part(input qvec16_t a,input int b,e,fold);
    int dot,lead;logic [31:0] mag,norm;
    dot=0;for(int i=0;i<TILE;i++)dot+=int'($signed(a.data[8*i+:8]))*b;
    mag=dot<0?-dot:dot;lead=0;for(int i=0;i<32;i++)if(mag[i])lead=i;
    norm=mag<<(31-lead);
    return fp32_legacy_ref_pkg::pack_scaled32(dot<0,norm,lead+int'(a.scale)+e-266+fold,dot==0,0);
  endfunction
  function automatic logic [31:0] projection_golden(input pcore_op_e op,input int row,n,col);
    if(op==OP_O_PROJ||op==OP_DOWN_PROJ)return reduced_gold[op][row];
    return bits(real'(aint(row)*bint(op,n,col,0)));
  endfunction
  function automatic logic [31:0] local_projection_golden(input pcore_op_e op,input int row);
    logic [31:0] v;int count;qvec16_t a;
    count=op==OP_O_PROJ?16:(op==OP_DOWN_PROJ?32:64);v=0;
    for(int k=0;k<count;k++)begin
      a=op==OP_O_PROJ?ogold[k][row]:(op==OP_DOWN_PROJ?zgold[k][row]:qv(aint(row)));
      v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(a,1,128,0));
    end
    return v;
  endfunction

  // ---------------- source agents ----------------
  // A source beat holds its payload until it is accepted so back-to-back beats
  // cost one cycle instead of two; stress gaps drop valid before pausing.
  task automatic send_b(input int transport,group,n,input bit is_kvb,input int block,input bit pv);
    b2_t b;b='0;b.tile_idx=TILE_BITS'(transport);b.group_idx=3'(group);b.epoch=job.header.epoch;
    for(int c=0;c<2;c++)begin
      b.col[c]=qv(0);
      for(int i=0;i<TILE;i++)b.col[c].data[i*8+:8]=8'(is_kvb?(pv?1:1+block%3):bint(job.header.op,n,2*group+c,transport[0]));
    end
    @(negedge clk);
    if(stress&&random_limit(is_kvb?2:1,15)==0)begin
      if(is_kvb)kv_valid=0;else hbm_valid=0;
      delay_cycles(is_kvb?2:1,7,is_kvb?2:1);
    end
    if(is_kvb)begin kv_entry=b;kv_valid=1;do @(posedge clk);while(!kv_ready);end
    else begin hbm_entry=b;hbm_valid=1;do @(posedge clk);while(!hbm_ready);end
  endtask
  task automatic send_xbc(input int k,g);
    @(negedge clk);
    if(stress&&random_limit(0,15)==0)begin xbc_valid=0;delay_cycles(0,7,0);end
    xbc_entry='0;xbc_entry.tile_idx=TILE_BITS'(k);xbc_entry.group_idx=4'(g);
    xbc_entry.row_valid=g==XBC_GROUPS-1?4'b0111:4'b1111;
    for(int r=0;r<4;r++)xbc_entry.row[r]=qv(aint(4*g+r));
    xbc_valid=1;do @(posedge clk);while(!xbc_ready);
  endtask
  // Retire only the transport this branch owns: the sibling branch may still
  // be holding a valid beat against a stalled sink.
  task automatic source_stop(input bit xbc_st,input bit kv_st);
    @(negedge clk);
    if(xbc_st)xbc_valid=0;
    if(kv_st)begin hbm_valid=0;kv_valid=0;end
  endtask
  task automatic feed_projection(input int nt,kt,input bit local_a);
    fork
      begin
        if(stress&&!local_a)begin
          int pause;pause=(seed+int'(job.header.op))%2?320:32;
          coverage[0]+=pause;repeat(pause)@(negedge clk);
        end
        if(!local_a)for(int n=0;n<nt;n++)for(int k=0;k<kt;k++)for(int g=0;g<XBC_GROUPS;g++)send_xbc(k,g);
        source_stop(1,0);
      end
      begin
        if(stress)begin
          int pause;pause=(seed+int'(job.header.op))%2?32:320;
          coverage[1]+=pause;repeat(pause)@(negedge clk);
        end
        for(int n=0;n<nt;n++)for(int k=0;k<kt;k++)for(int g=0;g<TILE/2;g++)
          send_b(local_a?(n*kt+k)%64:k,g,n,0,0,0);
        source_stop(0,1);
      end
    join
  endtask
  task automatic feed_gu;
    fork
      begin
        if(stress)begin coverage[0]+=128;repeat(128)@(negedge clk);end
        for(int n=0;n<32;n++)begin
          if(n>0)wait(allowed_n>=n);
          for(int k=0;k<64;k++)for(int g=0;g<XBC_GROUPS;g++)send_xbc(k,g);
        end
        source_stop(1,0);
      end
      begin
        if(stress)begin coverage[1]+=256;repeat(256)@(negedge clk);end
        for(int n=0;n<32;n++)for(int t=0;t<128;t++)for(int g=0;g<8;g++)send_b(t%64,g,n,0,0,0);
        source_stop(0,1);
      end
    join
  endtask
  task automatic feed_attention;
    int b;bit pv_job;
    if(stress)begin coverage[2]+=160;repeat(160)@(negedge clk);end
    for(int j=0;j<110;j++)begin
      delay_cycles(2,15,2);
      if(j==0)begin b=0;pv_job=0;end
      else if(j==109)begin b=54;pv_job=1;end
      else begin pv_job=!j[0];b=j[0]?(j+1)/2:j/2-1;end
      for(int t=0;t<16;t++)for(int g=0;g<8;g++)begin
        if(j==109&&t==15&&g==7)begin
          // Hold the last accepted beat off the wire before the completion corner.
          @(negedge clk);kv_valid=0;hbm_valid=0;barrier_wait(OP_ATTENTION);
        end
        send_b((j*16+t)%64,g,0,1,b,pv_job);
      end
    end
    source_stop(1,1);
  endtask

  // ---------------- result emission ----------------
  // Result identity is checked by the DUT (index/token), so a held valid can
  // never be consumed twice; hold_result lets the agents stream at II=1 while
  // the manual fault environment keeps the legacy one-beat-per-two-cycles.
  task automatic result_pair(input control_command_t c,input int tile,p,input qvec16_t a,b,input bit token_axis,input logic [15:0] mask);
    // A held beat is consumed on the next rising edge, so a stress pause must
    // park the channel low first or the DUT would re-take the stale payload.
    if(stress)begin @(negedge clk);vector_result_valid=0;end
    delay_cycles(5,5,5);
    if(c.job.header.op==OP_Q_PROJ&&tile==15&&p==PAIRS-1)begin
      @(negedge clk);vector_result_valid=0;barrier_wait(OP_Q_PROJ);
    end
    if(c.job.header.op==OP_GU&&tile==31&&p==PAIRS-1)begin
      @(negedge clk);vector_result_valid=0;barrier_wait(OP_GU);
    end
    if(c.function_id==VECTOR_AFIN_QUANT&&tile==15&&p==PAIRS-1)begin
      @(negedge clk);vector_result_valid=0;barrier_wait(OP_ATTENTION);
    end
    if(clk!==1'b0)@(negedge clk);
    vector_result='0;vector_result.token=c.token;vector_result.tile=6'(tile);vector_result.index=10'(p);
    vector_result.quant_axis=token_axis?QUANT_TOKEN_B16:QUANT_FEATURE_B16;
    vector_result.vector_valid=token_axis?2'b11:row_mask(p);vector_result.token_mask=mask;
    vector_result.vector_data[0]=a;vector_result.vector_data[1]=b;
    vector_result.last=p==(token_axis?31:PAIRS-1);vector_result_valid=1;
    do @(posedge clk);while(!vector_result_ready);
    @(negedge clk);vector_result_valid=0;
  endtask

  // ---------------- legacy manual helpers (fault environment) ----------------
  task automatic memory_access(input control_command_t c,input bit sf,input control_buffer_e buffer_id,
    input int index,input bit bank,write,input logic [15:0][31:0] payload,output logic [15:0][31:0] value);
    control_memory_req_t req;
    req='0;req.token=c.token;req.buffer_id=buffer_id;req.index=6'(index);req.bank=bank;req.write=write;
    req.mask=buffer_id==WORK_SCORE?'1:16'b1;req.data=payload;
    @(negedge clk);
    if(sf)begin
      function_mem_req=req;function_mem_valid=1;do @(posedge clk);while(!function_mem_ready);
      @(negedge clk);function_mem_valid=0;
      if(!write)begin
        delay_cycles(11,9,10);
        function_mem_out_ready=1;do @(posedge clk);while(!function_mem_out_valid);
        if(function_mem_out.token!=c.token)$fatal(1,"SFU memory response identity");value=function_mem_out.data;
        @(negedge clk);function_mem_out_ready=0;
      end
    end else begin
      vector_mem_req=req;vector_mem_valid=1;do @(posedge clk);while(!vector_mem_ready);
      @(negedge clk);vector_mem_valid=0;
      if(!write)begin
        delay_cycles(10,9,10);
        vector_mem_out_ready=1;do @(posedge clk);while(!vector_mem_out_valid);
        if(vector_mem_out.token!=c.token)$fatal(1,"VPU memory response identity");value=vector_mem_out.data;
        @(negedge clk);vector_mem_out_ready=0;
      end
    end
  endtask

  // ---------------- vector (VPU32) agent ----------------
  // Drop ready on the same negedge that captures the beat: any cycle the agent
  // spends on post work must not let the DUT retire a second unobserved beat.
  task automatic recv_vbeat(output control_fp_data_t d);
    vector_data_ready=1;
    do @(posedge clk);while(!vector_data_valid);
    d=vector_data;@(negedge clk);vector_data_ready=0;
  endtask
  task automatic rope_quant(input control_command_t c);
    control_fp_data_t d;control_rope_rsp_t rr;int tile;
    control_rope_req_t request_item;
    logic [15:0][31:0] va[ROWS],vb[ROWS];
    logic [$bits(qvec16_t)-1:0] qa[ROWS],qb[ROWS];
    for(int r=0;r<ROWS;r++)begin
      request_item='0;request_item.token=c.token;request_item.row=6'(r);
      request_item.position=16'(c.job.position_base+r);request_item.frequency_base=c.rope_frequency_base;
      rope_req_q.push_back(request_item);
    end
    for(int r=0;r<ROWS;r++)begin
      recv_vbeat(d);
      if(d.index!=r||d.token!=c.token||d.job!=c.job||!d.vector_valid[0])$fatal(1,"RoPE stream identity");
      va[r]=d.first;vb[r]=d.second;
      for(int i=0;i<TILE;i++)begin
        if(d.first[i]!==projection_golden(c.job.header.op,r,c.tile-1,i)||d.second[i]!==projection_golden(c.job.header.op,r,c.tile,i))$fatal(1,"RoPE matrix golden");
      end
    end
    vector_data_ready=0;
    for(int r=0;r<ROWS;r++)begin
      rope_collect(rr);
      for(int i=0;i<TILE;i++)begin
        scratch0[r][i]=bits(real32(va[r][i])*real32(rr.cosine[i])-real32(vb[r][i])*real32(rr.sine[i]));
        scratch1[r][i]=bits(real32(vb[r][i])*real32(rr.cosine[i])+real32(va[r][i])*real32(rr.sine[i]));
      end
      qa[r]=quant(scratch0[r]);qb[r]=quant(scratch1[r]);
    end
    for(int h=0;h<2;h++)begin
      tile=c.job.header.op==OP_Q_PROJ?c.tile/2+h*8:h;
      for(int r=0;r<ROWS;r++)begin
        if(c.job.header.op==OP_Q_PROJ)qgold[tile][r]=h?qb[r]:qa[r];
        else kgold[tile][r]=h?qb[r]:qa[r];
      end
      for(int p=0;p<PAIRS;p++)result_pair(c,tile,p,h?qb[2*p]:qa[2*p],p<25?(h?qb[2*p+1]:qa[2*p+1]):'0,0,'1);
    end
  endtask
  task automatic v_quant(input control_command_t c);
    control_fp_data_t d;
    logic [15:0][31:0] a,b;
    logic [$bits(qvec16_t)-1:0] qa[V_PACKETS_PER_TILE],qb[V_PACKETS_PER_TILE];
    for(int j=0;j<V_PACKETS_PER_TILE;j++)begin
      recv_vbeat(d);
      for(int i=0;i<TILE;i++)begin
        int row,col;row=(j/8)*16+i;col=(j%8)*2;
        if(row<ROWS&&(d.first[i]!==projection_golden(OP_V_PROJ,row,c.tile,col)||d.second[i]!==projection_golden(OP_V_PROJ,row,c.tile,col+1)))$fatal(1,"V token packing golden");
        if(row>=ROWS&&(d.first[i]!=0||d.second[i]!=0||d.token_mask[i]))$fatal(1,"V padding");
      end
      a=d.first;b=d.second;
      vgold[c.tile][j]=quant(a);qa[j]=quant(a);qb[j]=quant(b);
    end
    vector_data_ready=0;
    for(int j=0;j<V_PACKETS_PER_TILE;j++)result_pair(c,c.tile,j,qa[j],qb[j],1,j>=24?16'h7:16'hffff);
  endtask
  task automatic gu_post(input control_command_t c);
    control_fp_data_t d;
    logic [$bits(qvec16_t)-1:0] qz[ROWS];
    for(int r=0;r<ROWS;r++)begin
      recv_vbeat(d);
      if(d.index!=r||d.second[0]!==bits(2.0*aint(r)))$fatal(1,"GU Up pair");
      for(int i=0;i<TILE;i++)scratch0[r][i]=mul32(d.first[i],d.second[i]);
      zgold[c.tile][r]=quant(scratch0[r]);qz[r]=zgold[c.tile][r];
    end
    vector_data_ready=0;
    for(int p=0;p<PAIRS;p++)result_pair(c,c.tile,p,qz[2*p],p<25?qz[2*p+1]:'0,0,'1);
  endtask
  // Statistics use the existing 16-row workspace spans; SCORE stays full-row.
  task automatic qk_post(input control_command_t c);
    logic [15:0][31:0] a,b,stat,wdata;control_memory_rsp_t rsp;
    logic [31:0] v,old_m,nm;
    logic [31:0] old_max[ROWS],aa_value[ROWS];
    acc_sel_e facc=c.attention_vpu.facc_bank?ACC_FACC_B:ACC_FACC_A;
    for(int p=0;p<PAIRS;p++)acc_rd_issue(facc,p);
    for(int base=0;base<ROWS;base+=TILE)vm_issue(c,WORK_M,1'b0,base,0,'0);
    for(int base=0;base<ROWS;base+=TILE)begin
      vm_collect(rsp);stat=rsp.data;
      for(int i=0;i<TILE;i++)if(base+i<ROWS)begin
        old_max[base+i]=stat[i];
        if(stat[i]!==m[base+i])$fatal(1,"M span readback row=%0d",base+i);
      end
    end
    for(int p=0;p<PAIRS;p++)begin
      acc_collect(a,b);
      for(int r=0;r<2;r++)if(2*p+r<ROWS)begin
        v=0;
        for(int k=0;k<TILE;k++)v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(qgold[k][2*p+r],1+c.tile%3,128,-4));
        for(int i=0;i<TILE;i++)begin
          if((r?b[i]:a[i])!==v)
            $fatal(1,"QK numerical golden block=%0d row=%0d lane=%0d got=%h exp=%h",c.tile,2*p+r,i,r?b[i]:a[i],v);
          score[c.tile][2*p+r][i]=(2*p+r==0||(c.tile==54&&i==15))?32'hff800000:v;
        end
        wdata='0;
        for(int i=0;i<TILE;i++)wdata[i]=score[c.tile][2*p+r][i];
        vm_issue(c,WORK_SCORE,c.tile[0],2*p+r,1,wdata);
        old_m=old_max[2*p+r];nm=old_m;
        for(int i=0;i<TILE;i++)
          if(real32(score[c.tile][2*p+r][i])>real32(nm))nm=score[c.tile][2*p+r][i];
        // exp(old-new) is the cross-block scale; equal maxima mean no scale at
        // all, which also keeps an all -inf row free of NaN.
        aa_value[2*p+r]=(old_m==nm)?32'd0:bits(real32(old_m)-real32(nm));
        m[2*p+r]=nm;
      end
    end
    for(int base=0;base<ROWS;base+=TILE)begin
      wdata='0;for(int i=0;i<TILE;i++)if(base+i<ROWS)wdata[i]=m[base+i];
      vm_stat_write(c,WORK_M,base,wdata);
      wdata='0;for(int i=0;i<TILE;i++)if(base+i<ROWS)wdata[i]=aa_value[base+i];
      vm_stat_write(c,WORK_AA,base,wdata);
    end
  endtask
  // P_POST per block: consume the 26 P beats, read L and ALPHA for every row,
  // fold them into the running denominator and write L back (51 writes).
  task automatic p_post(input control_command_t c);
    control_fp_data_t d;control_memory_rsp_t lr,ar;
    logic [15:0][31:0] x,lstat,astat,wdata;logic [31:0] nl;
    logic [$bits(qvec16_t)-1:0] qa[PAIRS],qb[PAIRS];
    for(int p=0;p<PAIRS;p++)begin
      for(int r=0;r<2;r++)if(2*p+r<ROWS)begin
        vm_issue(c,WORK_L,1'b0,2*p+r,0,'0);
        vm_issue(c,WORK_ALPHA,c.tile[0],2*p+r,0,'0);
      end
    end
    for(int p=0;p<PAIRS;p++)begin
      recv_vbeat(d);
      if(d.index!=p||d.tile!=c.tile||d.token!=c.token)$fatal(1,"P stream identity");
      for(int r=0;r<2;r++)if(2*p+r<ROWS)begin
        vm_collect(lr);lstat=lr.data;
        vm_collect(ar);astat=ar.data;
        x=r?d.second:d.first;
        if(lstat[0]!==lsum[2*p+r])$fatal(1,"L readback row=%0d got=%h exp=%h",2*p+r,lstat[0],lsum[2*p+r]);
        if(astat[0]!==alpha[c.tile][2*p+r][0])
          $fatal(1,"ALPHA readback block=%0d row=%0d got=%h exp=%h",c.tile,2*p+r,astat[0],alpha[c.tile][2*p+r][0]);
        nl=mul32(lsum[2*p+r],astat[0]);
        for(int i=0;i<TILE;i++)nl=fp32_legacy_ref_pkg::fp32_add(nl,x[i]);
        wdata='0;wdata[0]=nl;vm_issue(c,WORK_L,1'b0,2*p+r,1,wdata);
        lsum[2*p+r]=nl;
        pgold[c.tile][2*p+r]=quant(x);
        if(r)qb[p]=pgold[c.tile][2*p+r];else qa[p]=pgold[c.tile][2*p+r];
      end
      result_pair(c,c.tile,p,qa[p],p<25?qb[p]:'0,0,'1);
    end
  endtask
  task automatic oacc_scale(input control_command_t c);
    logic [15:0][31:0] a,b,stat,dummy;logic [31:0] v;
    control_memory_rsp_t rsp;
    for(int t=0;t<QOZ_O_TILES;t++)for(int p=0;p<PAIRS;p++)begin
      acc_rd_issue(ACC_OACC,t*PAIRS+p);
      vm_issue(c,WORK_ALPHA,c.tile[0],2*p,0,'0);
    end
    for(int r=0;r<ROWS;r++)begin
      v=0;
      for(int block=0;block<int'(c.tile);block++)begin
        if(block>0)v=mul32(v,alpha[block][r][0]);
        v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(pgold[block][r],1,128,0));
      end
      attention_gold[r]=v;
    end
    for(int t=0;t<QOZ_O_TILES;t++)for(int p=0;p<PAIRS;p++)begin
      acc_collect(a,b);
      vm_collect(rsp);
      for(int i=0;i<TILE;i++)begin
        if(a[i]!==attention_gold[2*p]||(p<25&&b[i]!==attention_gold[2*p+1]))
          $fatal(1,"PV before SCALE block=%0d tile=%0d pair=%0d lane=%0d even=%h expected=%h odd=%h expected_odd=%h",c.tile,t,p,i,a[i],attention_gold[2*p],b[i],attention_gold[2*p+1]);
      end
      stat=rsp.data;
      for(int i=0;i<TILE;i++)begin a[i]=mul32(a[i],stat[0]);if(p<25)b[i]=mul32(b[i],stat[1]);end
      acc_wr_issue(t*PAIRS+p,a,b);
    end
  endtask
  task automatic afin_quant(input control_command_t c);
    logic [15:0][31:0] a,b,stat,dummy;control_memory_rsp_t rsp;logic [31:0] v;
    for(int t=0;t<QOZ_O_TILES;t++)for(int p=0;p<PAIRS;p++)begin
      acc_rd_issue(ACC_OACC,t*PAIRS+p);
      vm_issue(c,WORK_RECIP,0,2*p,0,'0);
    end
    for(int r=0;r<ROWS;r++)begin
      v=0;
      for(int block=0;block<KV_BLOCKS;block++)begin
        if(block>0)v=mul32(v,alpha[block][r][0]);
        v=fp32_legacy_ref_pkg::fp32_add(v,dot_part(pgold[block][r],1,128,0));
      end
      attention_gold[r]=v;
    end
    for(int t=0;t<QOZ_O_TILES;t++)for(int p=0;p<PAIRS;p++)begin
      acc_collect(a,b);
      vm_collect(rsp);stat=rsp.data;
      for(int i=0;i<TILE;i++)begin
        if(a[i]!==attention_gold[2*p]||(p<25&&b[i]!==attention_gold[2*p+1]))$fatal(1,"PV OACC golden tile=%0d pair=%0d even=%h expected=%h odd=%h expected_odd=%h",t,p,i,a[i],attention_gold[2*p],b[i],attention_gold[2*p+1]);
        if(stat[0]!==recip[2*p]||(p<25&&stat[1]!==recip[2*p+1]))$fatal(1,"reciprocal memory");
        a[i]=mul32(a[i],stat[0]);if(p<25)b[i]=mul32(b[i],stat[1]);
      end
      ogold[t][2*p]=quant(a);if(p<25)ogold[t][2*p+1]=quant(b);
      result_pair(c,t,p,ogold[t][2*p],p<25?ogold[t][2*p+1]:'0,0,'1);
    end
  endtask
  task automatic vector_agent;
    control_command_t c;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(vector_valid&&vector_ready)begin
        c=vector_cmd;commands[c.job.header.op]++;@(negedge clk);acc_token=c.token;
        vector_result_valid=0;vector_data_ready=0;hold_result=1;
        vstage_start=cycle;
        stage_delay(VPU_CMD_LAT,5,37,5);
        if(corners&&(c.function_id==VECTOR_AFIN_QUANT))barrier_wait(OP_ATTENTION);
        if(c.function_id==VECTOR_OACC_SCALE||c.function_id==VECTOR_AFIN_QUANT)begin
          if(c.elements!=ROWS*TILE*QOZ_O_TILES||c.tiles!=QOZ_O_TILES||c.source!=WORK_OACC)
            $fatal(1,"OACC command descriptor");
        end else if(c.elements!=ROWS*TILE*(c.function_id==VECTOR_ROPE_QUANT?2:1))
          $fatal(1,"vector command element count");
        if(c.function_id==VECTOR_QK_POST&&(c.source!=WORK_FACC||c.destination!=WORK_SCORE))$fatal(1,"QK descriptor");
        if((c.job.header.op==OP_K_PROJ||c.job.header.op==OP_V_PROJ)&&c.destination!=WORK_KV_OUT)$fatal(1,"KV descriptor");
        case(c.function_id)
          VECTOR_ROPE_QUANT:rope_quant(c);
          VECTOR_V_QUANT:v_quant(c);
          VECTOR_GU_POST:gu_post(c);
          VECTOR_QK_POST:qk_post(c);
          VECTOR_P_POST:p_post(c);
          VECTOR_OACC_SCALE:oacc_scale(c);
          VECTOR_AFIN_QUANT:afin_quant(c);
          default:$fatal(1,"unexpected vector function");
        endcase
        @(negedge clk);vector_result_valid=0;vector_data_ready=0;hold_result=0;
        drain_vector_channels();
        vstage_end=cycle;
        if(vstage_end-vstage_start>stage_dur_max[c.function_id])stage_dur_max[c.function_id]=vstage_end-vstage_start;
        if(c.function_id==VECTOR_OACC_SCALE)begin
          scale_cycles=vstage_end-vstage_start;
          scale_margin_min=ATTN_SLOT-scale_cycles;
        end
        stage_delay(VPU_DONE_LAT,7,31,7);
        @(negedge clk);vector_done='{command:c,error:0};vector_done_valid=1;
        do @(posedge clk);while(!vector_done_ready);@(negedge clk);vector_done_valid=0;
      end
    end
  endtask

  // ---------------- function (SFU4) agent ----------------
  task automatic function_agent;
    control_command_t c;control_fp_data_t d;control_memory_rsp_t rsp;real x,t;
    logic [15:0][31:0] sc,stat;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(function_valid&&function_ready)begin
        c=function_cmd;@(negedge clk);
        function_commands++;
        function_result_valid=0;function_data_ready=0;
        fstage_start=cycle;
        stage_delay(SFU_CMD_LAT,6,37,6);
        fpace_n=0;fpace_ref=cycle;
        if(corners&&c.function_id==FUNCTION_RECIP)barrier_wait(OP_ATTENTION);
        if(c.elements!=((c.function_id==FUNCTION_GELU||c.function_id==FUNCTION_P_EXP)?ROWS*TILE:ROWS))
          $fatal(1,"SFU command element count");
        if(c.function_id==FUNCTION_GELU)begin
          for(int r=0;r<ROWS;r++)begin
            function_data_ready=1;do @(posedge clk);while(!function_data_valid);
            d=function_data;@(negedge clk);function_data_ready=0;
            if(d.index!=r||d.token!=c.token)$fatal(1,"GELU input token");
            function_result=d;
            for(int i=0;i<TILE;i++)begin
              if(d.first[i]!==bits(aint(r)))$fatal(1,"Gate golden");
              x=real32(d.first[i]);t=$sqrt(2.0/3.141592653589793)*(x+0.044715*x*x*x);
              function_result.first[i]=bits(0.5*x*(2.0/(1.0+$exp(-2.0*t))));
            end
            pace_beat(TILE,SFU_LANES);
            @(negedge clk);function_result_valid=1;
            do @(posedge clk);while(!function_result_ready);
            @(negedge clk);function_result_valid=0;
          end
        end else if(c.function_id==FUNCTION_P_EXP)begin
          for(int p=0;p<PAIRS;p++)begin
            fm_issue(c,WORK_SCORE,c.tile[0],2*p,0,'0);
            fm_issue(c,WORK_M,1'b0,2*p,0,'0);
            if(2*p+1<ROWS)begin
              fm_issue(c,WORK_SCORE,c.tile[0],2*p+1,0,'0);
              fm_issue(c,WORK_M,1'b0,2*p+1,0,'0);
            end
          end
          for(int p=0;p<PAIRS;p++)begin
            function_result='0;function_result.job=c.job;function_result.token=c.token;function_result.tile=c.tile;
            function_result.index=6'(p);function_result.last=p==PAIRS-1;function_result.vector_valid=row_mask(p);
            for(int lane=0;lane<2;lane++)if(2*p+lane<ROWS)begin
              fm_collect(rsp);sc=rsp.data;
              fm_collect(rsp);stat=rsp.data;
              if(stat[0]!==m[2*p+lane])$fatal(1,"M readback row=%0d got=%h exp=%h",2*p+lane,stat[0],m[2*p+lane]);
              for(int i=0;i<TILE;i++)begin
                if(sc[i]!==score[c.tile][2*p+lane][i])$fatal(1,"SBUF readback row=%0d lane=%0d",2*p+lane,i);
                if(lane==0)function_result.first[i]=(sc[i]==32'hff800000)?32'd0:bits($exp(real32(sc[i])-real32(stat[0])));
                else function_result.second[i]=(sc[i]==32'hff800000)?32'd0:bits($exp(real32(sc[i])-real32(stat[0])));
              end
            end
            pace_beat(2*TILE,SFU_LANES);
            @(negedge clk);function_result_valid=1;
            do @(posedge clk);while(!function_result_ready);
            @(negedge clk);function_result_valid=0;
          end
        end else if(c.function_id==FUNCTION_RECIP)begin
          for(int r=0;r<ROWS;r++)fm_issue(c,WORK_L,1'b0,r,0,'0);
          for(int r=0;r<ROWS;r++)begin
            fm_collect(rsp);stat=rsp.data;
            if(stat[0]!==lsum[r])$fatal(1,"RECIP L readback row=%0d got=%h exp=%h",r,stat[0],lsum[r]);
            recip[r]=stat[0]==0?0:bits(1.0/real32(stat[0]));stat[0]=recip[r];
            fm_issue(c,WORK_RECIP,1'b0,r,1,stat);
          end
        end else if(c.function_id==FUNCTION_ALPHA_EXP)begin
          for(int r=0;r<ROWS;r++)fm_issue(c,WORK_AA,1'b0,r,0,'0);
          for(int r=0;r<ROWS;r++)begin
            fm_collect(rsp);stat=rsp.data;
            stat[0]=bits($exp(real32(stat[0])));
            alpha[c.tile][r][0]=stat[0];
            fm_issue(c,WORK_ALPHA,c.tile[0],r,1,stat);
          end
        end else $fatal(1,"unexpected SFU function");
        @(negedge clk);function_result_valid=0;function_data_ready=0;
        drain_function_channels();
        fstage_end=cycle;
        if(fstage_end-fstage_start>stage_dur_max[c.function_id])stage_dur_max[c.function_id]=fstage_end-fstage_start;
        stage_delay(SFU_DONE_LAT,8,31,8);
        @(negedge clk);function_done='{command:c,error:0};function_done_valid=1;
        do @(posedge clk);while(!function_done_ready);@(negedge clk);function_done_valid=0;
      end
    end
  endtask

  // RoPE service: request accepted II=1, response released ROPE_LAT later.
  task automatic rope_agent;
    control_rope_req_t req;control_rope_rsp_t answer;real angle;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(rope_sfu_valid&&rope_sfu_ready)begin
        req=rope_sfu_req;answer='0;answer.request=req;
        for(int i=0;i<TILE;i++)begin
          angle=req.position*(10000.0**(-2.0*(req.frequency_base+i)/256.0));
          answer.cosine[i]=bits($cos(angle));answer.sine[i]=bits($sin(angle));
        end
        rope_sfu_rsp_q.push_back(answer);
      end
    end
  endtask
  // Present the oldest SFU answer until the DUT takes it. The queue itself is
  // retired on the accepting rising edge; the manual environment drives this
  // channel itself, so only the enabled agent may assign it.
  initial begin: rope_forwarder
    wait(!reset);
    forever begin
      @(negedge clk);
      if(agents_enabled&&!reset&&!clear)begin
        if(rope_sfu_rsp_q.size()>0)begin
          rope_sfu_out=rope_sfu_rsp_q[0];rope_sfu_out_valid=1;
        end else rope_sfu_out_valid=0;
      end
    end
  end
  initial begin: unit_agents
    forever begin
      wait(agents_enabled&&!reset&&!clear);
      fork
        vector_agent();
        function_agent();
        rope_agent();
        begin wait(!agents_enabled||clear||reset);end
      join_any
      disable fork;
    end
  end

  // ---------------- channel drivers and per-cycle bookkeeping ----------------
  always @(negedge clk)begin: channel_present
    acc_rd_item_t read_item;
    if(!reset&&agents_enabled)begin
    if(stress)begin
      kv_out_ready=random_limit(13,4)!=0;
      reduce_out_ready=random_limit(14,4)!=0;
      vector_ready=random_limit(3,4)!=0;
      function_ready=random_limit(4,4)!=0;
      rope_sfu_ready=random_limit(15,4)!=0;
    end else begin
      kv_out_ready=perf?1:cycle%7!=0;
      reduce_out_ready=perf?1:cycle%5!=0;
      vector_ready=perf?1:cycle%11!=0;
      function_ready=perf?1:cycle%13!=0;
      rope_sfu_ready=1;
    end
    if(corners&&kv_out_valid&&kv_out.last&&!kv_tail_seen)begin kv_tail_seen=1;kv_tail_hold=32;barrier_hits[job.header.op]++;end
    if(corners&&reduce_out_valid&&reduce_out.last&&!reduce_tail_seen)begin reduce_tail_seen=1;reduce_tail_hold=32;barrier_hits[job.header.op]++;end
    if(kv_tail_hold>0)begin kv_out_ready=0;kv_tail_hold--;if(done_valid)$fatal(1,"KV tail done");end
    if(reduce_tail_hold>0)begin reduce_out_ready=0;reduce_tail_hold--;if(done_valid)$fatal(1,"reduce tail done");end
    if(hold_kv)kv_out_ready=0;
    if(hold_reduce)reduce_out_ready=0;
    // Response release: LAT cycles after the request was accepted, II=1.
    acc_data_ready=acc_age.size()>0&&acc_age[0]>=ACC_RD_LAT-1;
    vector_mem_out_ready=vm_age.size()>0&&vm_age[0]>=WORK_RD_LAT-1;
    function_mem_out_ready=fm_age.size()>0&&fm_age[0]>=WORK_RD_LAT-1;
    rope_out_ready=rope_age.size()>0&&rope_age[0]>=ROPE_LAT-1;
    // Request presentation, one beat per cycle while the queue is non-empty.
    if(acc_rd_q.size()>0)begin read_item=acc_rd_q[0];acc_rd_valid=1;acc_rd_sel=read_item.sel;acc_rd_addr=read_item.addr;end
    else acc_rd_valid=0;
    if(acc_wr_q.size()>0)begin acc_wr_valid=1;acc_wr=acc_wr_q[0];end
    else acc_wr_valid=0;
    if(vm_req_q.size()>0)begin vector_mem_valid=1;vector_mem_req=vm_req_q[0];end
    else vector_mem_valid=0;
    if(fm_req_q.size()>0)begin function_mem_valid=1;function_mem_req=fm_req_q[0];end
    else function_mem_valid=0;
    if(rope_req_q.size()>0)begin rope_req_valid=1;rope_req=rope_req_q[0];end
    else rope_req_valid=0;
    end
  end

  always @(posedge clk)if(reset||clear)begin
    kv_stall=0;reduce_stall=0;vector_stall=0;function_stall=0;
    acc_stall=0;vm_stall=0;fm_stall=0;rope_stall=0;
    q_released=0;
    acc_rd_q.delete();acc_wr_q.delete();vm_req_q.delete();fm_req_q.delete();rope_req_q.delete();
    acc_age.delete();vm_age.delete();fm_age.delete();rope_age.delete();
    acc_rsp_q.delete();vm_rsp_q.delete();fm_rsp_q.delete();rope_rsp_q.delete();rope_sfu_rsp_q.delete();
  end else begin
    cycle++;
    if(!agents_enabled)begin
      acc_rd_q.delete();acc_wr_q.delete();vm_req_q.delete();fm_req_q.delete();rope_req_q.delete();
      acc_age.delete();vm_age.delete();fm_age.delete();rope_age.delete();
      acc_rsp_q.delete();vm_rsp_q.delete();fm_rsp_q.delete();rope_rsp_q.delete();rope_sfu_rsp_q.delete();
    end else begin
      // Request acceptance pops the queue head and starts the response timer.
      // The timer starts one below zero so that LAT is measured from the
      // accepting edge, not from the edge that already carried it.
      if(acc_rd_valid&&acc_rd_ready)begin acc_rd_q.pop_front();acc_age.push_back(-1-resp_extra(9));end
      if(acc_wr_valid&&acc_wr_ready)acc_wr_q.pop_front();
      if(vector_mem_valid&&vector_mem_ready)begin
        vm_req_q.pop_front();
        if(!vector_mem_req.write)vm_age.push_back(-1-resp_extra(10));
      end
      if(function_mem_valid&&function_mem_ready)begin
        fm_req_q.pop_front();
        if(!function_mem_req.write)fm_age.push_back(-1-resp_extra(10));
      end
      if(rope_req_valid&&rope_req_ready)rope_req_q.pop_front();
      // Response transfer captures the payload for the waiting collector.
      if(acc_data_valid&&acc_data_ready)begin acc_rsp_q.push_back({acc_odd,acc_even});void'(acc_age.pop_front());end
      if(vector_mem_out_valid&&vector_mem_out_ready)begin vm_rsp_q.push_back(vector_mem_out);void'(vm_age.pop_front());end
      if(function_mem_out_valid&&function_mem_out_ready)begin fm_rsp_q.push_back(function_mem_out);void'(fm_age.pop_front());end
      if(rope_out_valid&&rope_out_ready)begin rope_rsp_q.push_back(rope_out);void'(rope_age.pop_front());end
      // RoPE hop: the external service answers in request order.
      if(rope_sfu_valid&&rope_sfu_ready)rope_age.push_back(-1-resp_extra(12));
      if(rope_sfu_out_valid&&rope_sfu_out_ready)void'(rope_sfu_rsp_q.pop_front());
      foreach(acc_age[i])acc_age[i]++;
      foreach(vm_age[i])vm_age[i]++;
      foreach(fm_age[i])fm_age[i]++;
      foreach(rope_age[i])rope_age[i]++;
    end
    if(cycle%10000==0)$display("CONTROL_PROGRESS cycle=%0d op=%0d issues=%0d post=%0d capture=%0d index=%0d vec=%0d sfu=%0d region=%0d",
      cycle,job.header.op,issues[job.header.op],dut.post_service.state_q,dut.post_service.capture_q,dut.post_service.index_q,
      dut.vheld_q.function_id,dut.fheld_q.function_id,qoz_region.owner);
    if(protocol_error&&!allow_fault)$fatal(1,"control fault status=%0d post=%b engine=%b op=%0d",dut.status_q,dut.se,dut.ee,job.header.op);
    if(xbc_valid&&!xbc_ready)coverage[13]++;
    if(hbm_valid&&!hbm_ready)coverage[14]++;
    if(kv_valid&&!kv_ready)coverage[15]++;
    if(vector_valid&&!vector_ready)coverage[3]++;
    if(function_valid&&!function_ready)coverage[4]++;
    if(acc_data_valid&&!acc_data_ready)coverage[9]++;
    if((vector_mem_out_valid&&!vector_mem_out_ready)||(function_mem_out_valid&&!function_mem_out_ready))coverage[10]++;
    if(rope_sfu_valid&&!rope_sfu_ready)coverage[11]++;
    if(rope_out_valid&&!rope_out_ready)coverage[12]++;
    if(kv_out_valid&&!kv_out_ready)coverage[16]++;
    if(reduce_out_valid&&!reduce_out_ready)coverage[17]++;
    if(dut.exec.dispatch.matrix.req_valid)begin
      if(issues[job.header.op]==0)first_issue_cyc[job.header.op]=cycle;
      issues[job.header.op]++;last_issue_cyc[job.header.op]=cycle;
    end
    if(dut.exec.dispatch.req.start&&active_adapter==1)begin
      matrix_jobs++;
      if(attn_start_n<1024)attn_start[attn_start_n]=cycle;
      attn_start_n++;
    end
    if(active_adapter==1&&dut.exec.attention.mdv&&dut.exec.attention.mdr)begin
      if(dut.exec.attention.md.op==MATRIX_PV)attn_pv_commits++;else attn_qk_commits++;
    end
    if(gu_prefetch_valid&&gu_prefetch_ready)allowed_n=gu_prefetch_n;
    if(kv_stall&&(!kv_out_valid||kv_out!==kv_hold))$fatal(1,"KV changed while stalled");
    if(reduce_stall&&(!reduce_out_valid||reduce_out!==reduce_hold))$fatal(1,"reduce changed while stalled");
    kv_stall=kv_out_valid&&!kv_out_ready;reduce_stall=reduce_out_valid&&!reduce_out_ready;kv_hold=kv_out;reduce_hold=reduce_out;
    if(vector_stall&&(!vector_valid||vector_cmd!==vector_hold))$fatal(1,"vector command changed while stalled");
    if(function_stall&&(!function_valid||function_cmd!==function_hold))$fatal(1,"function command changed while stalled");
    vector_stall=vector_valid&&!vector_ready;function_stall=function_valid&&!function_ready;vector_hold=vector_cmd;function_hold=function_cmd;
    if(acc_stall&&(!acc_data_valid||{acc_odd,acc_even}!==acc_hold))$fatal(1,"ACC response changed while stalled");
    if(vm_stall&&(!vector_mem_out_valid||vector_mem_out!==vm_hold))$fatal(1,"VPU memory response changed while stalled");
    if(fm_stall&&(!function_mem_out_valid||function_mem_out!==fm_hold))$fatal(1,"SFU memory response changed while stalled");
    if(rope_stall&&(!rope_out_valid||rope_out!==rope_hold))$fatal(1,"RoPE response changed while stalled");
    acc_stall=acc_data_valid&&!acc_data_ready;acc_hold={acc_odd,acc_even};
    vm_stall=vector_mem_out_valid&&!vector_mem_out_ready;vm_hold=vector_mem_out;
    fm_stall=function_mem_out_valid&&!function_mem_out_ready;fm_hold=function_mem_out;
    rope_stall=rope_out_valid&&!rope_out_ready;rope_hold=rope_out;
    if(active_adapter==1&&dut.exec.qout&&dut.exec.qout_ready)lifecycle_reads++;
    if(active_adapter==1&&dut.exec.qrelease&&dut.exec.qrelease_ready)begin
      if(dut.exec.qoz.store.rd_out_valid||dut.exec.qread)$fatal(1,"Q release before reads drain");
      q_released=1;lifecycle_releases++;
    end
    if(active_adapter==1&&dut.exec.qoz_req_valid&&dut.exec.region_req_ready&&dut.exec.qoz_req.owner==QOZ_O)begin
      if(!q_released)$fatal(1,"O acquire before Q release");
      lifecycle_o_acquires++;
    end
    if(active_adapter==1&&dut.exec.attention.mdv&&dut.exec.attention.mdr&&dut.exec.attention.md.op==MATRIX_PV&&dut.exec.attention.md.block_id==54)pv54_commits++;
    if(function_valid&&function_ready&&function_cmd.function_id==FUNCTION_RECIP&&pv54_commits!=1)$fatal(1,"RECIP before PV54 commit");
    if(vector_result_valid&&vector_result_ready)last_post_cyc[job.header.op]=cycle;
    if(function_result_valid&&function_result_ready)last_post_cyc[job.header.op]=cycle;
    if(kv_out_valid&&kv_out_ready)begin
      qvec16_t expected;int tile,p,r;
      last_egress_cyc[job.header.op]=cycle;
      tile=kv_out.tile;p=kv_out.index;
      if(!kv_out.quantized||kv_out.op!=(job.header.op==OP_K_PROJ?COLLECT_K:COLLECT_V))$fatal(1,"KV layout/type");
      if(kv_out.feature_base!==(job.header.op==OP_K_PROJ?16'(job.rope_pair_base+tile*128):16'(job.core_id*32+tile*TILE+(p%8)*2)))$fatal(1,"KV feature coordinate");
      if(kv_out.token_base!==(job.header.op==OP_K_PROJ?16'(p*2):16'((p/8)*16)))$fatal(1,"KV token coordinate");
      if(kv_out.vector_valid!==(job.header.op==OP_K_PROJ?row_mask(p):2'b11)||kv_out.token_mask!==(job.header.op==OP_V_PROJ&&p>=24?16'h0007:16'hffff))$fatal(1,"KV mask");
      if(kv_out.job!=job||sent[job.header.op]!=(job.header.op==OP_K_PROJ?tile*PAIRS+p:tile*32+p))$fatal(1,"KV order/context");
      for(int lane=0;lane<2;lane++)if(kv_out.vector_valid[lane])begin
        if(job.header.op==OP_K_PROJ)expected=kgold[tile][2*p+lane];
        else begin
          logic [15:0][31:0] vals;
          for(int i=0;i<TILE;i++)vals[i]=(p/8*16+i<ROWS)?projection_golden(OP_V_PROJ,p/8*16+i,tile,p%8*2+lane):0;
          expected=quant(vals);
        end
        if(kv_out.scales[lane]!==expected.scale)$fatal(1,"KV scale");
        for(int i=0;i<TILE;i++)if(kv_out.payload[lane][i][7:0]!==expected.data[i*8+:8])$fatal(1,"KV data");
      end
      if(kv_out.last!=(tile==1&&kv_out.tile_last))$fatal(1,"KV last");
      sent[job.header.op]++;
    end
    if(reduce_out_valid&&reduce_out_ready)begin
      last_egress_cyc[job.header.op]=cycle;
      if(reduce_out.quantized||reduce_out.op!=(job.header.op==OP_O_PROJ?REDUCE_O:REDUCE_DOWN)||
         reduce_out.feature_base!=reduce_out.tile*TILE||reduce_out.token_base!=reduce_out.index*ROW_LANES||
         reduce_out.vector_valid!=row_mask(reduce_out.index))$fatal(1,"reduce layout/coordinate");
      if(reduce_out.job!=job||sent[job.header.op]!=reduce_out.tile*PAIRS+reduce_out.index)$fatal(1,"reduce order/context");
      for(int r=0;r<2;r++)if(reduce_out.vector_valid[r])for(int i=0;i<TILE;i++)
        if(reduce_out.payload[r][i]!==projection_golden(job.header.op,2*reduce_out.index+r,reduce_out.tile,i))$fatal(1,"reduce numerical golden");
      sent[job.header.op]++;
    end
  end

  task automatic run_job(input pcore_op_e op,input int id,expected_issues);
    int job_cycles,span,steady_max,steady_sum,steady_n;
    if(op==OP_O_PROJ||op==OP_DOWN_PROJ)
      for(int r=0;r<ROWS;r++)reduced_gold[op][r]=local_projection_golden(op,r);
    @(negedge clk);job='0;job.header='{job_id:16'(id),epoch:4'd3,head:3'd1,op:op};
    job.data_context=16'h1234;job.user_tag=64'ha5a5000000000000|id;job.position_base=7;job.core_id=2;job.rope_pair_base=32;
    kv_tail_seen=0;reduce_tail_seen=0;
    if(op==OP_ATTENTION)attn_start_n=0;
    job_valid=1;do @(posedge clk);while(!job_ready);job_start=cycle;job_accept_cyc[op]=cycle;@(negedge clk);job_valid=0;
    fork
      begin
        case(op)
          OP_K_PROJ,OP_V_PROJ:feed_projection(2,64,0);
          OP_Q_PROJ:feed_projection(16,64,0);
          OP_ATTENTION:feed_attention();
          OP_O_PROJ:feed_projection(64,16,1);
          OP_GU:feed_gu();
          OP_DOWN_PROJ:feed_projection(64,32,1);
        endcase
      end
      begin
        wait(done_valid);
        done_cyc[op]=cycle;
        if(done.job!==job||done.status!=CONTROL_OK||issues[op]!=expected_issues)$fatal(1,"Job completion op=%0d issues=%0d expected=%0d",op,issues[op],expected_issues);
        $display("CONTROL_JOB op=%0d cycles=%0d issues=%0d sent=%0d commands=%0d",op,cycle-job_start,issues[op],sent[op],commands[op]);
        job_cycles=cycle-job_accept_cyc[op];
        span=last_issue_cyc[op]-first_issue_cyc[op]+1;
        $display("JOB_PERF op=%s cycles=%0d matrix_issues=%0d first_issue=%0d last_issue=%0d matrix_span=%0d matrix_util=%0d.%02d%% job_matrix_occupancy=%0d.%02d%% post_tail=%0d egress_tail=%0d commands=%0d",
          op_name(op),
          job_cycles,issues[op],first_issue_cyc[op],last_issue_cyc[op],span,
          issues[op]*100/span,(issues[op]*10000/span)%100,
          issues[op]*100/job_cycles,(issues[op]*10000/job_cycles)%100,
          done_cyc[op]-last_issue_cyc[op],done_cyc[op]-last_egress_cyc[op],commands[op]);
        if(op==OP_ATTENTION)begin
          steady_max=0;steady_sum=0;steady_n=0;
          for(int i=5;i+6<attn_start_n;i++)begin
            int iv;iv=attn_start[i+1]-attn_start[i];
            if(iv>steady_max)steady_max=iv;steady_sum+=iv;steady_n++;
          end
          $display("ATTN_PERF qk_jobs=%0d pv_jobs=%0d matrix_body=%0d steady_interval_max=%0d steady_interval_avg=%0d qk_post_max=%0d alpha_max=%0d p_exp_max=%0d p_post_max=%0d scale_cycles=%0d scale_margin_min=%0d recip=%0d afin=%0d total_cycles=%0d",
            attn_qk_commits,attn_pv_commits,issues[op],steady_max,
            steady_n?steady_sum/steady_n:0,stage_dur_max[VECTOR_QK_POST],stage_dur_max[FUNCTION_ALPHA_EXP],
            stage_dur_max[FUNCTION_P_EXP],stage_dur_max[VECTOR_P_POST],
            scale_cycles,scale_margin_min,stage_dur_max[FUNCTION_RECIP],stage_dur_max[VECTOR_AFIN_QUANT],job_cycles);
        end
        done_wait[op]=stress?4+random_limit(7,31):4;
        repeat(done_wait[op])begin @(negedge clk);if(!done_valid||job_ready||done.job!==job||done.status!=CONTROL_OK)$fatal(1,"completion hold");end
        done_ready=1;@(negedge clk);done_ready=0;completed++;
      end
    join
  endtask
  function automatic string op_name(input pcore_op_e op);
    case(op)
      OP_Q_PROJ:return "Q";OP_K_PROJ:return "K";OP_V_PROJ:return "V";
      OP_ATTENTION:return "ATTENTION";OP_O_PROJ:return "O";OP_GU:return "GU";default:return "DOWN";
    endcase
  endfunction
  task automatic prepare_q;
    logic [15:0][31:0] a,b;real angle,cs,sn,x,y;
    for(int group=0;group<8;group++)for(int r=0;r<ROWS;r++)begin
      for(int i=0;i<TILE;i++)begin
        x=aint(r)*bint(OP_Q_PROJ,2*group,i,0);y=aint(r)*bint(OP_Q_PROJ,2*group+1,i,0);
        angle=(7+r)*(10000.0**(-2.0*(group*TILE+i)/256.0));cs=real32(bits($cos(angle)));sn=real32(bits($sin(angle)));
        a[i]=bits(x*cs-y*sn);b[i]=bits(y*cs+x*sn);
      end
      qgold[group][r]=quant(a);qgold[group+8][r]=quant(b);
    end
    @(negedge clk);ext_qoz_region='0;ext_qoz_region.header='{job_id:16'd30,epoch:4'd3,head:3'd1,op:OP_Q_PROJ};
    ext_qoz_region.owner=QOZ_Q;ext_qoz_region.tiles=16;ext_qoz_region_valid=1;
    do @(posedge clk);while(!ext_qoz_region_ready);@(negedge clk);ext_qoz_region_valid=0;
    for(int t=0;t<16;t++)for(int p=0;p<PAIRS;p++)begin
      ext_qoz_wr='0;ext_qoz_wr.header=ext_qoz_region.header;ext_qoz_wr.n=6'(t);
      ext_qoz_wr.pair_data.tile_idx=6'(t);ext_qoz_wr.pair_data.pair_idx=PAIR_BITS'(p);
      ext_qoz_wr.pair_data.row_valid=row_mask(p);
      ext_qoz_wr.pair_data.row[0]=qgold[t][2*p];if(p<25)ext_qoz_wr.pair_data.row[1]=qgold[t][2*p+1];ext_qoz_wr.last=p==PAIRS-1;
      ext_qoz_wr_valid=1;do @(posedge clk);while(!ext_qoz_wr_ready);@(negedge clk);ext_qoz_wr_valid=0;
    end
  endtask
  initial begin
    string mode_s;
    agents_enabled=!MANUAL;
    if($value$plusargs("MODE=%s",mode_s))begin
      if(mode_s=="PERFORMANCE")mode=TB_PERFORMANCE;
      else if(mode_s=="STRESS")mode=TB_STRESS;
      else mode=TB_FUNCTIONAL;
    end else mode=$test$plusargs("STRESS")?TB_STRESS:TB_FUNCTIONAL;
    stress=(mode==TB_STRESS)||$test$plusargs("STRESS");
    perf=(mode==TB_PERFORMANCE)||(mode==TB_STRESS);
    corners=$test$plusargs("CORNERS");
    mode_name=(mode==TB_PERFORMANCE)?"PERFORMANCE":(mode==TB_STRESS)?"STRESS":"FUNCTIONAL";
    if($value$plusargs("SEED=%d",seed))begin end
    for(int i=0;i<20;i++)random_state[i]=32'(seed)^(32'h9e3779b9*32'(i+1));
    for(int i=0;i<24;i++)coverage[i]=0;
    for(int i=0;i<7;i++)begin barrier_hits[i]=0;done_wait[i]=0;end
    for(int i=0;i<32;i++)stage_dur_max[i]=0;
    job='0;vector_done='0;function_done='0;vector_result='0;function_result='0;xbc_entry='0;hbm_entry='0;kv_entry='0;acc_wr='0;
    ext_qoz_region='0;ext_qoz_wr='0;
    for(int i=0;i<7;i++)begin
      issues[i]=0;sent[i]=0;commands[i]=0;outputs[i]=0;
      job_accept_cyc[i]=0;first_issue_cyc[i]=0;last_issue_cyc[i]=0;done_cyc[i]=0;last_post_cyc[i]=0;last_egress_cyc[i]=0;
    end
    for(int r=0;r<ROWS;r++)begin m[r]=32'hff800000;lsum[r]=0;end
    repeat(35)@(negedge clk);reset=0;
    if(MANUAL)wait(1'b0);
    if($test$plusargs("ATTENTION_ONLY"))begin
      prepare_q();run_job(OP_ATTENTION,4,45760);
      if(!qoz_complete||qoz_region.owner!=QOZ_O||matrix_jobs!=110)$fatal(1,"Attention-only count");
      $display("tb_v3_pcore_control_v3 PASS attention_only=1 attention_jobs=110 real_softmax=1 workspace=1 O_commit=1 mode=%s",mode_name);$finish;
    end
    if($test$plusargs("GU_ONLY"))begin
      run_job(OP_GU,6,106496);run_job(OP_DOWN_PROJ,7,53248);
      $display("tb_v3_pcore_control_v3 PASS gu_down_only=1 real_gelu=1 Z_chain=1 mode=%s",mode_name);$finish;
    end
    if($test$plusargs("K_ONLY"))begin
      run_job(OP_K_PROJ,1,3328);
      $display("tb_v3_pcore_control_v3 PASS k_only=1 rope=1 quant=1 mode=%s",mode_name);$finish;
    end
    run_job(OP_K_PROJ,1,3328);
    run_job(OP_V_PROJ,2,3328);
    run_job(OP_Q_PROJ,3,26624);
    if(!qoz_complete||qoz_region.owner!=QOZ_Q)$fatal(1,"Q not committed");
    run_job(OP_ATTENTION,4,45760);
    if(!qoz_complete||qoz_region.owner!=QOZ_O||matrix_jobs!=110)$fatal(1,"Attention O/matrix count");
    run_job(OP_O_PROJ,5,26624);
    run_job(OP_GU,6,106496);
    run_job(OP_DOWN_PROJ,7,53248);
    if(sent[OP_K_PROJ]!=52||sent[OP_V_PROJ]!=64||sent[OP_O_PROJ]!=1664||sent[OP_DOWN_PROJ]!=1664)$fatal(1,"egress counts");
    if(lifecycle_reads!=55*16*PAIRS||lifecycle_releases!=1||lifecycle_o_acquires!=1||pv54_commits!=1)$fatal(1,"Attention lifecycle coverage reads=%0d release=%0d acquire=%0d tail=%0d",lifecycle_reads,lifecycle_releases,lifecycle_o_acquires,pv54_commits);
    if(stress)begin
      for(int i=0;i<13;i++)if(coverage[i]==0)$fatal(1,"missing stress coverage channel=%0d",i);
      if(coverage[16]==0||coverage[17]==0)$fatal(1,"missing egress stress coverage");
    end
    $display("CONTROL_LIFECYCLE Q_reads=%0d Q_release=%0d O_acquire=%0d PV54_commit=%0d",lifecycle_reads,lifecycle_releases,lifecycle_o_acquires,pv54_commits);
    for(int i=0;i<7;i++)begin
      if(corners&&barrier_hits[i]==0)$fatal(1,"missing completion corner op=%0d",i);
      $display("CONTROL_COVER_JOB op=%0d issues=%0d packets=%0d vpu=%0d barrier=%0d done_hold=%0d",i,issues[i],sent[i],commands[i],barrier_hits[i],done_wait[i]);
    end
    $display("CONTROL_COVER seed=%0d stress=%0d xbc_gap=%0d hbm_gap=%0d kvb_gap=%0d vcmd_stall=%0d fcmd_stall=%0d vresult_delay=%0d fresult_delay=%0d vdone_delay=%0d fdone_delay=%0d acc_backpressure=%0d workspace_backpressure=%0d rope_request_stall=%0d rope_response_stall=%0d kv_out_stall=%0d reduce_out_stall=%0d sfu_commands=%0d",seed,stress,coverage[0],coverage[1],coverage[2],coverage[3],coverage[4],coverage[5],coverage[6],coverage[7],coverage[8],coverage[9],coverage[10],coverage[11],coverage[12],coverage[16],coverage[17],function_commands);
    $display("tb_v3_pcore_control_v3 PASS jobs=7 issues=265408 attention_jobs=110 real_rope=1 real_gelu=1 real_softmax=1 all_mask_row=1 q_o_z_chain=1 egress_backpressure=1 mode=%s vpu_lanes=%0d sfu_lanes=%0d rope_lat=%0d acc_rd_lat=%0d work_lat=%0d",
      mode_name,VPU_LANES,SFU_LANES,ROPE_LAT,ACC_RD_LAT,WORK_RD_LAT);$finish;
  end
  initial begin #12000000;$fatal(1,"control watchdog op=%0d stage=%0d vec=%0d sfu=%0d",job.header.op,dut.post_service.state_q,dut.vheld_q.function_id,dut.fheld_q.function_id);end
endmodule
