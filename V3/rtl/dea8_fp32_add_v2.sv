import dea8_fp32_v3_pkg::*;
// Registered single-lane OOC probe. SPLIT isolates the proposed D2/D3 boundary.
module dea8_fp32_add_v2 #(parameter bit SPLIT=0)(
  input logic clk,input logic [31:0] a,b,output logic [31:0] result
);
  logic [31:0] a_q,b_q;
  fp_add_pre_t pre_q;
  always_ff @(posedge clk) begin
    a_q<=a;b_q<=b;
    if(SPLIT) begin pre_q<=fp32_prepare(a_q,b_q);result<=fp32_finish(pre_q);end
    else result<=fp32_add(a_q,b_q);
  end
endmodule
