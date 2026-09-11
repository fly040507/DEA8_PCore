import dea8_pcore_pkg::*;

// Generates the 16 lane visibility mask. NEG_INF substitution remains in VPU.
module dea8_attention_mask (
  input  query_kind_e                 query_kind,
  input  logic [ROW_BITS-1:0]         query_row,
  input  logic [BLOCK_BITS-1:0]       block_id,
  input  logic [PREFIX_CAP-1:0]      prefix_valid,
  output logic [TILE-1:0]             lane_mask
);
  integer j;
  integer key_index;
  integer suffix_index;

  always_comb begin
    lane_mask = '0;
    for (j = 0; j < TILE; j = j + 1) begin
      key_index    = block_id * TILE + j;
      suffix_index = key_index - PREFIX_CAP;
      unique case (query_kind)
        QUERY_PREFIX: begin
          if (key_index < PREFIX_CAP) lane_mask[j] = prefix_valid[key_index];
        end
        QUERY_STATE: begin
          if (key_index < PREFIX_CAP) lane_mask[j] = prefix_valid[key_index];
          else lane_mask[j] = (suffix_index == 0);
        end
        QUERY_ACTION: begin
          if (key_index < PREFIX_CAP) lane_mask[j] = prefix_valid[key_index];
          else lane_mask[j] = (suffix_index >= 0) &&
                              (suffix_index < SUFFIX_LEN) &&
                              (suffix_index <= query_row);
        end
        default:      lane_mask[j] = 1'b0;
      endcase
    end
  end
endmodule
