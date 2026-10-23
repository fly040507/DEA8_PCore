module dea8_gcore_packet_rx #(
  parameter int DEPTH=gcore_pkg::RX_DEPTH
) (
  input logic clk,reset,clear,
  input logic [7:0] in_valid,output logic [7:0] in_ready,
  input logic [7:0][255:0] in_data,input logic [7:0] in_last,
  output logic [7:0] kv_header_valid,input logic [7:0] kv_header_ready,
  output dea8_tile_link_pkg::tile_header_t kv_header[8],
  output logic [7:0] kv_valid,input logic [7:0] kv_ready,
  output logic [7:0][135:0] kv_data,output logic [7:0] kv_last,
  input logic [7:0] kv_retire,
  output logic [7:0] fp_header_valid,input logic [7:0] fp_header_ready,
  output dea8_tile_link_pkg::tile_header_t fp_header[8],
  output logic [7:0] fp_valid,input logic [7:0] fp_ready,
  output logic [7:0][255:0] fp_data,input logic fp_retire,
  output logic busy,protocol_error
);
  import dea8_tile_link_pkg::*;
  typedef enum logic [1:0] {HEADER,PAYLOAD,DRAIN,RETIRE} state_e;
  state_e state_q[8];
  tile_header_t header_q[8],incoming[8];
  logic [7:0] is_kv,header_ok,word_ok,push,pop,fifo_valid,fifo_ready;
  logic [7:0][255:0] fifo_data;
  logic [7:0] received[8],consumed[8];
  logic [7:0] expected[8];
  logic [7:0] port_busy;
  assign busy=|port_busy;
  for(genvar c=0;c<8;c++)begin:ports
    always_comb begin
      incoming[c]=tile_header_t'(in_data[c][127:0]);incoming[c].reserved=0;
      is_kv[c]=header_q[c].kind==TILE_K||header_q[c].kind==TILE_V;
      header_ok[c]=packet_header_legal(in_data[c])&&incoming[c].source_id==c&&!in_last[c];
      word_ok[c]=in_last[c]==(received[c]==expected[c]-1'b1);
      if(is_kv[c])begin
        if(in_data[c][255:136]!=0||in_data[c][135:128]==8'hff)word_ok[c]=0;
        if(header_q[c].kind==TILE_V&&received[c]>=48&&in_data[c][127:24]!=0)word_ok[c]=0;
      end else for(int i=0;i<8;i++)if(!gcore_fp_pkg::finite32(in_data[c][32*i+:32]))word_ok[c]=0;
      kv_header[c]=incoming[c];fp_header[c]=incoming[c];
      kv_header_valid[c]=state_q[c]==HEADER&&in_valid[c]&&header_ok[c]&&
        (incoming[c].kind==TILE_K||incoming[c].kind==TILE_V)&&!protocol_error&&!reset&&!clear;
      fp_header_valid[c]=state_q[c]==HEADER&&in_valid[c]&&header_ok[c]&&
        (incoming[c].kind==TILE_O||incoming[c].kind==TILE_DOWN)&&!protocol_error&&!reset&&!clear;
      in_ready[c]=0;
      if(!protocol_error&&!reset&&!clear)case(state_q[c])
        HEADER:in_ready[c]=!header_ok[c]?1'b1:
          ((incoming[c].kind==TILE_K||incoming[c].kind==TILE_V)?kv_header_ready[c]:fp_header_ready[c]);
        PAYLOAD:in_ready[c]=fifo_ready[c];
        default:;
      endcase
    end
    assign push[c]=state_q[c]==PAYLOAD&&in_valid[c]&&in_ready[c]&&word_ok[c];
    assign kv_valid[c]=fifo_valid[c]&&is_kv[c]&&!protocol_error;
    assign kv_data[c]=fifo_data[c][135:0];
    assign kv_last[c]=consumed[c]==expected[c]-1'b1;
    assign fp_valid[c]=fifo_valid[c]&&!is_kv[c]&&!protocol_error;
    assign fp_data[c]=fifo_data[c];
    assign pop[c]=is_kv[c]?(kv_valid[c]&&kv_ready[c]):(fp_valid[c]&&fp_ready[c]);
    assign port_busy[c]=state_q[c]!=HEADER;
    dea8_gcore_fifo #(.WIDTH(256),.DEPTH(DEPTH)) fifo (
      .clk,.reset,.clear,.in_valid(push[c]),.in_ready(fifo_ready[c]),.in_data(in_data[c]),
      .out_valid(fifo_valid[c]),.out_ready(pop[c]),.out_data(fifo_data[c]),.occupancy()
    );
    always_ff @(posedge clk) begin
      if(reset||clear)begin state_q[c]<=HEADER;header_q[c]<='0;received[c]<=0;consumed[c]<=0;expected[c]<=0;end
      else begin
        if(state_q[c]==HEADER&&in_valid[c]&&in_ready[c]&&header_ok[c])begin
          header_q[c]<=incoming[c];expected[c]<=8'(packet_beats(incoming[c].kind));
          received[c]<=0;consumed[c]<=0;state_q[c]<=PAYLOAD;
        end
        if(state_q[c]==PAYLOAD&&in_valid[c]&&in_ready[c]&&word_ok[c])begin
          received[c]<=received[c]+1'b1;
          if(received[c]==expected[c]-1'b1)state_q[c]<=DRAIN;
        end
        if(pop[c])begin consumed[c]<=consumed[c]+1'b1;if(consumed[c]==expected[c]-1'b1)state_q[c]<=RETIRE;end
        if(state_q[c]==RETIRE&&(is_kv[c]?kv_retire[c]:fp_retire))state_q[c]<=HEADER;
      end
    end
  end
  always_ff @(posedge clk)begin
    if(reset||clear)protocol_error<=0;
    else for(int c=0;c<8;c++)if(in_valid[c]&&in_ready[c]&&
      ((state_q[c]==HEADER&&!header_ok[c])||(state_q[c]==PAYLOAD&&!word_ok[c])))protocol_error<=1;
  end
endmodule
