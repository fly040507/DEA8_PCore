import dea8_pcore_pkg::*;
import dea8_fp32_pkg::*;

// L0-L3 arithmetic. The enclosing engine's synchronous RAM commit is L4.
// old_acc_fp is sampled at L2, aligned with the L1 memory read request.
module dea8_deqacc_lane #(parameter int unsigned EXP_BITS = 10) (
  input logic clk, rst_n, valid_in,
  input logic signed [PSUM_BITS-1:0] psum_in,
  input logic [SCALE_BITS-1:0] e_stream_in, e_stat_in,
  input logic signed [EXP_FOLD_BITS-1:0] exp_fold_in,
  input logic [FP_BITS-1:0] old_acc_fp,
  input logic first_acc,
  output logic valid_out,
  output logic signed [EXP_BITS-1:0] scale_exp,
  output logic [PSUM_BITS-1:0] abs_psum,
  output logic psum_sign,
  output logic [FP_BITS-1:0] partial_fp, acc_fp
);
  logic [3:0] valid_q;
  logic [2:0] clear_q;
  logic [PSUM_BITS-1:0] magnitude_l0, normalized_l1;
  logic sign_l0, sign_l1, bad_l0, bad_l1, zero_l1;
  logic signed [EXP_BITS-1:0] exponent_l0, unbiased_l1;
  logic [FP_BITS-1:0] partial_l2, old_l2, sum_l3;
  integer leading_bit;

  always_comb begin
    leading_bit = 0;
    for (int i = 0; i < PSUM_BITS; i++) if (magnitude_l0[i]) leading_bit = i;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= '0; clear_q <= '0;
      magnitude_l0 <= '0; sign_l0 <= 0; bad_l0 <= 0; exponent_l0 <= '0;
      normalized_l1 <= '0; sign_l1 <= 0; bad_l1 <= 0; zero_l1 <= 1; unbiased_l1 <= '0;
      partial_l2 <= '0; old_l2 <= '0; sum_l3 <= '0;
    end else begin
      valid_q <= {valid_q[2:0], valid_in};
      clear_q <= {clear_q[1:0], first_acc};
      // L0: integer magnitude and shared-exponent combination.
      if (valid_in) begin
        magnitude_l0 <= psum_in[PSUM_BITS-1] ? (~psum_in + 1'b1) : psum_in;
        sign_l0 <= psum_in[PSUM_BITS-1];
        bad_l0 <= (&e_stream_in) || (&e_stat_in);
        exponent_l0 <= EXP_BITS'($signed({1'b0, e_stream_in})) +
                       EXP_BITS'($signed({1'b0, e_stat_in})) -
                       EXP_BITS'(DOT_EXP_OFFSET) + EXP_BITS'($signed(exp_fold_in));
      end
      // L1: retain all significance to avoid double rounding at underflow.
      if (valid_q[0]) begin
        normalized_l1 <= magnitude_l0 << (PSUM_BITS - 1 - leading_bit);
        unbiased_l1 <= exponent_l0 + EXP_BITS'(leading_bit);
        sign_l1 <= sign_l0; bad_l1 <= bad_l0; zero_l1 <= magnitude_l0 == 0;
      end
      // L2: FP32 RNE packing and synchronous old-accumulator response.
      if (valid_q[1]) begin
        partial_l2 <= pack_scaled32(sign_l1, normalized_l1,
                                   int'($signed(unbiased_l1)), zero_l1, bad_l1);
        old_l2 <= clear_q[1] ? '0 : old_acc_fp;
      end
      // L3: one FP32 addition; clear bypass preserves the partial's signed zero.
      if (valid_q[2]) sum_l3 <= clear_q[2] ? partial_l2 : fp32_add(old_l2, partial_l2);
    end
  end
  assign valid_out = valid_q[3];
  assign partial_fp = partial_l2;
  assign acc_fp = sum_l3;
  assign abs_psum = magnitude_l0;
  assign psum_sign = sign_l0;
  assign scale_exp = exponent_l0;
  initial if (PSUM_BITS != 32 || FP_BITS != 32 || SCALE_BITS != 8 || EXP_BITS < 10)
    $fatal(1, "DEQACC requires INT32, binary32, E8M0 and >=10 exponent bits");
endmodule
