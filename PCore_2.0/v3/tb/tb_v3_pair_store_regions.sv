`timescale 1ns/1ps
import pcore3_pkg::*;

module tb_v3_pair_store_regions;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic [1:0] wr_mask; logic wr_bank; logic [TILE_BITS-1:0] wr_tile; logic [PAIR_BITS-1:0] wr_pair;
  qvec16_t wr_row[0:1];
  logic begin_valid,begin_bank; logic [EPOCH_BITS-1:0] begin_epoch; logic [TILE_BITS-1:0] begin_base; logic [TILE_BITS:0] begin_tiles;
  logic commit_valid,commit_bank; logic [EPOCH_BITS-1:0] commit_epoch; logic [TILE_BITS-1:0] commit_base; logic [TILE_BITS:0] commit_tiles;
  logic protocol_error; logic [1:0] complete; logic [EPOCH_BITS-1:0] complete_epoch[0:1]; logic [TILE_BITS-1:0] complete_base[0:1]; logic [TILE_BITS:0] complete_tiles[0:1];
  logic rd_valid,rd_ready,rd_bank,rd_slot; logic [TILE_BITS-1:0] rd_tile; logic [PAIR_BITS-1:0] rd_pair; logic [EPOCH_BITS-1:0] rd_epoch;
  logic out_valid,out_ready; a2_t out_entry;

  dea8_pair_store_v3 #(.MEM_TILES(32),.BANKS(2)) dut(.clk,.reset,.clear,.wr_mask,.wr_bank,.wr_tile,.wr_pair,.wr_row,
    .begin_valid,.begin_bank,.begin_epoch,.begin_base,.begin_tiles,.commit_valid,.commit_bank,.commit_epoch,.commit_base,.commit_tiles,
    .protocol_error,.complete,.complete_epoch,.complete_base,.complete_tiles,.rd_valid,.rd_ready,.rd_bank,.rd_tile,.rd_pair,.rd_slot,.rd_epoch,
    .out_valid,.out_ready,.out_entry);

  task automatic begin_region(input int bank,input int epoch,input int tiles);
    @(negedge clk);begin_valid=1;begin_bank=bank;begin_epoch=epoch;begin_base=0;begin_tiles=tiles;
    @(posedge clk);#1;begin_valid=0;
  endtask
  task automatic write_region(input int bank,input int tiles);
    for(int t=0;t<tiles;t++) for(int p=0;p<PAIRS;p++) begin
      @(negedge clk);wr_bank=bank;wr_tile=t;wr_pair=p;wr_mask=row_mask(p);
      for(int r=0;r<2;r++) begin wr_row[r].scale=8'd128;for(int k=0;k<TILE;k++) wr_row[r].data[k*8+:8]=8'(t+p+r+k);end
      @(posedge clk);#1;
    end
  endtask
  task automatic commit_region(input int bank,input int epoch,input int tiles);
    @(negedge clk);wr_mask=0;commit_valid=1;commit_bank=bank;commit_epoch=epoch;commit_base=0;commit_tiles=tiles;
    @(posedge clk);#1;commit_valid=0;
  endtask
  initial begin
    wr_mask=0;wr_bank=0;wr_tile=0;wr_pair=0;begin_valid=0;begin_bank=0;begin_epoch=0;begin_base=0;begin_tiles=0;
    commit_valid=0;commit_bank=0;commit_epoch=0;commit_base=0;commit_tiles=0;rd_valid=0;rd_bank=0;rd_tile=0;rd_pair=0;rd_slot=0;rd_epoch=0;out_ready=1;
    for(int r=0;r<2;r++) begin wr_row[r].data=0;wr_row[r].scale=0;end
    repeat(20) @(negedge clk);reset=0;
    begin_region(0,1,16);write_region(0,16);commit_region(0,1,16);
    if(!complete[0]||complete_tiles[0]!=16||protocol_error)
      $fatal(1,"Q16 commit failed complete=%b tiles=%0d err=%b even=%0d odd=%0d",complete,complete_tiles[0],protocol_error,dut.writes[0][0],dut.writes[0][1]);
    begin_region(1,2,32);write_region(1,32);commit_region(1,2,32);
    if(!complete[1]||complete_tiles[1]!=32||protocol_error) $fatal(1,"Z32 commit failed");
    // Reuse the Q bank after its previous committed Region has been consumed.
    begin_region(0,3,16);write_region(0,16);commit_region(0,3,16);
    if(!complete[0]||complete_tiles[0]!=16||complete_epoch[0]!=3||protocol_error)
      $fatal(1,"Z32 to Q16 reuse failed");
    rd_valid=1;rd_bank=1;rd_tile=31;rd_pair=25;rd_epoch=2;@(negedge clk);#1;
    if(!rd_ready) $fatal(1,"Z32 tail read not ready");
    @(posedge clk);#1;
    if(!out_valid||out_entry.row_valid!=2'b01||out_entry.tile_idx!=31) $fatal(1,"Z32 tail read mismatch");
    $display("tb_v3_pair_store_regions PASS Q16=400odd Z32=800odd reuse=1");
    $finish;
  end
  initial begin #300000;$fatal(1,"v3 pair store region watchdog"); end
endmodule
