import dea8_pcore_pkg::*;

// HBM compatibility wrapper: transport FIFOs feed the shared stationary owner.
// bank_activate is a pre-edge event: the MXU captures the new active scales
// at the same edge that changes active_bank.
module dea8_w_loader (
  input logic clk, rst_n,
  input logic hbm_valid,
  output logic hbm_ready,
  input logic [HBM_BITS-1:0] hbm_data,
  input logic bank_load_enable,
  input logic tile_last_mul_fire,
  output logic active_bank, active_valid,
  output logic load_bank, load_valid,
  output logic [TILE_IDX_BITS-1:0] load_weight_idx,
  output logic signed [TILE-1:0][WEIGHT_BITS-1:0] load_weight_beat,
  output logic scale_load_valid,
  output logic [SCALE_WORD_BITS-1:0] load_scale_word,
  output logic load_tile_complete,
  output logic bank_activate, new_active_bank,
  output bank_state_e bank_state_a, bank_state_b
);
  logic [1:0] unpack_valid, unpack_ready;
  logic [1:0][WEIGHT_WORD_BITS-1:0] unpack_data;
  logic unpack_scale_valid, unpack_scale_ready;
  logic [SCALE_WORD_BITS-1:0] unpack_scale;
  logic data_valid, data_pop, scale_valid, scale_pop;
  logic [WEIGHT_WORD_BITS-1:0] data_word;
  logic [$clog2(WFIFO_DATA_DEPTH+1)-1:0] data_count;
  logic [$clog2(WFIFO_SCALE_DEPTH+1)-1:0] scale_count;
  logic [SCALE_WORD_BITS-1:0] scale_word;

  dea8_hbm_tile_unpack u_fetch (
    .clk(clk), .rst_n(rst_n), .hbm_valid(hbm_valid),
    .hbm_ready(hbm_ready), .hbm_data(hbm_data),
    .data_wr_valid(unpack_valid), .data_wr_ready(unpack_ready),
    .data_wr_data(unpack_data), .scale_wr_valid(unpack_scale_valid),
    .scale_wr_ready(unpack_scale_ready), .scale_wr_data(unpack_scale),
    .tile_complete()
  );
  dea8_dualwrite_fifo u_data_fifo (
    .clk(clk), .rst_n(rst_n), .in_valid(unpack_valid),
    .in_ready(unpack_ready), .in_data(unpack_data),
    .out_valid(data_valid), .out_ready(data_pop),
    .out_data(data_word), .count(data_count)
  );
  dea8_stream_fifo u_scale_fifo (
    .clk(clk), .rst_n(rst_n), .in_valid(unpack_scale_valid),
    .in_ready(unpack_scale_ready), .in_data(unpack_scale),
    .out_valid(scale_valid), .out_ready(scale_pop),
    .out_data(scale_word), .count(scale_count)
  );

  dea8_stationary_loader stationary (
    .tile_available(data_count >= TILE && scale_count != 0), .*
  );
endmodule
