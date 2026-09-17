import dea8_pcore_pkg::*;

// Register/LUT FIFO with combinational head, used by legacy/client adapters.
// The active W/KV payload queues use dea8_b_fifo instead.
module dea8_stream_fifo #(
  parameter int unsigned WIDTH = SCALE_WORD_BITS,
  parameter int unsigned DEPTH = LEGACY_WFIFO_SCALE_DEPTH
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             in_valid,
  output logic             in_ready,
  input  logic [WIDTH-1:0] in_data,
  output logic             out_valid,
  input  logic             out_ready,
  output logic [WIDTH-1:0] out_data,
  output logic [$clog2(DEPTH + 1)-1:0] count
);
  localparam int unsigned PTR_BITS = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int unsigned CNT_BITS = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1);

  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [PTR_BITS-1:0] rd_ptr_q;
  logic [PTR_BITS-1:0] wr_ptr_q;
  logic [CNT_BITS-1:0] count_q;
  logic push, pop;

  assign count     = count_q;
  assign in_ready  = rst_n && ((count_q < DEPTH) || pop);
  assign out_valid = rst_n && (count_q != 0);
  assign out_data  = mem[rd_ptr_q];
  assign push      = in_valid && in_ready;
  assign pop       = out_valid && out_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_ptr_q <= '0;
      wr_ptr_q <= '0;
      count_q  <= '0;
    end else begin
      if (push) begin
        mem[wr_ptr_q] <= in_data;
        wr_ptr_q <= (wr_ptr_q == DEPTH - 1) ? '0 : wr_ptr_q + 1'b1;
      end
      if (pop) begin
        rd_ptr_q <= (rd_ptr_q == DEPTH - 1) ? '0 : rd_ptr_q + 1'b1;
      end
      case ({push, pop})
        2'b10: count_q <= count_q + 1'b1;
        2'b01: count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase
    end
  end
endmodule
