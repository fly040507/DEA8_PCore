import pcore3_pkg::*;
import dea8_fp32_v3_pkg::*;

// D0: abs/exponent, D1: normalize + synchronous accumulator read request,
// D2: pack partial + capture RAM response, D3: FP32 add, D4: write/commit.
module dea8_deqacc32_v3 (
  input logic clk,reset,clear,
  input logic rsp_valid,input mxu_rsp_t rsp,
  output logic commit_valid,done,output pair_meta_t commit_meta,
  input logic dbg_valid,input acc_sel_e dbg_sel,input logic dbg_parity,
  input logic [9:0] dbg_addr,input logic [3:0] dbg_lane,
  output logic [31:0] dbg_data
);
  logic valid_q[0:3];
  logic [1:0] row_valid_q[0:3];
  pair_meta_t meta_q[0:3];
  logic [1:0][15:0][31:0] mag_q0,normalized_q1,old_q2,partial_q2,sum_q3;
  logic [1:0][15:0] sign_q0,zero_q0,bad_q0;
  logic [1:0][15:0] sign_q1,zero_q1,bad_q1;
  logic signed [10:0] exponent_q0[0:1][0:15];
  logic signed [10:0] exponent_q1[0:1][0:15];
  logic [1:0][15:0][31:0] d0_mag;
  logic [1:0][15:0] d0_sign,d0_zero,d0_bad;
  logic signed [10:0] d0_exp[0:1][0:15];
  logic acc_rd_valid,acc_rd_rsp_valid,acc_wr_valid;
  acc_sel_e acc_rd_sel,acc_wr_sel;
  logic [9:0] acc_rd_addr,acc_wr_addr;
  logic [15:0][31:0] acc_rd_even,acc_rd_odd,acc_wr_even,acc_wr_odd;
  logic acc_wr_even_valid,acc_wr_odd_valid;

  function automatic int lead32(input logic [31:0] value);
    int lead; begin lead=0; for(int b=0;b<32;b++) if(value[b]) lead=b; return lead; end
  endfunction

  always_comb begin
    d0_mag='0;d0_sign='0;d0_zero='0;d0_bad='0;
    for(int r=0;r<2;r++) for(int n=0;n<16;n++) begin
      d0_mag[r][n]=rsp.psum[r][n][31]?(~rsp.psum[r][n]+1'b1):rsp.psum[r][n];
      d0_sign[r][n]=rsp.psum[r][n][31];
      d0_zero[r][n]=(d0_mag[r][n]==0);
      d0_bad[r][n]=(&rsp.e_stream[r])||(&rsp.e_stat[n]);
      d0_exp[r][n]=$signed({1'b0,rsp.e_stream[r]})+$signed({1'b0,rsp.e_stat[n]})-
        DOT_EXP_OFFSET+$signed(rsp.meta.exp_fold)+lead32(d0_mag[r][n]);
    end
  end

  assign acc_rd_valid=valid_q[0]&&!meta_q[0].acc_clear;
  assign acc_rd_sel=meta_q[0].acc_sel;
  assign acc_rd_addr=(meta_q[0].acc_sel==ACC_OACC)?
    10'(oacc_addr(meta_q[0].pair_idx,meta_q[0].nt)):10'(meta_q[0].pair_idx);
  assign acc_wr_valid=valid_q[3];
  assign acc_wr_sel=meta_q[3].acc_sel;
  assign acc_wr_addr=(meta_q[3].acc_sel==ACC_OACC)?
    10'(oacc_addr(meta_q[3].pair_idx,meta_q[3].nt)):10'(meta_q[3].pair_idx);
  assign acc_wr_even_valid=valid_q[3]&&row_valid_q[3][0];
  assign acc_wr_odd_valid=valid_q[3]&&row_valid_q[3][1];
  always_comb begin
    acc_wr_even=sum_q3[0];acc_wr_odd=sum_q3[1];
  end

  dea8_acc_store_v3 acc_store(
    .clk,.reset,.clear,.rd_valid(acc_rd_valid),.rd_sel(acc_rd_sel),.rd_addr(acc_rd_addr),
    .rd_data_valid(acc_rd_rsp_valid),.rd_even_data(acc_rd_even),.rd_odd_data(acc_rd_odd),
    .wr_valid(acc_wr_valid),.wr_sel(acc_wr_sel),.wr_even_valid(acc_wr_even_valid),
    .wr_odd_valid(acc_wr_odd_valid),.wr_addr(acc_wr_addr),.wr_even_data(acc_wr_even),
    .wr_odd_data(acc_wr_odd),.dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      for(int s=0;s<4;s++) begin valid_q[s]<=0;row_valid_q[s]<='0;meta_q[s]<='0;end
      commit_valid<=0;done<=0;commit_meta<='0;
      mag_q0<='0;normalized_q1<='0;old_q2<='0;partial_q2<='0;sum_q3<='0;
      sign_q0<='0;zero_q0<='0;bad_q0<='0;sign_q1<='0;zero_q1<='0;bad_q1<='0;
      for(int r=0;r<2;r++) for(int n=0;n<16;n++) begin exponent_q0[r][n]<='0;exponent_q1[r][n]<='0;end
    end else begin
      valid_q[0]<=rsp_valid;valid_q[1]<=valid_q[0];valid_q[2]<=valid_q[1];valid_q[3]<=valid_q[2];
      commit_valid<=valid_q[3];done<=valid_q[3]&&meta_q[3].last;commit_meta<=meta_q[3];
      if(rsp_valid) begin
        mag_q0<=d0_mag;sign_q0<=d0_sign;zero_q0<=d0_zero;bad_q0<=d0_bad;
        for(int r=0;r<2;r++) for(int n=0;n<16;n++) exponent_q0[r][n]<=d0_exp[r][n];
        row_valid_q[0]<=rsp.row_valid;meta_q[0]<=rsp.meta;
      end
      if(valid_q[0]) begin
        for(int r=0;r<2;r++) for(int n=0;n<16;n++) begin
          normalized_q1[r][n]<=zero_q0[r][n]?0:(mag_q0[r][n] << (31-lead32(mag_q0[r][n])));
          sign_q1[r][n]<=sign_q0[r][n];zero_q1[r][n]<=zero_q0[r][n];bad_q1[r][n]<=bad_q0[r][n];
          exponent_q1[r][n]<=exponent_q0[r][n];
        end
        row_valid_q[1]<=row_valid_q[0];meta_q[1]<=meta_q[0];
      end
      if(valid_q[1]) begin
        for(int r=0;r<2;r++) for(int n=0;n<16;n++) begin
          partial_q2[r][n]<=pack_scaled32(sign_q1[r][n],normalized_q1[r][n],exponent_q1[r][n],zero_q1[r][n],bad_q1[r][n]);
          old_q2[r][n]<=r==0?acc_rd_even[n]:acc_rd_odd[n];
        end
        row_valid_q[2]<=row_valid_q[1];meta_q[2]<=meta_q[1];
      end
      if(valid_q[2]) begin
        for(int r=0;r<2;r++) for(int n=0;n<16;n++)
          sum_q3[r][n]<=meta_q[2].acc_clear?partial_q2[r][n]:fp32_add(old_q2[r][n],partial_q2[r][n]);
        row_valid_q[3]<=row_valid_q[2];meta_q[3]<=meta_q[2];
      end
    end
  end
endmodule
