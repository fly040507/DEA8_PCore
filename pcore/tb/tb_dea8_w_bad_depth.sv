`timescale 1ns/1ps
import dea8_pcore_pkg::*;
module tb_dea8_w_bad_depth;
  logic clk=0;always #5 clk=~clk;
  dea8_w_b_stream #(.FIFO_DEPTH(TILE/2)) dut (
    .clk,.rst_n(1'b0),.clear(1'b0),.hbm_valid(1'b0),.hbm_ready(),.hbm_data('0),
    .b_valid(),.b_ready(1'b0),.b_entry(),.count()
  );
  initial begin #100;$fatal(1,"Bad W depth was not rejected");end
endmodule
