import pcore2_pkg::*;
module dea8_a2_fifo (
  input logic clk,reset,clear,in_valid,
  output logic in_ready,
  input a2_t in_entry,
  input logic reserve_tile,
  output logic tile_available,running,out_valid,
  output a2_t out_entry,
  output logic protocol_error,
  output logic [$clog2(A_DEPTH+1)-1:0] count,
  output logic [$clog2(A_DEPTH+1)-1:0] complete_tiles
);
  logic raw_ready,raw_valid,push,finish,raw_pop,bad;
  logic [PAIR_BITS-1:0] receive_pair,consume_pair;
  logic [TILE_BITS-1:0] receive_tile;
  logic receive_slot;
  assign bad=in_valid && (in_entry.pair_idx!=receive_pair ||
    in_entry.row_valid!=row_mask(receive_pair) || in_entry.reserved!=0 ||
    (receive_pair!=0 && (in_entry.tile_idx!=receive_tile || in_entry.slot!=receive_slot)));
  assign in_ready=raw_ready && !bad && !protocol_error;
  assign push=in_valid && in_ready;
  assign finish=push && receive_pair==PAIRS-1;
  assign tile_available=!reset && !clear && !running && complete_tiles!=0 && raw_valid;
  // Reservation only changes ownership. The first entry is popped on the
  // following clock, so the consumer sees pair 0 after reserve_tile.
  assign raw_pop=running;
  assign out_valid=raw_valid && raw_pop;
  pcore2_fifo #(.WIDTH($bits(a2_t)),.DEPTH(A_DEPTH)) fifo (
    .clk,.reset,.clear,.in_valid(in_valid && !bad && !protocol_error),.in_ready(raw_ready),
    .in_data(in_entry),.out_valid(raw_valid),.out_ready(raw_pop),.out_data(out_entry),.count
  );
  always_ff @(posedge clk) begin
    if(reset || clear) begin
      complete_tiles<=0;running<=0;receive_pair<=0;consume_pair<=0;protocol_error<=0;
      receive_tile<=0;receive_slot<=0;
    end else begin
      if(bad) protocol_error<=1;
      if(push) begin
        receive_tile<=in_entry.tile_idx;receive_slot<=in_entry.slot;
        receive_pair<=finish ? '0 : receive_pair+1'b1;
      end
      case({finish,(reserve_tile && tile_available)})
        2'b10: complete_tiles<=complete_tiles+1'b1;
        2'b01: complete_tiles<=complete_tiles-1'b1;
        default: ;
      endcase
      if(reserve_tile && tile_available) begin running<=1;consume_pair<=0;end
      else if(running) begin
        if(consume_pair==PAIRS-1) begin running<=0;consume_pair<=0;end
        else consume_pair<=consume_pair+1'b1;
      end
    end
  end
  // synthesis translate_off
  initial if($bits(a2_t)!=288 || A_DEPTH<2*PAIRS) $fatal(1,"A2 FIFO geometry");
  always @(posedge clk) if(!reset && !clear) begin
    if(bad) $fatal(1,"A2 input order/mask/context");
    if(reserve_tile && !tile_available) $fatal(1,"A2 reservation without complete tile");
    if(raw_pop && !raw_valid) $fatal(1,"A2 reserved tile underflow");
    if(out_valid && out_entry.pair_idx!=(running ? consume_pair : 0)) $fatal(1,"A2 consume order");
  end
  // synthesis translate_on
endmodule
