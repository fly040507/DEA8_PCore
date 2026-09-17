import dea8_pcore_pkg::*;

// HBM adapter only. Both W and KV streams use the same 136-bit B contract.
module dea8_w_b_stream #(
  parameter int FIFO_DEPTH=W_B_FIFO_DEPTH
) (
  input logic clk,rst_n,clear,
  input logic hbm_valid,
  output logic hbm_ready,
  input logic [HBM_BITS-1:0] hbm_data,
  output logic b_valid,
  input logic b_ready,
  output b_entry_t b_entry,
  output logic [$clog2(FIFO_DEPTH+1)-1:0] count
);
  logic assembled_valid,assembled_ready;
  b_entry_t assembled_entry;
  dea8_w_tile_assembler assembler (
    .out_valid(assembled_valid),.out_ready(assembled_ready),.out_entry(assembled_entry),.*
  );
  dea8_b_fifo #(.DEPTH(FIFO_DEPTH)) wfifo (
    .in_valid(assembled_valid),.in_ready(assembled_ready),.in_entry(assembled_entry),
    .out_valid(b_valid),.out_ready(b_ready),.out_entry(b_entry),.*
  );
endmodule
