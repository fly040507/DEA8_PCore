import dea8_pcore_pkg::*;

// PCore INTERNAL normalized B-tile interface, NOT a frozen GCore wire layout.
// Entry n carries B[k=0..15,n] and E_stat[n]. Two staging slots transpose
// columns into loader rows. They are transport storage, not extra PE banks.
module dea8_tile_columns (
  input logic clk, rst_n,
  input logic in_valid,
  output logic in_ready,
  input logic [DW_ACT-1:0] in_data,
  input logic [SCALE_BITS-1:0] in_scale,
  output logic tile_available, data_valid,
  output logic [WEIGHT_WORD_BITS-1:0] data_word,
  output logic [SCALE_WORD_BITS-1:0] scale_word,
  input logic data_pop, scale_pop
);
  logic [DW_ACT-1:0] columns [0:BANK_COUNT-1][0:TILE-1];
  logic [SCALE_WORD_BITS-1:0] scales [0:BANK_COUNT-1];
  logic [BANK_COUNT-1:0] full_q;
  logic wr_bank, rd_bank;
  logic [TILE_IDX_BITS-1:0] col_q, row_q;
  assign in_ready = rst_n && !full_q[wr_bank];
  assign tile_available = full_q[rd_bank] && row_q == 0;
  assign data_valid = full_q[rd_bank];
  assign scale_word = scales[rd_bank];
  for(genvar n=0;n<TILE;n++) begin : g_transpose
    assign data_word[n*WEIGHT_BITS+:WEIGHT_BITS] = columns[rd_bank][n][row_q*WEIGHT_BITS+:WEIGHT_BITS];
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      full_q <= '0; wr_bank <= 0; rd_bank <= 0; col_q <= '0; row_q <= '0;
    end else begin
      if(in_valid && in_ready) begin
        columns[wr_bank][col_q] <= in_data;
        scales[wr_bank][col_q*SCALE_BITS+:SCALE_BITS] <= in_scale;
        if(col_q == TILE-1) begin full_q[wr_bank] <= 1; wr_bank <= ~wr_bank; col_q <= '0; end
        else col_q <= col_q + 1'b1;
      end
      if(data_pop) begin
        if(row_q == TILE-1) begin full_q[rd_bank] <= 0; rd_bank <= ~rd_bank; row_q <= '0; end
        else row_q <= row_q + 1'b1;
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(rst_n) begin
    if(data_pop && !data_valid) $fatal(1,"B tile staging underflow");
    if(scale_pop != (data_pop && row_q == 0)) $fatal(1,"B scale must pop with first row");
  end
  initial if(BANK_COUNT!=2) $fatal(1,"B staging requires two slots");
  // synthesis translate_on
endmodule
