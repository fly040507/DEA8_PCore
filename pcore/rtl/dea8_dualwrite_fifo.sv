import dea8_pcore_pkg::*;

// One logical WFIFO_DATA with two write lanes and one read lane.
// A payload HBM beat supplies two 128-bit entries in one core cycle.
module dea8_dualwrite_fifo #(
  parameter int unsigned WIDTH = WEIGHT_WORD_BITS,
  parameter int unsigned DEPTH = WFIFO_DATA_DEPTH
) (
  input  logic                          clk,
  input  logic                          rst_n,
  input  logic [1:0]                    in_valid,
  output logic [1:0]                    in_ready,
  input  logic [1:0][WIDTH-1:0]         in_data,
  output logic                          out_valid,
  input  logic                          out_ready,
  output logic [WIDTH-1:0]              out_data,
  output logic [$clog2(DEPTH + 1)-1:0] count
);
  localparam int unsigned PTR_BITS = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int unsigned CNT_BITS = (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1);

  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [PTR_BITS-1:0] rd_ptr_q;
  logic [PTR_BITS-1:0] wr_ptr_q;
  logic [CNT_BITS-1:0] count_q;
  logic push, pop;
  logic [PTR_BITS-1:0] wr_ptr_next;

  // The unpacker presents both lanes together. Keep one free slot for each.
  assign in_ready[0] = (count_q <= DEPTH - 2);
  assign in_ready[1] = in_ready[0];
  assign push        = in_valid[0] && in_valid[1] && in_ready[0];
  assign out_valid   = (count_q != 0);
  assign out_data    = mem[rd_ptr_q];
  assign pop         = out_valid && out_ready;
  assign wr_ptr_next = (wr_ptr_q >= DEPTH - 2) ?
                       wr_ptr_q + 2 - DEPTH : wr_ptr_q + 2;
  assign count       = count_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_ptr_q <= '0;
      wr_ptr_q <= '0;
      count_q  <= '0;
    end else begin
      if (push) begin
        mem[wr_ptr_q] <= in_data[0];
        mem[wr_ptr_q + 1'b1] <= in_data[1];
        wr_ptr_q <= wr_ptr_next;
      end
      if (pop) begin
        rd_ptr_q <= (rd_ptr_q == DEPTH - 1) ? '0 : rd_ptr_q + 1'b1;
      end
      case ({push, pop})
        2'b10: count_q <= count_q + 2;
        2'b01: count_q <= count_q - 1'b1;
        default: count_q <= count_q + (push ? 1 : 0);
      endcase
    end
  end

  initial begin
    assert (DEPTH >= 2)
      else $error("dea8_dualwrite_fifo requires DEPTH >= 2");
  end
endmodule
