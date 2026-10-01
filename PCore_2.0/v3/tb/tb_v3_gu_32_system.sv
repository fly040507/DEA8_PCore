`timescale 1ns/1ps
import pcore3_pkg::*;

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
  logic pair_ready,pair_accept=1;
  logic out_valid,out_ready=1; logic [5:0] out_row;
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

  dea8_gu_scheduler_v3 #(.N_TILES(N_TILES)) scheduler(
    .clk,.reset,.clear,.start,.start_ready,.job_epoch(epoch),.job_head(head),
    .tile_valid,.tile_ready,.tile_n,.tile_epoch,.tile_head,
    .prefetch_valid,.prefetch_ready,.prefetch_n,.prefetch_epoch,.prefetch_head,
    .tile_matrix_done(matrix_done),.z_tile_commit(z_commit),.z_n,
    .z_epoch,.z_head,.busy(scheduler_busy),.matrix_all_done,.done(job_done),
    .protocol_error(scheduler_error));

  dea8_gu_matrix_v3 #(.K_TILES(A_TILES),.GU_TILES(GU_TILES)) matrix(
    .clk,.reset,.clear,.start(gu_start),.start_ready(gu_start_ready),
    .job_epoch(epoch),.job_head(head),.job_n(tile_n),
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
    .region_owner(QOZ_Z),.region_epoch(epoch),.region_head(head),.region_tiles(6'd32),
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
  endtask

  task automatic emit_z(input int n);
    for(int p=0;p<PAIRS;p++) begin
      @(negedge clk);vz_tile=n[5:0];vz_pair=p;vz_n=n;vz_epoch=epoch;vz_head=head;
      vz_row_valid=row_mask(p);vz_even=z_golden[n*ROWS+2*p];
      vz_odd=(p<PAIRS-1)?z_golden[n*ROWS+2*p+1]:'0;vz_last=(p==PAIRS-1);vz_valid=1;
      do @(posedge clk); while(!vz_ready);
      @(negedge clk);vz_valid=0;
    end
  endtask

  initial begin
    $readmemh("tb/data/gu_fp32.mem",gu_golden);
    $readmemh("tb/data/gu_z_mxint8.mem",z_golden);
    for(int i=0;i<N_TILES;i++) begin output_rows[i]=0;issue_count[i]=0;first_issue[i]=-1;last_issue[i]=-1;qoz_complete[i]=0;source_started[i]=0;end
    a_valid=0;b_valid=0;a_entry='0;b_entry='0;
    repeat(35) @(posedge clk);reset=0;
    @(negedge clk);qoz_begin_valid=1;
    do @(posedge clk); while(!qoz_begin_ready);
    @(negedge clk);qoz_begin_valid=0;
    @(negedge clk);start=1;@(negedge clk);start=0;
    wait(job_done);
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
    $display("tb_v3_gu_32_system PASS n_tiles=32 matrix_done=32 rows=%0d z_pairs=%0d qoz_shared=1 qoz_readback=832 issues_per_n=%0d",row_count,z_count,issue_count[0]);
    #20;$finish;
  end

  always @(posedge clk) begin
    cycle_count++;
    if(matrix.matrix.req_valid) begin
      int issue_n;
      issue_n=matrix.matrix.req_meta.gu_n;
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
      if(out_last) fork automatic int n=out_n; emit_z(n); join_none
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
  initial begin #3000000;$fatal(1,"GU 32 system watchdog");end
endmodule
