import dea8_pcore_pkg::*;

// Physical attention memories. Arithmetic engines access these through the
// ports below; address generation belongs to the attention controller/VPU.
module dea8_attention_storage (
  input logic clk,
  input logic sbuf_we, input logic sbuf_bank,
  input logic [ROW_BITS-1:0] sbuf_addr, input logic [DW_VEC-1:0] sbuf_wdata,
  output logic [DW_VEC-1:0] sbuf_rdata_a, sbuf_rdata_b,
  input logic pbuf_we, input logic pbuf_bank,
  input logic [ROW_BITS-1:0] pbuf_addr, input logic [DW_ACT-1:0] pbuf_wdata,
  input logic [SCALE_BITS-1:0] ep_wdata,
  output logic [DW_ACT-1:0] pbuf_rdata_a, pbuf_rdata_b,
  output logic [SCALE_BITS-1:0] ep_rdata_a, ep_rdata_b,
  input logic facc_we, input logic facc_bank,
  input logic [ROW_BITS-1:0] facc_addr, input logic [DW_VEC-1:0] facc_wdata,
  output logic [DW_VEC-1:0] facc_rdata_a, facc_rdata_b,
  input logic oacc_rd_en,
  input logic [ACC_ADDR_BITS-1:0] oacc_rd_addr,
  output logic [DW_VEC-1:0] oacc_rdata,
  input logic oacc_wr_en,
  input logic [ACC_ADDR_BITS-1:0] oacc_wr_addr,
  input logic [DW_VEC-1:0] oacc_wdata
);
  logic [DW_VEC-1:0] sbuf [0:1][0:SUFFIX_LEN-1];
  logic [DW_ACT-1:0] pbuf [0:1][0:SUFFIX_LEN-1];
  logic [SCALE_BITS-1:0] ep [0:1][0:SUFFIX_LEN-1];
  logic [DW_VEC-1:0] facc [0:1][0:SUFFIX_LEN-1];
  logic [DW_VEC-1:0] oacc [0:OACC_WORDS-1];
  always_ff @(posedge clk) begin
    if (sbuf_we) sbuf[sbuf_bank][sbuf_addr] <= sbuf_wdata;
    if (pbuf_we) begin pbuf[pbuf_bank][pbuf_addr] <= pbuf_wdata; ep[pbuf_bank][pbuf_addr] <= ep_wdata; end
    if (facc_we) facc[facc_bank][facc_addr] <= facc_wdata;
    if (oacc_wr_en) oacc[oacc_wr_addr] <= oacc_wdata;
    sbuf_rdata_a <= sbuf[0][sbuf_addr]; sbuf_rdata_b <= sbuf[1][sbuf_addr];
    pbuf_rdata_a <= pbuf[0][pbuf_addr]; pbuf_rdata_b <= pbuf[1][pbuf_addr];
    ep_rdata_a <= ep[0][pbuf_addr]; ep_rdata_b <= ep[1][pbuf_addr];
    facc_rdata_a <= facc[0][facc_addr]; facc_rdata_b <= facc[1][facc_addr];
    if (oacc_rd_en) oacc_rdata <= oacc[oacc_rd_addr];
  end
endmodule
