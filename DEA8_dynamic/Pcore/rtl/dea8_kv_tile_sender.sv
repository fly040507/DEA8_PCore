import pcore_pkg::*;
import dea8_tile_link_pkg::*;

// One physical 64x136 Tile RAM, retained until the matching GCore commit.
module dea8_kv_tile_sender (
  input logic clk,reset,clear,
  input logic in_hdr_valid,output logic in_hdr_ready,input tile_header_t in_hdr,
  input logic in_valid,output logic in_ready,input logic [ROW_BITS-1:0] in_data,input logic in_last,
  output logic hdr_valid,input logic hdr_ready,output tile_header_t hdr,
  output logic out_valid,input logic out_ready,output logic [ROW_BITS-1:0] out_data,output logic out_last,
  input logic commit_valid,output logic commit_ready,input tile_commit_t commit,
  output logic busy,protocol_error
);
  localparam int WORDS=V_GROUPS*TILE,COUNT_BITS=$clog2(WORDS+1);
  typedef enum logic [2:0] {EMPTY,FILL,HEADER,DATA,COMMIT} state_e;
  state_e state;
  (* ram_style="block" *) logic [ROW_BITS-1:0] mem[0:WORDS-1];
  logic [ROW_BITS-1:0] word_q;
  logic [COUNT_BITS-1:0] filled,sent,expected;
  tile_header_t header_q;
  logic enabled;
  assign enabled=!reset&&!clear&&!protocol_error;
  assign in_hdr_ready=enabled&&state==EMPTY;
  assign in_ready=enabled&&state==FILL&&filled<expected;
  assign hdr_valid=enabled&&state==HEADER;
  assign hdr=header_q;
  assign out_valid=enabled&&state==DATA;
  assign out_data=word_q;
  assign out_last=sent==expected-1'b1;
  assign commit_ready=enabled&&state==COMMIT;
  assign busy=state!=EMPTY;
  always_ff @(posedge clk)begin
    if(reset||clear)begin state<=EMPTY;filled<=0;sent<=0;expected<=0;protocol_error<=0;end
    else begin
      if(in_hdr_valid&&in_hdr_ready)begin
        if(in_hdr.reserved!=0||in_hdr.rows!=ROWS||in_hdr.columns!=TILE||in_hdr.source_id>=8||in_hdr.tile_seq>=2||
          !((in_hdr.kind==TILE_K&&in_hdr.layout==LAYOUT_K_ROWS)||
            (in_hdr.kind==TILE_V&&in_hdr.layout==LAYOUT_V_GROUPS)))protocol_error<=1;
        else begin
          header_q<=in_hdr;expected<=COUNT_BITS'(in_hdr.kind==TILE_K?ROWS:WORDS);
          filled<=0;sent<=0;state<=FILL;
        end
      end
      if(in_valid&&in_ready)begin
        if(in_last!=(filled==expected-1'b1))protocol_error<=1;
        else begin
          mem[filled[$clog2(WORDS)-1:0]]<=in_data;filled<=filled+1'b1;
          if(in_last)state<=HEADER;
        end
      end
      if(hdr_valid&&hdr_ready)begin word_q<=mem[0];state<=DATA;end
      if(out_valid&&out_ready)begin
        sent<=sent+1'b1;
        if(out_last)state<=COMMIT;
        else word_q<=mem[sent+1'b1];
      end
      if(commit_valid)begin
        if(!commit_ready||!commit_matches(commit,header_q))protocol_error<=1;
        else state<=EMPTY;
      end
    end
  end
endmodule
