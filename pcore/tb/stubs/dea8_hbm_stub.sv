import dea8_pcore_pkg::*;

// Simulation transport fixture, not an AXI/MCU implementation.
// Each private-weight tile: eight data beats, then low-128-bit scales.
module dea8_hbm_stub #(
  parameter int TILE_COUNT=HEAD_TILES,
  parameter logic [WEIGHT_BITS-1:0] CODE=8'd1,
  parameter logic [SCALE_BITS-1:0] EXPONENT=8'd133
) (
  input logic clk,rst_n,start,
  output logic busy,done,
  output logic hbm_valid,
  input logic hbm_ready,
  output logic [HBM_BITS-1:0] hbm_data
);
  localparam int TOTAL_BEATS=TILE_COUNT*HBM_BEATS_PER_TILE;
  int unsigned beat_q;
  assign hbm_valid=rst_n && busy;
  always_comb begin
    hbm_data='0;
    if(beat_q%HBM_BEATS_PER_TILE < WEIGHT_HBM_BEATS_PER_TILE)
      hbm_data={HBM_BITS/WEIGHT_BITS{CODE}};
    else hbm_data[SCALE_WORD_BITS-1:0]={TILE{EXPONENT}};
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin busy<=0;done<=0;beat_q<=0;end
    else begin
      done<=0;
      if(start && !busy) begin busy<=1;beat_q<=0;end
      if(hbm_valid && hbm_ready) begin
        if(beat_q==TOTAL_BEATS-1) begin busy<=0;done<=1;end
        else beat_q<=beat_q+1;
      end
    end
  end
endmodule
