import pcore_pkg::*;

// Characterization launch/capture registers are outside the seven-stage core.
// Capture every functional output (including all commit_write bits) so normal
// synthesis cannot prune the result interface or its metadata consumers.
module deqacc_v2_timing_shell(
  input logic clk,reset,clear,rsp_valid,input mxu_rsp_t rsp,
  input acc_read_owner_e result_rd_owner,
  input logic result_rd_valid,input acc_sel_e result_rd_sel,input logic [9:0] result_rd_addr,
  input logic vpu_wr_valid,input acc_write_t vpu_wr,
  output logic result_rd_ready,vpu_wr_ready,result_rd_data_valid,commit_valid,done,commit_write_valid,
  output pair_meta_t commit_meta,output acc_write_t commit_write,
  output logic [15:0][31:0] result_even_data,result_odd_data
);
  (* shreg_extract="no" *) logic reset_q,clear_q,rsp_valid_q,rd_valid_q,wr_valid_q;
  (* shreg_extract="no" *) mxu_rsp_t rsp_q;
  acc_read_owner_e owner_q;
  acc_sel_e sel_q;logic [9:0] addr_q;acc_write_t wr_q;
  logic rd_ready_i,wr_ready_i,data_valid_i,commit_i,done_i,write_valid_i;
  pair_meta_t meta_i;acc_write_t write_i;
  logic [15:0][31:0] even_i,odd_i;
  wire core_clk;
  // Actual global clock network for the routed OOC characterization, rather
  // than an unbuffered virtual clock input with estimated insertion delay.
  BUFG clock_buffer(.I(clk),.O(core_clk));
  // External launch boundaries are not part of the functional core latency.
  always_ff @(posedge core_clk)begin
    reset_q<=reset;clear_q<=clear;rsp_valid_q<=rsp_valid;rsp_q<=rsp;
    owner_q<=result_rd_owner;rd_valid_q<=result_rd_valid;sel_q<=result_rd_sel;addr_q<=result_rd_addr;
    wr_valid_q<=vpu_wr_valid;wr_q<=vpu_wr;
    result_rd_ready<=rd_ready_i;vpu_wr_ready<=wr_ready_i;result_rd_data_valid<=data_valid_i;
    result_even_data<=even_i;result_odd_data<=odd_i;
    commit_valid<=commit_i;done<=done_i;commit_meta<=meta_i;
    commit_write_valid<=write_valid_i;commit_write<=write_i;
  end
  DEQACC_V1 core(.clk(core_clk),.reset(reset_q),.clear(clear_q),.rsp_valid(rsp_valid_q),.rsp(rsp_q),
    .result_rd_owner(owner_q),.result_rd_valid(rd_valid_q),.result_rd_ready(rd_ready_i),
    .result_rd_sel(sel_q),.result_rd_addr(addr_q),.vpu_wr_valid(wr_valid_q),.vpu_wr_ready(wr_ready_i),.vpu_wr(wr_q),
    .result_rd_data_valid(data_valid_i),.result_even_data(even_i),.result_odd_data(odd_i),
    .commit_valid(commit_i),.done(done_i),.commit_meta(meta_i),.commit_write_valid(write_valid_i),.commit_write(write_i),
    .dbg_valid(1'b0),.dbg_sel(ACC_OACC),.dbg_parity(1'b0),.dbg_addr('0),.dbg_lane('0),.dbg_data());
endmodule
