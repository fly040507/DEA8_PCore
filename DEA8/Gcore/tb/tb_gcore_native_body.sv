`timescale 1ns/1ps
module tb_gcore_native_body;
  tb_gcore_body #(.NATIVE_RSQRT(1'b1)) test();
  final $display("tb_gcore_native_body FINISHED; require nested tb_gcore_body PASS");
endmodule
