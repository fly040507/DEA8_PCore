// Native FP32 MUL: Full_Usage (two DSPs), no behavioral fallback.
module dea8_gcore_fp_mul(
  input logic clk,reset,clear,advance,input logic [31:0] a,b,
  output logic [31:0] result
);
  logic output_valid;
  dea8_fpmul_ip arithmetic(.aclk(clk),.aclken(advance),.aresetn(!(reset||clear)),
    .s_axis_a_tvalid(advance&&!reset&&!clear),.s_axis_a_tdata(a),
    .s_axis_b_tvalid(advance&&!reset&&!clear),.s_axis_b_tdata(b),
    .m_axis_result_tvalid(output_valid),.m_axis_result_tdata(result));
endmodule
