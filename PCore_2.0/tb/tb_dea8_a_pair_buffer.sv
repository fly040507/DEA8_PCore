`timescale 1ns/1ps
import pcore2_pkg::*;
module tb_dea8_a_pair_buffer;
  localparam int MEM_TILES=32;
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
  logic [1:0] bank_complete;
  logic [EPOCH_BITS-1:0] committed_epoch[0:1];
  logic [TILE_BITS-1:0] committed_base[0:1];
  logic [TILE_BITS:0] committed_tiles[0:1];
  logic rd_valid=0,rd_ready,rd_bank=0,rd_slot=0;
  logic [TILE_BITS-1:0] rd_tile=0,rd_emit_tile=0;
  logic [PAIR_BITS-1:0] rd_pair=0;
  logic [EPOCH_BITS-1:0] rd_epoch=0;
  logic out_valid,out_ready=1;
  a2_t out_entry;
  logic [EPOCH_BITS-1:0] out_epoch;
  int checked=0;

  dea8_a_pair_buffer #(.MEM_TILES(MEM_TILES),.BANKS(2)) dut(.*);

  function automatic logic [7:0] value(input int bank,t,p,r,k,base);
    return 8'(bank*37+base*11+t*5+p*3+r*17+k);
  endfunction

  task automatic pulse_begin(input int bank,epoch,count);
    @(negedge clk); begin_bank='0;begin_bank.valid=1;begin_bank.bank=bank;
      begin_bank.epoch=epoch;begin_bank.tile_base=0;begin_bank.tile_count=count;
    @(negedge clk); begin_bank='0;
  endtask

  task automatic write_tiles(input int bank,count,base);
    for(int t=0;t<count;t++) for(int p=0;p<PAIRS;p++) begin
      @(negedge clk); wr_bank=bank;wr_tile=t;wr_pair=p;wr_mask=row_mask(p);
      for(int r=0;r<ROW_LANES;r++) begin
        wr_scale[r]=8'(base+r+t);
        for(int k=0;k<TILE;k++) wr_data[r][k*INT_BITS+:INT_BITS]=value(bank,t,p,r,k,base);
      end
      @(posedge clk);
    end
    @(negedge clk);wr_mask='0;
  endtask

  task automatic pulse_commit(input int bank,epoch,count);
    @(negedge clk);commit_bank='0;commit_bank.valid=1;commit_bank.bank=bank;
      commit_bank.epoch=epoch;commit_bank.tile_base=0;commit_bank.tile_count=count;
    @(negedge clk);commit_bank='0;
  endtask

  task automatic read_one(input int bank,t,p,epoch,base);
    @(negedge clk);rd_bank=bank;rd_tile=t;rd_emit_tile=t;rd_pair=p;rd_epoch=epoch;rd_valid=1;
    #1;
    if(!rd_ready) $fatal(1,"Expected readable region bank=%0d tile=%0d pair=%0d",bank,t,p);
    @(posedge clk); #1;
    if(!out_valid || out_epoch!==epoch || out_entry.tile_idx!==t || out_entry.pair_idx!==p)
      $fatal(1,"Read metadata mismatch");
    for(int r=0;r<ROW_LANES;r++) begin
      if(out_entry.row_valid[r] && out_entry.scale[r]!==8'(base+r+t))
        $fatal(1,"Read scale mismatch");
      for(int k=0;k<TILE;k++) if(out_entry.row_valid[r] &&
        out_entry.data[r][k*INT_BITS+:INT_BITS]!==value(bank,t,p,r,k,base))
        $fatal(1,"Read data mismatch bank=%0d tile=%0d pair=%0d row=%0d k=%0d",bank,t,p,r,k);
    end
    checked++;
    @(negedge clk);rd_valid=0;
  endtask

  task automatic expect_not_ready(input int bank,t,p,epoch);
    @(negedge clk);rd_bank=bank;rd_tile=t;rd_emit_tile=t;rd_pair=p;rd_epoch=epoch;rd_valid=1;
    @(posedge clk); #1;
    if(rd_ready || out_valid) $fatal(1,"Uncommitted/out-of-region tile was readable");
    @(negedge clk);rd_valid=0;
  endtask

  initial begin
    repeat(30) @(negedge clk); reset=0;

    // Z: full physical QOZ capacity, 32 logical Tiles.
    pulse_begin(0,10,32); write_tiles(0,32,10); pulse_commit(0,10,32);
    $display("Z status complete=%b epoch=%0d base=%0d tiles=%0d err=%b",bank_complete,committed_epoch[0],committed_base[0],committed_tiles[0],protocol_error);
    if(!bank_complete[0] || committed_tiles[0]!==32 || committed_epoch[0]!==10)
      $fatal(1,"Z32 commit failed");
    read_one(0,0,0,10,10); read_one(0,31,PAIRS-1,10,10);

    // Z -> Q reuse: old tile16..31 remains in RAM but is no longer valid.
    pulse_begin(0,11,16); write_tiles(0,16,90); pulse_commit(0,11,16);
    if(!bank_complete[0] || committed_tiles[0]!==16 || committed_epoch[0]!==11)
      $fatal(1,"Q16 commit after reuse failed");
    read_one(0,0,0,11,90); read_one(0,15,PAIRS-1,11,90);
    expect_not_ready(0,16,0,11);
    expect_not_ready(0,0,0,10);

    // Invalid writes are reported through protocol_error and do not become
    // part of the committed region.
    clear=1; @(negedge clk); clear=0;
    pulse_begin(1,20,16);
    @(negedge clk);wr_bank=1;wr_tile=16;wr_pair=0;wr_mask=2'b11;
    @(posedge clk); #1;
    if(!protocol_error) $fatal(1,"Out-of-region write was not rejected");
    $display("tb_dea8_a_pair_buffer PASS checked_reads=%0d",checked);
    $finish;
  end
  initial begin #1000000;$fatal(1,"Pair buffer watchdog"); end
endmodule
