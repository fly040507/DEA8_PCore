// Combinational arithmetic candidates. Registers and backpressure live in TOP.
module dea8_vpu_oacc_scale(
 input dea8_vpu_math_pkg::pair_fp_t oacc,
 input dea8_vpu_math_pkg::scalars_t alpha,
 input logic [1:0] row_valid,
 output dea8_vpu_math_pkg::pair_fp_t scaled,
 output logic [1:0] error
);
 import dea8_vpu_math_pkg::*;
 always_comb begin
  scaled=0;error=0;
  for(int r=0;r<2;r++)if(row_valid[r])for(int j=0;j<16;j++)begin
   scaled[r][j]=mul_fp(oacc[r][j],alpha[r]);
   error[r]|=nonfinite(oacc[r][j])||nonfinite(alpha[r])||nonfinite(scaled[r][j]);
  end
 end
endmodule

module dea8_vpu_afin(
 input dea8_vpu_math_pkg::pair_fp_t oacc,
 input dea8_vpu_math_pkg::scalars_t recip_l,
 input logic [1:0] row_valid,
 output dea8_vpu_math_pkg::pair_fp_t normalized,
 output dea8_vpu_math_pkg::pair_int8_t quant,
 output logic [1:0][7:0] scale,
 output logic [1:0] error
);
 logic [1:0] mul_error,quant_error;
 dea8_vpu_oacc_scale mul(.oacc,.alpha(recip_l),.row_valid,.scaled(normalized),.error(mul_error));
 for(genvar r=0;r<2;r++)begin
  dea8_vpu_quant16 q(.x(normalized[r]),.lane_valid({16{row_valid[r]}}),.q(quant[r]),.scale(scale[r]),.error(quant_error[r]));
 end
 assign error=mul_error|quant_error;
endmodule

module dea8_vpu_p_post(
 input dea8_vpu_math_pkg::pair_fp_t probability,
 input dea8_vpu_math_pkg::scalars_t alpha,l_old,
 input logic [1:0] row_valid,
 output dea8_vpu_math_pkg::scalars_t l_new,rowsum,
 output dea8_vpu_math_pkg::pair_int8_t quant,
 output logic [1:0][7:0] scale,
 output logic [1:0] error
);
 import dea8_vpu_math_pkg::*;
 logic [1:0] qe;scalars_t product;
 for(genvar r=0;r<2;r++)begin
  dea8_vpu_quant16 q(.x(probability[r]),.lane_valid({16{row_valid[r]}}),.q(quant[r]),.scale(scale[r]),.error(qe[r]));
 end
 always_comb begin
  l_new=0;rowsum=0;product=0;error=qe;
  for(int r=0;r<2;r++)if(row_valid[r])begin
   rowsum[r]=sum16(probability[r]);
   product[r]=mul_fp(alpha[r],l_old[r]);
   l_new[r]=dea8_fp32_v3_pkg::fp32_add(product[r],rowsum[r]);
   error[r]|=nonfinite(alpha[r])||nonfinite(l_old[r])||nonfinite(l_new[r]);
   for(int j=0;j<16;j++)error[r]|=(probability[r][j][31]&&(|probability[r][j][30:0]));
  end
 end
endmodule

module dea8_vpu_rope_pair(
 input dea8_vpu_math_pkg::pair_fp_t x_lo,x_hi,
 input logic [1:0][15:0][15:0] sin_bf16,cos_bf16,
 input logic [1:0] row_valid,
 output dea8_vpu_math_pkg::pair_fp_t y_lo,y_hi,
 output dea8_vpu_math_pkg::pair_int8_t q_lo,q_hi,
 output logic [1:0][7:0] scale_lo,scale_hi,
 output logic [1:0] error
);
 import dea8_vpu_math_pkg::*;
 logic [1:0] el,eh,arithmetic_error;logic [31:0] ac,bs,as_,bc,s,c;
 for(genvar r=0;r<2;r++)begin
  dea8_vpu_quant16 ql(.x(y_lo[r]),.lane_valid({16{row_valid[r]}}),.q(q_lo[r]),.scale(scale_lo[r]),.error(el[r]));
  dea8_vpu_quant16 qh(.x(y_hi[r]),.lane_valid({16{row_valid[r]}}),.q(q_hi[r]),.scale(scale_hi[r]),.error(eh[r]));
 end
 always_comb begin
  y_lo=0;y_hi=0;arithmetic_error=0;ac=0;bs=0;as_=0;bc=0;s=0;c=0;
  for(int r=0;r<2;r++)if(row_valid[r])for(int j=0;j<16;j++)begin
   s={sin_bf16[r][j],16'b0};c={cos_bf16[r][j],16'b0};
   ac=mul_fp(x_lo[r][j],c);bs=mul_fp(x_hi[r][j],s);
   as_=mul_fp(x_lo[r][j],s);bc=mul_fp(x_hi[r][j],c);
   y_lo[r][j]=dea8_fp32_v3_pkg::fp32_add(ac,{~bs[31],bs[30:0]});
   y_hi[r][j]=dea8_fp32_v3_pkg::fp32_add(as_,bc);
   arithmetic_error[r]|=nonfinite(x_lo[r][j])||nonfinite(x_hi[r][j])||nonfinite(s)||nonfinite(c);
  end
 end
assign error=arithmetic_error|el|eh;
endmodule
