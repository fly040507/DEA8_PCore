`timescale 1ns/1ps
import dea8_pcore_pkg::*;
module tb_dea8_w_b_stream;
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,clear=0,hbm_valid=0,hbm_ready,b_valid,b_ready=0;
  logic [HBM_BITS-1:0] hbm_data;
  b_entry_t b_entry;
  logic [$clog2(W_B_FIFO_DEPTH+1)-1:0] count;
  int received=0,phase=0,cycle=0,backpressure=0,produced=0;
  logic [31:0] random_q=32'hc731b493;
  dea8_w_b_stream dut (.*);
  function automatic logic [HBM_BITS-1:0] beat(input int tile,idx);
    logic [HBM_BITS-1:0] value;
    value='1;
    if(idx<WEIGHT_HBM_BEATS_PER_TILE)
      for(int r=0;r<WEIGHT_WORDS_PER_HBM;r++) for(int n=0;n<TILE;n++)
        value[(r*TILE+n)*WEIGHT_BITS+:WEIGHT_BITS]=WEIGHT_BITS'(tile*31+(idx*2+r)*7+n*13);
    else for(int n=0;n<TILE;n++) value[n*SCALE_BITS+:SCALE_BITS]=SCALE_BITS'(tile*11+n);
    return value;
  endfunction
  task automatic send_beat(input int tile,idx);
    @(negedge clk);hbm_valid=1;hbm_data=beat(tile,idx);
    do @(posedge clk);while(!hbm_ready);
    @(negedge clk);hbm_valid=0;
  endtask
  task automatic flush;
    @(negedge clk);clear=1;hbm_valid=0;b_ready=0;
    @(negedge clk);clear=0;
    repeat(2) @(negedge clk);
    if(count || b_valid) $fatal(1,"W clear retained stale tile");
  endtask
  always @(negedge clk) if(phase==1) begin
    cycle++;
    random_q={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
    b_ready=cycle>230 && random_q[0];
  end
  always @(posedge clk) if(rst_n && !clear && phase==1) begin
    if(hbm_valid && !hbm_ready) backpressure++;
    if(b_valid && b_ready) begin
      for(int k=0;k<TILE;k++) if(b_entry.data[k*WEIGHT_BITS+:WEIGHT_BITS]!==
        WEIGHT_BITS'((received/TILE)*31+k*7+(received%TILE)*13)) $fatal(1,"HBM transpose mismatch");
      if(b_entry.scale!==SCALE_BITS'((received/TILE)*11+received%TILE)) $fatal(1,"HBM scale pairing mismatch");
      received++;
    end
  end
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    // Cancel a half-received tile, then a partially drained tile/full FIFO.
    for(int i=0;i<4;i++) send_beat(99,i);
    flush();
    for(int i=0;i<HBM_BEATS_PER_TILE;i++) send_beat(88,i);
    repeat(5) @(negedge clk);flush();
    phase=1;
    for(int t=0;t<12;t++) begin
      for(int i=0;i<HBM_BEATS_PER_TILE;i++) begin
        if(t==3 && i==WEIGHT_HBM_BEATS_PER_TILE) repeat(23) @(negedge clk);
        send_beat(t,i);produced++;
      end
    end
    wait(received==12*TILE);@(negedge clk);phase=2;b_ready=0;
    if(count || backpressure==0 || produced!=12*HBM_BEATS_PER_TILE) $fatal(1,"W stream coverage missing");
    $display("tb_dea8_w_b_stream PASS: one-tile row-to-column,64x136 FIFO, delayed scale, clear and backpressure");
    $finish;
  end
  initial begin #100000;$fatal(1,"W B stream timeout");end
endmodule
