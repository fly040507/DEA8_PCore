import dea8_pcore_pkg::*;

// Shared column write datapath. Bank/column ownership stays in its controller;
// no extra buffering, independent scale handshake, or transpose at this point.
module dea8_b_column_loader (
  input b_entry_t entry,
  input logic load_valid,
  input logic [TILE_IDX_BITS-1:0] load_weight_idx,
  output logic signed [TILE-1:0][WEIGHT_BITS-1:0] load_weight_beat,
  output logic scale_load_valid,load_tile_complete,
  output logic [SCALE_WORD_BITS-1:0] load_scale_word
);
  assign load_weight_beat=entry.data;
  assign scale_load_valid=load_valid;
  assign load_scale_word={{(SCALE_WORD_BITS-SCALE_BITS){1'b0}},entry.scale};
  assign load_tile_complete=load_valid && load_weight_idx==TILE-1;
endmodule
