import pcore3_pkg::*;

// One logical 64-entry FIFO.  It accepts two consecutive A2 entries from an
// XBC4 beat and emits at most one entry per cycle to the MXU.
module dea8_afifo_v3 #(parameter int DEPTH=AFIFO_DEPTH) (
  input logic clk,reset,clear,
  input logic [1:0] in_valid,
  output logic [1:0] in_ready,
  input a2_t in_entry[0:1],
  input logic reserve_tile,
  output logic tile_available,running,out_valid,
  output a2_t out_entry,
  output logic protocol_error,
  output logic [$clog2(DEPTH+1)-1:0] count,
  output logic [$clog2(DEPTH/PAIRS+1)-1:0] complete_tiles
);
  localparam int PTR_BITS=$clog2(DEPTH);
  logic [PTR_BITS-1:0] head,tail;
  a2_t mem[0:DEPTH-1];
  logic [PAIR_BITS-1:0] expected_pair;
  logic [TILE_BITS-1:0] expected_tile;
  logic expected_slot;
  logic have_context;
  logic [PAIR_BITS-1:0] next_pair;
  logic [TILE_BITS-1:0] next_tile;
  logic push0,push1,pop_fire,reserve_fire;
  logic bad0,bad1,finish0,finish1;
  logic [$clog2(DEPTH+1):0] space;

  assign out_entry=mem[head];
  assign out_valid=running && (count!=0);
  assign tile_available=!reset && !clear && !running && complete_tiles!=0 && count>=PAIRS;
  assign pop_fire=out_valid;
  assign reserve_fire=reserve_tile && tile_available;
  assign space=DEPTH-count+pop_fire;
  assign in_ready[0]=!reset && !clear && !protocol_error && space>=1;
  // Both lanes are advertised from available space only.  Depending lane1
  // ready on lane0 valid would close a combinational loop through XBC4 ready.
  assign in_ready[1]=in_ready[0] && space>=2;
  assign push0=in_valid[0] && in_ready[0];
  assign push1=in_valid[1] && in_ready[1];

  assign finish0=push0 && expected_pair==PAIRS-1;
  assign next_pair=finish0 ? '0 : expected_pair+1'b1;
  assign next_tile=finish0 ? expected_tile+1'b1 : expected_tile;
  assign finish1=push1 && next_pair==PAIRS-1;
  assign bad0=push0 && (in_entry[0].pair_idx!=expected_pair ||
    in_entry[0].tile_idx!=expected_tile || (have_context && in_entry[0].slot!=expected_slot) ||
    in_entry[0].row_valid!=row_mask(expected_pair) || in_entry[0].reserved!=0);
  assign bad1=push1 && (in_entry[1].pair_idx!=next_pair ||
    in_entry[1].tile_idx!=next_tile || (have_context && in_entry[1].slot!=expected_slot) ||
    in_entry[1].row_valid!=row_mask(next_pair) || in_entry[1].reserved!=0);

  always_ff @(posedge clk) begin
    if(reset || clear) begin
      head<='0;tail<='0;count<='0;complete_tiles<='0;running<=0;
      expected_pair<='0;expected_tile<='0;expected_slot<=0;have_context<=0;protocol_error<=0;
    end else begin
      if(bad0||bad1) protocol_error<=1;
      if(push0) begin mem[tail]<=in_entry[0]; tail<=tail+1'b1; end
      if(push1) begin mem[tail+push0]<=in_entry[1]; tail<=tail+push0+1'b1; end
      if(pop_fire) head<=head+1'b1;
      case({push0,push1,pop_fire})
        3'b100,3'b010: count<=count+1'b1;
        3'b110: count<=count+2'd2;
        3'b001: count<=count-1'b1;
        3'b101,3'b011: count<=count;
        3'b111: count<=count+1'b1;
        default: ;
      endcase
      case({finish0,finish1,reserve_fire})
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
      else if(pop_fire && out_entry.pair_idx==PAIRS-1) running<=0;
    end
  end

  initial if(DEPTH<2*PAIRS || (DEPTH&(DEPTH-1))!=0) $fatal(1,"AFIFO geometry");
  // synthesis translate_off
  always @(posedge clk) if(!reset&&!clear) begin
    if((bad0||bad1)) $fatal(1,"AFIFO A4/A2 order or mask mismatch");
    if(reserve_tile&&!tile_available) $fatal(1,"AFIFO reserve without complete Tile");
    if(pop_fire&&!out_valid) $fatal(1,"AFIFO underflow");
  end
  // synthesis translate_on
endmodule
