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
  logic [BANKS-1:0] selected_q;
  qvec16_t even_q[0:BANKS-1],odd_q[0:BANKS-1];
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
  for(genvar b=0;b<BANKS;b++) begin: banks
    (* ram_style="block" *) logic [135:0] even_mem[0:TILES*PAIRS-1];
    (* ram_style="block" *) logic [135:0] odd_mem[0:TILES*(ROWS/2)-1];
    logic [135:0] even_data_q,odd_data_q;
    logic odd_present_q;
    assign even_q[b]=qvec16_t'(even_data_q);
    assign odd_q[b]=odd_present_q?qvec16_t'(odd_data_q):qvec16_t'('0);
    always_ff @(posedge clk) begin
      if(load_valid&&load_ready&&load_entry.slot==b) begin
        even_mem[load_entry.tile_idx*PAIRS+load_entry.pair_idx]<=load_entry.row[0];
        if(load_entry.row_valid[1]) odd_mem[load_entry.tile_idx*(ROWS/2)+load_entry.pair_idx]<=load_entry.row[1];
      end
      if(rd_valid&&rd_ready&&rd_bank==b) begin
        even_data_q<=even_mem[rd_tile*PAIRS+rd_pair];
        if(rd_pair<ROWS/2) odd_data_q<=odd_mem[rd_tile*(ROWS/2)+rd_pair];
        odd_present_q<=rd_pair<ROWS/2;
      end
    end
  end
  always_comb begin
    out_entry.row='0;
    for(int b=0;b<BANKS;b++) if(selected_q[b]) begin
      out_entry.row[0]=even_q[b];out_entry.row[1]=odd_q[b];
    end
  end
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      complete<=0;protocol_error<=0;out_valid<=0;selected_q<=0;
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
        selected_q<=BANKS'(1)<<rd_bank;out_valid<=1;
        out_entry.row_valid<=row_mask(rd_pair);out_entry.pair_idx<=rd_pair;
        out_entry.tile_idx<=rd_transport;out_entry.slot<=rd_bank;out_entry.reserved<=0;
      end else if(out_valid&&out_ready) out_valid<=0;
    end
  end
endmodule
