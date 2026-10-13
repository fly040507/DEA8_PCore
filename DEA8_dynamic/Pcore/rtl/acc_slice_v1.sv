import pcore_pkg::*;

// Complete DEQACC accumulator store.
//
// V2 keeps one physical FACC/OACC store. The arithmetic side exchanges four
// fixed 256-bit bundles with this module, but the data RAM, validity and bank
// ownership remain here. A bank stores one complete 16-column row word, so no
// four-way ACC copy is created by arithmetic grouping.
module acc_slice_v1 #(
  parameter int COLS = TILE
) (
  input logic clk,reset,clear,
  input logic rd_valid,input acc_sel_e rd_sel,input logic [9:0] rd_addr,
  output logic [1:0][COLS-1:0][31:0] old_data,
  input logic wr_valid,input acc_sel_e wr_sel,input logic [9:0] wr_addr,
  input logic [1:0] wr_rows,input logic [1:0][COLS-1:0][31:0] wr_data,
  input logic external_rd_fire,input acc_sel_e external_rd_sel,input logic [9:0] external_rd_addr,
  output logic [1:0][COLS-1:0][31:0] external_data,
  input logic external_wr_fire,input acc_sel_e external_wr_sel,input logic [9:0] external_wr_addr,
  input logic [1:0] external_wr_rows,input logic [1:0][COLS-1:0][31:0] external_wr_data,
  input acc_sel_e dbg_sel,input logic dbg_parity,input logic [9:0] dbg_addr,
  input logic [3:0] dbg_column,output logic [31:0] dbg_data
);
  localparam int WORD_BITS = COLS*32;
  logic [WORD_BITS-1:0] bank_data[0:2][0:1];
  logic [WORD_BITS-1:0] bank_raw[0:2][0:1];
  logic [31:0] bank_debug[0:2][0:1];
  acc_sel_e read_sel_q,external_sel_q;

  for(genvar b=0;b<3;b++) begin: banks
    for(genvar p=0;p<2;p++) begin: parity
      localparam int ROW_COUNT=(p==0)?(ROWS+1)/2:ROWS/2;
      localparam int DEPTH=ROW_COUNT*((b==2)?TILE:1);
      wire matrix_rd = rd_valid && rd_sel==acc_sel_e'(b);
      wire external_rd = external_rd_fire && external_rd_sel==acc_sel_e'(b);
      wire matrix_wr = wr_valid && wr_rows[p] && wr_sel==acc_sel_e'(b);
      wire external_wr = external_wr_fire && external_wr_rows[p] && external_wr_sel==acc_sel_e'(b);
      wire rd_en = matrix_rd || external_rd;
      wire wr_en = matrix_wr || external_wr;
      wire [9:0] ram_rd_addr = matrix_rd ? rd_addr : external_rd_addr;
      wire [9:0] ram_wr_addr = matrix_wr ? wr_addr : external_wr_addr;
      wire [WORD_BITS-1:0] ram_wr_data = matrix_wr ? wr_data[p] : external_wr_data[p];

      // External accesses are back-pressured by the top-level owner when they
      // collide with a matrix access to the same bank. The explicit priority
      // here keeps the single-store ownership rule visible to synthesis.
      dea8_acc_bank #(
        .DEPTH(DEPTH),.WIDTH(WORD_BITS),.SHARED_VALIDITY(0),
        .STYLE(b==2?"block":"distributed")
      ) ram (
        .clk,.reset,.clear,
        .rd_en(rd_en),.wr_en(wr_en),.rd_initialized(1'b0),
        .rd_addr(ram_rd_addr),.wr_addr(ram_wr_addr),.wr_data(ram_wr_data),
        .rd_data(bank_data[b][p]),.rd_data_raw(bank_raw[b][p]),.rd_word_valid(),
        .dbg_addr,.dbg_lane(dbg_column),.dbg_data(bank_debug[b][p])
      );
    end
  end

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      read_sel_q<=ACC_FACC_A;
      external_sel_q<=ACC_FACC_A;
    end else begin
      if(rd_valid) read_sel_q<=rd_sel;
      if(external_rd_fire) external_sel_q<=external_rd_sel;
    end
  end

  for(genvar p=0;p<2;p++) begin: output_rows
    for(genvar n=0;n<COLS;n++) begin: output_cols
      assign old_data[p][n]=bank_data[read_sel_q][p][n*32+:32];
      assign external_data[p][n]=bank_data[external_sel_q][p][n*32+:32];
    end
  end

  always_comb begin
    dbg_data=0;
    // synthesis translate_off
    if(dbg_sel<=ACC_OACC)
      dbg_data=bank_debug[dbg_sel][dbg_parity];
    // synthesis translate_on
  end
endmodule
