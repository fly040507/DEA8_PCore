import pcore2_pkg::*;
// Sole owner of the PE stationary banks. A tile reserves all 16 FIFO entries.
module dea8_b_column_loader (
  input logic clk,reset,clear,enable,
  input logic [TILE_BITS:0] tiles,
  input logic fifo_valid,
  output logic fifo_ready,
  input b_t fifo_entry,
  input logic [$clog2(B_DEPTH+1)-1:0] fifo_count,
  input logic release_valid,release_bank,
  output logic [1:0] bank_ready,
  output logic [TILE_BITS-1:0] bank_tile[0:1],
  output logic load_valid,load_bank,
  output logic [$clog2(TILE)-1:0] load_column,
  output b_t load_entry
);
  logic [1:0] occupied;
  logic loading;
  logic [TILE_BITS:0] next_tile;
  assign load_valid=loading && fifo_valid && !reset && !clear;
  assign fifo_ready=loading && !reset && !clear;
  assign load_entry=fifo_entry;
  always_ff @(posedge clk) begin
    if(reset || clear) begin
      occupied<=0;bank_ready<=0;loading<=0;next_tile<=0;
      load_bank<=0;load_column<=0;bank_tile[0]<=0;bank_tile[1]<=0;
    end else begin
      if(release_valid) begin occupied[release_bank]<=0;bank_ready[release_bank]<=0;end
      if(!loading && enable && next_tile<tiles &&
         !occupied[next_tile[0]] && fifo_count>=TILE) begin
        occupied[next_tile[0]]<=1;load_bank<=next_tile[0];
        load_column<=0;loading<=1;
      end
      if(load_valid) begin
        if(load_column==TILE-1) begin
          loading<=0;bank_ready[load_bank]<=1;
          bank_tile[load_bank]<=next_tile[TILE_BITS-1:0];
          next_tile<=next_tile+1'b1;
        end else load_column<=load_column+1'b1;
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(!reset && !clear) begin
    if(loading && !fifo_valid) $fatal(1,"B reserved tile underflow");
    if(release_valid && !bank_ready[release_bank]) $fatal(1,"B release without ownership");
    if(release_valid && load_valid && release_bank==load_bank) $fatal(1,"B load/release collision");
  end
  // synthesis translate_on
endmodule
