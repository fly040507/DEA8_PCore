import pcore3_pkg::*;
// Operation ownership is stable until the adapter drains all work. No RR or
// extra command register: preserve same-edge completion/next launch timing.
module dea8_matrix_job_dispatch_v3(
  input logic clk,reset,clear,input logic [1:0] owner,
  input matrix_service_req_t requests[0:2],output matrix_service_rsp_t responses[0:2],
  input logic xbc_valid,output logic xbc_ready,input xbc4_t xbc_entry,
  input logic hbm_valid,output logic hbm_ready,input b2_t hbm_entry,
  input logic kv_valid,output logic kv_ready,input b2_t kv_entry,
  output logic protocol_error
);
  matrix_service_req_t req;matrix_service_rsp_t rsp;
  assign req=requests[owner];
  for(genvar i=0;i<3;i++)assign responses[i]=(owner==i)?rsp:matrix_service_rsp_t'('0);
  assign protocol_error=rsp.a_error||rsp.b_error;
  dea8_matrix_v3 #(.SHARED_MODE(1)) matrix(
    .clk,.reset,.clear,.runtime_local_a(owner!=0),.runtime_streaming(owner==1),
    .xbc_valid,.xbc_ready,.xbc_entry,.local_a_valid(req.local_valid),.local_a_ready(rsp.local_ready),.local_a_entry(req.local_entry),
    .hbm_valid,.hbm_ready,.hbm_entry,.kv_valid,.kv_ready,.kv_entry,.b_source(owner==1?B_KVB:B_HBM),
    .job_start(req.start),.job_a_tile_idx('0),.job_b_tile_idx('0),.job_a_stream_idx(req.a_stream),.job_b_stream_idx(req.b_stream),
    .job_tiles(req.tiles),.job_m_rows(req.rows),.job_epoch(req.epoch),.job_head(req.head),.job_nt(req.nt),
    .job_nt_per_tile(req.nt_per_tile),.job_clear_each_tile(req.clear_each_tile),.job_final_k(req.final_k),
    .job_exp_fold(req.exp_fold),.job_mode(req.mode),.job_gu_n(req.gu_n),.gu_slot_ready(req.slot_ready),
    .job_acc_sel(req.acc_sel),.job_add_old(req.add_old),.job_ready(rsp.ready),.job_busy(rsp.busy),
    .done(rsp.done),.matrix_issue_done(rsp.issue_done),.commit_valid(rsp.commit_valid),.commit_meta(rsp.meta),
    .commit_write_valid(rsp.write_valid),.commit_write(rsp.write_data),.gu_slot_reserve(rsp.slot_reserve),
    .result_rd_owner(ACC_READ_RESULT),.result_rd_valid(req.rd_valid),.result_rd_ready(rsp.rd_ready),.result_rd_sel(req.rd_sel),.result_rd_addr(req.rd_addr),
    .result_rd_data_valid(rsp.rd_valid),.result_even_data(rsp.even_data),.result_odd_data(rsp.odd_data),
    .vpu_wr_valid(req.wr_valid),.vpu_wr_ready(rsp.wr_ready),.vpu_wr(req.wr),
    .dbg_valid(1'b0),.dbg_sel(ACC_OACC),.dbg_parity(1'b0),.dbg_addr('0),.dbg_lane('0),.dbg_data(),
    .a_protocol_error(rsp.a_error),.b_protocol_error(rsp.b_error));
endmodule
