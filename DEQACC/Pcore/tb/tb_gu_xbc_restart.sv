`timescale 1ns/1ps
import pcore_pkg::*;
module tb_gu_xbc_restart;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,restart=0,in_valid=0,in_ready,out_valid,out_ready=0,protocol_error;
  xbc4_t in_entry='0;a2_t out_entry;
  dea8_gu_xbc_frontend dut(.*);
  initial begin
    repeat(4)@(negedge clk);reset=0;
    in_entry.row_valid=4'b1111;
    for(int r=0;r<4;r++)begin in_entry.row[r].data=128'(r+1);in_entry.row[r].scale=8'(128+r);end
    restart=1;in_valid=1;#1;if(in_ready)$fatal(1,"restart accepted beat");
    @(negedge clk);restart=0;#1;if(!in_ready)$fatal(1,"restart blocked recovery");
    @(negedge clk);in_valid=0;
    for(int p=0;p<2;p++)begin
      wait(out_valid);
      repeat(3)begin @(negedge clk);if(out_entry.pair_idx!=p||out_entry.row_valid!=3||out_entry.row[0]!==in_entry.row[2*p]||out_entry.row[1]!==in_entry.row[2*p+1])$fatal(1,"restart first beat lost or payload changed");end
      out_ready=1;@(negedge clk);out_ready=0;
    end
    if(out_valid||protocol_error)$fatal(1,"restart duplicate pair/error");
    $display("tb_gu_xbc_restart PASS restart_handshake_blocked=1 retained_first_beat=1 pairs=2 backpressure=1");$finish;
  end
  initial begin #1000;$fatal(1,"restart watchdog");end
endmodule
