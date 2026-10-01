import pcore3_pkg::*;

// Shared physical Q/O/Z storage.  Q and O use disjoint 16-tile logical
// regions; Z uses the full 32-tile region and therefore maps Z(n) to tile n.
// Only one region owner is active at a time in the serialized single-core
// chain, which makes release/complete a clear ownership boundary.
module dea8_qoz_store_v3 #(
  parameter int PHYSICAL_TILES=32
) (
  input logic clk,reset,clear,
  input logic region_begin_valid,output logic region_begin_ready,
  input qoz_owner_e region_owner,
  input logic [EPOCH_BITS-1:0] region_epoch,input logic [2:0] region_head,
  input logic [5:0] region_tiles,
  output logic region_active,output logic region_complete,
  input logic region_release_valid,output logic region_release_ready,
  input logic wr_valid,output logic wr_ready,input qoz_owner_e wr_owner,
  input logic [5:0] wr_tile,input logic [PAIR_BITS-1:0] wr_pair,
  input logic [1:0] wr_row_valid,input qvec16_t wr_even,input qvec16_t wr_odd,
  input logic [EPOCH_BITS-1:0] wr_epoch,input logic [2:0] wr_head,
  input logic rd_valid,output logic rd_ready,input qoz_owner_e rd_owner,
  input logic [5:0] rd_tile,input logic [PAIR_BITS-1:0] rd_pair,
  input logic [TILE_BITS-1:0] rd_transport,
  output logic rd_out_valid,input logic rd_out_ready,output a2_t rd_entry,
  output logic [EPOCH_BITS-1:0] active_epoch,output logic [2:0] active_head,
  output qoz_owner_e active_owner,output logic protocol_error
);
  (* ram_style="block" *) logic [135:0] data_mem[0:PHYSICAL_TILES-1][0:PAIRS-1][0:1];
  logic [PAIRS-1:0] written[0:PHYSICAL_TILES-1];
  logic [5:0] logical_tiles_q;
  logic [5:0] physical_base;
  logic [EPOCH_BITS-1:0] epoch_q;
  logic [2:0] head_q;
  qoz_owner_e owner_q;
  logic complete_q;
  logic [5:0] rd_physical_tile;
  logic [5:0] rd_request_physical_tile;
  logic [5:0] rd_tile_q;
  logic [PAIR_BITS-1:0] rd_pair_q;
  logic [TILE_BITS-1:0] rd_transport_q;
  logic rd_fire,wr_fire,begin_fire,release_fire;

  function automatic logic owner_ok(input qoz_owner_e o);
    return o==QOZ_Q||o==QOZ_O||o==QOZ_Z;
  endfunction
  function automatic logic [5:0] owner_base(input qoz_owner_e o);
    return o==QOZ_O ? 6'd16 : 6'd0;
  endfunction
  function automatic logic [5:0] owner_capacity(input qoz_owner_e o);
    return o==QOZ_Z ? 6'd32 : 6'd16;
  endfunction

  assign region_active=owner_q!=QOZ_NONE;
  assign region_complete=complete_q;
  assign active_owner=owner_q;assign active_epoch=epoch_q;assign active_head=head_q;
  assign region_begin_ready=!reset&&!clear&&!region_active&&
    owner_ok(region_owner)&&region_tiles!=0&&region_tiles<=owner_capacity(region_owner);
  assign region_release_ready=!reset&&!clear&&region_active&&complete_q;
  assign begin_fire=region_begin_valid&&region_begin_ready;
  assign release_fire=region_release_valid&&region_release_ready;
  assign rd_request_physical_tile=physical_base+rd_tile;
  assign rd_physical_tile=physical_base+rd_tile_q;
  assign rd_ready=!reset&&!clear&&!protocol_error&&region_complete&&
    rd_owner==owner_q&&rd_tile<logical_tiles_q&&rd_pair<PAIRS&&
    rd_request_physical_tile<PHYSICAL_TILES&&(!rd_out_valid||rd_out_ready);
  assign rd_fire=rd_valid&&rd_ready;
  assign wr_ready=!reset&&!clear&&!protocol_error&&region_active&&!complete_q&&
    wr_owner==owner_q&&wr_epoch==epoch_q&&wr_head==head_q&&
    wr_tile<logical_tiles_q&&wr_pair<PAIRS&&wr_row_valid==row_mask(wr_pair)&&
    physical_base+wr_tile<PHYSICAL_TILES&&!written[physical_base+wr_tile][wr_pair];
  assign wr_fire=wr_valid&&wr_ready;

  always_comb begin
    rd_entry='0;rd_entry.tile_idx=rd_transport_q;rd_entry.pair_idx=rd_pair_q;
    rd_entry.row_valid=row_mask(rd_pair_q);rd_entry.slot=0;
    if(rd_out_valid) begin
      rd_entry.row[0]=qvec16_t'(data_mem[rd_physical_tile][rd_pair][0]);
      rd_entry.row[1]=qvec16_t'(data_mem[rd_physical_tile][rd_pair][1]);
    end
  end

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      owner_q<=QOZ_NONE;complete_q<=0;logical_tiles_q<=0;physical_base<=0;
      epoch_q<=0;head_q<=0;rd_out_valid<=0;protocol_error<=0;
      rd_tile_q<=0;rd_pair_q<=0;rd_transport_q<=0;
      for(int t=0;t<PHYSICAL_TILES;t++) written[t]<='0;
    end else begin
      if(region_begin_valid&&!region_begin_ready) protocol_error<=1;
      if(wr_valid&&!wr_ready) protocol_error<=1;
      if(rd_valid&&!rd_ready) protocol_error<=1;
      if(region_release_valid&&!region_release_ready) protocol_error<=1;
      if(begin_fire) begin
        owner_q<=region_owner;complete_q<=0;logical_tiles_q<=region_tiles;
        physical_base<=owner_base(region_owner);epoch_q<=region_epoch;head_q<=region_head;
        for(int t=0;t<PHYSICAL_TILES;t++) written[t]<='0;
      end
      if(wr_fire) begin
        data_mem[physical_base+wr_tile][wr_pair][0]<=wr_even;
        data_mem[physical_base+wr_tile][wr_pair][1]<=wr_row_valid[1]?wr_odd:'0;
        written[physical_base+wr_tile][wr_pair]<=1;
        if(wr_tile==logical_tiles_q-1&&wr_pair==PAIRS-1) complete_q<=1;
      end
      if(rd_fire) begin
        rd_tile_q<=rd_tile;
        rd_pair_q<=rd_pair;
        rd_transport_q<=rd_transport;
        rd_out_valid<=1;
      end
      else if(rd_out_valid&&rd_out_ready) rd_out_valid<=0;
      if(release_fire) begin owner_q<=QOZ_NONE;complete_q<=0;logical_tiles_q<=0;end
    end
  end
  initial if(PHYSICAL_TILES<32||PAIRS<1) $fatal(1,"QOZ geometry");
endmodule
