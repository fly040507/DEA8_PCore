`timescale 1ns/1ps
import pcore2_pkg::*;
module tb_dea8_a2_fifo;
  localparam int TILES=12;
  logic clk=0;
  always #2 clk=~clk;
  logic reset=1,clear=0,in_valid=0,in_ready,reserve_tile=0;
  logic tile_available,running,out_valid,protocol_error;
  a2_t in_entry,out_entry;
  logic [$clog2(A_DEPTH+1)-1:0] count,complete_tiles;
  int seen=0,run_length=0,overlap=0,full_cycles=0,cycles=0;
  dea8_a2_fifo dut(.*);

  function automatic a2_t entry(input int t,p);
    a2_t v;
    v='0;
    v.tile_idx=t; v.slot=t%2; v.pair_idx=p; v.row_valid=row_mask(p);
    for(int r=0;r<ROW_LANES;r++) begin
      v.scale[r]=8'(t*11+p+r);
      for(int k=0;k<TILE;k++) v.data[r][k*INT_BITS+:INT_BITS]=8'(t*31+p*7+r*13+k);
    end
    return v;
  endfunction
  always @(posedge clk) if(!reset && !clear) begin
    cycles++;
    if(in_valid && in_ready && out_valid) overlap++;
    if(count==A_DEPTH) full_cycles++;
    if(out_valid) begin
      if(out_entry!==entry(seen/PAIRS,seen%PAIRS)) $fatal(1,"A2 payload/order %0d",seen);
      seen++; run_length++;
    end else if(run_length!=0) begin
      if(run_length!=PAIRS) $fatal(1,"A2 non-contiguous tile length %0d",run_length);
      run_length=0;
    end
  end
  // Wait for a full FIFO before the first reservation to exercise backpressure.
  always @(negedge clk)
    reserve_tile=!reset && !clear && tile_available && cycles>90;
  initial begin
    in_entry='0;
    repeat(3) @(negedge clk);reset=0;
    for(int t=0;t<TILES;t++) for(int p=0;p<PAIRS;p++) begin
      @(negedge clk);in_entry=entry(t,p);in_valid=1;
      do @(posedge clk);while(!in_ready);
    end
    @(negedge clk);in_valid=0;
    wait(seen==TILES*PAIRS);
    repeat(3) @(negedge clk);
    if(count!=0 || complete_tiles!=0 || running || protocol_error || overlap==0 || full_cycles==0)
      $fatal(1,"A2 final state/coverage");
    clear=1;
    @(negedge clk);clear=0;
    if(out_valid || tile_available) $fatal(1,"A2 clear");
    $display("tb_dea8_a2_fifo PASS entries=%0d overlap=%0d full_cycles=%0d",seen,overlap,full_cycles);
    $finish;
  end
  initial begin #20000;$fatal(1,"A2 FIFO watchdog");end
endmodule
