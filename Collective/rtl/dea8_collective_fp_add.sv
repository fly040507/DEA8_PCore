// Reuses the existing integer-only FP32 arithmetic functions, not PCore state.
module dea8_collective_fp_add(
  input logic clk,advance,
  input logic [31:0] a,b,
  output logic [31:0] result
);
  import dea8_fp32_v3_pkg::*;
  fp_add_pre_t pre_q;
  fp_add_raw_t raw_q;
  fp_norm_mid_t norm_q;
  always_ff @(posedge clk)if(advance)begin
    pre_q<=fp32_prepare(a,b);
    raw_q<=fp32_add_raw(pre_q);
    norm_q<=fp32_normalize_mid(raw_q);
    result<=fp32_pack_mid(norm_q);
  end
endmodule
