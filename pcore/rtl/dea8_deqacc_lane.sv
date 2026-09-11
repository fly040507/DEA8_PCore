import dea8_pcore_pkg::*;

// One DEQACC lane. Integer sign/absolute-value and exponent generation are
// implemented here; certified FPGA FP32 IP connects at the marked boundary.
module dea8_deqacc_lane #(
  parameter int unsigned EXP_BITS = 10
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    valid_in,
  input  logic signed [PSUM_BITS-1:0] psum_in,
  input  logic [SCALE_BITS-1:0]   e_stream_in,
  input  logic [SCALE_BITS-1:0]   e_stat_in,
  input  logic signed [EXP_FOLD_BITS-1:0] exp_fold_in,
  input  logic [FP_BITS-1:0]       old_acc_fp,
  input  logic                    first_acc,
  output logic                    valid_out,
  output logic signed [EXP_BITS-1:0] scale_exp,
  output logic [PSUM_BITS-1:0]     abs_psum,
  output logic                    psum_sign,
  output logic [FP_BITS-1:0]       partial_fp,
  output logic [FP_BITS-1:0]       acc_fp
);
  localparam int signed EXP_OFFSET = DOT_EXP_OFFSET;

  logic valid_q;
  logic [PSUM_BITS-1:0] abs_psum_q;
  logic sign_q;
  logic signed [EXP_BITS-1:0] exp_q;

  assign abs_psum  = abs_psum_q;
  assign psum_sign = sign_q;
  assign scale_exp = exp_q;
  assign valid_out = valid_q;

  // Replace these two assignments with the project's certified FP32 IP.
  assign partial_fp = '0;
  assign acc_fp     = first_acc ? partial_fp : old_acc_fp;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q    <= 1'b0;
      abs_psum_q <= '0;
      sign_q     <= 1'b0;
      exp_q      <= '0;
    end else begin
      valid_q <= valid_in;
      if (valid_in) begin
        sign_q <= psum_in[PSUM_BITS-1];
        if (psum_in[PSUM_BITS-1]) begin
          abs_psum_q <= (~psum_in) + 1'b1;
        end else begin
          abs_psum_q <= psum_in;
        end
        exp_q <= $signed({1'b0, e_stream_in})
               + $signed({1'b0, e_stat_in})
               - EXP_OFFSET
               + $signed(exp_fold_in);
      end
    end
  end
endmodule
