import pcore2_pkg::*;
module dea8_w_tile_assembler_pp (
  input logic clk,reset,clear,hbm_valid,
  output logic hbm_ready,
  input logic [HBM_BITS-1:0] hbm_data,
  output logic out_valid,
  input logic out_ready,
  output b_t out_entry
);
  // Full flags encode READY/DRAIN; counters encode partial FILL/DRAIN.
  logic [TILE-1:0][DATA_BITS-1:0] data_bank[0:1];
  logic [TILE-1:0][SCALE_BITS-1:0] scale_bank[0:1];
  logic [1:0] full;
  logic fill_bank,drain_bank;
  logic [$clog2(HBM_BEATS)-1:0] beat;
  logic [$clog2(TILE)-1:0] column;
  logic fill,drain;
  assign hbm_ready=!reset && !clear && !full[fill_bank];
  assign out_valid=!reset && !clear && full[drain_bank];
  assign fill=hbm_valid && hbm_ready;
  assign drain=out_valid && out_ready;
  always_comb begin
    for(int k=0;k<TILE;k++) out_entry.data[k*INT_BITS+:INT_BITS]=data_bank[drain_bank][k][column*INT_BITS+:INT_BITS];
    out_entry.scale=scale_bank[drain_bank][column];
  end
  always_ff @(posedge clk) begin
    if(reset || clear) begin full<=0;fill_bank<=0;drain_bank<=0;beat<=0;column<=0;end
    else begin
      if(fill) begin
        if(beat==DATA_BEATS) begin
          scale_bank[fill_bank]<=hbm_data[TILE*SCALE_BITS-1:0];
          full[fill_bank]<=1;fill_bank<=!fill_bank;beat<=0;
        end else begin
          for(int h=0;h<HBM_BITS/DATA_BITS;h++)
            data_bank[fill_bank][beat*(HBM_BITS/DATA_BITS)+h]<=hbm_data[h*DATA_BITS+:DATA_BITS];
          beat<=beat+1'b1;
        end
      end
      if(drain) begin
        if(column==TILE-1) begin full[drain_bank]<=0;drain_bank<=!drain_bank;column<=0;end
        else column<=column+1'b1;
      end
    end
  end
endmodule
