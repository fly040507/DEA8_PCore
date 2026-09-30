import pcore3_pkg::*;

// One synchronous read and one write per physical parity bank. Data RAM is
// never reset; validity is reset separately. Debug is simulation-only.
module dea8_acc_bank_v3 #(
  parameter int DEPTH=26,
  parameter STYLE="distributed"
) (
  input logic clk,reset,clear,rd_en,wr_en,
  input logic [9:0] rd_addr,wr_addr,
  input logic [511:0] wr_data,
  output logic [511:0] rd_data,
  output logic [511:0] rd_data_raw,
  output logic rd_word_valid,
  input logic [9:0] dbg_addr,input logic [3:0] dbg_lane,
  output logic [31:0] dbg_data
);
  localparam int AW=$clog2(DEPTH);
  (* ram_style=STYLE *) logic [511:0] mem[0:DEPTH-1];
  logic [DEPTH-1:0] valid_q;
  logic [511:0] data_q;
  logic initialized_q;
  always_ff @(posedge clk) begin
    if(rd_en && rd_addr<DEPTH) data_q<=mem[rd_addr[AW-1:0]];
    if(wr_en && !reset && !clear && wr_addr<DEPTH)
      mem[wr_addr[AW-1:0]]<=wr_data;
  end
  always_ff @(posedge clk) begin
    if(reset||clear) begin valid_q<='0;initialized_q<=0;end
    else begin
      if(rd_en) initialized_q<=(rd_addr<DEPTH)?valid_q[rd_addr[AW-1:0]]:1'b0;
      if(wr_en && wr_addr<DEPTH) valid_q[wr_addr[AW-1:0]]<=1;
    end
  end
  assign rd_data=initialized_q?data_q:'0;
  assign rd_data_raw=data_q;
  assign rd_word_valid=initialized_q;
  always_comb begin
    dbg_data=0;
    // synthesis translate_off
    if(dbg_addr<DEPTH && valid_q[dbg_addr]) dbg_data=mem[dbg_addr][32*dbg_lane+:32];
    // synthesis translate_on
  end
endmodule

// Independent FACC-A, FACC-B and OACC ownership. Matrix owns its selected
// bank(s); a VPU/result request to another bank proceeds in the same cycle.
// Same-bank conflicts are explicit backpressure, never silently dropped.
module dea8_acc_store_v3 #(
  parameter int ROWS_P=ROWS,OUT_TILES_P=TILE
) (
  input logic clk,reset,clear,
  input logic rd_valid,input acc_sel_e rd_sel,input logic [9:0] rd_addr,
  output logic rd_data_valid,
  output logic [15:0][31:0] rd_even_data,rd_odd_data,
  output logic [15:0][31:0] rd_even_raw,rd_odd_raw,
  output logic [1:0] rd_word_valid,
  input acc_read_owner_e result_rd_owner,
  input logic result_rd_valid,output logic result_rd_ready,
  input acc_sel_e result_rd_sel,input logic [9:0] result_rd_addr,
  output logic result_rd_data_valid,
  output logic [15:0][31:0] result_even_data,result_odd_data,
  input logic vpu_wr_valid,output logic vpu_wr_ready,input acc_write_t vpu_wr,
  input logic wr_valid,input acc_sel_e wr_sel,
  input logic wr_even_valid,wr_odd_valid,input logic [9:0] wr_addr,
  input logic [15:0][31:0] wr_even_data,wr_odd_data,
  input logic dbg_valid,input acc_sel_e dbg_sel,input logic dbg_parity,
  input logic [9:0] dbg_addr,input logic [3:0] dbg_lane,
  output logic [31:0] dbg_data
);
  logic [511:0] bank_data[0:2][0:1];
  logic [511:0] bank_raw[0:2][0:1];
  logic bank_word_valid[0:2][0:1];
  logic [31:0] bank_debug[0:2][0:1];
  acc_sel_e rd_sel_q,result_sel_q;
  assign result_rd_ready=!reset&&!clear&&result_rd_owner==ACC_READ_RESULT&&
    result_rd_sel<=ACC_OACC&&!(rd_valid&&rd_sel==result_rd_sel)&&
    !(wr_valid&&wr_sel==result_rd_sel);
  assign vpu_wr_ready=!reset&&!clear&&vpu_wr.sel<=ACC_OACC&&
    !(rd_valid&&rd_sel==vpu_wr.sel)&&!(wr_valid&&wr_sel==vpu_wr.sel);
  for(genvar b=0;b<3;b++) begin: banks
    wire mr=rd_valid&&rd_sel==b;
    wire vr=result_rd_valid&&result_rd_ready&&result_rd_sel==b;
    wire mw=wr_valid&&wr_sel==b;
    wire vw=vpu_wr_valid&&vpu_wr_ready&&vpu_wr.sel==b;
    wire [9:0] ra=mr?rd_addr:result_rd_addr;
    wire [9:0] wa=mw?wr_addr:vpu_wr.addr;
    for(genvar p=0;p<2;p++) begin: parity
      localparam int ROW_COUNT=(p==0)?(ROWS_P+1)/2:ROWS_P/2;
      localparam int DEPTH=ROW_COUNT*((b==2)?OUT_TILES_P:1);
      wire we=mw?(p==0?wr_even_valid:wr_odd_valid):(vw&&vpu_wr.row_valid[p]);
      wire [511:0] wd=mw?(p==0?wr_even_data:wr_odd_data):vpu_wr.data[p];
      dea8_acc_bank_v3 #(.DEPTH(DEPTH),.STYLE(b==2?"block":"distributed")) ram(
        .clk,.reset,.clear,.rd_en(mr||vr),.rd_addr(ra),.rd_data(bank_data[b][p]),
        .rd_data_raw(bank_raw[b][p]),.rd_word_valid(bank_word_valid[b][p]),
        .wr_en(we),.wr_addr(wa),.wr_data(wd),.dbg_addr,.dbg_lane,.dbg_data(bank_debug[b][p]));
    end
  end
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      rd_data_valid<=0;result_rd_data_valid<=0;rd_sel_q<=ACC_FACC_A;result_sel_q<=ACC_FACC_A;
    end else begin
      rd_data_valid<=rd_valid;result_rd_data_valid<=result_rd_valid&&result_rd_ready;
      if(rd_valid) rd_sel_q<=rd_sel;
      if(result_rd_valid&&result_rd_ready) result_sel_q<=result_rd_sel;
    end
  end
  assign rd_even_data=bank_data[rd_sel_q][0];
  assign rd_odd_data=bank_data[rd_sel_q][1];
  assign rd_even_raw=bank_raw[rd_sel_q][0];
  assign rd_odd_raw=bank_raw[rd_sel_q][1];
  assign rd_word_valid={bank_word_valid[rd_sel_q][1],bank_word_valid[rd_sel_q][0]};
  assign result_even_data=bank_data[result_sel_q][0];
  assign result_odd_data=bank_data[result_sel_q][1];
  assign dbg_data=(dbg_valid&&dbg_sel<=ACC_OACC)?bank_debug[dbg_sel][dbg_parity]:32'b0;
endmodule
