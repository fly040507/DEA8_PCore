`timescale 1ns/1ps
import pcore3_pkg::*;

module tb_v3_gu_scheduler;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0,start=0,start_ready;
  logic [EPOCH_BITS-1:0] epoch=4'h5; logic [2:0] head=3'h3;
  logic tile_valid,tile_ready=1; logic [5:0] tile_n;
  logic [EPOCH_BITS-1:0] tile_epoch; logic [2:0] tile_head;
  logic matrix_done=0,z_commit=0; logic [5:0] z_n;
  logic [EPOCH_BITS-1:0] z_epoch; logic [2:0] z_head;
  logic busy,matrix_all_done,done,error; int issued=0,zcount=0;

  dea8_gu_scheduler_v3 dut(
    .clk,.reset,.clear,.start,.start_ready,.job_epoch(epoch),.job_head(head),
    .tile_valid(tile_valid),.tile_ready(tile_ready),.tile_n(tile_n),
    .tile_epoch(tile_epoch),.tile_head(tile_head),
    .tile_matrix_done(matrix_done),.z_tile_commit(z_commit),.z_n(z_n),
    .z_epoch(z_epoch),.z_head(z_head),.busy(busy),
    .matrix_all_done(matrix_all_done),.done(done),.protocol_error(error));

  initial begin
    repeat(20) @(negedge clk); reset=0;
    @(negedge clk); start=1; @(negedge clk); start=0;
    wait(done);
    if(issued!=32||zcount!=32||!matrix_all_done||error)
      $fatal(1,"GU scheduler mismatch issued=%0d z=%0d all=%0d error=%0d",issued,zcount,matrix_all_done,error);
    $display("tb_v3_gu_scheduler PASS n_tiles=32 z_commits=32");
    #10 $finish;
  end
  always @(posedge clk) begin
    matrix_done<=0;z_commit<=0;
    if(tile_valid&&tile_ready) begin
      if(tile_n!=issued||tile_epoch!=epoch||tile_head!=head)
        $fatal(1,"GU tile context mismatch n=%0d expected=%0d",tile_n,issued);
      issued++; matrix_done<=1;
    end
    if(matrix_done&&zcount<32) begin
      z_commit<=1;z_n<=zcount;z_epoch<=epoch;z_head<=head;zcount++;
    end
  end
  initial begin #10000; $fatal(1,"GU scheduler watchdog"); end
endmodule
