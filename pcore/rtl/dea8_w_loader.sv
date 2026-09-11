import dea8_pcore_pkg::*;

// W_Loader owns HBM fetch, split FIFOs and all bank-state registers.
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
  bank_state_e bank_state [0:BANK_COUNT-1];
  logic loading_q, load_bank_q, start_load, free_bank;
  logic [TILE_IDX_BITS-1:0] load_index_q;

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
    .out_data(load_scale_word), .count(scale_count)
  );

  assign bank_state_a = bank_state[0];
  assign bank_state_b = bank_state[1];
  assign active_valid = (bank_state[active_bank] == BANK_ACTIVE);
  assign free_bank = (bank_state[0] == BANK_NULL) ? 1'b0 : 1'b1;
  assign start_load = rst_n && bank_load_enable && !loading_q &&
                      ((bank_state[0] == BANK_NULL) || (bank_state[1] == BANK_NULL)) &&
                      (data_count >= TILE) && (scale_count != 0);
  assign load_bank = loading_q ? load_bank_q : free_bank;
  assign load_weight_idx = loading_q ? load_index_q : '0;
  assign load_valid = rst_n && (loading_q || start_load) && data_valid;
  assign data_pop = load_valid;
  assign scale_pop = start_load && load_valid;
  assign scale_load_valid = scale_pop;
  assign load_weight_beat = data_word;
  assign load_tile_complete = load_valid && (load_weight_idx == TILE-1);

  always_comb begin
    bank_activate = 1'b0;
    new_active_bank = active_bank;
    // Completing a first tile or replacing a retiring active tile.
    if (load_tile_complete && (!active_valid || tile_last_mul_fire)) begin
      bank_activate = 1'b1;
      new_active_bank = load_bank;
    end else if (!active_valid || tile_last_mul_fire) begin
      if (bank_state[0] == BANK_READY) begin
        bank_activate = 1'b1;
        new_active_bank = 1'b0;
      end else if (bank_state[1] == BANK_READY) begin
        bank_activate = 1'b1;
        new_active_bank = 1'b1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      loading_q <= 1'b0;
      load_bank_q <= 1'b0;
      load_index_q <= '0;
      active_bank <= 1'b0;
      for (int b=0; b<BANK_COUNT; b++) bank_state[b] <= BANK_NULL;
    end else begin
      if (start_load) begin
        load_bank_q <= free_bank;
        loading_q <= 1'b1;
        load_index_q <= 1;
        bank_state[free_bank] <= BANK_LOAD;
      end else if (load_valid) begin
        load_index_q <= load_index_q + 1'b1;
      end
      if (load_tile_complete) begin
        loading_q <= 1'b0;
        load_index_q <= '0;
        bank_state[load_bank] <= BANK_READY;
      end
      if (tile_last_mul_fire) bank_state[active_bank] <= BANK_NULL;
      if (bank_activate) begin
        bank_state[new_active_bank] <= BANK_ACTIVE;
        active_bank <= new_active_bank;
      end
    end
  end

  always @(posedge clk) if (rst_n) begin
    if (loading_q && !data_valid) $fatal(1, "Reserved tile data underflow");
    if (load_valid && bank_state[load_bank] == BANK_ACTIVE)
      $fatal(1, "Loader wrote ACTIVE bank");
    if (tile_last_mul_fire && !active_valid) $fatal(1, "Retire without ACTIVE bank");
    if ((bank_state[0] == BANK_ACTIVE) && (bank_state[1] == BANK_ACTIVE))
      $fatal(1, "Multiple ACTIVE banks");
    if ((bank_state[0] == BANK_LOAD) && (bank_state[1] == BANK_LOAD))
      $fatal(1, "Multiple LOAD banks");
  end
endmodule

