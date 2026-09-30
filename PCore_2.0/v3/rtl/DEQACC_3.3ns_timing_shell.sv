import pcore3_pkg::*;

// Characterization only: launch/capture FFs are not part of DEQACC latency.
module DEQACC_3_3ns_timing_shell(
  input logic clk,reset,clear,rsp_valid,input mxu_rsp_t rsp,
  input logic result_rd_valid,input acc_sel_e result_rd_sel,input logic [9:0] result_rd_addr,
  input logic vpu_wr_valid,input acc_write_t vpu_wr,
  output logic result_rd_ready,vpu_wr_ready,commit_valid,done,result_rd_data_valid,
  output pair_meta_t commit_meta,
  output logic [15:0][31:0] result_even_data,result_odd_data
);
  logic reset_q,clear_q,rsp_valid_q,rd_valid_q,wr_valid_q;
  mxu_rsp_t rsp_q;
  acc_sel_e sel_q;logic [9:0] addr_q;acc_write_t wr_q;
  logic rd_ready_i,wr_ready_i,commit_i,done_i,data_valid_i;
  pair_meta_t meta_i;
  logic [15:0][31:0] even_i,odd_i;
  always_ff @(posedge clk) begin
    reset_q<=reset;clear_q<=clear;rsp_valid_q<=rsp_valid;rsp_q<=rsp;
    rd_valid_q<=result_rd_valid;sel_q<=result_rd_sel;addr_q<=result_rd_addr;
    wr_valid_q<=vpu_wr_valid;wr_q<=vpu_wr;
    result_rd_ready<=rd_ready_i;vpu_wr_ready<=wr_ready_i;
    commit_valid<=commit_i;done<=done_i;commit_meta<=meta_i;
    result_rd_data_valid<=data_valid_i;result_even_data<=even_i;result_odd_data<=odd_i;
  end
  DEQACC_3_3ns core(.clk,.reset(reset_q),.clear(clear_q),.rsp_valid(rsp_valid_q),.rsp(rsp_q),
    .result_rd_owner(ACC_READ_RESULT),.result_rd_valid(rd_valid_q),.result_rd_ready(rd_ready_i),
    .result_rd_sel(sel_q),.result_rd_addr(addr_q),.result_rd_data_valid(data_valid_i),
    .result_even_data(even_i),.result_odd_data(odd_i),
    .vpu_wr_valid(wr_valid_q),.vpu_wr_ready(wr_ready_i),.vpu_wr(wr_q),
    .commit_valid(commit_i),.done(done_i),.commit_meta(meta_i),
    .dbg_valid(1'b0),.dbg_sel(ACC_OACC),.dbg_parity(1'b0),.dbg_addr('0),.dbg_lane('0),.dbg_data());
endmodule
