import dea8_pcore_pkg::*;

// Synchronous 1R1W bank. No reset of RAM contents; initialization is explicit.
module dea8_acc_bank #(
  parameter int WORDS = FACC_WORDS,
  parameter int ADDR_BITS = ACC_ADDR_BITS
) (
  input logic clk,
  input logic rd_en,
  input logic [ADDR_BITS-1:0] rd_addr,
  output logic [DW_VEC-1:0] rd_data,
  input logic wr_en,
  input logic [ADDR_BITS-1:0] wr_addr,
  input logic [TILE-1:0] wr_lane_en,
  input logic [DW_VEC-1:0] wr_data
);
  for (genvar n=0; n<TILE; n++) begin : g_lane
    logic [FP_BITS-1:0] mem [0:WORDS-1];
    always_ff @(posedge clk) begin
      if (wr_en && wr_lane_en[n]) mem[wr_addr] <= wr_data[n*FP_BITS+:FP_BITS];
      if (rd_en) rd_data[n*FP_BITS+:FP_BITS] <= mem[rd_addr];
    end
  end
  // synthesis translate_off
  always @(posedge clk) begin
    if ((rd_en && rd_addr >= WORDS) || (wr_en && wr_addr >= WORDS))
      $fatal(1, "Accumulator bank address out of range");
    if (rd_en && wr_en && rd_addr == wr_addr)
      $fatal(1, "Accumulator same-address read/write is not permitted");
  end
  // synthesis translate_on
endmodule
