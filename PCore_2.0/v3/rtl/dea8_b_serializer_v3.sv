import pcore3_pkg::*;

// Converts one B2 FIFO item into two consecutive B1 column items.  The held
// register is what guarantees data and scale remain atomic across the split.
module dea8_b_serializer_v3 (
  input logic clk,reset,clear,
  input logic start_tile,
  input logic in_valid,
  output logic in_ready,
  input b2_t in_entry,
  output logic out_valid,
  input logic out_ready,
  output b1_t out_entry,
  output logic busy
);
  b2_t hold;
  logic holding,half;
  // A new B2 may be accepted while the current B2's second column is being
  // consumed.  This replaces the holding register without inserting a gap.
  assign in_ready=start_tile&&!reset&&!clear&&
    (!holding || (holding&&half&&out_ready&&
      hold.group_idx != (TILE/2-1)));
  assign out_valid=holding&&!reset&&!clear;
  assign busy=holding;
  always_comb begin
    out_entry='0;
    out_entry.tile_idx=hold.tile_idx;
    out_entry.epoch=hold.epoch;
    out_entry.column={hold.group_idx,1'b0}+half;
    out_entry.col=hold.col[half];
  end
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      holding<=0;half<=0;hold.col[0]<='0;hold.col[1]<='0;hold.tile_idx<=0;hold.group_idx<=0;hold.epoch<=0;hold.reserved<=0;
    end
    else begin
      if(in_valid&&in_ready) begin
        hold<=in_entry;holding<=1;half<=0;
      end else if(out_valid&&out_ready) begin
        if(!half) half<=1;
        else begin holding<=0;half<=0;end
      end
    end
  end
endmodule
