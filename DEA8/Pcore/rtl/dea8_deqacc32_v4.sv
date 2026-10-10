import pcore_pkg::*;
import dea8_fp32_pkg::*;

// Eight-stage DEQACC candidate:
// D0 abs/exponent, D1 partial pack + accumulator read, D2 synchronous-read
// response capture, D3 response alignment, D4 lane-local compare/align,
// D5 mantissa add/sub, D6/D7 lane-local normalize, D8 accumulator commit.
// The explicit read-response stage is required by the synchronous accumulator
// RAM and prevents an isolated OACC read/modify/write from using stale data.
module dea8_deqacc32_v4 (
  input logic clk,reset,clear,
  input logic rsp_valid,input mxu_rsp_t rsp,
  input acc_read_owner_e result_rd_owner,
  input logic result_rd_valid,output logic result_rd_ready,
  input logic vpu_wr_valid,output logic vpu_wr_ready,input acc_write_t vpu_wr,
  input acc_sel_e result_rd_sel,input logic [9:0] result_rd_addr,
  output logic result_rd_data_valid,
  output logic [15:0][31:0] result_even_data,result_odd_data,
  output logic commit_valid,done,output pair_meta_t commit_meta,
  input logic dbg_valid,input acc_sel_e dbg_sel,input logic dbg_parity,
  input logic [9:0] dbg_addr,input logic [3:0] dbg_lane,
  output logic [31:0] dbg_data
);
  logic valid_q0,valid_q1,valid_q2,valid_q3;
  logic meta_valid_q0,meta_valid_q1,meta_valid_q2,meta_valid_q3,meta_valid_q4,meta_valid_q5,meta_valid_q6,meta_valid_q7;
  logic [1:0] row_valid_q0,row_valid_q1,row_valid_q2;
  pair_meta_t meta_q0,meta_q1,meta_q2;
  logic [1:0][15:0][31:0] mag_q0,partial_q1,partial_q2,partial_q3;
  // The accumulator RAM is synchronous.  Capture its response as an
  // independent stream, then align it with partial_q3 at the lane input.
  // This is intentionally separate from the arithmetic valid pipeline: a
  // request may be absent for the first/clear tile, while the response path
  // must still inject an explicit zero for that position.
  logic [1:0][15:0][31:0] old_rsp_q0,old_rsp_q1;
  logic [1:0][15:0] sign_q0,zero_q0,bad_q0;
  logic signed [10:0] exponent_q0[0:1][0:15];
  logic [1:0][15:0][31:0] d0_mag;
  logic [1:0][15:0][31:0] d0_norm;
  logic [1:0][15:0] d0_sign,d0_zero,d0_bad;
  logic signed [10:0] d0_exp[0:1][0:15];
  logic acc_rd_valid,acc_rd_rsp_valid,acc_wr_valid;
  acc_sel_e acc_rd_sel,acc_wr_sel;
  logic [9:0] acc_rd_addr,acc_wr_addr;
  logic [15:0][31:0] acc_rd_even,acc_rd_odd,acc_wr_even,acc_wr_odd;
  logic acc_wr_even_valid,acc_wr_odd_valid;
  logic lane_valid[0:1][0:15];
  logic [31:0] lane_result[0:1][0:15];
  logic lane_out_valid;
  logic [1:0] row_valid_q3,row_valid_q4,row_valid_q5,row_valid_q6,row_valid_q7;
  pair_meta_t meta_q3,meta_q4,meta_q5,meta_q6,meta_q7;

  always_comb begin
    d0_mag='0;d0_norm='0;d0_sign='0;d0_zero='0;d0_bad='0;
    for(int r=0;r<2;r++) for(int n=0;n<16;n++) begin
      d0_mag[r][n]=rsp.psum[r][n][31]?(~rsp.psum[r][n]+1'b1):rsp.psum[r][n];
      // Normalize before the D0 register.  D1 then sees a fixed-point
      // significand and only performs exponent adjustment/RNE packing.
      d0_norm[r][n]=d0_mag[r][n] << (5'd31-lead32(d0_mag[r][n]));
      d0_sign[r][n]=rsp.psum[r][n][31];
      d0_zero[r][n]=(d0_mag[r][n]==0);
      d0_bad[r][n]=(&rsp.e_stream[r])||(&rsp.e_stat[n]);
      d0_exp[r][n]=$signed({1'b0,rsp.e_stream[r]})+$signed({1'b0,rsp.e_stat[n]})-
        DOT_EXP_OFFSET+$signed(rsp.meta.exp_fold)+$signed({1'b0,lead32(d0_mag[r][n])});
    end
  end

  assign acc_rd_valid=valid_q0&&meta_q0.add_old;
  assign acc_rd_sel=meta_q0.acc_sel;
  assign acc_rd_addr=(meta_q0.acc_sel==ACC_OACC)?
    10'(oacc_addr(meta_q0.pair_idx,meta_q0.nt)):10'(meta_q0.pair_idx);
  assign lane_out_valid=lane_valid[0][0];
  assign acc_wr_valid=lane_out_valid;
  // The lane gained one register between raw normalization and final pack;
  // q7 is therefore the metadata stage paired with its registered output.
  assign acc_wr_sel=meta_q7.acc_sel;
  assign acc_wr_addr=(meta_q7.acc_sel==ACC_OACC)?
    10'(oacc_addr(meta_q7.pair_idx,meta_q7.nt)):10'(meta_q7.pair_idx);
  assign acc_wr_even_valid=lane_out_valid&&meta_valid_q7&&row_valid_q7[0];
  assign acc_wr_odd_valid=lane_out_valid&&meta_valid_q7&&row_valid_q7[1];
  always_comb begin
    acc_wr_even='0;acc_wr_odd='0;
    for(int n=0;n<16;n++) begin
      acc_wr_even[n]=lane_result[0][n];acc_wr_odd[n]=lane_result[1][n];
    end
  end

  dea8_acc_store acc_store(
    .clk,.reset,.clear,.rd_valid(acc_rd_valid),.rd_sel(acc_rd_sel),.rd_addr(acc_rd_addr),
    .rd_data_valid(acc_rd_rsp_valid),.rd_even_data(acc_rd_even),.rd_odd_data(acc_rd_odd),
    .result_rd_owner,.result_rd_valid,.result_rd_ready,.result_rd_sel,.result_rd_addr,
    .vpu_wr_valid,.vpu_wr_ready,.vpu_wr,
    .result_rd_data_valid,.result_even_data,.result_odd_data,
    .wr_valid(acc_wr_valid),.wr_sel(acc_wr_sel),.wr_even_valid(acc_wr_even_valid),
    .wr_odd_valid(acc_wr_odd_valid),.wr_addr(acc_wr_addr),.wr_even_data(acc_wr_even),
    .wr_odd_data(acc_wr_odd),.dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);

  for(genvar r=0;r<2;r++) for(genvar n=0;n<16;n++) begin: lanes
    dea8_fp32_acc_lane_v4 lane(
      .clk,.reset,.clear,.in_valid(valid_q3),.add_old(meta_q3.add_old),
      .old_value(old_rsp_q1[r][n]),.partial_value(partial_q3[r][n]),
      .out_valid(lane_valid[r][n]),.result_value(lane_result[r][n]));
  end

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      valid_q0<=0;valid_q1<=0;valid_q2<=0;valid_q3<=0;
      row_valid_q0<='0;row_valid_q1<='0;row_valid_q2<='0;
      row_valid_q3<='0;row_valid_q4<='0;row_valid_q5<='0;row_valid_q6<='0;row_valid_q7<='0;
      meta_valid_q0<=0;meta_valid_q1<=0;meta_valid_q2<=0;meta_valid_q3<=0;
      meta_valid_q4<=0;meta_valid_q5<=0;meta_valid_q6<=0;meta_valid_q7<=0;
      meta_q0<='0;meta_q1<='0;meta_q2<='0;meta_q3<='0;meta_q4<='0;meta_q5<='0;meta_q6<='0;meta_q7<='0;
      commit_valid<=0;done<=0;commit_meta<='0;
      mag_q0<='0;partial_q1<='0;partial_q2<='0;partial_q3<='0;
      old_rsp_q0<='0;old_rsp_q1<='0;
      sign_q0<='0;zero_q0<='0;bad_q0<='0;
      for(int r=0;r<2;r++) for(int n=0;n<16;n++) exponent_q0[r][n]<='0;
    end else begin
      valid_q0<=rsp_valid;valid_q1<=valid_q0;valid_q2<=valid_q1;valid_q3<=valid_q2;
      meta_valid_q0<=rsp_valid;
      meta_valid_q1<=meta_valid_q0;
      meta_valid_q2<=meta_valid_q1;
      meta_valid_q3<=meta_valid_q2;
      meta_valid_q4<=meta_valid_q3;
      meta_valid_q5<=meta_valid_q4;
      meta_valid_q6<=meta_valid_q5;
      meta_valid_q7<=meta_valid_q6;
      meta_q3<=meta_q2;
      meta_q4<=meta_q3;
      meta_q5<=meta_q4;
      meta_q6<=meta_q5;
      meta_q7<=meta_q6;
      row_valid_q3<=row_valid_q2;
      row_valid_q4<=row_valid_q3;
      row_valid_q5<=row_valid_q4;
      row_valid_q6<=row_valid_q5;
      row_valid_q7<=row_valid_q6;
      if(rsp_valid) begin
         mag_q0<=d0_norm;sign_q0<=d0_sign;zero_q0<=d0_zero;bad_q0<=d0_bad;
        for(int r=0;r<2;r++) for(int n=0;n<16;n++) exponent_q0[r][n]<=d0_exp[r][n];
        row_valid_q0<=rsp.row_valid;meta_q0<=rsp.meta;
      end
      if(valid_q0) begin
        for(int r=0;r<2;r++) for(int n=0;n<16;n++) begin
          partial_q1[r][n]<=pack_scaled32(sign_q0[r][n],
            mag_q0[r][n],exponent_q0[r][n],
            zero_q0[r][n],bad_q0[r][n]);
        end
        row_valid_q1<=row_valid_q0;meta_q1<=meta_q0;
      end
      if(valid_q1) begin
        partial_q2<=partial_q1;
        row_valid_q2<=row_valid_q1;meta_q2<=meta_q1;
      end
      if(valid_q2) begin
        partial_q3<=partial_q2;
      end

      // acc_rd_rsp_valid is generated by the synchronous accumulator store
      // for the read request issued earlier.  Do not infer this response
      // from valid_q1/valid_q2: doing so associates a neighboring tile's
      // read data with the current tile under a continuous stream.
      if(acc_rd_rsp_valid) begin
        old_rsp_q0[0]<=acc_rd_even;
        old_rsp_q0[1]<=acc_rd_odd;
      end else begin
        old_rsp_q0<='0;
      end
      old_rsp_q1<=old_rsp_q0;
      commit_valid<=lane_out_valid&&meta_valid_q7;
      done<=lane_out_valid&&meta_valid_q7&&meta_q7.last;
      commit_meta<=meta_q7;
    end
  end
endmodule
