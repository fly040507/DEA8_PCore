import pcore2_pkg::*;
// Two entries decouple the upstream RAM-ready path from downstream FIFO
// backpressure.  Once the stage is filled, the normal streaming case stays
// at one entry and accepts one item per cycle; the conservative full case
// intentionally avoids a combinational ready path through the stage.
module dea8_a_source_stage (
  input logic clk,reset,clear,
  input logic in_valid,
  output logic in_ready,
  input a2_t in_entry,
  output logic out_valid,
  input logic out_ready,
  output a2_t out_entry
);
  a2_t entries[0:1];
  logic read_ptr,write_ptr;
  logic [1:0] count;
  logic push,pop;
  assign in_ready=!reset && !clear && count<2;
  assign out_valid=!reset && !clear && count!=0;
  assign out_entry=entries[read_ptr];
  assign push=in_valid && in_ready;
  assign pop=out_valid && out_ready;
  always_ff @(posedge clk) begin
    if(reset || clear) begin
      read_ptr<=0;write_ptr<=0;count<=0;
    end else begin
      if(push) begin entries[write_ptr]<=in_entry;write_ptr<=!write_ptr;end
      if(pop) read_ptr<=!read_ptr;
      case({push,pop})
        2'b10:count<=count+1'b1;
        2'b01:count<=count-1'b1;
        default:;
      endcase
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(!reset && !clear && count>2) $fatal(1,"A source stage overflow");
  // synthesis translate_on
endmodule
