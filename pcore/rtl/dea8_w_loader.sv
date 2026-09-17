import dea8_pcore_pkg::*;

// HBM wrapper: one tile assembler + one paired B FIFO + column bank owner.
// bank_activate is a pre-edge event: the MXU captures the new active scales
// at the same edge that changes active_bank.
module dea8_w_loader (
  input logic clk, rst_n, clear,
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
  b_entry_t entry;
  logic data_valid,data_pop;
  logic [$clog2(W_B_FIFO_DEPTH+1)-1:0] count;
  dea8_w_b_stream stream (
    .b_valid(data_valid),.b_ready(data_pop),.b_entry(entry),.*
  );
  dea8_stationary_loader stationary (
    .tile_available(count >= TILE), .*
  );
endmodule
