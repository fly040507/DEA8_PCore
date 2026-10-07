`timescale 1ns/1ps
import pcore3_pkg::*;
import pcore_control_pkg::*;
import fp32_legacy_ref_pkg::*;
module tb_v3_pcore_three_job_chain;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,done_valid,done_ready=0;
  logic ext_qoz_region_valid=0,ext_qoz_region_ready,ext_qoz_wr_valid=0,ext_qoz_wr_ready;
  qoz_region_req_t ext_qoz_region;post_result_t ext_qoz_wr;
  control_job_t job;control_completion_t done,job_done;
  assign job_done=done;
  pcore_job_t matrix_job;
  pcore_completion_t matrix_done;
  assign matrix_job='{header:job.header};
  assign done.job=job;
  assign done.status=matrix_done.status==JOB_OK?CONTROL_OK:
    (matrix_done.status==JOB_UNSUPPORTED?CONTROL_UNSUPPORTED:CONTROL_CONTEXT_ERROR);
  logic busy,protocol_error;logic [1:0] active_adapter;
  logic xbc_valid=0,xbc_ready;xbc4_t xbc_entry;
  logic hbm_valid=0,hbm_ready;b2_t hbm_entry;
  logic kv_valid=0,kv_ready;b2_t kv_entry;
  logic post_valid,post_ready=1,post_done_valid=0,post_done_ready;pcore_post_job_t post_job,post_done;
  logic post_data_valid,post_data_ready=0;post_data_t post_data;
  logic post_result_valid=0,post_result_ready;post_result_t post_result;
  logic collective_cmd_valid,collective_cmd_ready=1;pcore_post_job_t collective_cmd;
  logic collective_data_valid,collective_data_ready=0;post_data_t collective_data;
  logic collective_result_valid,collective_result_ready=1;post_result_t collective_result;
  logic collective_done_valid=0,collective_done_ready;pcore_post_job_t collective_done;
  assign collective_cmd_valid=0;
  assign collective_data_valid=0;
  assign collective_result_valid=0;
  assign collective_done_ready=0;
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
  int route_xbc[3],route_hbm[3],route_kvb[3],route_qoz_rd[3];
  int op_xbc[7],op_hbm[7],op_kvb[7],op_local[7],op_issues[7],op_outputs[7];
  int op_accept[7],op_first[7],op_last[7],op_done[7],op_launches[7],op_posts[7],op_results[7];
  int proj_first[7][64];
  int stall_a_n[32],stall_b_n[32],stall_slot_n[32],handoff_n[32];
  int gu_issue_tile=0,gu_issue_pair=0,previous_gu_n=-1,attn_final_done=-1;
  bit slow_post=0,gu_only=0,gu_fast=0,fault_test=0;
  bit data_stalled=0;post_data_t held_data;
  logic [1023:0] gu_golden[0:1631];logic [135:0] z_golden[0:1631];
  qvec16_t z_computed[0:50];
  operation_profile_t desc_profile;
  dea8_pcore_exec_v3 dut(.job(matrix_job),.job_valid,.job_ready,
    .job_done(matrix_done),.job_done_valid(done_valid),.job_done_ready(done_ready),.*);
  function automatic qvec16_t qv(input int v,input int e);
    qvec16_t q;q='0;q.scale=8'(e);for(int i=0;i<16;i++)q.data[8*i+:8]=8'(v);return q;
  endfunction
  function automatic int aval(input int r,k,i);return (r+2*k+3*i)%9-4;endfunction
  function automatic int projection_k_tiles(input pcore_op_e op);
    case(op)
      OP_O_PROJ: projection_k_tiles=16;
      OP_DOWN_PROJ: projection_k_tiles=32;
      default: projection_k_tiles=64;
    endcase
  endfunction
  function automatic logic [31:0] projection_expected(input pcore_op_e op);
    case(op)
      OP_K_PROJ: return 32'h40000000;
      OP_V_PROJ: return 32'h40400000;
      OP_O_PROJ: return 32'h3e800000;
      OP_DOWN_PROJ: return 32'h3f000000;
      default: return 32'h3f800000;
    endcase
  endfunction
  function automatic logic [31:0] down_expected(input int row);
    logic [31:0] acc,partial,mag,norm;qvec16_t a;int dot,lead;
    acc=0;
    for(int k=0;k<32;k++)begin
      a=qvec16_t'(z_golden[k*ROWS+row]);dot=0;
      for(int i=0;i<16;i++)dot+=int'($signed(a.data[8*i+:8]));
      mag=dot<0?-dot:dot;lead=0;
      for(int b=0;b<32;b++)if(mag[b])lead=b;
      norm=mag<<(31-lead);
      partial=fp32_legacy_ref_pkg::pack_scaled32(dot<0,norm,lead+int'(a.scale)+128-266,dot==0,0);
      acc=fp32_legacy_ref_pkg::fp32_add(acc,partial);
    end
    return acc;
  endfunction
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
  task automatic send_b_transport(input int logical_tile,transport_tile,group,n,input bit gu,input bit kv);
    b2_t e;e='0;e.tile_idx=TILE_BITS'(transport_tile);e.group_idx=3'(group);e.epoch=job.header.epoch;
    for(int c=0;c<2;c++)begin
      e.col[c]=qv(job.header.op==OP_K_PROJ?2:(job.header.op==OP_V_PROJ?3:1),128);
      if(gu)begin
        for(int i=0;i<16;i++)e.col[c].data[8*i+:8]=8'(bval(n,logical_tile/2,i,2*group+c,logical_tile[0]));
        e.col[c].scale=8'(128+(2*group+c)%2);
      end
    end
    if(kv)begin kv_entry=e;kv_valid=1;do @(posedge clk);while(!kv_ready);@(negedge clk);kv_valid=0;end
    else begin hbm_entry=e;hbm_valid=1;do @(posedge clk);while(!hbm_ready);@(negedge clk);hbm_valid=0;end
  endtask
  task automatic send_b(input int tile,group,n,input bit gu,input bit kv);
    send_b_transport(tile,tile,group,n,gu,kv);
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
  task automatic feed_projection_xbc(input int n_count,k_count);
    fork
      begin
        for(int n=0;n<n_count;n++)for(int k=0;k<k_count;k++)for(int g=0;g<XBC_GROUPS;g++)begin
          xbc_entry='0;xbc_entry.tile_idx=TILE_BITS'(k);xbc_entry.group_idx=4'(g);
          xbc_entry.row_valid=g==XBC_GROUPS-1?4'b0111:4'b1111;
          for(int r=0;r<4;r++)xbc_entry.row[r]=qv(1,128);
          xbc_valid=1;do @(posedge clk);while(!xbc_ready);@(negedge clk);xbc_valid=0;
        end
      end
      begin for(int n=0;n<n_count;n++)for(int k=0;k<k_count;k++)for(int g=0;g<8;g++)send_b(k,g,n,0,0);end
    join
  endtask
  task automatic feed_projection_hbm(input int n_count,k_count);
    for(int n=0;n<n_count;n++)for(int k=0;k<k_count;k++)for(int g=0;g<8;g++)
      send_b_transport(k,(n*k_count+k)%64,g,n,0,0);
  endtask
  task automatic prepare_fixture(input qoz_owner_e owner,input pcore_op_e producer,input int tiles,input int id);
    ext_qoz_region='0;ext_qoz_region.header='{job_id:16'(id),epoch:4'd3,head:3'd1,op:producer};
    ext_qoz_region.owner=owner;ext_qoz_region.tiles=6'(tiles);ext_qoz_region_valid=1;
    do @(posedge clk);while(!ext_qoz_region_ready);@(negedge clk);ext_qoz_region_valid=0;
    for(int t=0;t<tiles;t++)for(int p=0;p<PAIRS;p++)begin
      ext_qoz_wr='0;ext_qoz_wr.header=ext_qoz_region.header;ext_qoz_wr.n=6'(t);
      ext_qoz_wr.pair_data.tile_idx=TILE_BITS'(t);ext_qoz_wr.pair_data.pair_idx=PAIR_BITS'(p);
      ext_qoz_wr.pair_data.row_valid=row_mask(p);
      ext_qoz_wr.pair_data.row[0]=(owner==QOZ_Z)?qvec16_t'(z_golden[t*ROWS+2*p]):qv(1,128);
      ext_qoz_wr.pair_data.row[1]=(owner==QOZ_Z&&p<PAIRS-1)?qvec16_t'(z_golden[t*ROWS+2*p+1]):qv(1,128);
      ext_qoz_wr.last=p==PAIRS-1;ext_qoz_wr_valid=1;
      do @(posedge clk);while(!ext_qoz_wr_ready);@(negedge clk);ext_qoz_wr_valid=0;
    end
    wait(qoz_complete);
  endtask
  // Seven-job regression uses the frozen GU ingress: one XBC beat contains
  // four consecutive rows and the GU front end serializes it into two A2
  // pairs.  The payload matches the independent reference model, so the
  // existing FP32/GELU reference remains the oracle.
  task automatic feed_gu_xbc;
    fork
      begin
        for(int n=0;n<32;n++)begin
          wait(allowed_n>=n);@(negedge clk);
          for(int k=0;k<64;k++)for(int g=0;g<XBC_GROUPS;g++)begin
            xbc_entry='0;
            xbc_entry.tile_idx=TILE_BITS'(k);
            xbc_entry.group_idx=4'(g);
            xbc_entry.row_valid=g==XBC_GROUPS-1?4'b0111:4'b1111;
            xbc_entry.slot=1'b0;
            for(int r=0;r<4;r++)begin
              xbc_entry.row[r]='0;
              xbc_entry.row[r].scale=8'(128+(4*g+r)%3);
              for(int i=0;i<16;i++)
                xbc_entry.row[r].data[8*i+:8]=8'(aval(4*g+r,k,i));
            end
            xbc_valid=1;
            do @(posedge clk);while(!xbc_ready);
            @(negedge clk);xbc_valid=0;
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
    pcore_post_job_t c;post_data_t d;qvec16_t e,o;bit reduce_path;
    wait(!reset);
    forever begin
      @(posedge clk);
      if((post_valid&&post_ready)||(collective_cmd_valid&&collective_cmd_ready))begin
        reduce_path=collective_cmd_valid&&!post_valid;
        c=reduce_path?collective_cmd:post_job;posts++;
        @(negedge clk);
        if(slow_post&&c.op==POST_GU&&c.n==0)repeat(3500)@(negedge clk);
        if(c.op==POST_PROJ_QUANT)begin
          for(int p=0;p<PAIRS;p++)begin
            post_data_ready=!reduce_path;collective_data_ready=reduce_path;
            do @(posedge clk);while(reduce_path?!collective_data_valid:!post_data_valid);
            d=reduce_path?collective_data:post_data;
            if(d.header!=c.header||d.n!=c.n||d.row!=p||d.row_valid!=row_mask(p)||d.last!=(p==PAIRS-1))$fatal(1,"projection post context/mask/last");
            for(int i=0;i<16;i++)begin
              if(d.first[i]!==(c.header.op==OP_DOWN_PROJ?down_expected(2*p):projection_expected(c.header.op)))
                $fatal(1,"projection FP golden op=%0d",c.header.op);
              if(d.row_valid[1]&&d.second[i]!==(c.header.op==OP_DOWN_PROJ?down_expected(2*p+1):projection_expected(c.header.op)))
                $fatal(1,"projection FP odd golden op=%0d",c.header.op);
            end
            e=quant(d.first,'0,0);o=d.row_valid[1]?quant(d.second,'0,0):qvec16_t'('0);
            if(c.header.op==OP_Q_PROJ)begin
              @(negedge clk);post_data_ready=0;collective_data_ready=0;emit_pair(c,p,e,o);q_pairs++;
            end else if((c.header.op==OP_K_PROJ)||(c.header.op==OP_V_PROJ))begin
              // K/V quantized results return through the post_result port and
              // are forwarded by the control center to the concat boundary.
              @(negedge clk);post_data_ready=0;collective_data_ready=0;emit_pair(c,p,e,o);
            end else begin
              @(negedge clk);post_data_ready=0;collective_data_ready=0;
            end
          end
          op_outputs[c.header.op]++;
        end else begin
          for(int row=0;row<ROWS;row++)begin
            post_data_ready=!reduce_path;collective_data_ready=reduce_path;
            do @(posedge clk);while(reduce_path?!collective_data_valid:!post_data_valid);
            d=reduce_path?collective_data:post_data;
            if(d.header!=c.header||d.n!=c.n||d.row!=row||d.row_valid!=1||d.last!=(row==ROWS-1))$fatal(1,"GU post context/mask/last");
            for(int i=0;i<16;i++)if(d.first[i]!==gu_golden[c.n*ROWS+row][32*i+:32]||d.second[i]!==gu_golden[c.n*ROWS+row][512+32*i+:32])$fatal(1,"GU FP fixture");
            z_computed[row]=gu_fast?qv(0,128):quant(d.first,d.second,1);
            if(!gu_fast&&z_computed[row]!==qvec16_t'(z_golden[c.n*ROWS+row]))$fatal(1,"GU post reference");
            @(negedge clk);post_data_ready=0;collective_data_ready=0;
          end
          for(int p=0;p<PAIRS;p++)begin emit_pair(c,p,z_computed[2*p],p<25?z_computed[2*p+1]:qvec16_t'('0));z_pairs++;end
        end
        @(negedge clk);
        if(reduce_path)begin
          collective_done=c;collective_done_valid=1;
          do @(posedge clk);while(!collective_done_ready);
          @(negedge clk);collective_done_valid=0;
        end else begin
          post_done=c;post_done_valid=1;
          do @(posedge clk);while(!post_done_ready);
          @(negedge clk);post_done_valid=0;
        end
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
    wait(done_valid);
    if(job_done.job.header!==job.header||job_done.status!=CONTROL_OK||protocol_error)$fatal(1,"operation completion mismatch op=%0d",job.header.op);
    if($test$plusargs("SEVEN_JOBS"))begin
      int op,k_count,n_count;op=int'(job.header.op);k_count=projection_k_tiles(job.header.op);n_count=(job.header.op==OP_K_PROJ||job.header.op==OP_V_PROJ)?2:((job.header.op==OP_O_PROJ||job.header.op==OP_DOWN_PROJ)?64:16);
      if(job.header.op==OP_ATTENTION)begin
        if(op_xbc[op]||op_hbm[op]||!op_kvb[op]||!op_local[op])$fatal(1,"Attention source routing");
      end else begin
        if(op_kvb[op]||!op_hbm[op])$fatal(1,"HBM source routing");
        if(job.header.op==OP_O_PROJ||job.header.op==OP_DOWN_PROJ)begin
          if(op_xbc[op]||!op_local[op])$fatal(1,"local Projection source routing");
        end else if(!op_xbc[op]||op_local[op])$fatal(1,"XBC source routing");
        if(job.header.op!=OP_GU&&(op_issues[op]!=k_count*n_count*PAIRS||op_outputs[op]!=n_count))$fatal(1,"Projection issue/output count");
      end
      if(active_adapter==0)begin
        int lo,hi,delta,span,job_span;
        operation_profile_t profile;
        profile=operation_profile(job.header.op);
        if(!profile.geometry_valid||profile.k_tiles!=k_count||profile.n_tiles!=n_count)
          $fatal(1,"Projection profile geometry");
        if(op_launches[op]!=n_count||op_posts[op]!=n_count)$fatal(1,"Projection launch/post count");
        if((job.header.op==OP_K_PROJ||job.header.op==OP_V_PROJ)&&
           (op_xbc[op]!=1664||op_hbm[op]!=1024||op_results[op]!=n_count*PAIRS))$fatal(1,"KV workload/result contract");
        lo=32'h7fffffff;hi=0;
        for(int n=1;n<n_count;n++)begin
          delta=proj_first[op][n]-proj_first[op][n-1];
          if(delta<lo)lo=delta;
          if(delta>hi)hi=delta;
        end
        op_done[op]=cycle;
        span=op_last[op]-op_first[op]+1;job_span=op_done[op]-op_accept[op];
        if(span<=0||job_span<=0)$fatal(1,"Projection invalid measured span");
        $display("PROJ_PERF op=%0d K=%0d N=%0d accept=%0d first=%0d last=%0d done=%0d issues=%0d outputs=%0d launches=%0d posts=%0d interval=%0d..%0d matrix_span=%0d job_cycles=%0d PE_matrix_util=%0.3f%% PE_job_util=%0.3f%%",
          op,k_count,n_count,op_accept[op],op_first[op],op_last[op],op_done[op],op_issues[op],op_outputs[op],op_launches[op],op_posts[op],lo,hi,span,job_span,
          100.0*op_issues[op]/span,100.0*op_issues[op]/job_span);
      end
      $display("OP_CHECK op=%0d issues=%0d outputs=%0d XBC=%0d HBM=%0d KVB=%0d QOZ=%0d mismatches=0",op,op_issues[op],op_outputs[op],op_xbc[op],op_hbm[op],op_kvb[op],op_local[op]);
    end
    repeat(4)begin @(negedge clk);if(!done_valid||job_ready)$fatal(1,"completion hold");end
    done_ready=1;@(negedge clk);done_ready=0;ops++;
  endtask
  always @(posedge clk)if(!reset&&!clear&&!fault_test)begin
    cycle++;
    if(job_valid&&job_ready)op_accept[job.header.op]=cycle;
    if((post_valid&&post_ready)||(collective_cmd_valid&&collective_cmd_ready))op_posts[job.header.op]++;
    if(post_result_valid&&post_result_ready)op_results[job.header.op]++;
    if(data_stalled&&(!post_data_valid||post_data!==held_data))$fatal(1,"post data changed under backpressure");
    data_stalled=post_data_valid&&!post_data_ready;held_data=post_data;
    if(protocol_error)$fatal(1,"PCore protocol error owner=%0d ctrl=%b adapters=%b qoz=%b matrix=%b GU_ae=%b GU_be=%b GU_ge=%b",active_adapter,dut.ctrl_error,dut.errors,dut.qoz_error,dut.matrix_error,dut.gu.ae,dut.gu.be,dut.gu.ge);
    if(xbc_valid&&xbc_ready)route_xbc[active_adapter]++;
    if(xbc_valid&&xbc_ready)op_xbc[job.header.op]++;
    if(hbm_valid&&hbm_ready)op_hbm[job.header.op]++;
    if(kv_valid&&kv_ready)op_kvb[job.header.op]++;
    if((dut.projection_rd_valid&&dut.projection_rd_ready)||(dut.qread&&dut.qread_ready))op_local[job.header.op]++;
    if(hbm_valid&&hbm_ready)route_hbm[active_adapter]++;
    if(kv_valid&&kv_ready)route_kvb[active_adapter]++;
    if((dut.projection_rd_valid&&dut.projection_rd_ready)||(dut.qread&&dut.qread_ready)||(z_rd_valid&&z_rd_ready))route_qoz_rd[active_adapter]++;
    if(gu_prefetch_valid&&gu_prefetch_ready)begin allowed_n=gu_prefetch_n;prefetches++;end
    if(active_adapter==2&&dut.gu_input_valid&&dut.gu_input_ready&&
       (dut.gu.gu.a_replay.in_entry.tile_idx!=dut.gu.gu.a_replay.expected_k_q||dut.gu.gu.a_replay.in_entry.pair_idx!=dut.gu.gu.a_replay.fill_pair_q||dut.gu.gu.a_replay.in_entry.row_valid!=row_mask(dut.gu.gu.a_replay.fill_pair_q)||dut.gu.gu.a_replay.in_entry.reserved!=0))
      $fatal(1,"GU replay input mismatch tile=%0d expected=%0d pair=%0d expected=%0d mask=%b reserved=%h",dut.gu.gu.a_replay.in_entry.tile_idx,dut.gu.gu.a_replay.expected_k_q,dut.gu.gu.a_replay.in_entry.pair_idx,dut.gu.gu.a_replay.fill_pair_q,dut.gu.gu.a_replay.in_entry.row_valid,dut.gu.gu.a_replay.in_entry.reserved);
    if(dut.dispatch.matrix.req_valid)begin
      if(op_issues[job.header.op]==0)op_first[job.header.op]=cycle;
      op_last[job.header.op]=cycle;
      if(active_adapter==0&&dut.dispatch.matrix.tile_seq_q==0&&dut.dispatch.matrix.req_meta.pair_idx==0)begin
        proj_first[job.header.op][dut.dispatch.matrix.req_meta.nt]=cycle;
        $display("PROJ_FIRST op=%0d n=%0d cycle=%0d",job.header.op,dut.dispatch.matrix.req_meta.nt,cycle);
      end
      op_issues[job.header.op]++;
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
    if(dut.dispatch.req.start)begin
      op_launches[job.header.op]++;
      desc_profile=operation_profile(job.header.op);
      if(dut.dispatch.req.mode!=desc_profile.mode||dut.dispatch.req.a_source!=desc_profile.matrix_a||dut.dispatch.req.b_source!=desc_profile.b_source)$fatal(1,"Matrix descriptor source/mode");
      if(active_adapter==0)begin
        if(!desc_profile.geometry_valid||dut.dispatch.req.tiles!=desc_profile.k_tiles||
           dut.dispatch.req.nt>=desc_profile.n_tiles)$fatal(1,"Projection descriptor geometry");
        if(dut.dispatch.req.acc_sel!=(dut.dispatch.req.nt[0]?ACC_FACC_B:ACC_FACC_A))
          $fatal(1,"Projection FACC parity");
        if(dut.dispatch.req.a_stream!=TILE_BITS'(int'(dut.dispatch.req.nt)*int'(desc_profile.k_tiles))||
           dut.dispatch.req.b_stream!=dut.dispatch.req.a_stream)$fatal(1,"Projection transport base");
      end
    end
    if(dut.dispatch.matrix.done)begin
      if(active_adapter==2)commit_gu[dut.dispatch.matrix.commit_meta.gu_n]=cycle;
      if(active_adapter==1)begin commit_attn[attn_commits]=cycle;end
    end
    if(active_adapter==1&&dut.dispatch.matrix.commit_write_valid)begin
       logic [31:0] bits_pv,mag,norm;int lead;
       mag=(attn_commits==109?54:(attn_commits-2)/2)+1;lead=0;
       for(int b=0;b<32;b++)if(mag[b])lead=b;
       norm=mag<<(31-lead);bits_pv=fp32_legacy_ref_pkg::pack_scaled32(0,norm,lead-6,0,0);
      if(dut.dispatch.matrix.commit_meta.acc_sel==ACC_OACC)begin
        for(int r=0;r<2;r++)for(int n=0;n<16;n++)if(dut.dispatch.matrix.commit_write.row_valid[r])
           if(dut.dispatch.matrix.commit_write.data[r][n]!==bits_pv)$fatal(1,"Attention PV write golden mismatch block=%0d got=%h expected=%h",dut.attention.frontend.cmd_q.block_id,dut.dispatch.matrix.commit_write.data[r][n],bits_pv);
      end else if(dut.dispatch.matrix.commit_meta.tile_idx%16==15)begin
        for(int r=0;r<2;r++)for(int n=0;n<16;n++)if(dut.dispatch.matrix.commit_write.row_valid[r])
          if(dut.dispatch.matrix.commit_write.data[r][n]!==32'h3f000000)$fatal(1,"Attention QK write golden mismatch");
      end
    end
    if(active_adapter==1&&dut.dispatch.matrix.done)attn_commits++;
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
    slow_post=$test$plusargs("SLOW_POST");gu_only=$test$plusargs("GU_ONLY");gu_fast=$test$plusargs("GU_FAST");
    $readmemh("tb/data/gu_fp32.mem",gu_golden);$readmemh("tb/data/gu_z_mxint8.mem",z_golden);
    job='0;post_result='0;ext_qoz_region='0;ext_qoz_wr='0;acc_wr='0;xbc_entry='0;hbm_entry='0;kv_entry='0;p_entry='0;
    for(int n=0;n<32;n++)begin count_gu[n]=0;first_gu[n]=0;last_gu[n]=0;commit_gu[n]=0;stall_a_n[n]=0;stall_b_n[n]=0;stall_slot_n[n]=0;handoff_n[n]=0;end
    for(int n=0;n<110;n++)begin count_attn[n]=0;first_attn[n]=0;last_attn[n]=0;commit_attn[n]=0;end
    for(int n=0;n<3;n++)begin route_xbc[n]=0;route_hbm[n]=0;route_kvb[n]=0;route_qoz_rd[n]=0;end
    for(int n=0;n<7;n++)begin op_xbc[n]=0;op_hbm[n]=0;op_kvb[n]=0;op_local[n]=0;op_issues[n]=0;op_outputs[n]=0;end
    for(int op=0;op<7;op++)begin
      op_accept[op]=0;op_first[op]=0;op_last[op]=0;op_done[op]=0;
      op_launches[op]=0;op_posts[op]=0;op_results[op]=0;
      for(int n=0;n<64;n++)proj_first[op][n]=0;
    end
    repeat(35)@(negedge clk);reset=0;
    if($test$plusargs("SEVEN_JOBS"))begin
      send_operation(OP_K_PROJ,11);fork feed_projection_xbc(2,64);finish_operation();join
      send_operation(OP_V_PROJ,12);fork feed_projection_xbc(2,64);finish_operation();join
      send_operation(OP_Q_PROJ,10);fork feed_projection_xbc(16,64);finish_operation();join
      if(!qoz_complete||qoz_region.owner!=QOZ_Q||q_pairs!=416)$fatal(1,"seven Q projection not committed");
      send_operation(OP_ATTENTION,13);
      fork
        begin for(int j=0;j<110;j++)for(int t=0;t<16;t++)for(int g=0;g<8;g++)send_b(j*16+t,g,0,0,1);end
        finish_operation();
      join
      if(qoz_complete||dut.qactive)$fatal(1,"seven Attention did not release Q");
      prepare_fixture(QOZ_O,OP_ATTENTION,16,20);
      send_operation(OP_O_PROJ,14);fork feed_projection_hbm(64,16);finish_operation();join
      if(qoz_complete||dut.qactive)$fatal(1,"seven O Projection did not release O");
      send_operation(OP_GU,15);fork feed_gu_xbc();finish_operation();join
      if(!qoz_complete||qoz_region.owner!=QOZ_Z)$fatal(1,"seven GU did not commit Z");
      for(int n=0;n<32;n++)begin
        if(count_gu[n]!=3328||last_gu[n]-first_gu[n]!=3327)$fatal(1,"seven GU issue body");
        if(n>0&&(first_gu[n]-first_gu[n-1]!=3346||stall_a_n[n]||stall_b_n[n]||stall_slot_n[n]))$fatal(1,"seven GU steady regression");
      end
      if(prefetches!=31)$fatal(1,"seven GU prefetch count");
      $display("SEVEN_GU issues_per_n=3328 last_minus_first=3327 steady=3346 stall_A=0 stall_B=0 stall_slot=0 handoffs=31");
      for(int j=0;j<110;j++)begin
        if(count_attn[j]!=416||last_attn[j]-first_attn[j]!=415)$fatal(1,"seven Attention body");
        if(j>0&&j<109&&first_attn[j]-first_attn[j-1]!=434)$fatal(1,"seven Attention steady");
      end
      if(first_attn[109]-first_attn[108]!=867||attn_final_done-commit_attn[109]!=439)$fatal(1,"seven Attention tail");
      $display("SEVEN_ATTENTION jobs=110 body=416 steady=434 PV53_PV54=867 final_tail=439");
      send_operation(OP_DOWN_PROJ,16);fork feed_projection_hbm(64,32);finish_operation();join
      if(qoz_complete||dut.qactive)$fatal(1,"seven Down Projection did not release Z");
      begin
        int total;total=0;for(int op=0;op<7;op++)total+=op_issues[op];
        if(total!=265408)$fatal(1,"seven total issue count=%0d",total);
        $display("SEVEN_TOTAL issues=%0d order=K,V,Q,ATTENTION,O,GU,DOWN",total);
      end
      if(route_xbc[0]==0||route_hbm[0]==0||route_xbc[2]==0||route_hbm[2]==0||
         route_kvb[1]==0||route_qoz_rd[1]==0||route_qoz_rd[0]==0)
        $fatal(1,"seven source routing incomplete XBC=%0d/%0d HBM=%0d/%0d KVB=%0d QOZ=%0d/%0d",
          route_xbc[0],route_xbc[2],route_hbm[0],route_hbm[2],route_kvb[1],route_qoz_rd[0],route_qoz_rd[1]);
      $display("tb_v3_pcore_three_job_chain PASS seven_jobs=7 shared_matrix=1 qoz_q=1 qoz_o=1 qoz_z=1 route_xbc=%0d/%0d route_hbm=%0d/%0d route_kvb=%0d route_qoz=%0d/%0d",
        route_xbc[0],route_xbc[2],route_hbm[0],route_hbm[2],route_kvb[1],route_qoz_rd[0],route_qoz_rd[1]);$finish;
    end
    if($test$plusargs("DOWN_ONLY"))begin
      prepare_fixture(QOZ_Z,OP_GU,32,30);
      send_operation(OP_DOWN_PROJ,31);fork feed_projection_hbm(64,32);finish_operation();join
      if(qoz_complete||dut.qactive||op_outputs[OP_DOWN_PROJ]!=64)
        $fatal(1,"Down-only collective reduction did not complete");
      $display("tb_v3_pcore_three_job_chain PASS down_only=1 collective_data_done=1 issues=%0d outputs=%0d",
        op_issues[OP_DOWN_PROJ],op_outputs[OP_DOWN_PROJ]);$finish;
    end
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
      if(!dut.qoz_error||!dut.ctrl_error||dut.ctrl.state_q!=3||job_ready||done_valid||!dut.qactive)
        $fatal(1,"QOZ fabric error did not enter retaining FAULT");
      repeat(5)begin @(negedge clk);if(done_valid||job_ready)$fatal(1,"FAULT escaped");end
      clear=1;@(negedge clk);
      if($test$plusargs("FAULT_RELEASE"))release dut.qrelease;
      clear=0;@(negedge clk);
      if(protocol_error||!job_ready||dut.qactive)$fatal(1,"fabric clear recovery failed");
      send_operation(pcore_op_e'(7),92);wait(done_valid);
      if(job_done.status!=CONTROL_UNSUPPORTED)$fatal(1,"dispatch after fabric clear failed");
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
    send_operation(OP_GU,3);fork feed_gu_xbc();finish_operation();join
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
      #1;if(!z_out_valid||(!gu_fast&&z_entry.row[0]!==qvec16_t'(z_golden[n*ROWS+2*p]))||
        (gu_fast&&z_entry.row[0]!==qv(0,128))||
        (p<25&&((!gu_fast&&z_entry.row[1]!==qvec16_t'(z_golden[n*ROWS+2*p+1]))||
                 (gu_fast&&z_entry.row[1]!==qv(0,128)))))$fatal(1,"Z readback n=%0d pair=%0d",n,p);
      readbacks++;@(negedge clk);z_rd_valid=0;
    end
    $display("tb_v3_pcore_three_job_chain PASS operations=%0d shared_matrix=1 shared_qoz=1 posts=%0d z_readbacks=%0d gu_interval=%0d stall_slot=%0d slow=%0d",ops,posts,readbacks,first_gu[2]-first_gu[1],stall_slot,slow_post);$finish;
  end
  initial begin #1600000;$fatal(1,"three job watchdog owner=%0d post=%0d q=%0d z=%0d GU_n=%0d ctrl=%0d proj=%0d region=%b xbc=%b/%b hbm=%b/%b issues=%0d",active_adapter,posts,q_pairs,z_pairs,dut.gu.n_q,dut.ctrl.state_q,dut.projection.state_q,dut.qactive,xbc_valid,xbc_ready,hbm_valid,hbm_ready,op_issues[0]);end
endmodule
