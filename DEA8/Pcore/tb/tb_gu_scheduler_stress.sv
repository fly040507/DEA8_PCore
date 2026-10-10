`timescale 1ns/1ps
import pcore_pkg::*;

module tb_gu_scheduler_stress;
  localparam int N=32;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0,start=0,start_ready;
  logic [EPOCH_BITS-1:0] epoch=4'h9; logic [2:0] head=3'h5;
  logic tile_valid,tile_ready; logic [5:0] tile_n,tile_prefetch_n;
  logic [EPOCH_BITS-1:0] tile_epoch,prefetch_epoch; logic [2:0] tile_head,prefetch_head;
  logic prefetch_valid,prefetch_ready; logic matrix_done=0,z_commit=0; logic [5:0] z_n;
  logic [EPOCH_BITS-1:0] z_epoch; logic [2:0] z_head;
  logic busy,matrix_all_done,done,error;
  int cycles=0,issued=0,completed=0,z_done=0,prefetches=0;
  int matrix_delay=0,z_delay=0; int z_fifo[$];

  dea8_gu_scheduler #(.N_TILES(N)) dut(
    .clk,.reset,.clear,.start,.start_ready,.job_epoch(epoch),.job_head(head),
    .tile_valid,.tile_ready,.tile_n,.tile_epoch,.tile_head,
    .prefetch_valid,.prefetch_ready,.prefetch_n(tile_prefetch_n),.prefetch_epoch,.prefetch_head,
    .tile_matrix_done(matrix_done),.z_tile_commit(z_commit),.z_n,
    .z_epoch,.z_head,.busy,.matrix_all_done,.done,.protocol_error(error));

  assign tile_ready=(cycles%5)!=0;
  assign prefetch_ready=(cycles%3)==0;

  initial begin
    repeat(20)@(negedge clk);reset=0;@(negedge clk);start=1;@(negedge clk);start=0;
    wait(done);
    if(issued!=N||completed!=N||z_done!=N||prefetches!=N-1||!matrix_all_done||error)
      $fatal(1,"scheduler stress mismatch issue=%0d matrix=%0d z=%0d prefetch=%0d all=%0d error=%0d",
        issued,completed,z_done,prefetches,matrix_all_done,error);
    $display("tb_gu_scheduler_stress PASS tile_stalls=1 matrix_delay=3 z_delay=5 prefetches=%0d matrix_all_done_before_done=1",prefetches);
    #10;$finish;
  end

  always @(posedge clk) begin
    cycles++;
    matrix_done<=0;z_commit<=0;
    if(tile_valid&&tile_ready) begin
      if(tile_n!=issued||tile_epoch!=epoch||tile_head!=head)
        $fatal(1,"tile context/order mismatch n=%0d expected=%0d",tile_n,issued);
      issued++;matrix_delay<=3;
    end else if(matrix_delay>0) begin
      if(matrix_delay==1) begin matrix_done<=1;matrix_delay<=0;z_fifo.push_back(tile_n);completed++;end
      else matrix_delay<=matrix_delay-1;
    end
    if(z_delay==0&&z_fifo.size()>0) z_delay<=5;
    else if(z_delay>0) begin
      if(z_delay==1) begin
        z_commit<=1;z_n<=z_fifo.pop_front();z_epoch<=epoch;z_head<=head;z_delay<=0;z_done++;
      end else z_delay<=z_delay-1;
    end
    if(prefetch_valid&&prefetch_ready) begin
      if(tile_prefetch_n!=tile_n+1'b1||prefetch_epoch!=epoch||prefetch_head!=head)
        $fatal(1,"prefetch context mismatch n=%0d next=%0d",tile_n,tile_prefetch_n);
      prefetches++;
    end
    if(matrix_all_done&&z_done<N) begin
      if(done) $fatal(1,"scheduler done before all Z commits");
    end
  end
  initial begin #20000;$display("GU stress debug state=%0d issued=%0d completed=%0d z=%0d prefetch=%0d md=%0d zd=%0d err=%0d",dut.state_q,issued,completed,z_done,prefetches,matrix_delay,z_delay,error);$fatal(1,"GU scheduler stress watchdog");end
endmodule
