import pcore_pkg::*;

// Complete DEQACC accumulator store.
//
// V2 keeps one complete FACC/OACC store. Read selectors/initialized masks
// use local 1->4->16 control trees, not a single 512-bit masking driver.
// RAM words, validity maps, bank ownership and synchronous latency are intact.
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
  logic [WORD_BITS-1:0] bank_raw[0:2][0:1];
  logic [1:0][2:0] bank_initialized;
  logic [1:0][COLS-1:0][2:0] old_mask_leaf,external_mask_leaf;
  logic [31:0] bank_debug[0:2][0:1];
  acc_sel_e read_sel_q,external_sel_q;

  for(genvar b=0;b<3;b++) begin: banks
    for(genvar p=0;p<2;p++) begin: parity
      localparam int ROW_COUNT=(p==0)?(ROWS+1)/2:ROWS/2;
      localparam int DEPTH=ROW_COUNT*((b==2)?TILE:1);
      wire matrix_rd = rd_valid && rd_sel==acc_sel_e'(b);
      wire external_rd = external_rd_fire && external_rd_sel==acc_sel_e'(b);
      (* MAX_FANOUT=32 *) wire matrix_wr = wr_valid && wr_rows[p] && wr_sel==acc_sel_e'(b);
      wire external_wr = external_wr_fire && external_wr_rows[p] && external_wr_sel==acc_sel_e'(b);
      (* MAX_FANOUT=32 *) wire rd_en = matrix_rd || external_rd;
      (* MAX_FANOUT=32 *) wire wr_en = matrix_wr || external_wr;
      (* MAX_FANOUT=32 *) wire [9:0] ram_rd_addr = matrix_rd ? rd_addr : external_rd_addr;
      (* MAX_FANOUT=32 *) wire [9:0] ram_wr_addr = matrix_wr ? wr_addr : external_wr_addr;
      wire [WORD_BITS-1:0] ram_wr_data = matrix_wr ? wr_data[p] : external_wr_data[p];
      // This small decode is allowed to replicate; never protect the whole RAM.
      (* keep="true", MAX_FANOUT=32 *) wire bank_flush = reset || clear;

      // External accesses are back-pressured by the top-level owner when they
      // collide with a matrix access to the same bank. The explicit priority
      // here keeps the single-store ownership rule visible to synthesis.
      dea8_acc_bank #(
        .DEPTH(DEPTH),.WIDTH(WORD_BITS),.SHARED_VALIDITY(0),
        .STYLE(b==2?"block":"distributed")
      ) ram (
        .clk,.reset(1'b0),.clear(bank_flush),
        .rd_en(rd_en),.wr_en(wr_en),.rd_initialized(1'b0),
        .rd_addr(ram_rd_addr),.wr_addr(ram_wr_addr),.wr_data(ram_wr_data),
        .rd_data(),.rd_data_raw(bank_raw[b][p]),.rd_word_valid(bank_initialized[p][b]),
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
    logic [2:0] old_mask_root,external_mask_root;
    for(genvar b=0;b<3;b++)begin: masks
      assign old_mask_root[b]=(read_sel_q==acc_sel_e'(b))&&bank_initialized[p][b];
      assign external_mask_root[b]=(external_sel_q==acc_sel_e'(b))&&bank_initialized[p][b];
    end
    deqacc_v2_fanout #(.WIDTH(3),.BRANCHES(4),.LEAVES_PER_BRANCH(COLS/4)) old_controls(
      .root(old_mask_root),.leaf(old_mask_leaf[p]));
    deqacc_v2_fanout #(.WIDTH(3),.BRANCHES(4),.LEAVES_PER_BRANCH(COLS/4)) external_controls(
      .root(external_mask_root),.leaf(external_mask_leaf[p]));
    for(genvar n=0;n<COLS;n++) begin: output_cols
      assign old_data[p][n]=
        (bank_raw[0][p][n*32+:32]&{32{old_mask_leaf[p][n][0]}})|
        (bank_raw[1][p][n*32+:32]&{32{old_mask_leaf[p][n][1]}})|
        (bank_raw[2][p][n*32+:32]&{32{old_mask_leaf[p][n][2]}});
      assign external_data[p][n]=
        (bank_raw[0][p][n*32+:32]&{32{external_mask_leaf[p][n][0]}})|
        (bank_raw[1][p][n*32+:32]&{32{external_mask_leaf[p][n][1]}})|
        (bank_raw[2][p][n*32+:32]&{32{external_mask_leaf[p][n][2]}});
    end
  end

  always_comb begin
    dbg_data=0;
    // synthesis translate_off
    if(dbg_sel<=ACC_OACC)
      dbg_data=bank_debug[dbg_sel][dbg_parity];
    // synthesis translate_on
  end
  // synthesis translate_off
  initial if(COLS!=16)$fatal(1,"V2 ACC control trees require sixteen columns");
  // synthesis translate_on
endmodule
