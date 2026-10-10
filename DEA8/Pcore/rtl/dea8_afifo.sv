import pcore_pkg::*;

// One logical 64-entry FIFO.  It accepts two consecutive A2 entries from an
// XBC4 beat and emits at most one entry per cycle to the MXU.
module dea8_afifo #(parameter int DEPTH=AFIFO_DEPTH,parameter bit STREAMING=0,parameter bit DYNAMIC_STREAMING=0) (
  input logic clk,reset,clear,
  input logic streaming_mode,
  input logic [PAIR_BITS:0] pairs_cfg,
  input logic [PAIR_BITS:0] rows_cfg,
  input logic [1:0] in_valid,
  output logic [1:0] in_ready,
  input a2_t in_entry[0:1],
  input logic reserve_tile,
  output logic tile_available,running,out_valid,
  output a2_t out_entry,
  output logic protocol_error,
  output logic [$clog2(DEPTH+1)-1:0] count,
  // The configured M can be smaller than the architectural default.  Size
  // the credit counter for the FIFO capacity rather than for one fixed
  // 51-row configuration.
  output logic [$clog2(DEPTH+1)-1:0] complete_tiles
);
  localparam int PTR_BITS=$clog2(DEPTH);
  logic [PTR_BITS-1:0] head,tail;
  // Consecutive logical words land in opposite single-write physical banks.
  (* ram_style="block" *) logic [287:0] mem_even[0:DEPTH/2-1];
  (* ram_style="block" *) logic [287:0] mem_odd [0:DEPTH/2-1];
  logic [287:0] even_q,odd_q,bypass_q;
  logic bypass_valid_q,read_parity_q;
  logic [PTR_BITS-1:0] read_head,tail1;
  logic even_we,odd_we;
  logic [PTR_BITS-2:0] even_wa,odd_wa;
  logic [287:0] even_wd,odd_wd;
  logic [PAIR_BITS-1:0] expected_pair;
  logic [TILE_BITS-1:0] expected_tile;
  logic expected_slot;
  logic have_context;
  logic [PAIR_BITS-1:0] next_pair;
  logic [TILE_BITS-1:0] next_tile;
  logic push0,push1,pop_fire,reserve_fire;
  logic bad0,bad1,finish0,finish1;
  logic [$clog2(DEPTH+1):0] space;
  logic rollover_available;
  logic [PAIR_BITS:0] active_pairs;
  logic [1:0] expected_mask;
  wire stream_enabled=DYNAMIC_STREAMING?streaming_mode:STREAMING;

  assign active_pairs=(pairs_cfg==0)?PAIRS: pairs_cfg;
  assign expected_mask=(expected_pair==active_pairs-1 && rows_cfg[0]) ? 2'b01 : 2'b11;
  assign read_head=head+PTR_BITS'(pop_fire);
  assign tail1=tail+PTR_BITS'(push0);
  assign even_we=(push0&&!tail[0])||(push1&&!tail1[0]);
  assign odd_we=(push0&&tail[0])||(push1&&tail1[0]);
  assign even_wa=(push0&&!tail[0])?tail[PTR_BITS-1:1]:tail1[PTR_BITS-1:1];
  assign odd_wa=(push0&&tail[0])?tail[PTR_BITS-1:1]:tail1[PTR_BITS-1:1];
  assign even_wd=(push0&&!tail[0])?in_entry[0]:in_entry[1];
  assign odd_wd=(push0&&tail[0])?in_entry[0]:in_entry[1];
  always_ff @(posedge clk) begin
    even_q<=mem_even[read_head[PTR_BITS-1:1]];
    odd_q<=mem_odd[read_head[PTR_BITS-1:1]];
    if(even_we) mem_even[even_wa]<=even_wd;
    if(odd_we) mem_odd[odd_wa]<=odd_wd;
    read_parity_q<=read_head[0];
    bypass_valid_q<=(push0&&tail==read_head)||(push1&&tail1==read_head);
    if(push0&&tail==read_head) bypass_q<=in_entry[0];
    else if(push1&&tail1==read_head) bypass_q<=in_entry[1];
  end
  assign out_entry=a2_t'(bypass_valid_q?bypass_q:(read_parity_q?odd_q:even_q));
  assign out_valid=running && (count!=0);
  assign rollover_available=running&&out_valid&&out_entry.pair_idx==active_pairs-1&&
    complete_tiles!=0&&count>=active_pairs+1;
  assign tile_available=!reset && !clear &&
    (stream_enabled ? (count>=4) :
    ((!running&&complete_tiles!=0&&count>=active_pairs)||rollover_available));
  assign pop_fire=out_valid;
  assign reserve_fire=reserve_tile && tile_available;
  assign space=DEPTH-count+pop_fire;
  assign in_ready[0]=!reset && !clear && !protocol_error && space>=1;
  // Both lanes are advertised from available space only.  Depending lane1
  // ready on lane0 valid would close a combinational loop through XBC4 ready.
  assign in_ready[1]=in_ready[0] && space>=2;
  assign push0=in_valid[0] && in_ready[0];
  assign push1=in_valid[1] && in_ready[1];

  assign finish0=push0 && expected_pair==active_pairs-1;
  assign next_pair=finish0 ? '0 : expected_pair+1'b1;
  assign next_tile=finish0 ? expected_tile+1'b1 : expected_tile;
  assign finish1=push1 && next_pair==active_pairs-1;
  // slot identifies the producer-side QOZ/PBUF bank and may legitimately
  // change at a Job boundary.  FIFO order is checked with pair/tile/row mask;
  // bank ownership is checked by Matrix Core against the command stream ID.
  assign bad0=push0 && (in_entry[0].pair_idx!=expected_pair ||
    in_entry[0].tile_idx!=expected_tile ||
    in_entry[0].row_valid!=expected_mask || in_entry[0].reserved!=0);
  assign bad1=push1 && (in_entry[1].pair_idx!=next_pair ||
    in_entry[1].tile_idx!=next_tile ||
    in_entry[1].row_valid!=((next_pair==active_pairs-1 && rows_cfg[0]) ? 2'b01 : 2'b11) ||
    in_entry[1].reserved!=0);

  always_ff @(posedge clk) begin
    if(reset || clear) begin
      head<='0;tail<='0;count<='0;complete_tiles<='0;running<=0;
      expected_pair<='0;expected_tile<='0;expected_slot<=0;have_context<=0;protocol_error<=0;
    end else begin
      if(bad0||bad1) protocol_error<=1;
      if(push0||push1) tail<=tail+push0+push1;
      if(pop_fire) head<=head+1'b1;
      case({push0,push1,pop_fire})
        3'b100,3'b010: count<=count+1'b1;
        3'b110: count<=count+2'd2;
        3'b001: count<=count-1'b1;
        3'b101,3'b011: count<=count;
        3'b111: count<=count+1'b1;
        default: ;
      endcase
      case({finish0,finish1,stream_enabled?(pop_fire&&out_entry.pair_idx==active_pairs-1):reserve_fire})
        3'b100,3'b010,3'b110: complete_tiles<=complete_tiles+1'b1;
        3'b001: complete_tiles<=complete_tiles-1'b1;
        3'b101,3'b011: complete_tiles<=complete_tiles;
        3'b111: complete_tiles<=complete_tiles;
        default: ;
      endcase
      if(push1 && finish1) begin expected_pair<=0;expected_tile<=next_tile+1'b1;end
      else if(push0 && finish0) begin expected_pair<=0;expected_tile<=expected_tile+1'b1;end
      else if(push1) expected_pair<=next_pair+1'b1;
      else if(push0) expected_pair<=expected_pair+1'b1;
      if(push0) expected_slot<=in_entry[0].slot;
      if(push1) expected_slot<=in_entry[1].slot;
      if(push0||push1) have_context<=1;
      if(reserve_fire) begin running<=1; end
      else if(pop_fire && out_entry.pair_idx==active_pairs-1) running<=0;
    end
  end

  initial if(DEPTH<2*PAIRS || (DEPTH&(DEPTH-1))!=0) $fatal(1,"AFIFO geometry");
  // synthesis translate_off
  always @(posedge clk) if(!reset&&!clear) begin
    if((bad0||bad1)) $fatal(1,"AFIFO A4/A2 order or mask mismatch p0=%0d/%0d t0=%0d/%0d rv0=%b/%b p1=%0d/%0d t1=%0d/%0d rv1=%b/%b active=%0d rows=%0d",
      in_entry[0].pair_idx,expected_pair,in_entry[0].tile_idx,expected_tile,in_entry[0].row_valid,expected_mask,
      in_entry[1].pair_idx,next_pair,in_entry[1].tile_idx,next_tile,in_entry[1].row_valid,
      ((next_pair==active_pairs-1&&rows_cfg[0])?2'b01:2'b11),active_pairs,rows_cfg);
    if(reserve_tile&&!tile_available) $fatal(1,"AFIFO reserve without complete Tile");
    if(pop_fire&&!out_valid) $fatal(1,"AFIFO underflow");
    if(stream_enabled&&running&&count==0) $fatal(1,"Committed local source violated streaming credit guarantee");
  end
  // synthesis translate_on
endmodule
