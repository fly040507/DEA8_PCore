import pcore_pkg::*;

// One synchronous read and one write per physical parity bank. Data RAM is
// never reset; validity is reset separately. Debug is simulation-only.
module dea8_acc_bank #(
  parameter int DEPTH=26,
  parameter STYLE="block"
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
  logic [DEPTH-1:0] valid_q;
  logic [511:0] data_q,debug_word;
  logic [ACC_READ_LATENCY-1:0] initialized_q;
  logic ren_q;
  logic [AW-1:0] raddr_q;
  wire ren=rd_en&&rd_addr<DEPTH;
  wire wen=wr_en&&!reset&&!clear&&wr_addr<DEPTH;
  if(STYLE=="block")begin: bram
    always_ff @(posedge clk)begin ren_q<=ren;raddr_q<=rd_addr[AW-1:0];end
    dea8_sdp_ram #(.WIDTH(512),.DEPTH(DEPTH),.LATENCY(ACC_READ_LATENCY-1),.PRIMITIVE("block")) ram(
      .clk,.rd_en(ren_q),.rd_addr(raddr_q),.wr_en(wen),.wr_addr(wr_addr[AW-1:0]),
      .wr_data,.rd_data(data_q),.dbg_addr(dbg_addr[AW-1:0]),.dbg_data(debug_word));
  end else begin: uram
    dea8_sdp_ram #(.WIDTH(512),.DEPTH(DEPTH),.LATENCY(ACC_READ_LATENCY),.PRIMITIVE("ultra")) ram(
      .clk,.rd_en(ren),.rd_addr(rd_addr[AW-1:0]),.wr_en(wen),.wr_addr(wr_addr[AW-1:0]),
      .wr_data,.rd_data(data_q),.dbg_addr(dbg_addr[AW-1:0]),.dbg_data(debug_word));
  end
  always_ff @(posedge clk) begin
    if(reset||clear)initialized_q<='0;
    else begin
      initialized_q[0]<=ren?valid_q[rd_addr[AW-1:0]]:1'b0;
      for(int i=1;i<ACC_READ_LATENCY;i++)initialized_q[i]<=initialized_q[i-1];
    end
  end
  for(genvar address=0;address<DEPTH;address++)begin: validity
    always_ff @(posedge clk)begin
      if(reset||clear)valid_q[address]<=0;
      else if(wen&&wr_addr[AW-1:0]==address)valid_q[address]<=1;
    end
  end
  assign rd_data=initialized_q[ACC_READ_LATENCY-1]?data_q:'0;
  assign rd_data_raw=data_q;
  assign rd_word_valid=initialized_q[ACC_READ_LATENCY-1];
  always_comb begin
    dbg_data=0;
    // synthesis translate_off
    if(dbg_addr<DEPTH && valid_q[dbg_addr]) dbg_data=debug_word[32*dbg_lane+:32];
    // synthesis translate_on
  end
endmodule

