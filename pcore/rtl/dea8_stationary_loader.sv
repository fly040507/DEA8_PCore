import dea8_pcore_pkg::*;

// Single owner of stationary banks, independent of HBM/KVB transport.
// tile_available reserves 16 consecutive data words and one complete scale
// vector. After the first pop the source MUST supply all remaining words.
module dea8_stationary_loader (
  input logic clk, rst_n,
  input logic tile_available, data_valid,
  input logic [WEIGHT_WORD_BITS-1:0] data_word,
  input logic [SCALE_WORD_BITS-1:0] scale_word,
  output logic data_pop, scale_pop,
  input logic bank_load_enable, tile_last_mul_fire,
  output logic active_bank, active_valid,
  output logic load_bank, load_valid,
  output logic [TILE_IDX_BITS-1:0] load_weight_idx,
  output logic signed [TILE-1:0][WEIGHT_BITS-1:0] load_weight_beat,
  output logic scale_load_valid,
  output logic [SCALE_WORD_BITS-1:0] load_scale_word,
  output logic load_tile_complete, bank_activate, new_active_bank,
  output bank_state_e bank_state_a, bank_state_b
);
  bank_state_e bank_state [0:BANK_COUNT-1];
  logic loading_q, load_bank_q, start_load, free_bank;
  logic [TILE_IDX_BITS-1:0] load_index_q;
  assign bank_state_a = bank_state[0];
  assign bank_state_b = bank_state[1];
  assign active_valid = bank_state[active_bank] == BANK_ACTIVE;
  assign free_bank = bank_state[0] == BANK_NULL ? 1'b0 : 1'b1;
  assign start_load = rst_n && bank_load_enable && !loading_q &&
                     (bank_state[0] == BANK_NULL || bank_state[1] == BANK_NULL) && tile_available;
  assign load_bank = loading_q ? load_bank_q : free_bank;
  assign load_weight_idx = loading_q ? load_index_q : '0;
  assign load_valid = rst_n && (loading_q || start_load) && data_valid;
  assign data_pop = load_valid;
  assign scale_pop = start_load && load_valid;
  assign scale_load_valid = scale_pop;
  assign load_weight_beat = data_word;
  assign load_scale_word = scale_word;
  assign load_tile_complete = load_valid && load_weight_idx == TILE-1;

  always_comb begin
    bank_activate = 0;
    new_active_bank = active_bank;
    if (load_tile_complete && (!active_valid || tile_last_mul_fire)) begin
      bank_activate = 1;
      new_active_bank = load_bank;
    end else if (!active_valid || tile_last_mul_fire) begin
      if (bank_state[0] == BANK_READY) begin bank_activate = 1; new_active_bank = 0; end
      else if (bank_state[1] == BANK_READY) begin bank_activate = 1; new_active_bank = 1; end
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      loading_q <= 0; load_bank_q <= 0; load_index_q <= '0; active_bank <= 0;
      for (int b=0; b<BANK_COUNT; b++) bank_state[b] <= BANK_NULL;
    end else begin
      if (start_load && data_valid) begin
        load_bank_q <= free_bank;
        loading_q <= 1;
        load_index_q <= TILE_IDX_BITS'(1);
        bank_state[free_bank] <= BANK_LOAD;
      end else if (load_valid) load_index_q <= load_index_q + 1'b1;
      if (load_tile_complete) begin
        loading_q <= 0; load_index_q <= '0;
        bank_state[load_bank] <= BANK_READY;
      end
      if (tile_last_mul_fire) bank_state[active_bank] <= BANK_NULL;
      if (bank_activate) begin
        bank_state[new_active_bank] <= BANK_ACTIVE;
        active_bank <= new_active_bank;
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk) if (rst_n) begin
    if ((loading_q || start_load) && !data_valid) $fatal(1, "Reserved tile data underflow");
    if (load_valid && bank_state[load_bank] == BANK_ACTIVE) $fatal(1, "Loader wrote ACTIVE bank");
    if (tile_last_mul_fire && !active_valid) $fatal(1, "Retire without ACTIVE bank");
    if (bank_state[0] == BANK_ACTIVE && bank_state[1] == BANK_ACTIVE) $fatal(1, "Multiple ACTIVE banks");
    if (bank_state[0] == BANK_LOAD && bank_state[1] == BANK_LOAD) $fatal(1, "Multiple LOAD banks");
  end
  initial if (BANK_COUNT != 2 || TILE < 2) $fatal(1, "Unsupported stationary bank geometry");
  // synthesis translate_on
endmodule
