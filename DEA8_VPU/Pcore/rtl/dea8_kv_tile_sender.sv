import dea8_tile_link_pkg::*;

// Two 64-word slots share a 128x144 SDP memory. Fill overlaps sending, but
// only ONE tile may be outstanding at GCore: commit precedes the next header.
module dea8_kv_tile_sender(
 input logic clk,reset,clear,
 input logic in_hdr_valid,output logic in_hdr_ready,input tile_header_t in_hdr,
 input logic in_data_valid,output logic in_data_ready,input logic [135:0] in_data,input logic in_last,
 output logic out_hdr_valid,input logic out_hdr_ready,output tile_header_t out_hdr,
 output logic out_data_valid,input logic out_data_ready,output logic [135:0] out_data,output logic out_last,
 input logic commit_valid,output logic commit_ready,input tile_commit_t commit,
 output logic busy,payload_pending,protocol_error
);
 typedef enum logic [1:0] {IDLE,HEADER,DATA,COMMIT} state_t;
 state_t state;
 logic fill_active,fill_slot,send_slot,error_q;
 logic [1:0] occupied,full;
 tile_header_t headers[2];
 logic [6:0] expected[2];
 logic [6:0] fill_index,send_index;
 logic [143:0] read_data;
 wire enabled=!reset&&!clear&&!error_q;
 wire write_take=in_data_valid&&in_data_ready;
 wire header_take=out_hdr_valid&&out_hdr_ready;
 wire data_take=out_data_valid&&out_data_ready;
 assign busy=fill_active||(|occupied)||state!=IDLE;
 assign payload_pending=fill_active||(|(full&~(state==COMMIT?(2'b01<<send_slot):2'b0)));
 assign protocol_error=error_q;
 assign in_hdr_ready=enabled&&!fill_active&&!occupied[fill_slot];
 assign in_data_ready=enabled&&fill_active&&fill_index<expected[fill_slot];
 assign out_hdr_valid=enabled&&state==HEADER;
 assign out_hdr=headers[send_slot];
 assign out_data_valid=enabled&&state==DATA;
 assign out_data=read_data[135:0];assign out_last=send_index==expected[send_slot]-1;
 assign commit_ready=enabled&&state==COMMIT;
 dea8_sdp_ram #(.WIDTH(144),.DEPTH(128)) memory(
   .clk,.wr_en(write_take&&in_last==(fill_index==expected[fill_slot]-1)),
   .wr_addr({fill_slot,fill_index[5:0]}),.wr_data({8'b0,in_data}),
   .rd_en(header_take||(data_take&&!out_last)),
   .rd_addr({send_slot,header_take?6'b0:6'(send_index+1'b1)}),.rd_data(read_data),.dbg_addr('0),.dbg_data());
 always_ff @(posedge clk)begin
   if(reset||clear)begin
     state<=IDLE;fill_active<=0;fill_slot<=0;send_slot<=0;occupied<=0;full<=0;
     fill_index<=0;send_index<=0;error_q<=0;
   end else begin
     if(in_hdr_valid&&in_hdr_ready)begin
       if(in_hdr.reserved!=0||in_hdr.rows!=51||in_hdr.columns!=16||in_hdr.source_id>=8||in_hdr.tile_seq>=2||
         !((in_hdr.kind==TILE_K&&in_hdr.layout==LAYOUT_K_ROWS)||(in_hdr.kind==TILE_V&&in_hdr.layout==LAYOUT_V_GROUPS)))error_q<=1;
       else begin
         headers[fill_slot]<=in_hdr;expected[fill_slot]<=in_hdr.kind==TILE_K?7'd51:7'd64;
         occupied[fill_slot]<=1;fill_active<=1;fill_index<=0;
       end
     end
     if(write_take)begin
       if(in_last!=(fill_index==expected[fill_slot]-1))error_q<=1;
       else begin
         fill_index<=fill_index+1'b1;
         if(in_last)begin full[fill_slot]<=1;fill_active<=0;fill_slot<=!fill_slot;end
       end
     end
     if(state==IDLE&&full[send_slot])begin state<=HEADER;send_index<=0;end
     if(header_take)state<=DATA;
     if(data_take)begin send_index<=send_index+1'b1;if(out_last)state<=COMMIT;end
     if(commit_valid&&commit_ready)begin
       if(!commit_matches(commit,headers[send_slot]))error_q<=1;
       else begin full[send_slot]<=0;occupied[send_slot]<=0;send_slot<=!send_slot;state<=IDLE;end
     end
   end
 end
endmodule