// Independent FACC-A, FACC-B and OACC ownership. Matrix owns its selected
// bank(s); a VPU/result request to another bank proceeds in the same cycle.
// Same-bank conflicts are explicit backpressure, never silently dropped.
module dea8_acc_store #(
  parameter int ROWS_P=ROWS,OUT_TILES_P=TILE
) (
  input logic clk,reset,clear,
  input logic rd_valid,input acc_sel_e rd_sel,input logic [9:0] rd_addr,
  output logic rd_data_valid,
  input logic [3:0] matrix_tile,input logic matrix_needs_scaled,
  input logic raw_begin,raw_page,
  output logic matrix_tile_ready,
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
  logic [831:0] raw_valid;
  logic [511:0] bank_raw[0:2][0:1];
  logic bank_word_valid[0:2][0:1];
  logic [31:0] bank_debug[0:2][0:1];
  acc_sel_e rd_sel_q[0:ACC_READ_LATENCY-1],result_sel_q[0:ACC_READ_LATENCY-1];
  logic [ACC_READ_LATENCY-1:0] matrix_valid_q,result_valid_q;
   assign result_rd_ready=!reset&&!clear&&result_rd_owner==ACC_READ_RESULT&&
    result_rd_sel<=ACC_OACC&&(result_rd_sel==ACC_OACC?raw_valid[result_rd_addr]:(!(rd_valid&&rd_sel==result_rd_sel)&&
    !(wr_valid&&wr_sel==result_rd_sel)));
  assign vpu_wr_ready=!reset&&!clear&&vpu_wr.sel<=ACC_OACC&&
    (vpu_wr.sel==ACC_OACC||(!(rd_valid&&rd_sel==vpu_wr.sel)&&!(wr_valid&&wr_sel==vpu_wr.sel)));
  for(genvar b=0;b<2;b++) begin: banks
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
      dea8_acc_bank #(.DEPTH(DEPTH),.STYLE(b<2?"block":"ultra")) ram(
        .clk,.reset,.clear,.rd_en(mr||vr),.rd_addr(ra),.rd_data(bank_data[b][p]),
        .rd_data_raw(bank_raw[b][p]),.rd_word_valid(bank_word_valid[b][p]),
        .wr_en(we),.wr_addr(wa),.wr_data(wd),.dbg_addr,.dbg_lane,.dbg_data(bank_debug[b][p]));
    end
  end
  // OACC_1: single-consumer scaled state. Valid is consumed on read request,
  // never by writing zeros through an already occupied payload write port.
  logic [415:0] scaled_valid;
  logic [1:0][511:0] scaled_raw,scaled_data,raw_data,raw_unused;
  logic [1:0] scaled_word_valid,raw_word_valid;
  logic [31:0] scaled_debug[2],raw_debug[2];
  always_comb begin
    matrix_tile_ready=1;
    if(matrix_needs_scaled)for(int pair=0;pair<26;pair++)
      matrix_tile_ready&=scaled_valid[pair*16+matrix_tile];
  end
  // Fixed flag destinations keep address decode out of a wide read/modify/
  // write cone. Preserve same-edge priority: raw write beats page invalidation;
  // a scaled read consumes its flag even if a same-address write is present.
  for(genvar address=0;address<832;address++)begin: raw_validity
    always_ff @(posedge clk)begin
      if(reset||clear)raw_valid[address]<=0;
      else if(wr_valid&&wr_sel==ACC_OACC&&wr_addr==address)raw_valid[address]<=1;
      else if(raw_begin&&raw_page==(address/416))raw_valid[address]<=0;
    end
  end
  for(genvar address=0;address<416;address++)begin: scaled_validity
    always_ff @(posedge clk)begin
      if(reset||clear)scaled_valid[address]<=0;
      else if(rd_valid&&rd_sel==ACC_OACC&&rd_addr==address)scaled_valid[address]<=0;
      else if(vpu_wr_valid&&vpu_wr_ready&&vpu_wr.sel==ACC_OACC&&vpu_wr.addr==address)
        scaled_valid[address]<=1;
    end
  end
  for(genvar p=0;p<2;p++)begin: oacc
    dea8_acc_bank #(.DEPTH(416),.STYLE("ultra")) scaled(
      .clk,.reset,.clear,.rd_en(rd_valid&&rd_sel==ACC_OACC),.wr_en(vpu_wr_valid&&vpu_wr_ready&&vpu_wr.sel==ACC_OACC&&vpu_wr.row_valid[p]),
      .rd_addr,.wr_addr(vpu_wr.addr),.wr_data(vpu_wr.data[p]),.rd_data(scaled_data[p]),.rd_data_raw(scaled_raw[p]),
      .rd_word_valid(scaled_word_valid[p]),.dbg_addr,.dbg_lane,.dbg_data(scaled_debug[p]));
    dea8_acc_bank #(.DEPTH(832),.STYLE("ultra")) raw_pages(
      .clk,.reset,.clear,.rd_en(result_rd_valid&&result_rd_ready&&result_rd_sel==ACC_OACC),
      .wr_en(wr_valid&&wr_sel==ACC_OACC&&(p==0?wr_even_valid:wr_odd_valid)),
      .rd_addr(result_rd_addr),.wr_addr,.wr_data(p==0?wr_even_data:wr_odd_data),
      .rd_data(raw_data[p]),.rd_data_raw(raw_unused[p]),.rd_word_valid(raw_word_valid[p]),
      .dbg_addr,.dbg_lane,.dbg_data(raw_debug[p]));
    assign bank_data[2][p]=scaled_data[p];assign bank_raw[2][p]=scaled_raw[p];
    assign bank_word_valid[2][p]=scaled_word_valid[p];assign bank_debug[2][p]=raw_debug[p];
  end
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      matrix_valid_q<='0;result_valid_q<='0;
    end else begin
      matrix_valid_q<={matrix_valid_q[ACC_READ_LATENCY-2:0],rd_valid};
      result_valid_q<={result_valid_q[ACC_READ_LATENCY-2:0],result_rd_valid&&result_rd_ready};
    end
    rd_sel_q[0]<=rd_sel;result_sel_q[0]<=result_rd_sel;
    for(int i=1;i<ACC_READ_LATENCY;i++)begin rd_sel_q[i]<=rd_sel_q[i-1];result_sel_q[i]<=result_sel_q[i-1];end
  end
  assign rd_data_valid=matrix_valid_q[ACC_READ_LATENCY-1];
  assign result_rd_data_valid=result_valid_q[ACC_READ_LATENCY-1];
  assign rd_even_data=bank_data[rd_sel_q[ACC_READ_LATENCY-1]][0];
  assign rd_odd_data=bank_data[rd_sel_q[ACC_READ_LATENCY-1]][1];
  assign rd_even_raw=bank_raw[rd_sel_q[ACC_READ_LATENCY-1]][0];
  assign rd_odd_raw=bank_raw[rd_sel_q[ACC_READ_LATENCY-1]][1];
  assign rd_word_valid={bank_word_valid[rd_sel_q[ACC_READ_LATENCY-1]][1],bank_word_valid[rd_sel_q[ACC_READ_LATENCY-1]][0]};
   assign result_even_data=result_sel_q[ACC_READ_LATENCY-1]==ACC_OACC?raw_data[0]:bank_data[result_sel_q[ACC_READ_LATENCY-1]][0];
   assign result_odd_data=result_sel_q[ACC_READ_LATENCY-1]==ACC_OACC?raw_data[1]:bank_data[result_sel_q[ACC_READ_LATENCY-1]][1];
  assign dbg_data=(dbg_valid&&dbg_sel<=ACC_OACC)?bank_debug[dbg_sel][dbg_parity]:32'b0;
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear&&rd_valid&&rd_sel==ACC_OACC&&!scaled_valid[rd_addr])
    $fatal(1,"OACC scaled read before production or repeated consumption address=%0d",rd_addr);
  // synthesis translate_on
endmodule
