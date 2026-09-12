import dea8_pcore_pkg::*;

// Three physical logical banks, each 1R1W. Port ownership is external.
// No bulk reset: clear-on-first-write initializes valid output elements.
module dea8_accumulator_storage (
  input logic clk,
  input logic rd_en,
  input acc_sel_e rd_sel,
  input logic [ACC_ADDR_BITS-1:0] rd_addr,
  output logic [DW_VEC-1:0] rd_data,
  input logic wr_en,
  input acc_sel_e wr_sel,
  input logic [ACC_ADDR_BITS-1:0] wr_addr,
  input logic [TILE-1:0] wr_lane_en,
  input logic [DW_VEC-1:0] wr_data
);
  for (genvar n = 0; n < TILE; n++) begin : g_lane_mem
    logic [FP_BITS-1:0] facc_a [0:FACC_WORDS-1];
    logic [FP_BITS-1:0] facc_b [0:FACC_WORDS-1];
    logic [FP_BITS-1:0] oacc [0:OACC_WORDS-1];
    always_ff @(posedge clk) begin
      if (wr_en && wr_lane_en[n]) begin
        case (wr_sel)
          ACC_FACC_A: facc_a[wr_addr] <= wr_data[n*FP_BITS+:FP_BITS];
          ACC_FACC_B: facc_b[wr_addr] <= wr_data[n*FP_BITS+:FP_BITS];
          ACC_OACC: oacc[wr_addr] <= wr_data[n*FP_BITS+:FP_BITS];
          default: ;
        endcase
      end
      if (rd_en) begin
        case (rd_sel)
          ACC_FACC_A: rd_data[n*FP_BITS+:FP_BITS] <= facc_a[rd_addr];
          ACC_FACC_B: rd_data[n*FP_BITS+:FP_BITS] <= facc_b[rd_addr];
          ACC_OACC: rd_data[n*FP_BITS+:FP_BITS] <= oacc[rd_addr];
          default: rd_data[n*FP_BITS+:FP_BITS] <= '0;
        endcase
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk) begin
    if (rd_en && wr_en && rd_sel == wr_sel && rd_addr == wr_addr)
      $fatal(1, "Accumulator same-address read/write is not permitted");
    if ((rd_en && rd_sel == ACC_SBUF) || (wr_en && wr_sel == ACC_SBUF))
      $fatal(1, "SBUF is not an accumulator");
    if (rd_en && rd_addr >= (rd_sel == ACC_OACC ? OACC_WORDS : FACC_WORDS))
      $fatal(1, "Accumulator read address out of range");
    if (wr_en && wr_addr >= (wr_sel == ACC_OACC ? OACC_WORDS : FACC_WORDS))
      $fatal(1, "Accumulator write address out of range");
  end
  // synthesis translate_on
endmodule
