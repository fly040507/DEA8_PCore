import pcore_pkg::*;

// One synchronous read and one write per physical parity bank. Data RAM is
// never reset; validity is reset separately. Debug is simulation-only.
module dea8_acc_bank #(
  parameter int DEPTH=26,
  parameter int WIDTH=512,
  parameter bit SHARED_VALIDITY=0,
  parameter STYLE="distributed"
) (
  input logic clk,reset,clear,rd_en,wr_en,rd_initialized,
  input logic [9:0] rd_addr,wr_addr,
  input logic [WIDTH-1:0] wr_data,
  output logic [WIDTH-1:0] rd_data,
  output logic [WIDTH-1:0] rd_data_raw,
  output logic rd_word_valid,
  input logic [9:0] dbg_addr,input logic [3:0] dbg_lane,
  output logic [31:0] dbg_data
);
  localparam int AW=$clog2(DEPTH);
  (* ram_style=STYLE *) logic [WIDTH-1:0] mem[0:DEPTH-1];
  logic [WIDTH-1:0] data_q;
  (* dont_touch="yes", shreg_extract="no" *) logic initialized_q;
  always_ff @(posedge clk) begin
    if(rd_en && rd_addr<DEPTH) data_q<=mem[rd_addr[AW-1:0]];
    if(wr_en && !reset && !clear && wr_addr<DEPTH)
      mem[wr_addr[AW-1:0]]<=wr_data;
  end
  if(SHARED_VALIDITY)begin: shared_valid
    always_ff @(posedge clk)begin
      if(reset||clear)initialized_q<=0;
      else if(rd_en)initialized_q<=rd_initialized;
    end
    always_comb begin
      dbg_data=0;
      // synthesis translate_off
      if(dbg_addr<DEPTH)dbg_data=mem[dbg_addr][32*dbg_lane+:32];
      // synthesis translate_on
    end
  end else begin: independent_valid
    logic [DEPTH-1:0] valid_q;
    always_ff @(posedge clk)begin
      if(reset||clear)begin valid_q<=0;initialized_q<=0;end
      else begin
        if(rd_en)initialized_q<=rd_addr<DEPTH?valid_q[rd_addr[AW-1:0]]:1'b0;
        if(wr_en&&wr_addr<DEPTH)valid_q[wr_addr[AW-1:0]]<=1;
      end
    end
    always_comb begin
      dbg_data=0;
      // synthesis translate_off
      if(dbg_addr<DEPTH&&valid_q[dbg_addr])dbg_data=mem[dbg_addr][32*dbg_lane+:32];
      // synthesis translate_on
    end
  end
  assign rd_data=initialized_q?data_q:'0;
  assign rd_data_raw=data_q;
  assign rd_word_valid=initialized_q;
endmodule

