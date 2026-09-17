import dea8_pcore_pkg::*;

// One physical tile: HBM row-major (8 payload + 1 scale) to 16 B columns.
// Accept no new tile while draining; upstream must honor HBM ready.
module dea8_w_tile_assembler (
  input logic clk,rst_n,clear,
  input logic hbm_valid,
  output logic hbm_ready,
  input logic [HBM_BITS-1:0] hbm_data,
  output logic out_valid,
  input logic out_ready,
  output b_entry_t out_entry
);
  localparam int BEAT_BITS=$clog2(HBM_BEATS_PER_TILE);
  logic [WEIGHT_BITS-1:0] weights[0:TILE-1][0:TILE-1];
  logic [SCALE_WORD_BITS-1:0] scales;
  logic [BEAT_BITS-1:0] beat_q;
  logic [TILE_IDX_BITS-1:0] column_q;
  logic draining_q;
  assign hbm_ready=rst_n && !clear && !draining_q;
  assign out_valid=rst_n && !clear && draining_q;
  always_comb begin
    for(int k=0;k<TILE;k++) out_entry.data[k*WEIGHT_BITS+:WEIGHT_BITS]=weights[k][column_q];
    out_entry.scale=scales[column_q*SCALE_BITS+:SCALE_BITS];
  end
  always_ff @(posedge clk) if(hbm_valid && hbm_ready) begin
    if(beat_q<WEIGHT_HBM_BEATS_PER_TILE) begin
      for(int row=0;row<WEIGHT_WORDS_PER_HBM;row++)
        for(int n=0;n<TILE;n++) weights[beat_q*WEIGHT_WORDS_PER_HBM+row][n]<=
          hbm_data[(row*TILE+n)*WEIGHT_BITS+:WEIGHT_BITS];
    end else scales<=hbm_data[0+:SCALE_WORD_BITS];
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin beat_q<='0;column_q<='0;draining_q<=0;end
    else if(clear) begin beat_q<='0;column_q<='0;draining_q<=0;end
    else begin
      if(hbm_valid && hbm_ready) begin
        if(beat_q==HBM_BEATS_PER_TILE-1) begin beat_q<='0;draining_q<=1;end
        else beat_q<=beat_q+1'b1;
      end
      if(out_valid && out_ready) begin
        if(column_q==TILE-1) begin column_q<='0;draining_q<=0;end
        else column_q<=column_q+1'b1;
      end
    end
  end
  // synthesis translate_off
  initial if(SCALE_HBM_BEATS_PER_TILE!=1 || TILE%WEIGHT_WORDS_PER_HBM!=0)
    $fatal(1,"Unsupported HBM tile packing");
  // synthesis translate_on
endmodule
