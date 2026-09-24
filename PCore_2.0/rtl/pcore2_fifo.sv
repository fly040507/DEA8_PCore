// Synchronous RAM plus cached head, simultaneous push/pop and full throughput.
module pcore2_fifo #(parameter int WIDTH=136,DEPTH=64)(
  input logic clk,reset,clear,in_valid,
  output logic in_ready,
  input logic [WIDTH-1:0] in_data,
  output logic out_valid,
  input logic out_ready,
  output logic [WIDTH-1:0] out_data,
  output logic [$clog2(DEPTH+1)-1:0] count
);
  localparam int PTR=$clog2(DEPTH);
  (* ram_style="block" *) logic [WIDTH-1:0] mem[0:DEPTH-1];
  logic [WIDTH-1:0] head_ram,head_bypass;
  logic [PTR-1:0] rp,wp,rnext;
  logic bypass,push,pop;
  assign rnext=rp==DEPTH-1 ? '0 : rp+1'b1;
  assign out_valid=!reset && !clear && count!=0;
  assign pop=out_valid && out_ready;
  assign in_ready=!reset && !clear && (count<DEPTH || pop);
  assign push=in_valid && in_ready;
  assign out_data=bypass ? head_bypass : head_ram;
  always_ff @(posedge clk) begin
    if(push) mem[wp]<=in_data;
    if(pop && count>1) head_ram<=mem[rnext];
    if(push && (count==0 || (count==1 && pop))) head_bypass<=in_data;
    if(reset || clear) begin count<=0;rp<=0;wp<=0;bypass<=1;end
    else begin
      if(push) wp<=wp==DEPTH-1 ? '0 : wp+1'b1;
      if(pop) rp<=rnext;
      if(pop && count>1) bypass<=0;
      if(push && (count==0 || (count==1 && pop))) bypass<=1;
      case({push,pop})
        2'b10: count<=count+1'b1;
        2'b01: count<=count-1'b1;
        default: ;
      endcase
    end
  end
endmodule
