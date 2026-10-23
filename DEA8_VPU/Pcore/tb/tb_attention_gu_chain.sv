`timescale 1ns/1ps
import pcore_pkg::*;

// Shared-QOZ lifecycle contract used by the single-core task chain.  The
// matrix datapaths are covered by Attention55 and GU32 system tests; this TB
// verifies that both phases use the same physical owner protocol.
module tb_attention_gu_chain;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic bv,br; qoz_owner_e bo; logic [5:0] bt; logic [EPOCH_BITS-1:0] be; logic [2:0] bh;
  logic active,complete,relv,relr; logic wv,wr; qoz_owner_e wo; logic [5:0] wt; logic [PAIR_BITS-1:0] wp; logic [1:0] wmask; qvec16_t we,wo_data; logic [EPOCH_BITS-1:0] wepoch; logic [2:0] whead;
  logic rv,rr; qoz_owner_e ro; logic [5:0] rt; logic [PAIR_BITS-1:0] rp; logic [TILE_BITS-1:0] rtransport; logic rov,ror=1; a2_t rout; logic protocol_error;
  int read_count=0,z_writes=0;

  dea8_qoz_store qoz(
    .clk,.reset,.clear,.region_begin_valid(bv),.region_begin_ready(br),.region_owner(bo),.region_epoch(be),.region_head(bh),.region_tiles(bt),
    .region_active(active),.region_complete(complete),.region_release_valid(relv),.region_release_ready(relr),.wr_valid(wv),.wr_ready(wr),.wr_owner(wo),.wr_tile(wt),.wr_pair(wp),.wr_row_valid(wmask),.wr_even(we),.wr_odd(wo_data),.wr_epoch(wepoch),.wr_head(whead),
    .rd_valid(rv),.rd_ready(rr),.rd_owner(ro),.rd_tile(rt),.rd_pair(rp),.rd_transport(rtransport),.rd_out_valid(rov),.rd_out_ready(ror),.rd_entry(rout),.active_epoch(),.active_head(),.active_owner(),.protocol_error);

  function automatic qvec16_t qv(input int x); qvec16_t q; begin q='0;q.scale=8'd128;for(int i=0;i<TILE;i++)q.data[i*8+:8]=x[7:0];return q;end endfunction
  task automatic begin_region(input qoz_owner_e owner,input int tiles);
    @(negedge clk);bo=owner;bt=tiles;be=4'hb;bh=3'h6;bv=1;do @(posedge clk);while(!br);@(negedge clk);bv=0;
  endtask
  task automatic write_region(input qoz_owner_e owner,input int tiles,input int base);
    for(int t=0;t<tiles;t++)for(int p=0;p<PAIRS;p++) begin
      @(negedge clk);wo=owner;wt=t;wp=p;wmask=row_mask(p);we=qv(base+t+p);wo_data=qv(base+t+p+1);wepoch=4'hb;whead=3'h6;wv=1;do @(posedge clk);while(!wr);@(negedge clk);wv=0;
      if(owner==QOZ_Z) z_writes++;
    end
  endtask
  task automatic read_one(input qoz_owner_e owner,input int tile,input int pair);
    @(negedge clk);ro=owner;rt=tile;rp=pair;rtransport=tile;rv=1;do @(posedge clk);while(!rr);do @(posedge clk);while(!rov);read_count++;@(negedge clk);rv=0;
  endtask
  task automatic release_region;
    @(negedge clk);relv=1;do @(posedge clk);while(!relr);@(negedge clk);relv=0;
  endtask

  initial begin
    bv=0;relv=0;wv=0;rv=0;we='0;wo_data='0;repeat(20)@(negedge clk);reset=0;
    // Q owner: Attention input region.
    begin_region(QOZ_Q,16);write_region(QOZ_Q,16,1);if(!complete)$fatal(1,"Q region incomplete");read_one(QOZ_Q,0,0);read_one(QOZ_Q,15,25);release_region();
    // The release edge is the explicit Attention->G-U handoff.
    if(active) $fatal(1,"Q owner was not released");
    begin_region(QOZ_Z,32);write_region(QOZ_Z,32,1000);if(!complete||z_writes!=32*PAIRS)$fatal(1,"Z region incomplete writes=%0d",z_writes);
    for(int t=0;t<32;t+=5) read_one(QOZ_Z,t,25);release_region();
    if(active||protocol_error||read_count!=9)$fatal(1,"QOZ chain mismatch active=%0d error=%0d reads=%0d",active,protocol_error,read_count);
    $display("tb_attention_gu_chain PASS Q16_read_release=1 Z32_write_read_release=1 shared_owner=1");$finish;
  end
  initial begin #300000;$fatal(1,"Attention/GU QOZ chain watchdog");end
endmodule
