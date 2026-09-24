`timescale 1ns/1ps
import pcore2_pkg::*;
module tb_dea8_w_tile_assembler_pp;
  localparam int TILES=12;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,hbm_valid=0,hbm_ready,out_valid,out_ready=1;
  logic [HBM_BITS-1:0] hbm_data;
  b_t out_entry,held;
  int seen=0,cycle=0,last_cycle=0,overlap=0,stalls=0;
  bit was_stalled=0;
  dea8_w_tile_assembler_pp dut(.*);
  function automatic logic [7:0] value(input int t,k,n);
    return 8'(t*43+k*17+n*7-128);
  endfunction
  always @(negedge clk)
    out_ready=seen<4*TILE || cycle%7!=0;
  always @(posedge clk) if(!reset && !clear) begin
    cycle++;
    if(was_stalled && (!out_valid || out_entry!==held)) $fatal(1,"W unstable under backpressure");
    was_stalled=out_valid && !out_ready;
    held=out_entry;
    if(was_stalled) stalls++;
    if(hbm_valid && hbm_ready && out_valid && out_ready) overlap++;
    if(out_valid && out_ready) begin
      if(seen>0 && seen<4*TILE && cycle!=last_cycle+1) $fatal(1,"W steady drain bubble");
      for(int k=0;k<TILE;k++)
        if(out_entry.data[k*INT_BITS+:INT_BITS]!==value(seen/TILE,k,seen%TILE))
          $fatal(1,"W transpose tile=%0d col=%0d k=%0d",seen/TILE,seen%TILE,k);
      if(out_entry.scale!==8'(seen/TILE*19+seen%TILE)) $fatal(1,"W scale");
      seen++;last_cycle=cycle;
    end
  end
  initial begin
    hbm_data='0;repeat(3) @(negedge clk);reset=0;
    for(int t=0;t<TILES;t++) for(int b=0;b<HBM_BEATS;b++) begin
      @(negedge clk);hbm_data='0;
      if(b<DATA_BEATS) begin
        for(int h=0;h<HBM_BITS/DATA_BITS;h++) for(int n=0;n<TILE;n++)
          hbm_data[(h*TILE+n)*INT_BITS+:INT_BITS]=value(t,b*(HBM_BITS/DATA_BITS)+h,n);
      end else for(int n=0;n<TILE;n++) hbm_data[n*SCALE_BITS+:SCALE_BITS]=8'(t*19+n);
      hbm_valid=1;
      do @(posedge clk);while(!hbm_ready);
    end
    @(negedge clk);hbm_valid=0;
    wait(seen==TILES*TILE);@(negedge clk);
    if(overlap==0 || stalls==0) $fatal(1,"W missing coverage");
    $display("tb_dea8_w_tile_assembler_pp PASS columns=%0d overlap=%0d stalls=%0d",seen,overlap,stalls);
    $finish;
  end
  initial begin #20000;$fatal(1,"W assembler watchdog");end
endmodule
