import pcore_pkg::*;

module dea8_b_queue (
  input logic clk,reset,clear,
  input logic desc_valid,output logic desc_ready,input b_packet_desc_t desc,
  input logic in_valid,output logic in_ready,input logic [B_BEAT_BITS-1:0] in_data,
  input b_beat_tag_t in_tag,
  output logic out_valid,input logic out_ready,output b4_t out_entry,
  output logic empty,protocol_error,
  output logic [$clog2(B_SLOTS+1)-1:0] used_slots
);
  localparam int SLOT_BITS=$clog2(B_SLOTS);
  (* ram_style="block" *) logic [B_BEAT_BITS-1:0] data_mem[0:B_SLOTS*B_LOAD_GROUPS-1];
  logic [TILE-1:0][SCALE_BITS-1:0] scales[B_SLOTS];
  b_packet_desc_t meta[B_SLOTS],fill_desc,hold_desc;
  logic [B_SLOTS-1:0] ready_q;
  logic [SLOT_BITS-1:0] wptr,fetch_slot,fill_base,hold_slot;
  logic [B_GROUP_BITS-1:0] fetch_group,hold_group;
  logic fill_open,hold_valid,desc_legal,in_legal,read_fire,out_fire,free_fire;
  logic reserve_fire,in_fire,can_advance;
  logic [B_BEAT_INDEX_BITS-1:0] fill_beat;
  logic [B_BEAT_BITS-1:0] data_hold;
  logic [TILE-1:0][SCALE_BITS-1:0] scale_hold;
  int packet_count,fill_count,write_slot,write_group;

  function automatic logic [SLOT_BITS-1:0] advance(input logic [SLOT_BITS-1:0] p,input int n);
    return SLOT_BITS'((int'(p)+n)%B_SLOTS);
  endfunction
  always_comb begin
    packet_count=b_packet_tiles(desc.source);fill_count=b_packet_tiles(fill_desc.source);
    desc_legal=desc.source<=B_KVB&&desc.mode<=MAT_GU&&desc.role<=ROLE_UP&&
      int'(desc.first_tile)+packet_count<=(1<<SEQ_BITS);
    in_legal=fill_open&&in_tag.token==fill_desc.token&&in_tag.work_seq==fill_desc.work_seq&&
      in_tag.packet_seq==fill_desc.packet_seq&&in_tag.beat_idx==fill_beat&&
      in_tag.last==(int'(fill_beat)==fill_count*B_LOAD_GROUPS);
    if(fill_desc.source==B_KVB&&fill_beat==0)
      in_legal=in_legal&&in_data[B_BEAT_BITS-1-:B_PACKET_BITS]==B_PACKET_BITS'(fill_desc);
    write_slot=int'(advance(fill_base,(int'(fill_beat)-1)/B_LOAD_GROUPS));
    write_group=(int'(fill_beat)-1)%B_LOAD_GROUPS;
  end
  assign desc_ready=!reset&&!clear&&!protocol_error&&!fill_open&&desc_legal&&
    int'(used_slots)+packet_count<=B_SLOTS;
  assign reserve_fire=desc_valid&&desc_ready;
  assign in_ready=!reset&&!clear&&!protocol_error&&in_legal;
  assign in_fire=in_valid&&in_ready;
  assign out_valid=hold_valid&&!reset&&!clear&&!protocol_error;
  assign out_fire=out_valid&&out_ready;
  assign free_fire=out_fire&&hold_group==B_LOAD_GROUPS-1;
  assign can_advance=!hold_valid||out_fire;
  assign read_fire=!reset&&!clear&&!protocol_error&&can_advance&&ready_q[fetch_slot];
  assign empty=used_slots==0&&!fill_open&&!hold_valid;
  always_comb begin
    out_entry='0;out_entry.token=hold_desc.token;out_entry.work_seq=hold_desc.work_seq;
    out_entry.tile_idx=hold_desc.first_tile;out_entry.role=hold_desc.mode==MAT_GU?
      (hold_desc.first_tile[0]?ROLE_UP:ROLE_GATE):hold_desc.role;
    out_entry.bank=hold_desc.first_tile[0];out_entry.group_idx=hold_group;
    out_entry.data=data_hold;out_entry.scales=scale_hold;
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      wptr<=0;fetch_slot<=0;fill_base<=0;hold_slot<=0;
      fetch_group<=0;hold_group<=0;fill_open<=0;fill_beat<=0;
      fill_desc<='0;hold_desc<='0;hold_valid<=0;ready_q<=0;used_slots<=0;protocol_error<=0;
    end else begin
      if(desc_valid&&!desc_legal)protocol_error<=1;
      if(in_valid&&fill_open&&!in_legal)protocol_error<=1;
      if(reserve_fire||free_fire)
        used_slots<=int'(used_slots)+(reserve_fire?packet_count:0)-(free_fire?1:0);
      if(reserve_fire)begin
        fill_desc<=desc;fill_base<=wptr;fill_open<=1;fill_beat<=0;
        wptr<=advance(wptr,packet_count);
        for(int t=0;t<B_PACKET_MAX_TILES;t++)if(t<packet_count)begin
          b_packet_desc_t tile_desc;
          tile_desc=desc;tile_desc.first_tile=desc.first_tile+SEQ_BITS'(t);
          meta[advance(wptr,t)]<=tile_desc;
        end
      end
      if(in_fire)begin
        if(fill_beat==0)begin
          for(int t=0;t<B_PACKET_MAX_TILES;t++)if(t<fill_count)
            scales[advance(fill_base,t)]<=in_data[t*TILE*SCALE_BITS+:TILE*SCALE_BITS];
        end else begin
          data_mem[write_slot*B_LOAD_GROUPS+write_group]<=in_data;
          if(write_group==B_LOAD_GROUPS-1)ready_q[write_slot]<=1;
        end
        if(int'(fill_beat)==fill_count*B_LOAD_GROUPS)fill_open<=0;
        else fill_beat<=fill_beat+1'b1;
      end
      if(free_fire)ready_q[hold_slot]<=0;
      if(can_advance)hold_valid<=read_fire;
      if(read_fire)begin
        data_hold<=data_mem[int'(fetch_slot)*B_LOAD_GROUPS+int'(fetch_group)];
        scale_hold<=fetch_group==0?scales[fetch_slot]:'0;
        hold_desc<=meta[fetch_slot];hold_slot<=fetch_slot;hold_group<=fetch_group;
        if(fetch_group==B_LOAD_GROUPS-1)begin fetch_group<=0;fetch_slot<=advance(fetch_slot,1);end
        else fetch_group<=fetch_group+1'b1;
      end
    end
  end
  // synthesis translate_off
  initial if(B_PACKET_BITS<$bits(b_packet_desc_t)||B_BEAT_BITS!=512||B_SLOTS<B_PACKET_MAX_TILES)
    $fatal(1,"B packet/queue geometry");
  // synthesis translate_on
endmodule
