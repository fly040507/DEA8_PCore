import dea8_pcore_pkg::*;

// Synchronous-read RAM with a cached head. Logical capacity includes the head.
// First push bypasses RAM read latency into a register (not combinational FWFT).
// On pop, synchronously read the successor; sustain one transfer per clock.
module dea8_b_fifo #(
  parameter int WIDTH = B_ENTRY_BITS,
  parameter int DEPTH = B_FIFO_DEPTH
) (
  input logic clk, rst_n, clear,
  input logic in_valid,
  output logic in_ready,
  input logic [WIDTH-1:0] in_entry,
  output logic out_valid,
  input logic out_ready,
  output logic [WIDTH-1:0] out_entry,
  output logic [$clog2(DEPTH+1)-1:0] count
);
  localparam int PTR_BITS = (DEPTH<2) ? 1 : $clog2(DEPTH);
  (* ram_style = "block" *) logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [PTR_BITS-1:0] rd_ptr_q,wr_ptr_q,rd_next,wr_next;
  logic [WIDTH-1:0] ram_head_q,bypass_head_q;
  logic bypass_q,push,pop,read_next;
  assign rd_next=rd_ptr_q==DEPTH-1 ? '0 : rd_ptr_q+1'b1;
  assign wr_next=wr_ptr_q==DEPTH-1 ? '0 : wr_ptr_q+1'b1;
  assign out_valid=rst_n && !clear && count!=0;
  assign pop=out_valid && out_ready;
  assign in_ready=rst_n && !clear && (count<DEPTH || pop);
  assign push=in_valid && in_ready;
  assign read_next=pop && count>1;
  assign out_entry=bypass_q ? bypass_head_q : ram_head_q;

  // No resets on RAM data or its read register; valid/count hide stale bits.
  always_ff @(posedge clk) begin
    if(push) mem[wr_ptr_q]<=in_entry;
    if(read_next) ram_head_q<=mem[rd_next];
    if(push && (count==0 || (count==1 && pop))) bypass_head_q<=in_entry;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin rd_ptr_q<='0;wr_ptr_q<='0;count<='0;bypass_q<=1;end
    else if(clear) begin rd_ptr_q<='0;wr_ptr_q<='0;count<='0;bypass_q<=1;end
    else begin
      if(push) wr_ptr_q<=wr_next;
      if(pop) rd_ptr_q<=rd_next;
      if(read_next) bypass_q<=0;
      if(push && (count==0 || (count==1 && pop))) bypass_q<=1;
      case({push,pop})
        2'b10: count<=count+1'b1;
        2'b01: count<=count-1'b1;
        default: ;
      endcase
    end
  end
  // synthesis translate_off
  initial if(DEPTH<2 || WIDTH<1) $fatal(1,"Invalid B FIFO geometry");
  always @(posedge clk) if(rst_n && !clear) begin
    if(count>DEPTH) $fatal(1,"B FIFO count overflow");
    if(push && read_next && wr_ptr_q==rd_next) $fatal(1,"B FIFO RAM read/write collision");
  end
  // synthesis translate_on
endmodule
