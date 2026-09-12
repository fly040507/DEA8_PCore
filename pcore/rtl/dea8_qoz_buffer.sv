import dea8_pcore_pkg::*;

// Paired data/scale address, separate physical arrays, one-cycle synchronous read.
module dea8_qoz_buffer (
  input logic clk,
  input logic wr_en,
  input logic [QOZ_ADDR_BITS-1:0] wr_addr,
  input logic [DW_ACT-1:0] wr_data,
  input logic [SCALE_BITS-1:0] wr_scale,
  input logic rd_en,
  input logic [QOZ_ADDR_BITS-1:0] rd_addr,
  output logic [DW_ACT-1:0] rd_data,
  output logic [SCALE_BITS-1:0] rd_scale
);
  logic [DW_ACT-1:0] QOZ_BUF [0:QOZ_WORDS-1];
  logic [SCALE_BITS-1:0] E_QOZ [0:QOZ_WORDS-1];
  always_ff @(posedge clk) begin
    if (wr_en) begin
      QOZ_BUF[wr_addr] <= wr_data;
      E_QOZ[wr_addr] <= wr_scale;
    end
    if (rd_en) begin
      rd_data <= QOZ_BUF[rd_addr];
      rd_scale <= E_QOZ[rd_addr];
    end
  end
  // synthesis translate_off
  always @(posedge clk) begin
    if ((wr_en && wr_addr >= QOZ_WORDS) || (rd_en && rd_addr >= QOZ_WORDS))
      $fatal(1, "QOZ address out of range");
    if (wr_en && rd_en && wr_addr == rd_addr) $fatal(1, "QOZ read/write collision");
  end
  initial if (QOZ_WORDS != SUFFIX_LEN*QOZ_TILES) $fatal(1, "QOZ shape mismatch");
  // synthesis translate_on
endmodule
