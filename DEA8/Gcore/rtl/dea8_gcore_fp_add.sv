// Four CE-qualified stages; preserve gradual underflow and existing RNE.
// DSP0 adds aligned significands; DSP1 performs the rounding increment.
module dea8_gcore_fp_add (
  input logic clk,advance,
  input logic [31:0] a,b,
  output logic [31:0] result
);
  import dea8_fp32_pkg::*;
  fp_add_pre_t pre_q,raw_meta_q;
  fp_add_raw_t raw;
  fp_norm_mid_t norm_q,pack_meta_q;
  logic [47:0] sum,rounded;
  logic [24:0] final_mantissa;
  logic [8:0] final_exponent;
  logic [7:0] exponent_field;
  logic round_up;
  dea8_gcore_dsp_alu significand_add (
    .clk,.advance,.subtract(pre_q.subtract),
    .a({20'b0,pre_q.big_x}),.b({20'b0,pre_q.small_x}),.result(sum)
  );
  assign round_up=norm_q.sum_norm[2]&&
    (norm_q.sum_norm[1]||norm_q.sum_norm[0]||norm_q.sum_norm[3]);
  dea8_gcore_dsp_alu rounding_add (
    .clk,.advance,.subtract(1'b0),
    .a({24'b0,norm_q.sum_norm[26:3]}),.b({47'b0,round_up}),.result(rounded)
  );
  always_comb begin
    raw='0;raw.special=raw_meta_q.special;raw.special_value=raw_meta_q.special_value;
    raw.sign_result=raw_meta_q.sign_result;raw.zero_sign=raw_meta_q.zero_sign;
    raw.exponent=raw_meta_q.exponent;raw.sum_raw=sum[27:0];
    final_mantissa=rounded[24]?rounded[25:1]:rounded[24:0];
    final_exponent=pack_meta_q.exponent_norm+9'(rounded[24]);
    exponent_field=(final_exponent==1&&!final_mantissa[23])?8'b0:final_exponent[7:0];
    if(pack_meta_q.special) result=pack_meta_q.special_value;
    else if(pack_meta_q.is_zero) result={pack_meta_q.zero_sign,31'b0};
    else if(final_exponent>=255) result={pack_meta_q.sign_result,FP_INF[30:0]};
    else result={pack_meta_q.sign_result,exponent_field,final_mantissa[22:0]};
  end
  always_ff @(posedge clk) if(advance) begin
    pre_q<=fp32_prepare(a,b);
    raw_meta_q<=pre_q;
    norm_q<=fp32_normalize_mid(raw);
    pack_meta_q<=norm_q;
  end
endmodule
