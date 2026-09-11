import dea8_pcore_pkg::*;

// Two generations of alpha, indexed by block parity. EXP writes alpha for the
// next block while VPU reads the previously completed generation for SCALE.
module dea8_alpha_bank (
  input logic clk,
  input logic wr_en,
  input logic [BLOCK_BITS-1:0] wr_block,
  input logic [ROW_BITS-1:0] wr_row,
  input logic [FP_BITS-1:0] wr_alpha,
  input logic [BLOCK_BITS-1:0] rd_block,
  input logic [ROW_BITS-1:0] rd_row,
  output logic [FP_BITS-1:0] rd_alpha
);
  logic [FP_BITS-1:0] alpha [0:1][0:SUFFIX_LEN-1];

  always_ff @(posedge clk) begin
    if (wr_en) alpha[wr_block[0]][wr_row] <= wr_alpha;
    rd_alpha <= alpha[rd_block[0]][rd_row];
  end

  ap_row_range: assert property (@(posedge clk)
    wr_en |-> wr_row < SUFFIX_LEN);

endmodule
