`timescale 1ns/1ps
import pcore3_pkg::*;
import pcore3_legacy_pkg::*;

// Single-core G-U task run.  The scheduler launches 32 ordered N tiles;
// dea8_gu_matrix_v3 performs the real A-replay/MXU/DEQACC path for every
// tile.  VPU/SFU are modeled at the public boundary by returning the prepared
// Z stream after the 51-row Gate/Up read has completed.
module tb_v3_gu_32_system;
  localparam int N_TILES=32;
  localparam int A_TILES=64;
  localparam int GU_TILES=128;
  localparam int GOLDEN_ROWS=N_TILES*ROWS;

  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic start=0,start_ready;
  logic [EPOCH_BITS-1:0] epoch=4'h6;
  logic [2:0] head=3'h1;

  logic tile_valid,tile_ready; logic [5:0] tile_n;
  logic [EPOCH_BITS-1:0] tile_epoch; logic [2:0] tile_head;
  logic prefetch_valid,prefetch_ready=1; logic [5:0] prefetch_n;
  logic [EPOCH_BITS-1:0] prefetch_epoch; logic [2:0] prefetch_head;
  logic matrix_done,z_commit;
  logic [5:0] z_n; logic [EPOCH_BITS-1:0] z_epoch; logic [2:0] z_head;
  logic scheduler_busy,matrix_all_done,job_done,scheduler_error;

  logic gu_start,gu_start_ready,gu_busy,gu_matrix_done;
  logic a_valid,a_ready; a2_t a_entry;
  logic b_valid,b_ready; b2_t b_entry;
  logic pair_ready,pair_accept;
  logic out_valid,out_ready; logic [5:0] out_row;
  logic [EPOCH_BITS-1:0] out_epoch; logic [2:0] out_head; logic [5:0] out_n;
  logic [15:0][31:0] out_gate,out_up; logic [1:0] out_row_valid; logic out_last;
  logic out_consumed;
  logic vz_valid=0,vz_ready; logic [5:0] vz_tile=0;
  logic [PAIR_BITS-1:0] vz_pair=0; logic [1:0] vz_row_valid=0;
  logic [135:0] vz_even=0,vz_odd=0; logic [EPOCH_BITS-1:0] vz_epoch=0;
  logic [2:0] vz_head=0; logic [5:0] vz_n=0; logic vz_last=0;
  logic qz_valid,qz_ready; logic [5:0] qz_tile,qz_n;
  logic [PAIR_BITS-1:0] qz_pair; logic [1:0] qz_row_valid;
  logic [135:0] qz_even,qz_odd; logic [EPOCH_BITS-1:0] qz_epoch;
  logic [2:0] qz_head; logic qz_last;
  logic qoz_begin_valid,qoz_begin_ready,qoz_region_active,qoz_region_complete,qoz_release_valid,qoz_release_ready;
  logic ae,be,ge;

  logic [1023:0] gu_golden[0:GOLDEN_ROWS-1];
  logic [135:0] z_golden[0:GOLDEN_ROWS-1];
  logic qoz_complete[0:N_TILES-1];
  logic qoz_rd_valid,qoz_rd_ready,qoz_rd_out_valid,qoz_rd_out_ready=1;
  qoz_owner_e qoz_rd_owner; logic [5:0] qoz_rd_tile;
  logic [PAIR_BITS-1:0] qoz_rd_pair; logic [TILE_BITS-1:0] qoz_rd_transport;
  a2_t qoz_rd_entry; logic qoz_error;
  int launched=0,matrix_done_count=0,row_count=0,z_count=0;
  int output_rows[0:N_TILES-1];
  int cycle_count=0,issue_count[0:N_TILES-1],first_issue[0:N_TILES-1],last_issue[0:N_TILES-1];
  bit source_started[0:N_TILES-1];
  pcore_job_t op_job;
  pcore_completion_t op_done;
  job_header_t active_header;
  pcore_matrix_job_t matrix_job,matrix_done_job;
  pcore_vpu_job_t vpu_job,vpu_done_job;
  pcore_sfu_job_t sfu_job,sfu_done_job;
  logic vpu_job_valid,vpu_job_ready=1,vpu_done_valid=0,vpu_done_ready;
  logic sfu_job_valid,sfu_job_ready=1,sfu_done_valid=0,sfu_done_ready;
  logic matrix_done_ready,op_done_ready=0;
  bit vpu_active=0,sfu_active=0;
  logic [135:0] computed_z[0:N_TILES-1][0:ROWS-1];
  int post_jobs=0,sfu_jobs=0,readbacks=0;

  dea8_gu_ctrl_legacy ctrl(
    .clk,.reset,.clear,.job_valid(start),.job_ready(start_ready),.job(op_job),
    .job_done_valid(job_done),.job_done_ready(op_done_ready),.job_done(op_done),
    .busy(scheduler_busy),.protocol_error(scheduler_error),.active_header,
    .matrix_job_valid(tile_valid),.matrix_job_ready(tile_ready),.matrix_job,
    .matrix_done_valid(matrix_done),.matrix_done_ready,.matrix_done(matrix_done_job),
    .pair_valid(pair_ready),.pair_ready(pair_accept),.pair_n(out_n),.pair_epoch(out_epoch),.pair_head(out_head),
    .vpu_job_valid,.vpu_job_ready,.vpu_job,.vpu_done_valid,.vpu_done_ready,.vpu_done(vpu_done_job),
    .sfu_job_valid,.sfu_job_ready,.sfu_job,.sfu_done_valid,.sfu_done_ready,.sfu_done(sfu_done_job),
    .qoz_begin_valid,.qoz_begin_ready,.qoz_complete(qoz_region_complete),
    .z_tile_commit(z_commit),.z_n,.z_epoch,.z_head,
    .engine_error(ae||be||ge||qoz_error));
  assign tile_n=matrix_job.n;assign tile_epoch=matrix_job.header.epoch;assign tile_head=matrix_job.header.head;
  assign matrix_all_done=matrix_done_count==N_TILES;
  always @(posedge clk)if(tile_valid&&tile_ready)matrix_done_job<=matrix_job;

  dea8_gu_matrix_v3 #(.K_TILES(A_TILES),.GU_TILES(GU_TILES)) matrix(
    .clk,.reset,.clear,.start(gu_start),.start_ready(gu_start_ready),
    .job_epoch(tile_epoch),.job_head(tile_head),.job_n(tile_n),
    .local_a_valid(a_valid),.local_a_ready(a_ready),.local_a_entry(a_entry),
    .hbm_valid(b_valid),.hbm_ready(b_ready),.hbm_entry(b_entry),
    .gu_busy,.gu_matrix_done,.gu_pair_ready(pair_ready),.gu_pair_ready_accept(pair_accept),
    .gu_out_valid(out_valid),.gu_out_ready(out_ready),.gu_out_row(out_row),
    .gu_out_epoch(out_epoch),.gu_out_head(out_head),.gu_out_n(out_n),.gu_gate(out_gate),.gu_up(out_up),
    .gu_out_row_valid(out_row_valid),.gu_out_last(out_last),.gu_out_consumed(out_consumed),
    .vpu_z_valid(vz_valid),.vpu_z_ready(vz_ready),.vpu_z_tile(vz_tile),
    .vpu_z_pair(vz_pair),.vpu_z_row_valid(vz_row_valid),.vpu_z_even(vz_even),
    .vpu_z_odd(vz_odd),.vpu_z_epoch(vz_epoch),.vpu_z_head(vz_head),
    .vpu_z_n(vz_n),.vpu_z_last(vz_last),.qoz_z_wr_valid(qz_valid),
    .qoz_z_wr_ready(qz_ready),.qoz_z_wr_tile(qz_tile),.qoz_z_wr_pair(qz_pair),
    .qoz_z_wr_row_valid(qz_row_valid),.qoz_z_wr_even(qz_even),.qoz_z_wr_odd(qz_odd),
    .qoz_z_wr_epoch(qz_epoch),.qoz_z_wr_head(qz_head),.qoz_z_wr_n(qz_n),
    .qoz_z_wr_last(qz_last),.a_protocol_error(ae),.b_protocol_error(be),
    .gu_protocol_error(ge));

  assign tile_ready=gu_start_ready;
  assign gu_start=tile_valid&&tile_ready;
  assign matrix_done=gu_matrix_done;
  // Scheduler completion is tile-level: one pulse after all 26 QOZ pairs
  // for this n have been accepted.  The QOZ model still observes every pair.
  assign z_commit=qz_valid&&qz_ready&&qz_last;
  assign z_n=qz_n; assign z_epoch=qz_epoch; assign z_head=qz_head;

  dea8_qoz_store_v3 qoz(
    .clk,.reset,.clear,.region_begin_valid(qoz_begin_valid),.region_begin_ready(qoz_begin_ready),
    .region_owner(QOZ_Z),.region_epoch(active_header.epoch),.region_head(active_header.head),.region_tiles(6'd32),
    .region_active(qoz_region_active),.region_complete(qoz_region_complete),.region_release_valid(qoz_release_valid),
    .region_release_ready(qoz_release_ready),.wr_valid(qz_valid),.wr_ready(qz_ready),.wr_owner(QOZ_Z),
    .wr_tile(qz_tile),.wr_pair(qz_pair),.wr_row_valid(qz_row_valid),.wr_even(qvec16_t'(qz_even)),
    .wr_odd(qvec16_t'(qz_odd)),.wr_epoch(qz_epoch),.wr_head(qz_head),
    .rd_valid(qoz_rd_valid),.rd_ready(qoz_rd_ready),.rd_owner(qoz_rd_owner),.rd_tile(qoz_rd_tile),
    .rd_pair(qoz_rd_pair),.rd_transport(qoz_rd_transport),.rd_out_valid(qoz_rd_out_valid),
    .rd_out_ready(qoz_rd_out_ready),.rd_entry(qoz_rd_entry),.active_epoch(),.active_head(),
    .active_owner(),.protocol_error(qoz_error));

  function automatic int aval(input int row,input int k,input int i);
    return (row+2*k+3*i)%9-4;
  endfunction
  function automatic int bval(input int n,input int k,input int i,input int col,input bit up);
    if(up) return (2*n+3*k+2*col+i)%13-6;
    return (n+k+col+2*i)%11-5;
  endfunction
  function automatic qvec16_t qv(input int value,input int scale);
    qvec16_t v; begin
      v='0;v.scale=scale[7:0];
      for(int i=0;i<TILE;i++) v.data[i*INT_BITS +: INT_BITS]=value[7:0];
      return v;
    end
  endfunction

  task automatic send_a(input int tile,input int pair);
    a2_t v; begin
      v='0;v.tile_idx=TILE_BITS'(tile);v.pair_idx=PAIR_BITS'(pair);
      v.row_valid=row_mask(pair);
      for(int i=0;i<TILE;i++) begin
        v.row[0].data[i*INT_BITS +: INT_BITS]=aval(2*pair,tile,i);
        v.row[1].data[i*INT_BITS +: INT_BITS]=aval(2*pair+1,tile,i);
      end
      v.row[0].scale=8'(128+(2*pair)%3);
      v.row[1].scale=8'(128+(2*pair+1)%3);
      @(negedge clk);a_entry=v;a_valid=1;
      do @(posedge clk); while(!a_ready);
      @(negedge clk);a_valid=0;
    end
  endtask

  task automatic send_b(input int n,input int tile,input int group);
    b2_t v; begin
      v='0;v.tile_idx=TILE_BITS'(tile);v.group_idx=group[2:0];v.epoch=epoch;
      for(int c=0;c<2;c++) begin
        int col;col=2*group+c;v.col[c]='0;
        for(int i=0;i<TILE;i++)
          v.col[c].data[i*INT_BITS +: INT_BITS]=bval(n,tile/2,i,col,tile[0]);
        v.col[c].scale=8'(128+col%2);
      end
      @(negedge clk);b_entry=v;b_valid=1;
      do @(posedge clk); while(!b_ready);
      @(negedge clk);b_valid=0;
    end
  endtask

  task automatic feed_job(input int n);
    fork
      begin for(int t=0;t<A_TILES;t++) for(int p=0;p<PAIRS;p++) send_a(t,p); end
      begin for(int t=0;t<GU_TILES;t++) for(int g=0;g<8;g++) send_b(n,t,g); end
    join
  endtask

  task automatic read_qoz_z(input int tile,input int pair);
    @(negedge clk);qoz_rd_owner=QOZ_Z;qoz_rd_tile=tile[5:0];qoz_rd_pair=pair[PAIR_BITS-1:0];
    qoz_rd_transport=tile[TILE_BITS-1:0];qoz_rd_valid=1;
    do @(posedge clk); while(!qoz_rd_ready);
    do begin @(posedge clk); #1; end while(!qoz_rd_out_valid);
    if(qoz_rd_entry.row[0]!==qvec16_t'(z_golden[tile*ROWS+2*pair])||
       (pair<PAIRS-1&&qoz_rd_entry.row[1]!==qvec16_t'(z_golden[tile*ROWS+2*pair+1]))||
       qoz_rd_entry.tile_idx!=qoz_rd_transport||qoz_rd_entry.pair_idx!=pair)
      $fatal(1,"QOZ Z readback mismatch tile=%0d pair=%0d",tile,pair);
    @(negedge clk);qoz_rd_valid=0;
    readbacks++;
  endtask

  // Independent simulation post arithmetic driven ONLY by actual G/U outputs.
  // Float rounding points and E8M0/RNE INT8 match the documented Python fixture.
  function automatic real f32(input real x);
    shortreal y;y=x;return real'(y);
  endfunction
  function automatic logic [135:0] post_reference(input logic [15:0][31:0] gate,up);
    real z[16],g,u,t,gelu,mx,step,ratio,fraction;
    int e,q,base;logic [127:0] bytes;
    mx=0;bytes=0;
    for(int n=0;n<16;n++)begin
      g=real'($bitstoshortreal(gate[n]));u=real'($bitstoshortreal(up[n]));
      t=$sqrt(2.0/3.141592653589793)*(g+0.044715*g*g*g);
      gelu=f32(0.5*g*(1.0+(2.0/(1.0+$exp(-2.0*t))-1.0)));
      z[n]=f32(gelu*u);if((z[n]<0?-z[n]:z[n])>mx)mx=z[n]<0?-z[n]:z[n];
    end
    e=0;step=2.0**(-133);
    if(mx!=0)while(e<254&&mx>127.0*step)begin e++;step=step*2.0;end
    for(int n=0;n<16;n++)begin
      ratio=z[n]/step;base=int'($floor(ratio));fraction=ratio-real'(base);
      q=base+int'(fraction>0.5||(fraction==0.5&&(base%2!=0)));
      if(q>127)q=127;if(q< -128)q=-128;bytes[8*n+:8]=8'(q);
    end
    return {bytes,8'(e)};
  endfunction

  task automatic emit_z(input int n);
    for(int p=0;p<PAIRS;p++) begin
      @(negedge clk);vz_tile=n[5:0];vz_pair=p;vz_n=n;vz_epoch=epoch;vz_head=head;
      vz_row_valid=row_mask(p);vz_even=computed_z[n][2*p];
      vz_odd=(p<PAIRS-1)?computed_z[n][2*p+1]:'0;vz_last=(p==PAIRS-1);vz_valid=1;
      do @(posedge clk); while(!vz_ready);
      @(negedge clk);vz_valid=0;
    end
  endtask

  initial begin
    $readmemh("tb/data/gu_fp32.mem",gu_golden);
    $readmemh("tb/data/gu_z_mxint8.mem",z_golden);
    for(int i=0;i<N_TILES;i++) begin output_rows[i]=0;issue_count[i]=0;first_issue[i]=-1;last_issue[i]=-1;qoz_complete[i]=0;source_started[i]=0;end
    a_valid=0;b_valid=0;a_entry='0;b_entry='0;
    op_job='0;op_job.header='{job_id:16'h7319,epoch:epoch,head:head,op:OP_GU};
    qoz_release_valid=0;qoz_rd_valid=0;
    repeat(35) @(posedge clk);reset=0;
    @(negedge clk);start=1;do @(posedge clk);while(!start_ready);@(negedge clk);start=0;
    wait(job_done);
    if(op_done.header!==op_job.header||op_done.status!=JOB_OK||post_jobs!=32||sfu_jobs!=32)
      $fatal(1,"OP_GU completion context/count mismatch");
    repeat(9)begin @(negedge clk);if(!job_done||op_done.header!==op_job.header||start_ready)$fatal(1,"completion backpressure lost operation");end
    op_done_ready=1;@(negedge clk);op_done_ready=0;
    if(launched!=N_TILES||matrix_done_count!=N_TILES||row_count!=N_TILES*ROWS||
       z_count!=N_TILES*PAIRS||!matrix_all_done||scheduler_error||ae||be||ge||qoz_error||!qoz_region_complete)
      $fatal(1,"GU 32 system mismatch launch=%0d matrix=%0d rows=%0d z=%0d all=%0d errors=%0d/%0d/%0d/%0d",
        launched,matrix_done_count,row_count,z_count,matrix_all_done,scheduler_error,ae,be,ge);
    for(int n=0;n<N_TILES;n++) if(output_rows[n]!=ROWS||!qoz_complete[n])
      $fatal(1,"GU n%0d incomplete rows=%0d qoz=%0d",n,output_rows[n],qoz_complete[n]);
    for(int n=0;n<N_TILES;n++) begin
      if(issue_count[n]!=GU_TILES*PAIRS||last_issue[n]-first_issue[n]!=GU_TILES*PAIRS-1)
        $fatal(1,"GU n%0d issue coverage count=%0d first=%0d last=%0d",n,issue_count[n],first_issue[n],last_issue[n]);
    end
    for(int t=0;t<N_TILES;t++) for(int p=0;p<PAIRS;p++) read_qoz_z(t,p);
    @(negedge clk);qoz_release_valid=1;do @(posedge clk); while(!qoz_release_ready);@(negedge clk);qoz_release_valid=0;
    if(readbacks!=832)$fatal(1,"missing QOZ readback");
    $display("tb_v3_gu_32_system PASS OP_GU=1 job_id=7319 matrix_jobs=32 vpu_jobs=32 sfu_jobs=32 rows=%0d z_pairs=%0d qoz_shared=1 qoz_readback=832 actual_GU_post=1 issues_per_n=%0d",row_count,z_count,issue_count[0]);
    #20;$finish;
  end

  always @(posedge clk) begin
    cycle_count++;
    if(matrix.private_matrix.matrix.req_valid) begin
      int issue_n;
      issue_n=matrix.private_matrix.matrix.req_meta.gu_n;
      if(issue_n>=N_TILES) $fatal(1,"GU issue n out of range n=%0d",issue_n);
      issue_count[issue_n]++;
      if(first_issue[issue_n]<0) first_issue[issue_n]=cycle_count;
      last_issue[issue_n]=cycle_count;
    end
    if(tile_valid&&tile_ready) begin
      if(tile_n!=launched||tile_epoch!=epoch||tile_head!=head||source_started[tile_n])
        $fatal(1,"GU launch context/order mismatch n=%0d expected=%0d",tile_n,launched);
      source_started[tile_n]=1;launched++;
      fork automatic int n=tile_n; feed_job(n); join_none
    end
    if(matrix_done) matrix_done_count++;
    if(out_valid&&out_ready) begin
      if(out_epoch!=epoch||out_head!=head||out_n>=N_TILES||out_row>=ROWS||
         out_row_valid!=2'b01)
        $fatal(1,"GU output context mismatch n=%0d row=%0d epoch=%0d/%0d head=%0d/%0d rv=%b",
          out_n,out_row,out_epoch,epoch,out_head,head,out_row_valid);
      for(int i=0;i<TILE;i++) begin
        if(out_gate[i]!==gu_golden[out_n*ROWS+out_row][i*32 +: 32]||
           out_up[i]!==gu_golden[out_n*ROWS+out_row][512+i*32 +: 32])
          $fatal(1,"GU output mismatch n=%0d row=%0d lane=%0d",out_n,out_row,i);
      end
      output_rows[out_n]++;row_count++;
      if(!vpu_active||!sfu_active||out_n!=vpu_done_job.n||out_n!=sfu_done_job.n)
        $fatal(1,"GU output without engine jobs");
      computed_z[out_n][out_row]=post_reference(out_gate,out_up);
      if(computed_z[out_n][out_row]!==z_golden[out_n*ROWS+out_row])$fatal(1,"computed post golden mismatch n=%0d row=%0d got=%h want=%h",out_n,out_row,computed_z[out_n][out_row],z_golden[out_n*ROWS+out_row]);
    end
    if(qz_valid&&qz_ready) begin
      if(qz_n>=N_TILES||qz_tile!=qz_n||qz_pair>=PAIRS||qz_epoch!=epoch||qz_head!=head||
         qz_pair!=z_count%PAIRS||qz_row_valid!=row_mask(qz_pair)||
         qz_even!==z_golden[qz_n*ROWS+2*qz_pair]||
         (qz_pair<PAIRS-1&&qz_odd!==z_golden[qz_n*ROWS+2*qz_pair+1]))
        $fatal(1,"GU Z/QOZ mismatch n=%0d pair=%0d",qz_n,qz_pair);
      z_count++;
      if(qz_last) qoz_complete[qz_n]=1;
    end
  end
  // Public engine Job consumers. SFU models GELU production; VPU models MUL,
  // quantization and committed QOZ writes. Both contexts echo the accepted job.
  assign out_ready=vpu_active&&sfu_active;
  initial begin
    wait(!reset);
    forever begin
      @(posedge clk);
      if(vpu_job_valid&&vpu_job_ready)begin
        vpu_done_job=vpu_job;vpu_active=1;post_jobs++;
        wait(output_rows[vpu_job.n]==ROWS);
        emit_z(int'(vpu_done_job.n));
        @(negedge clk);vpu_done_valid=1;
        do @(posedge clk);while(!vpu_done_ready);
        @(negedge clk);vpu_done_valid=0;vpu_active=0;
      end
    end
  end
  initial begin
    wait(!reset);
    forever begin
      @(posedge clk);
      if(sfu_job_valid&&sfu_job_ready)begin
        sfu_done_job=sfu_job;sfu_active=1;sfu_jobs++;
        wait(output_rows[sfu_job.n]==ROWS);
        @(negedge clk);sfu_done_valid=1;
        do @(posedge clk);while(!sfu_done_ready);
        @(negedge clk);sfu_done_valid=0;sfu_active=0;
      end
    end
  end
  initial begin #3000000;$fatal(1,"GU 32 system watchdog");end
endmodule
