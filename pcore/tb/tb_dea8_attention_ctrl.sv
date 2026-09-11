`timescale 1ns/1ps
import dea8_pcore_pkg::*;

module tb_dea8_attention_ctrl;
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic rst_n = 1'b0;
  logic start = 1'b0;
  logic busy, done;
  logic qk_valid, exp_valid, pv_valid, scale_valid, afin_valid;
  logic qk_ready = 1'b1;
  logic exp_ready = 1'b1;
  logic pv_ready = 1'b1;
  logic scale_ready = 1'b1;
  logic afin_ready = 1'b1;
  attn_cmd_t qk_cmd, exp_cmd, pv_cmd, scale_cmd;

  int qk_count, exp_count, pv_count, scale_count, afin_count;
  int expected_qk, expected_exp, expected_pv, expected_scale;

  dea8_attention_ctrl dut (.*);

  always @(posedge clk) begin
    if (rst_n) begin
      if (qk_valid && qk_ready) begin
        assert (qk_cmd.blk == expected_qk)
          else $fatal(1, "QK expected block %0d, got %0d", expected_qk, qk_cmd.blk);
        assert (qk_cmd.pingpong == qk_cmd.blk[0]);
        qk_count <= qk_count + 1;
        expected_qk <= expected_qk + 1;
      end
      if (exp_valid && exp_ready) begin
        assert (exp_cmd.blk == expected_exp)
          else $fatal(1, "EXP expected block %0d, got %0d", expected_exp, exp_cmd.blk);
        exp_count <= exp_count + 1;
        expected_exp <= expected_exp + 1;
      end
      if (pv_valid && pv_ready) begin
        assert (pv_cmd.blk == expected_pv)
          else $fatal(1, "PV expected block %0d, got %0d", expected_pv, pv_cmd.blk);
        pv_count <= pv_count + 1;
        expected_pv <= expected_pv + 1;
      end
      if (scale_valid && scale_ready) begin
        assert (scale_cmd.blk == expected_scale)
          else $fatal(1, "SCALE expected block %0d, got %0d", expected_scale, scale_cmd.blk);
        scale_count <= scale_count + 1;
        expected_scale <= expected_scale + 1;
      end
      if (afin_valid && afin_ready) afin_count <= afin_count + 1;
    end
  end

  initial begin
    qk_count = 0; exp_count = 0; pv_count = 0; scale_count = 0; afin_count = 0;
    expected_qk = 0; expected_exp = 0; expected_pv = 0; expected_scale = 1;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    @(negedge clk); start = 1'b1;
    @(negedge clk); start = 1'b0;
    wait (done);
    @(posedge clk);
    @(negedge clk);
    assert (qk_count == N_KV_BLOCK) else $fatal(1, "QK count %0d", qk_count);
    assert (exp_count == N_KV_BLOCK) else $fatal(1, "EXP count %0d", exp_count);
    assert (pv_count == N_KV_BLOCK) else $fatal(1, "PV count %0d", pv_count);
    assert (scale_count == N_KV_BLOCK-1) else $fatal(1, "SCALE count %0d", scale_count);
    assert (afin_count == 1) else $fatal(1, "A_FIN count %0d", afin_count);
    assert (!busy) else $fatal(1, "controller remained busy");
    $display("tb_dea8_attention_ctrl PASS: QK=%0d EXP=%0d PV=%0d SCALE=%0d A_FIN=%0d",
             qk_count, exp_count, pv_count, scale_count, afin_count);
    $finish;
  end
endmodule
