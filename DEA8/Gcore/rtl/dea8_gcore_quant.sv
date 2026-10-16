module dea8_gcore_quant (
  input logic clk,advance,
  input logic [15:0][31:0] values,
  output logic [136:0] result
);
  import gcore_fp_pkg::*;
  logic [3:0][30:0] quarters_q;
  logic [15:0][31:0] values_q,aligned_q;
  logic bad_q,bad_aligned;
  logic [7:0] scale_q;
  logic [3:0][3:0][30:0] quarters;
  logic input_bad;
  always_comb begin
    input_bad=0;
    for(int q=0;q<4;q++) for(int lane=0;lane<4;lane++) begin
      quarters[q][lane]=values[4*q+lane][30:0];
      if(!finite32(values[4*q+lane])) input_bad=1;
    end
  end
  always_ff @(posedge clk) if(advance) begin
    // Two MAX16 tree levels per stage; shifts/RNE are a separate third stage.
    values_q<=values; bad_q<=input_bad;
    for(int q=0;q<4;q++) quarters_q[q]<=max4(quarters[q]);
    aligned_q<=values_q; bad_aligned<=bad_q; scale_q<=quant_scale(max4(quarters_q));
    result[136]<=bad_aligned;
    result[135:128]<=bad_aligned?8'b0:scale_q;
    for(int lane=0;lane<16;lane++) result[8*lane+:8]<=
      bad_aligned?8'b0:quant_lane(aligned_q[lane],scale_q);
  end
endmodule
