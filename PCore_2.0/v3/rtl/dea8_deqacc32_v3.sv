import pcore3_pkg::*;
import dea8_fp32_v3_pkg::*;

// Five registered stages. The storage is parity split: each cycle writes one
// 16-lane even vector and one 16-lane odd vector, never a 1024-bit monolithic RAM.
module dea8_deqacc32_v3 (
  input logic clk,reset,clear,
  input logic rsp_valid,input mxu_rsp_t rsp,
  output logic commit_valid,done,output pair_meta_t commit_meta,
  input logic dbg_valid,input acc_sel_e dbg_sel,input logic dbg_parity,
  input logic [9:0] dbg_addr,input logic [3:0] dbg_lane,
  output logic [FP_BITS-1:0] dbg_data
);
  logic [31:0] facc_a_even[0:25][0:15],facc_a_odd[0:24][0:15];
  logic [31:0] facc_b_even[0:25][0:15],facc_b_odd[0:24][0:15];
  logic [31:0] oacc_even[0:415][0:15],oacc_odd[0:399][0:15];
  logic valid_q[0:4];
  logic [1:0] row_valid_q[0:4];
  logic [1:0][15:0][31:0] partial_q[0:2],old_q[0:2],sum_q[0:3];
  pair_meta_t meta_q[0:4];
  logic [1:0][15:0][31:0] partial_now,old_now;
  logic [1:0][15:0][31:0] normalized_now;
  logic [1:0][15:0][7:0] exp_now;
  logic [1:0][15:0] bad_now,zero_now,sign_now;

  always_comb begin
    partial_now='0;old_now='0;normalized_now='0;exp_now='0;bad_now='0;zero_now='0;sign_now='0;
    if(rsp_valid) for(int r=0;r<2;r++) for(int n=0;n<16;n++) begin
      logic [31:0] mag; integer lead; integer exponent;
      mag=rsp.psum[r][n][31]?(~rsp.psum[r][n]+1'b1):rsp.psum[r][n];
      sign_now[r][n]=rsp.psum[r][n][31];zero_now[r][n]=mag==0;lead=0;
      for(int b=0;b<32;b++) if(mag[b]) lead=b;
      normalized_now[r][n]=mag << (31-lead);
      exponent=rsp.e_stream[r]+rsp.e_stat[n]-DOT_EXP_OFFSET+$signed(rsp.meta.exp_fold)+lead;
      exp_now[r][n]=exponent[7:0];bad_now[r][n]=(&rsp.e_stream[r])||(&rsp.e_stat[n]);
      partial_now[r][n]=pack_scaled32(sign_now[r][n],normalized_now[r][n],exponent,zero_now[r][n],bad_now[r][n]);
      if(!rsp.meta.acc_clear) begin
        if(rsp.meta.acc_sel==ACC_OACC) begin
          if(rsp.meta.pair_idx*16+rsp.meta.nt < (r==0?416:400))
            old_now[r][n]=r==0?oacc_even[rsp.meta.pair_idx*16+rsp.meta.nt][n]:oacc_odd[rsp.meta.pair_idx*16+rsp.meta.nt][n];
        end else if(rsp.meta.pair_idx < (r==0?26:25)) begin
          if(rsp.meta.acc_sel==ACC_FACC_A) old_now[r][n]=r==0?facc_a_even[rsp.meta.pair_idx][n]:facc_a_odd[rsp.meta.pair_idx][n];
          else old_now[r][n]=r==0?facc_b_even[rsp.meta.pair_idx][n]:facc_b_odd[rsp.meta.pair_idx][n];
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      for(int s=0;s<5;s++) begin valid_q[s]<=0;row_valid_q[s]<='0;end
      commit_valid<=0;done<=0;commit_meta<='0;
      for(int p=0;p<26;p++) for(int n=0;n<16;n++) begin facc_a_even[p][n]<=0;facc_b_even[p][n]<=0;end
      for(int p=0;p<25;p++) for(int n=0;n<16;n++) begin facc_a_odd[p][n]<=0;facc_b_odd[p][n]<=0;end
      for(int a=0;a<416;a++) for(int n=0;n<16;n++) oacc_even[a][n]<=0;
      for(int a=0;a<400;a++) for(int n=0;n<16;n++) oacc_odd[a][n]<=0;
    end else begin
      valid_q[0]<=rsp_valid;valid_q[1]<=valid_q[0];valid_q[2]<=valid_q[1];valid_q[3]<=valid_q[2];valid_q[4]<=valid_q[3];
      row_valid_q[0]<=rsp.row_valid;row_valid_q[1]<=row_valid_q[0];row_valid_q[2]<=row_valid_q[1];row_valid_q[3]<=row_valid_q[2];row_valid_q[4]<=row_valid_q[3];
      commit_valid<=valid_q[4];done<=valid_q[4]&&meta_q[4].last;commit_meta<=meta_q[4];
      if(rsp_valid) begin partial_q[0]<=partial_now;old_q[0]<=old_now;meta_q[0]<=rsp.meta;end
      if(valid_q[0]) begin partial_q[1]<=partial_q[0];old_q[1]<=old_q[0];meta_q[1]<=meta_q[0];end
      if(valid_q[1]) begin partial_q[2]<=partial_q[1];old_q[2]<=old_q[1];meta_q[2]<=meta_q[1];end
      if(valid_q[2]) begin
        for(int r=0;r<2;r++) for(int n=0;n<16;n++) sum_q[0][r][n]<=meta_q[2].acc_clear?partial_q[2][r][n]:fp32_add(old_q[2][r][n],partial_q[2][r][n]);
        meta_q[3]<=meta_q[2];
      end
      if(valid_q[3]) begin sum_q[1]<=sum_q[0];meta_q[4]<=meta_q[3];end
      if(valid_q[4]) begin
        for(int r=0;r<2;r++) for(int n=0;n<16;n++) begin
          if(meta_q[4].acc_sel==ACC_OACC) begin
            if(r==0) oacc_even[meta_q[4].pair_idx*16+meta_q[4].nt][n]<=sum_q[1][r][n];
            else if(row_valid_q[4][r]) oacc_odd[meta_q[4].pair_idx*16+meta_q[4].nt][n]<=sum_q[1][r][n];
          end else if(row_valid_q[4][r] && meta_q[4].acc_sel==ACC_FACC_A) begin
            if(r==0) facc_a_even[meta_q[4].pair_idx][n]<=sum_q[1][r][n]; else facc_a_odd[meta_q[4].pair_idx][n]<=sum_q[1][r][n];
          end else if(row_valid_q[4][r]) begin
            if(r==0) facc_b_even[meta_q[4].pair_idx][n]<=sum_q[1][r][n]; else facc_b_odd[meta_q[4].pair_idx][n]<=sum_q[1][r][n];
          end
        end
      end
    end
  end

  always_comb begin
    dbg_data='0;
    if(dbg_valid&&dbg_lane<16) begin
      if(dbg_sel==ACC_OACC) begin
        if(!dbg_parity&&dbg_addr<416) dbg_data=oacc_even[dbg_addr][dbg_lane];
        else if(dbg_parity&&dbg_addr<400) dbg_data=oacc_odd[dbg_addr][dbg_lane];
      end else if(dbg_sel==ACC_FACC_A) begin
        if(!dbg_parity&&dbg_addr<26) dbg_data=facc_a_even[dbg_addr][dbg_lane];
        else if(dbg_parity&&dbg_addr<25) dbg_data=facc_a_odd[dbg_addr][dbg_lane];
      end else begin
        if(!dbg_parity&&dbg_addr<26) dbg_data=facc_b_even[dbg_addr][dbg_lane];
        else if(dbg_parity&&dbg_addr<25) dbg_data=facc_b_odd[dbg_addr][dbg_lane];
      end
    end
  end
  initial if(TILE!=16) $fatal(1,"DEQACC32 geometry");
endmodule
