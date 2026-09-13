import dea8_pcore_pkg::*;

// Only SBUF/PBUF live here. FACC/OACC have ONE owner in accumulator_fabric.
// Producer and consumer use independently addressed, separately reserved banks.
module dea8_attention_buffers (
  input logic clk, rst_n,
  input logic sbuf_wr_en, sbuf_wr_bank,
  input logic [ROW_BITS-1:0] sbuf_wr_row,
  input logic [DW_VEC-1:0] sbuf_wr_data,
  input logic sbuf_rd_en, sbuf_rd_bank,
  input logic [ROW_BITS-1:0] sbuf_rd_row,
  output logic sbuf_rsp_valid,
  output logic [DW_VEC-1:0] sbuf_rd_data,
  input logic pbuf_wr_en, pbuf_wr_bank,
  input logic [ROW_BITS-1:0] pbuf_wr_row,
  input logic [DW_ACT-1:0] pbuf_wr_data,
  input logic [SCALE_BITS-1:0] pbuf_wr_scale,
  input logic pbuf_rd_en, pbuf_rd_bank,
  input logic [ROW_BITS-1:0] pbuf_rd_row,
  output logic pbuf_rsp_valid,
  output logic [DW_ACT-1:0] pbuf_rd_data,
  output logic [SCALE_BITS-1:0] pbuf_rd_scale
);
  logic [DW_VEC-1:0] sbuf [0:BANK_COUNT-1][0:SUFFIX_LEN-1];
  logic [DW_ACT-1:0] pbuf [0:BANK_COUNT-1][0:SUFFIX_LEN-1];
  logic [SCALE_BITS-1:0] e_p [0:BANK_COUNT-1][0:SUFFIX_LEN-1];
  always_ff @(posedge clk) if (rst_n) begin
    if (sbuf_wr_en) sbuf[sbuf_wr_bank][sbuf_wr_row] <= sbuf_wr_data;
    if (sbuf_rd_en) sbuf_rd_data <= sbuf[sbuf_rd_bank][sbuf_rd_row];
    if (pbuf_wr_en) begin
      pbuf[pbuf_wr_bank][pbuf_wr_row] <= pbuf_wr_data;
      e_p[pbuf_wr_bank][pbuf_wr_row] <= pbuf_wr_scale;
    end
    if (pbuf_rd_en) begin
      pbuf_rd_data <= pbuf[pbuf_rd_bank][pbuf_rd_row];
      pbuf_rd_scale <= e_p[pbuf_rd_bank][pbuf_rd_row];
    end
  end
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin sbuf_rsp_valid <= 0; pbuf_rsp_valid <= 0; end
    else begin sbuf_rsp_valid <= sbuf_rd_en; pbuf_rsp_valid <= pbuf_rd_en; end
  // synthesis translate_off
  always @(posedge clk) if (rst_n) begin
    if (sbuf_rd_en && sbuf_wr_en && sbuf_rd_bank == sbuf_wr_bank)
      $fatal(1, "SBUF bank has simultaneous producer and consumer");
    if (pbuf_rd_en && pbuf_wr_en && pbuf_rd_bank == pbuf_wr_bank)
      $fatal(1, "PBUF bank has simultaneous producer and consumer");
    if ((sbuf_rd_en && sbuf_rd_row >= SUFFIX_LEN) ||
        (sbuf_wr_en && sbuf_wr_row >= SUFFIX_LEN) ||
        (pbuf_rd_en && pbuf_rd_row >= SUFFIX_LEN) ||
        (pbuf_wr_en && pbuf_wr_row >= SUFFIX_LEN))
      $fatal(1, "Attention buffer row out of range");
  end
  // synthesis translate_on
endmodule
