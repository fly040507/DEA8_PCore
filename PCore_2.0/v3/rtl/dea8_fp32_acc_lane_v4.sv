import dea8_fp32_v3_pkg::*;

// One independent FP32 accumulator lane.
// Input is accepted at D4 in the top-level DEQACC.  The lane-local registers
// split prepare, add/sub, normalization and final pack so no lane contains a
// single raw-sum-to-FP32 critical cone.
module dea8_fp32_acc_lane_v4 (
  input logic clk,reset,clear,
  input logic in_valid,input logic add_old,
  input logic [31:0] old_value,partial_value,
  output logic out_valid,output logic [31:0] result_value
);
  logic valid_q0,valid_q1,valid_q2;
  logic add_old_q0,add_old_q1,add_old_q2;
  logic [31:0] partial_q0,partial_q1,partial_q2;
  fp_add_pre_t pre_q1;
  fp_add_raw_t raw_q2;
  fp_norm_mid_t norm_q3;

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      valid_q0<=0;valid_q1<=0;valid_q2<=0;out_valid<=0;
      add_old_q0<=0;add_old_q1<=0;add_old_q2<=0;
      partial_q0<=0;partial_q1<=0;partial_q2<=0;
      pre_q1<='0;raw_q2<='0;norm_q3<='0;result_value<=0;
    end else begin
      valid_q0<=in_valid;
      valid_q1<=valid_q0;
      valid_q2<=valid_q1;
      out_valid<=valid_q2;
      add_old_q0<=add_old;
      add_old_q1<=add_old_q0;
      add_old_q2<=add_old_q1;
      partial_q0<=partial_value;
      partial_q1<=partial_q0;
      partial_q2<=partial_q1;
      if(in_valid&&add_old) pre_q1<=fp32_prepare(old_value,partial_value);
      if(valid_q0&&add_old_q0) raw_q2<=fp32_add_raw(pre_q1);
      if(valid_q1&&add_old_q1) norm_q3<=fp32_normalize_mid(raw_q2);
      if(valid_q2&&add_old_q2) result_value<=fp32_pack_mid(norm_q3);
      else if(valid_q2&&!add_old_q2) result_value<=partial_q2;
    end
  end
endmodule
