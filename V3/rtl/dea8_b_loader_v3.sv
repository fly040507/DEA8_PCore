import pcore3_pkg::*;

// One B1 column is written per cycle into one of the two stationary banks.
module dea8_b_loader_v3 (
  input logic clk,reset,clear,
  input logic enable,
  input logic tile_available,
  input b2_t bfifo_head,
  input logic serializer_busy,
  output logic serializer_start,
  output logic serializer_allow,
  input logic b1_valid,
  output logic b1_ready,
  input b1_t b1_entry,
  input logic release_valid,
  input logic release_bank,
  output logic [1:0] bank_ready,
  output logic [TILE_BITS-1:0] bank_tile[0:1],
  output logic load_valid,
  output logic load_bank,
  output logic [3:0] load_column,
  output qvec16_t load_col
);
  logic [1:0] occupied;
  logic loading;
  // The serializer consumes the first B2 on serializer_start and exposes
  // its first B1 after that edge.  Keep one startup flag so the starvation
  // assertion does not inspect the old pre-NBA value on that first cycle.
  logic startup;
  logic target_bank;
  logic [3:0] column;
  logic chosen_bank;
  assign chosen_bank=bfifo_head.tile_idx[0];
  assign serializer_start=!reset&&!clear&&enable&&!loading&&tile_available&&
    !occupied[chosen_bank];
  // Start launches a Tile.  While that Tile is active, the serializer keeps
  // its input side enabled so it can replace the completed B2 on the same
  // edge as its second B1 output.
  assign serializer_allow=!reset&&!clear&&enable&&
    (serializer_start || loading);
  assign b1_ready=loading&&!reset&&!clear;
  assign load_valid=b1_valid&&b1_ready;
  assign load_bank=target_bank;
  assign load_column=column;
  assign load_col=b1_entry.col;
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      occupied<=0;bank_ready<=0;loading<=0;startup<=0;target_bank<=0;column<=0;
      bank_tile[0]<=0;bank_tile[1]<=0;
    end else begin
      if(release_valid) begin occupied[release_bank]<=0;bank_ready[release_bank]<=0;end
      if(serializer_start) begin
        target_bank<=chosen_bank;column<=0;loading<=1;startup<=1;occupied[chosen_bank]<=1;
      end
      if(load_valid) begin
        startup<=0;
        if(column==15) begin
          loading<=0;bank_ready[target_bank]<=1;bank_tile[target_bank]<=b1_entry.tile_idx;
        end else column<=column+1'b1;
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(!reset&&!clear) begin
    if(loading&&!startup&&!b1_valid) $fatal(1,"B loader starved during a reserved Tile col=%0d startup=%0d busy=%0d",column,startup,loading);
    if(load_valid&&load_column>15) $fatal(1,"B loader column overflow");
  end
  // synthesis translate_on
endmodule
