// Test-only packet decoder. Existing numerical scoreboards retain their
// row/vector checks while the real PCore exposes only its 256-bit link.
module tb_packet_decode (
  input logic clk,reset,clear,
  input logic tx_valid,output logic tx_ready,input logic [255:0] tx_data,input logic tx_last,
  output logic kv_hdr_valid,input logic kv_hdr_ready,output dea8_tile_link_pkg::tile_header_t kv_hdr,
  output logic kv_out_valid,input logic kv_out_ready,output logic [135:0] kv_out,output logic kv_out_last,
  output logic reduce_hdr_valid,input logic reduce_hdr_ready,output dea8_tile_link_pkg::tile_header_t reduce_hdr,
  output logic reduce_out_valid,input logic reduce_out_ready,output logic [511:0] reduce_out,output logic reduce_out_last
);
  import dea8_tile_link_pkg::*;
  logic payload_q,kv_q,half_q;
  logic [255:0] low_q;
  tile_header_t h;
  always_comb begin
    h=tile_header_t'(tx_data[127:0]);h.reserved=0;
    kv_hdr=h;reduce_hdr=h;
    kv_hdr_valid=tx_valid&&!payload_q&&(h.kind==TILE_K||h.kind==TILE_V);
    reduce_hdr_valid=tx_valid&&!payload_q&&(h.kind==TILE_O||h.kind==TILE_DOWN);
    kv_out_valid=tx_valid&&payload_q&&kv_q;kv_out=tx_data[135:0];kv_out_last=tx_last;
    reduce_out_valid=tx_valid&&payload_q&&!kv_q&&half_q;reduce_out={tx_data,low_q};reduce_out_last=tx_last;
    tx_ready=!payload_q?(h.kind==TILE_K||h.kind==TILE_V?kv_hdr_ready:reduce_hdr_ready):
      (kv_q?kv_out_ready:(!half_q||reduce_out_ready));
  end
  always @(posedge clk)begin
    if(reset||clear)begin payload_q<=0;kv_q<=0;half_q<=0;low_q<=0;end
    else if(tx_valid&&tx_ready)begin
      if(!payload_q)begin
        if(!packet_header_legal(tx_data)||tx_last)$fatal(1,"PCore invalid wire header");
        payload_q<=1;kv_q<=h.kind==TILE_K||h.kind==TILE_V;half_q<=0;
      end else begin
        if(!kv_q)begin if(!half_q)low_q<=tx_data;half_q<=!half_q;end
        if(tx_last)begin
          if(!kv_q&&!half_q)$fatal(1,"PCore FP32 packet ended on low half");
          payload_q<=0;
        end
      end
    end
  end
endmodule
