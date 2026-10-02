`timescale 1ns/1ps
import pcore3_pkg::*;
import fp32_legacy_ref_pkg::*;
module tb_v3_pcore_three_job_chain;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,job_done_valid,job_done_ready=0;
  pcore_job_t job;pcore_completion_t job_done;
  logic busy,protocol_error;logic [1:0] active_adapter;
  logic xbc_valid=0,xbc_ready;xbc4_t xbc_entry;
  logic gu_a_valid=0,gu_a_ready;a2_t gu_a_entry;
  logic hbm_valid=0,hbm_ready;b2_t hbm_entry;
  logic kv_valid=0,kv_ready;b2_t kv_entry;
  logic post_valid,post_ready=1,post_done_valid=0,post_done_ready;pcore_post_job_t post_job,post_done;
  logic post_data_valid,post_data_ready=0;post_data_t post_data;
  logic post_result_valid=0,post_result_ready;post_result_t post_result;
  logic vpu_valid,vpu_ready=1,vpu_done_valid=0,vpu_done_ready;vpu_cmd_t vpu_cmd,vpu_done;
  logic sfu_valid,sfu_ready=1,sfu_done_valid=0,sfu_done_ready;sfu_cmd_t sfu_cmd,sfu_done;
  logic p_valid=0,p_ready;a2_t p_entry;logic [5:0] p_block;logic [EPOCH_BITS-1:0] p_epoch;logic [2:0] p_head;
  logic acc_rd_valid=0,acc_rd_ready;acc_sel_e acc_rd_sel=ACC_OACC;logic [9:0] acc_rd_addr=0;
  logic acc_data_valid;logic [15:0][31:0] acc_even,acc_odd;
  logic acc_wr_valid=0,acc_wr_ready;acc_write_t acc_wr;
  logic z_rd_valid=0,z_rd_ready;logic [5:0] z_rd_tile=0;logic [PAIR_BITS-1:0] z_rd_pair=0;
  logic z_out_valid,z_out_ready=1;a2_t z_entry;
  logic qoz_complete;qoz_region_req_t qoz_region;
  logic gu_prefetch_valid,gu_prefetch_ready=1;logic [5:0] gu_prefetch_n;
  int cycle=0,ops=0,posts=0,q_pairs=0,z_pairs=0,readbacks=0,allowed_n=0,prefetches=0;
  int count_gu[32],first_gu[32],last_gu[32],commit_gu[32];
  int count_attn[110],first_attn[110],last_attn[110],commit_attn[110],attn_i=0,attn_commits=0;
  int stall_a=0,stall_b=0,stall_slot=0,stall_matrix_handoff=0;
  int stall_a_n[32],stall_b_n[32],stall_slot_n[32],handoff_n[32];
  int gu_issue_tile=0,gu_issue_pair=0,previous_gu_n=-1,attn_final_done=-1;
  bit slow_post=0,gu_only=0,fault_test=0;
  bit data_stalled=0;post_data_t held_data;
  logic [1023:0] gu_golden[0:1631];logic [135:0] z_golden[0:1631];
  qvec16_t z_computed[0:50];
  dea8_pcore_exec_v3 dut(.*);
  function automatic qvec16_t qv(input int v,input int e);
    qvec16_t q;q='0;q.scale=8'(e);for(int i=0;i<16;i++)q.data[8*i+:8]=8'(v);return q;
  endfunction
  function automatic int aval(input int r,k,i);return (r+2*k+3*i)%9-4;endfunction
  function automatic int bval(input int n,k,i,c,input bit up);
    return up?(2*n+3*k+2*c+i)%13-6:(n+k+c+2*i)%11-5;
  endfunction
  function automatic real f32(input real x);shortreal s;s=x;return real'(s);endfunction
  function automatic qvec16_t quant(input logic [15:0][31:0] g,u,input bit gelu);
    real z[16],x,y,t,mx,step,ratio,frac;int e,q,b;logic [127:0] bytes;
    mx=0;bytes=0;
    for(int i=0;i<16;i++)begin
      x=real'($bitstoshortreal(g[i]));y=real'($bitstoshortreal(u[i]));
      t=$sqrt(2.0/3.141592653589793)*(x+0.044715*x*x*x);
      z[i]=gelu?f32(f32(0.5*x*(2.0/(1.0+$exp(-2.0*t))))*y):x;
      if((z[i]<0?-z[i]:z[i])>mx)mx=z[i]<0?-z[i]:z[i];
    end
    e=0;step=2.0**(-133);if(mx!=0)while(e<254&&mx>127.0*step)begin e++;step*=2.0;end
    for(int i=0;i<16;i++)begin
      ratio=z[i]/step;b=int'($floor(ratio));frac=ratio-real'(b);
      q=b+int'(frac>0.5||(frac==0.5&&b%2!=0));if(q>127)q=127;if(q< -128)q=-128;
      bytes[8*i+:8]=8'(q);
    end
    return qvec16_t'({bytes,8'(e)});
  endfunction
  task automatic send_b(input int tile,group,n,input bit gu,input bit kv);
    b2_t e;e='0;e.tile_idx=TILE_BITS'(tile);e.group_idx=3'(group);e.epoch=job.header.epoch;
    for(int c=0;c<2;c++)begin
      e.col[c]=qv(1,128);
      if(gu)begin
        for(int i=0;i<16;i++)e.col[c].data[8*i+:8]=8'(bval(n,tile/2,i,2*group+c,tile[0]));
        e.col[c].scale=8'(128+(2*group+c)%2);
      end
    end
    if(kv)begin kv_entry=e;kv_valid=1;do @(posedge clk);while(!kv_ready);@(negedge clk);kv_valid=0;end
    else begin hbm_entry=e;hbm_valid=1;do @(posedge clk);while(!hbm_ready);@(negedge clk);hbm_valid=0;end
  endtask
  task automatic feed_projection;
    fork
      begin
        for(int n=0;n<16;n++)for(int k=0;k<64;k++)for(int g=0;g<XBC_GROUPS;g++)begin
          xbc_entry='0;xbc_entry.tile_idx=TILE_BITS'(k);xbc_entry.group_idx=4'(g);
          xbc_entry.row_valid=g==XBC_GROUPS-1?4'b0111:4'b1111;
          for(int r=0;r<4;r++)xbc_entry.row[r]=qv(1,128);
          xbc_valid=1;do @(posedge clk);while(!xbc_ready);@(negedge clk);xbc_valid=0;
        end
      end
      begin for(int n=0;n<16;n++)for(int k=0;k<64;k++)for(int g=0;g<8;g++)send_b(k,g,n,0,0);end
    join
  endtask
  task automatic feed_gu;
    fork
      begin
        for(int n=0;n<32;n++)begin
          wait(allowed_n>=n);@(negedge clk);
          for(int k=0;k<64;k++)for(int p=0;p<PAIRS;p++)begin
            gu_a_entry='0;gu_a_entry.tile_idx=TILE_BITS'(k);gu_a_entry.pair_idx=PAIR_BITS'(p);gu_a_entry.row_valid=row_mask(p);
            for(int r=0;r<2;r++)begin
              gu_a_entry.row[r].scale=8'(128+(2*p+r)%3);
              for(int i=0;i<16;i++)gu_a_entry.row[r].data[8*i+:8]=8'(aval(2*p+r,k,i));
            end
            gu_a_valid=1;do @(posedge clk);while(!gu_a_ready);@(negedge clk);gu_a_valid=0;
          end
        end
      end
      begin
        for(int n=0;n<32;n++)begin
          wait(allowed_n>=n);@(negedge clk);
          for(int k=0;k<128;k++)for(int g=0;g<8;g++)send_b(k,g,n,1,0);
        end
      end
    join
  endtask
  task automatic emit_pair(input pcore_post_job_t c,input int p,input qvec16_t e,o);
    post_result='0;post_result.header=c.header;post_result.n=c.n;
    post_result.pair_data.tile_idx=c.n;post_result.pair_data.pair_idx=PAIR_BITS'(p);
    post_result.pair_data.row_valid=row_mask(p);post_result.pair_data.row[0]=e;post_result.pair_data.row[1]=o;
    post_result.last=p==PAIRS-1;post_result_valid=1;
    do @(posedge clk);while(!post_result_ready);@(negedge clk);post_result_valid=0;
  endtask
  initial begin: post_model
    pcore_post_job_t c;post_data_t d;qvec16_t e,o;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(post_valid&&post_ready)begin
        c=post_job;posts++;
        @(negedge clk);
        if(slow_post&&c.op==POST_GU&&c.n==0)repeat(3500)@(negedge clk);
        if(c.op==POST_PROJ_QUANT)begin
          for(int p=0;p<PAIRS;p++)begin
            post_data_ready=1;do @(posedge clk);while(!post_data_valid);d=post_data;
            if(d.header!=c.header||d.n!=c.n||d.row!=p||d.row_valid!=row_mask(p)||d.last!=(p==PAIRS-1))$fatal(1,"projection post context/mask/last");
            for(int i=0;i<16;i++)if(d.first[i]!==32'h3f800000||(d.row_valid[1]&&d.second[i]!==32'h3f800000))$fatal(1,"projection FP golden");
            e=quant(d.first,'0,0);o=d.row_valid[1]?quant(d.second,'0,0):qvec16_t'('0);
            if(e!==qv(64,127))$fatal(1,"projection quant reference");
            @(negedge clk);post_data_ready=0;emit_pair(c,p,e,o);q_pairs++;
          end
        end else begin
          for(int row=0;row<ROWS;row++)begin
            post_data_ready=1;do @(posedge clk);while(!post_data_valid);d=post_data;
            if(d.header!=c.header||d.n!=c.n||d.row!=row||d.row_valid!=1||d.last!=(row==ROWS-1))$fatal(1,"GU post context/mask/last");
            for(int i=0;i<16;i++)if(d.first[i]!==gu_golden[c.n*ROWS+row][32*i+:32]||d.second[i]!==gu_golden[c.n*ROWS+row][512+32*i+:32])$fatal(1,"GU FP fixture");
            z_computed[row]=quant(d.first,d.second,1);
            if(z_computed[row]!==qvec16_t'(z_golden[c.n*ROWS+row]))$fatal(1,"GU post reference");
            @(negedge clk);post_data_ready=0;
          end
          for(int p=0;p<PAIRS;p++)begin emit_pair(c,p,z_computed[2*p],p<25?z_computed[2*p+1]:qvec16_t'('0));z_pairs++;end
        end
        @(negedge clk);post_done=c;post_done_valid=1;
        do @(posedge clk);while(!post_done_ready);@(negedge clk);post_done_valid=0;
      end
    end
  end
  initial begin: vpu_model
    vpu_cmd_t c;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(vpu_valid&&vpu_ready)begin
        c=vpu_cmd;@(negedge clk);
        if(c.op==VPU_P_POST)begin
          for(int p=0;p<PAIRS;p++)begin
            p_entry='0;p_entry.slot=c.block_id[0];p_entry.pair_idx=PAIR_BITS'(p);p_entry.row_valid=row_mask(p);
            p_entry.row[0]=qv(1,128);p_entry.row[1]=qv(1,128);p_block=c.block_id;p_epoch=c.epoch;p_head=c.head;p_valid=1;
            do @(posedge clk);while(!p_ready);@(negedge clk);p_valid=0;
          end
        end else if(c.op==VPU_OACC_SCALE)repeat(208)@(negedge clk);
        else if(c.op==VPU_AFIN)repeat(408)@(negedge clk);
        else repeat(26)@(negedge clk);
        vpu_done=c;vpu_done_valid=1;do @(posedge clk);while(!vpu_done_ready);@(negedge clk);vpu_done_valid=0;
      end
    end
  end
  initial begin: sfu_model
    sfu_cmd_t c;wait(!reset);
    forever begin @(posedge clk);if(sfu_valid&&sfu_ready)begin
      c=sfu_cmd;@(negedge clk);repeat(c.op==SFU_P_EXP?204:26)@(negedge clk);
      sfu_done=c;sfu_done_valid=1;do @(posedge clk);while(!sfu_done_ready);@(negedge clk);sfu_done_valid=0;
    end end
  end
  task automatic send_operation(input pcore_op_e op,input int id);
    @(negedge clk);job.header='{job_id:16'(id),epoch:4'd3,head:3'd1,op:op};job_valid=1;
    do @(posedge clk);while(!job_ready);@(negedge clk);job_valid=0;
    repeat(3)@(negedge clk);
  endtask
  task automatic finish_operation;
    wait(job_done_valid);
    if(job_done.header!==job.header||job_done.status!=JOB_OK||protocol_error)$fatal(1,"operation completion mismatch op=%0d",job.header.op);
    repeat(4)begin @(negedge clk);if(!job_done_valid||job_ready)$fatal(1,"completion hold");end
    job_done_ready=1;@(negedge clk);job_done_ready=0;ops++;
  endtask
  always @(posedge clk)if(!reset&&!clear&&!fault_test)begin
    cycle++;
    if(data_stalled&&(!post_data_valid||post_data!==held_data))$fatal(1,"post data changed under backpressure");
    data_stalled=post_data_valid&&!post_data_ready;held_data=post_data;
    if(protocol_error)$fatal(1,"PCore protocol error owner=%0d ctrl=%b adapters=%b qoz=%b matrix=%b",active_adapter,dut.ctrl_error,dut.errors,dut.qoz_error,dut.matrix_error);
    if(gu_prefetch_valid&&gu_prefetch_ready)begin allowed_n=gu_prefetch_n;prefetches++;end
    if(dut.dispatch.matrix.req_valid)begin
      if(active_adapter==2)begin
        int n;n=dut.dispatch.matrix.req_meta.gu_n;
        if(previous_gu_n!=n)begin previous_gu_n=n;gu_issue_tile=0;gu_issue_pair=0;end
        if(dut.dispatch.matrix.tile_seq_q!=gu_issue_tile||dut.dispatch.matrix.req_meta.pair_idx!=gu_issue_pair)
          $fatal(1,"GU issue sequence after slot stall");
        if(gu_issue_pair==PAIRS-1)begin gu_issue_pair=0;gu_issue_tile++;end else gu_issue_pair++;
        if(count_gu[n]==0)first_gu[n]=cycle;last_gu[n]=cycle;count_gu[n]++;
      end else if(active_adapter==1)begin
        if(count_attn[attn_i]==0)first_attn[attn_i]=cycle;
        last_attn[attn_i]=cycle;count_attn[attn_i]++;
        if(count_attn[attn_i]==416)attn_i++;
      end
    end
    if(dut.dispatch.matrix.done)begin
      if(active_adapter==2)commit_gu[dut.dispatch.matrix.commit_meta.gu_n]=cycle;
      if(active_adapter==1)begin commit_attn[attn_commits]=cycle;attn_commits++;end
    end
    if(active_adapter==1&&dut.dispatch.matrix.commit_write_valid)begin
      shortreal expected_pv;logic [31:0] bits_pv;
      expected_pv=shortreal'(real'(dut.attention.frontend.cmd_q.block_id+1)/64.0);
      bits_pv=$shortrealtobits(expected_pv);
      if(dut.dispatch.matrix.commit_meta.acc_sel==ACC_OACC)begin
        for(int r=0;r<2;r++)for(int n=0;n<16;n++)if(dut.dispatch.matrix.commit_write.row_valid[r])
          if(dut.dispatch.matrix.commit_write.data[r][n]!==bits_pv)$fatal(1,"Attention PV write golden mismatch");
      end else if(dut.dispatch.matrix.commit_meta.tile_idx%16==15)begin
        for(int r=0;r<2;r++)for(int n=0;n<16;n++)if(dut.dispatch.matrix.commit_write.row_valid[r])
          if(dut.dispatch.matrix.commit_write.data[r][n]!==32'h3f000000)$fatal(1,"Attention QK write golden mismatch");
      end
    end
    if(active_adapter==2&&dut.dispatch.matrix.job_busy&&!dut.dispatch.matrix.req_valid&&!dut.dispatch.matrix.a_running&&
       !dut.dispatch.matrix.tile_started_q)begin
      int n;n=dut.dispatch.matrix.job_gu_n_q;
      if(dut.dispatch.matrix.tile_seq_q==126&&!dut.gu.gu.matrix_gu_slot_ready)begin stall_slot++;stall_slot_n[n]++;end
      else begin
        if(!dut.dispatch.matrix.a_tile_available)begin stall_a++;stall_a_n[n]++;end
        if(!dut.dispatch.matrix.bank_ready[dut.dispatch.matrix.req_bank]||
           dut.dispatch.matrix.bank_tile[dut.dispatch.matrix.req_bank]!=dut.dispatch.matrix.current_b_stream)begin stall_b++;stall_b_n[n]++;end
      end
    end
    if(slow_post&&active_adapter==2&&dut.gu.post_active_q&&dut.gu.post_n_q==0&&count_gu[1]>0&&count_gu[1]<3276&&
       dut.dispatch.matrix.job_gu_n_q==1&&!dut.dispatch.matrix.req_valid)
      $fatal(1,"slow post stalled GU before G63");
    if(active_adapter==1&&dut.attention.attention_done)attn_final_done=cycle;
    if(active_adapter==1&&dut.attention.q_out_valid&&dut.attention.q_out_ready)begin
      if(dut.attention.frontend.q_entry.row[0]!==qv(64,127)||
        (dut.attention.frontend.q_entry.row_valid[1]&&dut.attention.frontend.q_entry.row[1]!==qv(64,127)))
        $fatal(1,"Attention did not consume Projection Q");
    end
  end
  initial begin
    slow_post=$test$plusargs("SLOW_POST");gu_only=$test$plusargs("GU_ONLY");
    $readmemh("tb/data/gu_fp32.mem",gu_golden);$readmemh("tb/data/gu_z_mxint8.mem",z_golden);
    job='0;post_result='0;acc_wr='0;xbc_entry='0;gu_a_entry='0;hbm_entry='0;kv_entry='0;p_entry='0;
    for(int n=0;n<32;n++)begin count_gu[n]=0;first_gu[n]=0;last_gu[n]=0;commit_gu[n]=0;stall_a_n[n]=0;stall_b_n[n]=0;stall_slot_n[n]=0;handoff_n[n]=0;end
    for(int n=0;n<110;n++)begin count_attn[n]=0;first_attn[n]=0;last_attn[n]=0;commit_attn[n]=0;end
    repeat(35)@(negedge clk);reset=0;
    if($test$plusargs("FAULT_WRITE")||$test$plusargs("FAULT_RELEASE"))begin
      fault_test=1;
      send_operation(OP_GU,90);wait(dut.qactive);@(negedge clk);
      if($test$plusargs("FAULT_WRITE"))begin
        post_result='0;post_result.header=job.header;post_result.header.job_id=91;
        post_result.pair_data.row_valid=3;post_result_valid=1;
        @(negedge clk);post_result_valid=0;
      end else begin
        force dut.qrelease=1'b1;@(negedge clk);force dut.qrelease=1'b0;
      end
      repeat(4)@(negedge clk);
      if(!dut.qoz_error||!dut.ctrl_error||dut.ctrl.state_q!=3||job_ready||job_done_valid||!dut.qactive)
        $fatal(1,"QOZ fabric error did not enter retaining FAULT");
      repeat(5)begin @(negedge clk);if(job_done_valid||job_ready)$fatal(1,"FAULT escaped");end
      clear=1;@(negedge clk);
      if($test$plusargs("FAULT_RELEASE"))release dut.qrelease;
      clear=0;@(negedge clk);
      if(protocol_error||!job_ready||dut.qactive)$fatal(1,"fabric clear recovery failed");
      send_operation(OP_DOWN_PROJ,92);wait(job_done_valid);
      if(job_done.status!=JOB_UNSUPPORTED)$fatal(1,"dispatch after fabric clear failed");
      $display("tb_v3_pcore_three_job_chain PASS fabric_fault=1 clear_recovery=1 write=%0d release=%0d",$test$plusargs("FAULT_WRITE"),$test$plusargs("FAULT_RELEASE"));$finish;
    end
    if(!gu_only)begin
      send_operation(OP_Q_PROJ,1);fork feed_projection();finish_operation();join
      if(!qoz_complete||qoz_region.owner!=QOZ_Q||q_pairs!=416)$fatal(1,"Q region not complete");
      send_operation(OP_ATTENTION,2);
      fork
        begin for(int j=0;j<110;j++)for(int t=0;t<16;t++)for(int g=0;g<8;g++)send_b(j*16+t,g,0,0,1);end
        finish_operation();
      join
      if(qoz_complete||dut.qactive)$fatal(1,"Attention did not release Q");
      for(int j=0;j<110;j++)begin
        if(count_attn[j]!=416||last_attn[j]-first_attn[j]!=415)$fatal(1,"Attention body regression");
        if(j>0&&j<109&&first_attn[j]-first_attn[j-1]!=434)$fatal(1,"Attention steady regression %0d",first_attn[j]-first_attn[j-1]);
      end
      if(first_attn[109]-first_attn[108]!=867)$fatal(1,"Attention tail regression");
      if(attn_final_done-commit_attn[109]!=439)$fatal(1,"Attention AFIN tail regression %0d",attn_final_done-commit_attn[109]);
    end
    send_operation(OP_GU,3);fork feed_gu();finish_operation();join
    if(!qoz_complete||qoz_region.owner!=QOZ_Z||z_pairs!=832||prefetches!=31)$fatal(1,"Z region/prefetch count");
    for(int n=0;n<32;n++)begin
      if(count_gu[n]!=3328)$fatal(1,"GU issue count n=%0d count=%0d",n,count_gu[n]);
      if(!slow_post&&last_gu[n]-first_gu[n]!=3327)$fatal(1,"GU body bubble n=%0d body=%0d",n,last_gu[n]-first_gu[n]+1);
      if(n>0&&!slow_post&&first_gu[n]-first_gu[n-1]>3347)$fatal(1,"GU interval n=%0d interval=%0d",n,first_gu[n]-first_gu[n-1]);
      if(n>0)begin
        handoff_n[n]=first_gu[n]-commit_gu[n-1];stall_matrix_handoff+=handoff_n[n];
        if(stall_a_n[n]||stall_b_n[n])$fatal(1,"GU steady source stall n=%0d A=%0d B=%0d",n,stall_a_n[n],stall_b_n[n]);
        if(!slow_post&&stall_slot_n[n])$fatal(1,"GU fast post slot stalled");
      end
    end
    if(slow_post&&(stall_slot==0||last_gu[1]-first_gu[1]<=3327))$fatal(1,"slow post G63 stall not exercised");
    $display("GU_PREFETCH first_interval=%0d steady_interval=%0d..%0d stall_a_cold=%0d stall_b_cold=%0d stall_slot=%0d stall_matrix_handoff=%0d prefetches=%0d",
      first_gu[1]-first_gu[0],first_gu[3]-first_gu[2],first_gu[31]-first_gu[30],stall_a_n[0],stall_b_n[0],stall_slot,stall_matrix_handoff,prefetches);
    for(int n=0;n<32;n++)for(int p=0;p<PAIRS;p++)begin
      @(negedge clk);z_rd_tile=6'(n);z_rd_pair=PAIR_BITS'(p);z_rd_valid=1;
      do @(posedge clk);while(!z_rd_ready);
      #1;if(!z_out_valid||z_entry.row[0]!==qvec16_t'(z_golden[n*ROWS+2*p])||
        (p<25&&z_entry.row[1]!==qvec16_t'(z_golden[n*ROWS+2*p+1])))$fatal(1,"Z readback n=%0d pair=%0d",n,p);
      readbacks++;@(negedge clk);z_rd_valid=0;
    end
    $display("tb_v3_pcore_three_job_chain PASS operations=%0d shared_matrix=1 shared_qoz=1 posts=%0d z_readbacks=%0d gu_interval=%0d stall_slot=%0d slow=%0d",ops,posts,readbacks,first_gu[2]-first_gu[1],stall_slot,slow_post);$finish;
  end
  initial begin #1600000;$fatal(1,"three job watchdog owner=%0d post=%0d q=%0d z=%0d GU_n=%0d",active_adapter,posts,q_pairs,z_pairs,dut.gu.n_q);end
endmodule
