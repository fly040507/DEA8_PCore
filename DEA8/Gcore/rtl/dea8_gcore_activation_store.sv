module dea8_gcore_activation_store (
  input logic clk,reset,clear,
  input logic wr_valid,
  output logic wr_ready,
  input logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] wr_index,
  input logic [135:0] wr_word,
  input logic rd_valid,
  output logic rd_ready,
  input logic [5:0] rd_tile,
  input logic [3:0] rd_group,
  output logic rsp_valid,
  input logic rsp_ready,
  output pcore_pkg::xbc4_t rsp,
  output logic protocol_error
);
  import gcore_pkg::*;
  import pcore_pkg::xbc4_t;
  logic [1:0] wr_bank;
  logic [$clog2(ACT_BANK_DEPTH)-1:0] wr_address,rd_address;
  logic wr_fire,rd_fire,rd_legal;
  logic [3:0][135:0] read_words;
  logic [5:0] tile_q;
  logic [3:0] group_q;

  assign wr_bank=2'((wr_index%ROWS)%4);
  assign wr_address=$clog2(ACT_BANK_DEPTH)'((wr_index/ROWS)*ROW_GROUPS+(wr_index%ROWS)/4);
  assign rd_address=$clog2(ACT_BANK_DEPTH)'(rd_tile*ROW_GROUPS+rd_group);
  assign wr_ready=!reset&&!clear&&!protocol_error;
  assign rd_ready=!reset&&!clear&&!protocol_error&&(!rsp_valid||rsp_ready);
  assign wr_fire=wr_valid&&wr_ready;
  assign rd_fire=rd_valid&&rd_ready;
  assign rd_legal=rd_group<ROW_GROUPS && !(wr_fire&&wr_address==rd_address);

  for(genvar b=0;b<4;b++) begin: banks
    (* ram_style="block" *) logic [135:0] memory [ACT_BANK_DEPTH];
    always_ff @(posedge clk) begin
      if(wr_fire && wr_index<VECTOR_WORDS && wr_bank==b) memory[wr_address]<=wr_word;
      if(rd_fire&&rd_legal) read_words[b]<=memory[rd_address];
    end
    always_comb begin
      rsp.row[b]='0;
      if(group_q*4+b<ROWS) begin
        rsp.row[b].data=read_words[b][127:0];
        rsp.row[b].scale=read_words[b][135:128];
      end
    end
  end
  always_comb begin
    rsp.row_valid=(group_q==ROW_GROUPS-1)?4'b0111:4'b1111;
    rsp.tile_idx=tile_q; rsp.group_idx=group_q; rsp.slot=0; rsp.reserved=0;
  end
  always_ff @(posedge clk) begin
    if(reset||clear) begin rsp_valid<=0; tile_q<=0; group_q<=0; protocol_error<=0; end
    else begin
      if(rsp_valid&&rsp_ready) rsp_valid<=0;
      if(rd_fire) begin
        if(!rd_legal) protocol_error<=1;
        else begin tile_q<=rd_tile; group_q<=rd_group; rsp_valid<=1; end
      end
      if(wr_fire&&wr_index>=VECTOR_WORDS) protocol_error<=1;
    end
  end
endmodule
