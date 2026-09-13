`timescale 1ns/1ps
import dea8_pcore_pkg::*;
module tb_dea8_xbc_adapter;
  localparam int BLOCK_BITS_X=$clog2(D_MODEL/TILE);
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0,xbc_valid=0,xbc_ready,xbc_last,a_valid,a_ready=0,a_last;
  logic [2*DW_ACT-1:0] xbc_q;
  logic [2*SCALE_BITS-1:0] xbc_e;
  logic [ROW_BITS-1:0] xbc_row,a_row;
  logic [BLOCK_BITS_X-1:0] xbc_blk,a_block;
  logic [2*TILE-1:0] xbc_lane_mask;
  logic [TILE-1:0] a_lane_mask;
  logic [EPOCH_BITS-1:0] xbc_epoch,a_epoch;
  logic [DW_ACT-1:0] a_data;
  logic [SCALE_BITS-1:0] a_scale;
  int received=0,cycles=0;
  dea8_xbc_adapter #(.FIFO_DEPTH(3)) dut (.*);
  always @(negedge clk) begin cycles++; a_ready=cycles>12 && cycles%4!=0; end
  always @(posedge clk) if(rst_n && a_valid && a_ready) begin
    if(a_data!==DW_ACT'(received) || a_scale!==SCALE_BITS'(120+received) ||
       a_row!==ROW_BITS'(received/2) || a_block!==BLOCK_BITS_X'(received%2) ||
       a_lane_mask!==TILE'(received%2==0 ? 'h000f : 'h00ff) ||
       a_epoch!==EPOCH_BITS'(3) || a_last!==(received==19))
      $fatal(1,"XBC split/metadata mismatch");
    received++;
  end
  initial begin
    repeat(3) @(negedge clk); rst_n=1;
    for(int i=0;i<10;i++) begin
      xbc_q={DW_ACT'(2*i+1),DW_ACT'(2*i)};
      xbc_e={SCALE_BITS'(121+2*i),SCALE_BITS'(120+2*i)};
      xbc_row=ROW_BITS'(i); xbc_blk=0; xbc_epoch=3;
      xbc_lane_mask={TILE'('h00ff),TILE'('h000f)}; xbc_last=i==9;
      xbc_valid=1;
      do @(posedge clk); while(!xbc_ready);
      @(negedge clk);
    end
    xbc_valid=0;
    wait(received==20); repeat(3) @(negedge clk);
    if(a_valid) $fatal(1,"Duplicate XBC output");
    $display("tb_dea8_xbc_adapter PASS: split, scale, row, block, mask, epoch, last, stalls");
    $finish;
  end
  initial begin #10000; $fatal(1,"XBC timeout"); end
endmodule
