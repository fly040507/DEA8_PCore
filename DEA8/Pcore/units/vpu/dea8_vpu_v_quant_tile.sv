// Explicit transpose: input[token][feature] -> output[feature][token].
// Each fixed feature's 16 sequence positions share one scale.
// Tail suffix tile uses token_valid=16'h0007 (3 real tokens), not all 16.
module dea8_vpu_v_quant_tile(
 input logic [15:0][15:0][31:0] token_feature,
 input logic [15:0] token_valid,
 output logic [15:0][15:0][7:0] feature_token_q,
 output logic [15:0][7:0] feature_scale,
 output logic [15:0] error
);
 for(genvar f=0;f<16;f++)begin
  logic [15:0][31:0] column;
  for(genvar t=0;t<16;t++)assign column[t]=token_feature[t][f];
  dea8_vpu_quant16 q(.x(column),.lane_valid(token_valid),.q(feature_token_q[f]),.scale(feature_scale[f]),.error(error[f]));
 end
endmodule
