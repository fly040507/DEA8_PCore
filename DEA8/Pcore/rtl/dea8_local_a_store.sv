import pcore_pkg::*;

// Ordered A2 producer port, parity memories, committed context descriptor and
// elastic synchronous reader. QOZ persists until clear; PBUF releases after PV.
module dea8_local_a_store #(parameter int TILES=16,BANKS=1) (
  input logic clk,reset,clear,
  input logic load_valid,output logic load_ready,input a2_t load_entry,
  input logic [EPOCH_BITS-1:0] load_epoch,input logic [2:0] load_head,
  input logic [5:0] load_block,
  input logic [BANKS-1:0] active,release_bank,
  output logic [BANKS-1:0] complete,
  output logic [EPOCH_BITS-1:0] epoch[0:BANKS-1],
  output logic [2:0] head[0:BANKS-1],
  output logic [5:0] block_id[0:BANKS-1],
  output logic protocol_error,
  input logic rd_valid,output logic rd_ready,input logic rd_bank,
  input logic [3:0] rd_tile,input logic [PAIR_BITS-1:0] rd_pair,
  input logic [TILE_BITS-1:0] rd_transport,
  output logic out_valid,input logic out_ready,output a2_t out_entry
);
  logic [TILE_BITS-1:0] next_tile[0:BANKS-1];
  logic [PAIR_BITS-1:0] next_pair[0:BANKS-1];
  logic load_bad;
  logic [135:0] even_data,odd_data;
  assign load_bad=load_entry.slot>=BANKS||load_entry.tile_idx>=TILES||
    (BANKS==2&&load_entry.slot!=load_block[0])||load_entry.reserved!=0||
    load_entry.pair_idx>=PAIRS||load_entry.row_valid!=row_mask(load_entry.pair_idx)||
    complete[load_entry.slot]||active[load_entry.slot]||
    next_tile[load_entry.slot]!=load_entry.tile_idx||next_pair[load_entry.slot]!=load_entry.pair_idx||
    ((next_tile[load_entry.slot]!=0||next_pair[load_entry.slot]!=0)&&
     (epoch[load_entry.slot]!=load_epoch||head[load_entry.slot]!=load_head||block_id[load_entry.slot]!=load_block));
  assign load_ready=!reset&&!clear&&!protocol_error&&!load_bad;
  assign rd_ready=!reset&&!clear&&!protocol_error&&(!out_valid||out_ready)&&
    rd_bank<BANKS&&complete[rd_bank]&&rd_tile<TILES&&rd_pair<PAIRS;
  for(genvar r=0;r<2;r++)begin: parity_ram
    localparam int RC=r==0?PAIRS:ROWS/2;
    localparam int DEPTH=BANKS*TILES*RC,AW=DEPTH>1?$clog2(DEPTH):1;
    wire [AW-1:0] wa=AW'((int'(load_entry.slot)*TILES+load_entry.tile_idx)*RC+load_entry.pair_idx);
    wire [AW-1:0] ra=AW'((int'(rd_bank)*TILES+rd_tile)*RC+rd_pair);
    wire [135:0] result;
    dea8_sdp_ram #(.WIDTH(136),.DEPTH(DEPTH)) memory(
      .clk,.rd_en(rd_valid&&rd_ready&&(r==0||rd_pair<ROWS/2)),.rd_addr(ra),
      .wr_en(load_valid&&load_ready&&load_entry.row_valid[r]),.wr_addr(wa),
      .wr_data(load_entry.row[r]),.rd_data(result),.dbg_addr('0),.dbg_data());
    if(r==0)assign even_data=result;else assign odd_data=result;
  end
  assign out_entry.row[0]=qvec16_t'(even_data);
  assign out_entry.row[1]=out_entry.row_valid[1]?qvec16_t'(odd_data):qvec16_t'('0);
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      complete<=0;protocol_error<=0;out_valid<=0;
      out_entry.row_valid<=0;out_entry.pair_idx<=0;out_entry.tile_idx<=0;out_entry.slot<=0;out_entry.reserved<=0;
      for(int b=0;b<BANKS;b++) begin next_tile[b]<=0;next_pair[b]<=0;epoch[b]<=0;head[b]<=0;block_id[b]<=0;end
    end else begin
      if(load_valid&&load_bad) protocol_error<=1;
      for(int b=0;b<BANKS;b++) if(release_bank[b]) complete[b]<=0;
      if(load_valid&&load_ready) begin
        epoch[load_entry.slot]<=load_epoch;head[load_entry.slot]<=load_head;block_id[load_entry.slot]<=load_block;
        if(load_entry.pair_idx==PAIRS-1) begin
          next_pair[load_entry.slot]<=0;
          if(load_entry.tile_idx==TILES-1) begin complete[load_entry.slot]<=1;next_tile[load_entry.slot]<=0;end
          else next_tile[load_entry.slot]<=load_entry.tile_idx+1'b1;
        end else next_pair[load_entry.slot]<=load_entry.pair_idx+1'b1;
      end
      if(rd_valid&&rd_ready) begin
        out_valid<=1;
        out_entry.row_valid<=row_mask(rd_pair);out_entry.pair_idx<=rd_pair;
        out_entry.tile_idx<=rd_transport;out_entry.slot<=rd_bank;out_entry.reserved<=0;
      end else if(out_valid&&out_ready) out_valid<=0;
    end
  end
endmodule
