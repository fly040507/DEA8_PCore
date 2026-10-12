`timescale 1ns/1ps
import pcore_pkg::*;

module tb_qoz_shared;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic begin_valid,begin_ready; qoz_owner_e begin_owner; logic [EPOCH_BITS-1:0] begin_epoch; logic [2:0] begin_head; logic [5:0] begin_tiles;
  logic active,complete,release_valid,release_ready;
  logic wr_valid,wr_ready; qoz_owner_e wr_owner; logic [5:0] wr_tile; logic [PAIR_BITS-1:0] wr_pair; logic [1:0] wr_rv; qvec16_t wr_even,wr_odd; logic [EPOCH_BITS-1:0] wr_epoch; logic [2:0] wr_head;
  logic rd_valid,rd_ready; qoz_owner_e rd_owner; logic [5:0] rd_tile; logic [PAIR_BITS-1:0] rd_pair; logic [TILE_BITS-1:0] rd_transport; logic rd_out_valid,rd_out_ready=1; a2_t rd_entry; logic [EPOCH_BITS-1:0] active_epoch; logic [2:0] active_head; qoz_owner_e active_owner; logic error;

  dea8_qoz_store dut(
    .clk,.reset,.clear,.region_begin_valid(begin_valid),.region_begin_ready(begin_ready),.region_owner(begin_owner),
    .region_epoch(begin_epoch),.region_head(begin_head),.region_tiles(begin_tiles),.region_active(active),.region_complete(complete),
    .region_release_valid(release_valid),.region_release_ready(release_ready),.wr_valid,.wr_ready,.wr_owner,.wr_tile,.wr_pair,
    .wr_row_valid(wr_rv),.wr_even,.wr_odd,.wr_epoch,.wr_head,.rd_valid,.rd_ready,.rd_owner,.rd_tile,.rd_pair,
    .rd_transport,.rd_out_valid,.rd_out_ready,.rd_entry,.active_epoch,.active_head,.active_owner,.protocol_error(error));

  function automatic qvec16_t qv(input int v);
    qvec16_t q; begin q='0;q.scale=8'd128;for(int i=0;i<TILE;i++)q.data[i*8+:8]=v[7:0];return q;end
  endfunction
  task automatic begin_region(input qoz_owner_e owner,input int tiles);
    @(negedge clk);begin_owner=owner;begin_tiles=tiles[5:0];begin_epoch=4'h7;begin_head=3'h4;begin_valid=1;
    do @(posedge clk); while(!begin_ready); @(negedge clk);begin_valid=0;
  endtask
  task automatic write_pair(input qoz_owner_e owner,input int tile,input int pair,input int value);
    @(negedge clk);wr_owner=owner;wr_tile=tile[5:0];wr_pair=pair[PAIR_BITS-1:0];wr_rv=row_mask(pair);wr_even=qv(value);wr_odd=qv(value+1);wr_epoch=4'h7;wr_head=3'h4;wr_valid=1;
    do @(posedge clk); while(!wr_ready); @(negedge clk);wr_valid=0;
  endtask
  task automatic release_region;
    @(negedge clk);release_valid=1;do @(posedge clk); while(!release_ready);@(negedge clk);release_valid=0;
  endtask
  task automatic read_pair(input qoz_owner_e owner,input int tile,input int pair,input int value);
    @(negedge clk);rd_owner=owner;rd_tile=tile[5:0];rd_pair=pair[PAIR_BITS-1:0];rd_transport=tile[TILE_BITS-1:0];rd_valid=1;
    do @(posedge clk); while(!rd_ready); do @(posedge clk); while(!rd_out_valid);
    if(rd_entry.row[0].data[7:0]!==value[7:0]||rd_entry.tile_idx!=rd_transport||rd_entry.pair_idx!=pair)
      $fatal(1,"QOZ read mismatch owner=%0d tile=%0d pair=%0d",owner,tile,pair);
    @(negedge clk);rd_valid=0;
  endtask

  initial begin
    begin_valid=0;release_valid=0;wr_valid=0;rd_valid=0;wr_even='0;wr_odd='0;
    repeat(20)@(negedge clk);reset=0;
    begin_region(QOZ_Q,16);for(int t=0;t<16;t++)for(int p=0;p<PAIRS;p++)write_pair(QOZ_Q,t,p,t+p);if(!complete)$fatal(1,"Q complete missing");read_pair(QOZ_Q,15,25,40);release_region();
    begin_region(QOZ_O,16);for(int t=0;t<16;t++)for(int p=0;p<PAIRS;p++)write_pair(QOZ_O,t,p,100+t+p);if(!complete)$fatal(1,"O complete missing");read_pair(QOZ_O,15,25,140);release_region();
    begin_region(QOZ_Z,32);for(int t=0;t<32;t++)for(int p=0;p<PAIRS;p++)write_pair(QOZ_Z,t,p,200+t+p);if(!complete)$fatal(1,"Z complete missing");for(int t=0;t<32;t+=7)read_pair(QOZ_Z,t,25,225+t);release_region();
    if(error) $fatal(1,"unexpected QOZ protocol error");
    @(negedge clk);begin_owner=QOZ_Z;begin_tiles=32;begin_epoch=4'h7;begin_head=3'h4;begin_valid=1;@(posedge clk);begin_valid=0;
    // Wrong-owner write must be rejected and latched as a protocol error.
    @(negedge clk);wr_owner=QOZ_Q;wr_tile=0;wr_pair=0;wr_rv=2'b11;wr_even=qv(1);wr_odd=qv(2);wr_epoch=4'h7;wr_head=3'h4;wr_valid=1;@(posedge clk);if(wr_ready)$fatal(1,"wrong owner accepted");wr_valid=0;
    $display("tb_qoz_shared PASS Q16/O16/Z32 complete_release=1 wrong_owner_rejected=1");$finish;
  end
  initial begin #300000;$fatal(1,"QOZ watchdog");end
endmodule
