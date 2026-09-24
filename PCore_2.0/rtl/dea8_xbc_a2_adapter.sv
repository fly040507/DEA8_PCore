import pcore2_pkg::*;
// Also validates RAM reader responses after the job-locked source selector.
module dea8_xbc_a2_adapter (
  input logic clk,reset,clear,enable,
  input job_t job,
  input logic in_valid,
  output logic in_ready,
  input a2_t in_entry,
  input logic [EPOCH_BITS-1:0] in_epoch,
  output logic out_valid,
  input logic out_ready,
  output a2_t out_entry,
  output logic protocol_error
);
  logic [TILE_BITS:0] next_tile;
  logic [PAIR_BITS-1:0] next_pair;
  logic bad,accepting;
  assign accepting=enable && next_tile<job.tiles && !reset && !clear && !protocol_error;
  assign bad=accepting && in_valid &&
    (in_epoch!=job.epoch || in_entry.slot!=job.slot ||
     in_entry.tile_idx!=next_tile[TILE_BITS-1:0] ||
     in_entry.pair_idx!=next_pair || in_entry.row_valid!=row_mask(next_pair) ||
     in_entry.reserved!=0);
  assign out_valid=accepting && in_valid && !bad;
  assign in_ready=accepting && out_ready && !bad;
  assign out_entry=in_entry;
  always_ff @(posedge clk) begin
    if(reset || clear) begin next_tile<=0;next_pair<=0;protocol_error<=0;end
    else begin
      if(bad) protocol_error<=1;
      if(out_valid && out_ready) begin
        if(next_pair==PAIRS-1) begin next_pair<=0;next_tile<=next_tile+1'b1;end
        else next_pair<=next_pair+1'b1;
      end
    end
  end
endmodule
