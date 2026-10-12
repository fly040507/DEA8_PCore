import dea8_tile_link_pkg::*;

// One per core. A single 64x136-bit buffer owns a Tile through GCore commit.
module dea8_kv_tile_sender(
  input logic clk,reset,clear,
  input logic in_hdr_valid,output logic in_hdr_ready,input tile_header_t in_hdr,
  input logic in_data_valid,output logic in_data_ready,input logic [135:0] in_data,input logic in_last,
  output logic out_hdr_valid,input logic out_hdr_ready,output tile_header_t out_hdr,
  output logic out_data_valid,input logic out_data_ready,output logic [135:0] out_data,output logic out_last,
  input logic commit_valid,output logic commit_ready,input tile_commit_t commit,
  output logic busy,payload_pending,protocol_error
);
  typedef enum logic [2:0] {EMPTY,FILL,SEND_HEADER,SEND_DATA,WAIT_COMMIT} state_e;
  state_e state_q;
  logic [135:0] tile_mem[0:63];
  tile_header_t header_q;
  logic [6:0] fill_q,send_q,expected_q;
  logic error_q;
  assign busy=state_q!=EMPTY;
  assign payload_pending=state_q!=EMPTY&&state_q!=WAIT_COMMIT;
  assign protocol_error=error_q;
  assign in_hdr_ready=state_q==EMPTY&&!reset&&!clear&&!error_q;
  assign in_data_ready=state_q==FILL&&!reset&&!clear&&!error_q&&fill_q<expected_q;
  assign out_hdr_valid=state_q==SEND_HEADER&&!reset&&!clear&&!error_q;
  assign out_hdr=header_q;
  assign out_data_valid=state_q==SEND_DATA&&!reset&&!clear&&!error_q;
  assign out_data=tile_mem[send_q[5:0]];
  assign out_last=send_q==expected_q-1'b1;
  assign commit_ready=state_q==WAIT_COMMIT&&!reset&&!clear&&!error_q;
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      state_q<=EMPTY;fill_q<=0;send_q<=0;expected_q<=0;error_q<=0;
    end else begin
      if(in_hdr_valid&&in_hdr_ready)begin
        if(in_hdr.reserved!=0||in_hdr.rows!=51||in_hdr.columns!=16||in_hdr.source_id>=8||
           in_hdr.tile_seq>=2||
           !((in_hdr.kind==TILE_K&&in_hdr.layout==LAYOUT_K_ROWS)||
             (in_hdr.kind==TILE_V&&in_hdr.layout==LAYOUT_V_GROUPS)))error_q<=1;
        else begin
          header_q<=in_hdr;expected_q<=in_hdr.kind==TILE_K?7'd51:7'd64;
          fill_q<=0;send_q<=0;state_q<=FILL;
        end
      end
      if(in_data_valid&&in_data_ready)begin
        if(in_last!=(fill_q==expected_q-1'b1))error_q<=1;
        else begin
          tile_mem[fill_q[5:0]]<=in_data;
          fill_q<=fill_q+1'b1;
          if(fill_q==expected_q-1'b1)state_q<=SEND_HEADER;
        end
      end
      if(out_hdr_valid&&out_hdr_ready)state_q<=SEND_DATA;
      if(out_data_valid&&out_data_ready)begin
        send_q<=send_q+1'b1;
        if(out_last)state_q<=WAIT_COMMIT;
      end
      if(commit_valid&&commit_ready)begin
        if(!commit_matches(commit,header_q))error_q<=1;
        else state_q<=EMPTY;
      end
    end
  end
endmodule
