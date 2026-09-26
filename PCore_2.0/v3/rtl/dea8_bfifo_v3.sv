import pcore3_pkg::*;

// B2 FIFO. Eight ordered B2 entries form one complete stationary-weight Tile.
module dea8_bfifo_v3 #(parameter int DEPTH=BFIFO_DEPTH) (
  input logic clk,reset,clear,
  input logic in_valid,
  output logic in_ready,
  input b2_t in_entry,
  output logic out_valid,
  input logic out_ready,
  output b2_t out_entry,
  output logic tile_available,
  output logic protocol_error,
  output logic [$clog2(DEPTH+1)-1:0] count,
  output logic [$clog2(DEPTH/8+1)-1:0] complete_tiles
);
  localparam int PTR_BITS=$clog2(DEPTH);
  b2_t mem[0:DEPTH-1];
  logic [PTR_BITS-1:0] head,tail;
  logic [2:0] expected_group;
  logic [TILE_BITS-1:0] expected_tile;
  logic [EPOCH_BITS-1:0] expected_epoch;
  logic have_context;
  logic pop_fire,bad;
  assign out_entry=mem[head];
  assign out_valid=count!=0;
  assign tile_available=!reset&&!clear&&!protocol_error&&complete_tiles!=0&&count>=8;
  assign in_ready=!reset&&!clear&&!protocol_error&&count<DEPTH;
  assign pop_fire=out_valid&&out_ready;
  assign bad=in_valid&&in_ready&&(in_entry.group_idx!=expected_group ||
    in_entry.tile_idx!=expected_tile || (have_context&&in_entry.epoch!=expected_epoch) ||
    in_entry.reserved!=0);
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      head<='0;tail<='0;count<='0;complete_tiles<='0;
      expected_group<='0;expected_tile<='0;expected_epoch<='0;have_context<=0;protocol_error<=0;
    end else begin
      if(bad) protocol_error<=1;
      if(in_valid&&in_ready&&!bad) begin
        mem[tail]<=in_entry;tail<=tail+1'b1;
        have_context<=1;
        if(expected_group==7) begin expected_group<=0;expected_tile<=expected_tile+1'b1;end
        else expected_group<=expected_group+1'b1;
        expected_epoch<=in_entry.epoch;
      end
      if(pop_fire) head<=head+1'b1;
      case({in_valid&&in_ready&&!bad,pop_fire})
        2'b10: count<=count+1'b1;
        2'b01: count<=count-1'b1;
        default: ;
      endcase
      if(in_valid&&in_ready&&!bad&&in_entry.group_idx==7) complete_tiles<=complete_tiles+1'b1;
      if(pop_fire&&out_entry.group_idx==7) complete_tiles<=complete_tiles-1'b1;
    end
  end
  initial if(DEPTH<8 || (DEPTH&(DEPTH-1))!=0) $fatal(1,"BFIFO geometry");
  // synthesis translate_off
  always @(posedge clk) if(!reset&&!clear) begin
    if(bad) $fatal(1,"BFIFO B2 group/tile/epoch order mismatch");
    if(pop_fire&&!out_valid) $fatal(1,"BFIFO underflow");
  end
  // synthesis translate_on
endmodule