// Independent FACC-A, FACC-B and OACC ownership. Matrix owns its selected
// bank(s); a VPU/result request to another bank proceeds in the same cycle.
// Same-bank conflicts are explicit backpressure, never silently dropped.
module dea8_acc_store #(
  parameter int ROWS_P=ROWS,OUT_TILES_P=TILE,
  parameter bit LOCAL_MATRIX_CONTROL=0
) (
  input logic clk,reset,clear,
  input logic rd_valid,input acc_sel_e rd_sel,input logic [9:0] rd_addr,
  output logic rd_data_valid,
  output logic [15:0][31:0] rd_even_data,rd_odd_data,
  output logic [15:0][31:0] rd_even_raw,rd_odd_raw,
  output logic [1:0] rd_word_valid,
  output logic [7:0][1:0] rd_group_word_valid,
  input logic [7:0] group_rd_valid,group_wr_valid,
  input logic [7:0][1:0] group_rd_sel,group_wr_sel,group_wr_rows,
  input logic [7:0][9:0] group_rd_addr,group_wr_addr,
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
  logic [7:0] bank_group_valid[0:2][0:1];
  logic [31:0] group_debug[0:2][0:1][0:7];
  logic [7:0][2:0][1:0] read_initialized;
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
      // All column slices share address and row writes. One bitmap preserves
      // the logical word's validity; only its registered read result is copied
      // per 64-bit slice, never fanned out to the complete 512-bit payload.
      localparam int AW=$clog2(DEPTH);
      // Same-edge reset/clear, replicated combinationally per parity bank.
      // Preserve only this small control LUT, not the RAM or arithmetic cone.
      wire local_clear;
      (* dont_touch="yes" *) LUT2 #(.INIT(4'hE)) clear_decode(
        .I0(reset),.I1(clear),.O(local_clear));
      logic [DEPTH-1:0] valid_map;
      wire result_initialized=result_rd_addr<DEPTH?valid_map[result_rd_addr[AW-1:0]]:1'b0;
      always_ff @(posedge clk)begin
        if(local_clear)valid_map<=0;
        else if(we&&wa<DEPTH)valid_map[wa[AW-1:0]]<=1;
      end
      for(genvar g=0;g<8;g++)begin: groups
        wire local_mr=LOCAL_MATRIX_CONTROL?(group_rd_valid[g]&&group_rd_sel[g]==b):mr;
        wire local_mw=LOCAL_MATRIX_CONTROL?(group_wr_valid[g]&&group_wr_sel[g]==b):mw;
        wire [9:0] local_ra=local_mr?(LOCAL_MATRIX_CONTROL?group_rd_addr[g]:rd_addr):result_rd_addr;
        wire [9:0] matrix_addr=LOCAL_MATRIX_CONTROL?group_rd_addr[g]:rd_addr;
        wire matrix_initialized=matrix_addr<DEPTH?valid_map[matrix_addr[AW-1:0]]:1'b0;
        // Matrix masking has its own registered initialized one-hot. The
        // per-bank masked result is consumed only for accepted external reads.
        wire initialized_d=result_initialized;
        assign read_initialized[g][b][p]=matrix_initialized;
        wire [9:0] local_wa=local_mw?(LOCAL_MATRIX_CONTROL?group_wr_addr[g]:wr_addr):vpu_wr.addr;
        wire local_we=local_mw?(LOCAL_MATRIX_CONTROL?group_wr_rows[g][p]:(p==0?wr_even_valid:wr_odd_valid)):
          (vw&&vpu_wr.row_valid[p]);
        wire [63:0] local_wd=local_mw?(p==0?wr_even_data[g*2+:2]:wr_odd_data[g*2+:2]):vpu_wr.data[p][g*2+:2];
        dea8_acc_bank #(.DEPTH(DEPTH),.WIDTH(64),.SHARED_VALIDITY(1),.STYLE(b==2?"block":"distributed")) ram(
          .clk,.reset(1'b0),.clear(local_clear),.rd_en(local_mr||vr),.rd_addr(local_ra),
          .rd_initialized(initialized_d),
          .rd_data(bank_data[b][p][g*64+:64]),.rd_data_raw(bank_raw[b][p][g*64+:64]),
          .rd_word_valid(bank_group_valid[b][p][g]),.wr_en(local_we),.wr_addr(local_wa),.wr_data(local_wd),
          .dbg_addr,.dbg_lane({3'b0,dbg_lane[0]}),.dbg_data(group_debug[b][p][g]));
      end
      assign bank_word_valid[b][p]=bank_group_valid[b][p][0];
      assign bank_debug[b][p]=(dbg_addr<DEPTH&&valid_map[dbg_addr])?group_debug[b][p][dbg_lane[3:1]]:32'b0;
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
  assign rd_word_valid=rd_group_word_valid[0];
  for(genvar g=0;g<8;g++)begin: group_read_select
    (* dont_touch="yes", shreg_extract="no" *) logic [2:0] sel_q,result_local_sel_q;
    (* dont_touch="yes", shreg_extract="no" *) logic [1:0][2:0] initialized_sel_q;
    always_ff @(posedge clk)begin
      if(reset||clear)begin sel_q<=3'b001;result_local_sel_q<=3'b001;end
      else begin
        if(rd_valid)for(int b=0;b<3;b++)sel_q[b]<=LOCAL_MATRIX_CONTROL?(group_rd_sel[g]==b):(rd_sel==b);
        if(result_rd_valid&&result_rd_ready)for(int b=0;b<3;b++)result_local_sel_q[b]<=result_rd_sel==b;
      end
      if(reset||clear)initialized_sel_q<=0;
      else if(rd_valid)for(int p=0;p<2;p++)for(int b=0;b<3;b++)
        initialized_sel_q[p][b]<=read_initialized[g][b][p]&&
          (LOCAL_MATRIX_CONTROL?(group_rd_sel[g]==b):(rd_sel==b));
    end
    for(genvar p=0;p<2;p++)begin: parity
      wire [63:0] raw_value=(bank_raw[0][p][g*64+:64]&{64{sel_q[0]}})|
        (bank_raw[1][p][g*64+:64]&{64{sel_q[1]}})|(bank_raw[2][p][g*64+:64]&{64{sel_q[2]}});
      wire [63:0] result_value=(bank_data[0][p][g*64+:64]&{64{result_local_sel_q[0]}})|
        (bank_data[1][p][g*64+:64]&{64{result_local_sel_q[1]}})|(bank_data[2][p][g*64+:64]&{64{result_local_sel_q[2]}});
      wire [63:0] initialized_value=(bank_raw[0][p][g*64+:64]&{64{initialized_sel_q[p][0]}})|
        (bank_raw[1][p][g*64+:64]&{64{initialized_sel_q[p][1]}})|
        (bank_raw[2][p][g*64+:64]&{64{initialized_sel_q[p][2]}});
      assign rd_group_word_valid[g][p]=|initialized_sel_q[p];
      if(p==0)begin
        assign rd_even_raw[g*2+:2]=raw_value;assign result_even_data[g*2+:2]=result_value;
        assign rd_even_data[g*2+:2]=initialized_value;
      end else begin
        assign rd_odd_raw[g*2+:2]=raw_value;assign result_odd_data[g*2+:2]=result_value;
        assign rd_odd_data[g*2+:2]=initialized_value;
      end
    end
  end
  assign dbg_data=(dbg_valid&&dbg_sel<=ACC_OACC)?bank_debug[dbg_sel][dbg_parity]:32'b0;
endmodule
