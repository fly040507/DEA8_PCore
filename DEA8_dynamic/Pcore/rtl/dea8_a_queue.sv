import pcore_pkg::*;

module dea8_a_queue (
  input logic clk,reset,clear,
  input logic desc_valid,output logic desc_ready,input a_slot_desc_t desc,
  input logic in_valid,output logic in_ready,input a3_beat_t in_entry,
  output logic out_valid,input logic out_ready,output a2_t out_entry,
  output logic tile_available,empty,protocol_error,
  output logic input_closed,
  output logic [$clog2(A_SLOTS+1)-1:0] used_slots
);
  a_slot_desc_t slots[A_SLOTS],hold_desc;
  logic [A_SLOTS-1:0] ready_q;
  logic [A_SLOT_BITS-1:0] wptr,fetch_slot,fill_slot,hold_slot;
  logic fill_open,hold_valid,desc_legal,in_legal,store_error,error_q;
  logic [A_GROUP_BITS-1:0] fill_group;
  logic [PAIR_BITS-1:0] fetch_pair,hold_pair;
  logic [4:0] fetch_use,hold_use;
  logic reserve_fire,in_fire,out_fire,read_fire,free_fire,can_advance;
  logic store_wr_ready,store_rd_ready,store_out_valid;
  logic [A_INPUT_ROWS-1:0][ROW_COUNT_BITS-1:0] wr_rows,rd_rows;
  logic [A_INPUT_ROWS-1:0] rd_mask;
  qvec16_t [A_INPUT_ROWS-1:0] read_data;

  function automatic logic [A_SLOT_BITS-1:0] next_slot(input logic [A_SLOT_BITS-1:0] p);
    return p==A_SLOTS-1?'0:p+1'b1;
  endfunction
  always_comb begin
    desc_legal=desc.m_rows>0&&desc.m_rows<=ROWS&&desc.uses>0&&desc.uses<=TILE;
    in_legal=0;
    if(fill_open&&fill_slot<A_SLOTS)begin
      in_legal=in_entry.token==slots[fill_slot].token&&
        in_entry.work_seq==slots[fill_slot].work_seq&&
        in_entry.occurrence_seq==slots[fill_slot].occurrence_seq&&
        in_entry.group_idx==fill_group&&
        in_entry.row_valid==a_group_mask(slots[fill_slot].m_rows,fill_group);
    end
    wr_rows='0;rd_rows='0;rd_mask='0;
    for(int i=0;i<A_INPUT_ROWS;i++)wr_rows[i]=ROW_COUNT_BITS'(int'(fill_group)*A_INPUT_ROWS+i);
    for(int i=0;i<ROW_LANES;i++)begin
      rd_rows[i]=ROW_COUNT_BITS'(int'(fetch_pair)*ROW_LANES+i);
      if(fetch_slot<A_SLOTS&&ready_q[fetch_slot])
        rd_mask[i]=int'(fetch_pair)*ROW_LANES+i<int'(slots[fetch_slot].m_rows);
    end
  end
  assign protocol_error=store_error||error_q;
  assign desc_ready=!reset&&!clear&&!protocol_error&&!fill_open&&used_slots<A_SLOTS&&desc_legal;
  assign reserve_fire=desc_valid&&desc_ready;
  assign in_ready=!reset&&!clear&&!protocol_error&&in_legal&&store_wr_ready;
  assign in_fire=in_valid&&in_ready;
  assign out_valid=hold_valid&&!reset&&!clear&&!protocol_error;
  assign out_fire=out_valid&&out_ready;
  assign can_advance=!hold_valid||out_fire;
  assign read_fire=!reset&&!clear&&!protocol_error&&can_advance&&ready_q[fetch_slot]&&store_rd_ready;
  assign free_fire=out_fire&&int'(hold_pair)+1==pairs_for_rows(hold_desc.m_rows)&&
    int'(hold_use)+1==int'(hold_desc.uses);
  assign tile_available=out_valid&&hold_pair==0;
  assign empty=used_slots==0&&!fill_open&&!hold_valid;
  assign input_closed=!fill_open;

  always_comb begin
    out_entry='0;
    out_entry.token=hold_desc.token;out_entry.work_seq=hold_desc.work_seq;
    out_entry.tile_idx=hold_desc.first_tile+SEQ_BITS'(hold_use);
    out_entry.pair_idx=hold_pair;out_entry.row_valid=row_mask_for_rows(hold_desc.m_rows,hold_pair);
    for(int i=0;i<ROW_LANES;i++)out_entry.row[i]=read_data[i];
  end
  dea8_row3_store #(.TILES(A_SLOTS)) storage(
    .clk,.reset,.clear,.wr_valid(in_fire),.wr_ready(store_wr_ready),.wr_tile(fill_slot),
    .wr_row(wr_rows),.wr_mask(in_entry.row_valid),.wr_entry(in_entry.row),
    .rd_valid(read_fire),.rd_ready(store_rd_ready),.rd_tile(fetch_slot),.rd_row(rd_rows),.rd_mask,
    .out_valid(store_out_valid),.out_entry(read_data),.protocol_error(store_error));

  always_ff @(posedge clk)begin
    if(reset||clear)begin
      wptr<=0;fetch_slot<=0;fill_slot<=0;fill_open<=0;fill_group<=0;
      hold_valid<=0;hold_desc<='0;hold_pair<=0;hold_use<=0;hold_slot<=0;
      fetch_pair<=0;fetch_use<=0;ready_q<=0;used_slots<=0;error_q<=0;
    end else begin
      if(desc_valid&&!desc_legal)error_q<=1;
      if(in_valid&&fill_open&&!in_legal)error_q<=1;
      case({reserve_fire,free_fire})
        2'b10:used_slots<=used_slots+1'b1;
        2'b01:used_slots<=used_slots-1'b1;
        default:;
      endcase
      if(reserve_fire)begin
        slots[wptr]<=desc;fill_slot<=wptr;wptr<=next_slot(wptr);
        fill_open<=1;fill_group<=0;
      end
      if(in_fire)begin
        if((int'(fill_group)+1)*A_INPUT_ROWS>=int'(slots[fill_slot].m_rows))begin
          ready_q[fill_slot]<=1;fill_open<=0;
        end else fill_group<=fill_group+1'b1;
      end
      if(free_fire)ready_q[hold_slot]<=0;
      if(can_advance)hold_valid<=read_fire;
      if(read_fire)begin
        hold_desc<=slots[fetch_slot];hold_slot<=fetch_slot;
        hold_pair<=fetch_pair;hold_use<=fetch_use;
        if(int'(fetch_pair)+1==pairs_for_rows(slots[fetch_slot].m_rows))begin
          fetch_pair<=0;
          if(int'(fetch_use)+1==int'(slots[fetch_slot].uses))begin
            fetch_use<=0;fetch_slot<=next_slot(fetch_slot);
          end else fetch_use<=fetch_use+1'b1;
        end else fetch_pair<=fetch_pair+1'b1;
      end
    end
  end
endmodule
