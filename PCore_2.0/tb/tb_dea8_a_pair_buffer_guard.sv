`timescale 1ns/1ps
import pcore2_pkg::*;

// Boundary regression for the single-bank QOZ configuration.  A one-bit bank
// field can still carry the invalid value 1 when BANKS=1.
module tb_dea8_a_pair_buffer_guard;
  localparam int MEM_TILES=1;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic [1:0] wr_mask=0;
  logic wr_bank=0;
  logic [TILE_BITS-1:0] wr_tile=0;
  logic [PAIR_BITS-1:0] wr_pair=0;
  logic [1:0][DATA_BITS-1:0] wr_data='0;
  logic [1:0][SCALE_BITS-1:0] wr_scale='0;
  a_bank_ctrl_t begin_bank='0,commit_bank='0;
  logic protocol_error;
  logic bank_complete;
  logic [EPOCH_BITS-1:0] committed_epoch[0:0];
  logic [TILE_BITS-1:0] committed_base[0:0];
  logic [TILE_BITS:0] committed_tiles[0:0];
  logic rd_valid=0,rd_ready,rd_bank=0,rd_slot=0;
  logic [TILE_BITS-1:0] rd_tile=0,rd_emit_tile=0;
  logic [PAIR_BITS-1:0] rd_pair=0;
  logic [EPOCH_BITS-1:0] rd_epoch=0;
  logic out_valid,out_ready=1;
  a2_t out_entry;
  logic [EPOCH_BITS-1:0] out_epoch;

  dea8_a_pair_buffer #(.MEM_TILES(MEM_TILES),.BANKS(1)) dut(.*);

  task automatic clear_error;
    @(negedge clk);begin_bank='0;commit_bank='0;rd_valid=0;clear=1;
    @(negedge clk);clear=0;
    @(posedge clk);#1;
    if(protocol_error) $fatal(1,"clear did not recover guard test");
  endtask

  initial begin
    repeat(32) @(negedge clk);reset=0;

    @(negedge clk);begin_bank='0;begin_bank.valid=1;begin_bank.bank=1;
    begin_bank.epoch=1;begin_bank.tile_count=1;
    @(posedge clk);#1;
    if(!protocol_error) $fatal(1,"invalid begin Bank was not rejected");
    clear_error();

    // Invalid read Bank must be rejected without indexing the single-bank RAM.
    @(negedge clk);rd_bank=1;rd_tile=0;rd_pair=0;rd_epoch=0;rd_valid=1;
    #1;
    if(rd_ready!==1'b0) $fatal(1,"invalid read Bank became ready");
    @(posedge clk);#1;
    if(protocol_error) $fatal(1,"invalid read Bank raised a protocol error");
    @(negedge clk);rd_valid=0;rd_bank=0;

    @(negedge clk);commit_bank='0;commit_bank.valid=1;commit_bank.bank=1;
    commit_bank.epoch=2;commit_bank.tile_count=1;
    @(posedge clk);#1;
    if(!protocol_error) $fatal(1,"invalid commit Bank was not rejected");
    $display("tb_dea8_a_pair_buffer_guard PASS");
    $finish;
  end
  initial begin #100000;$fatal(1,"Pair buffer guard watchdog"); end
endmodule
