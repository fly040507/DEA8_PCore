import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// Real shared QK/PV arithmetic. B input is normalized column transport.
// External KVB packing is deliberately isolated from this arithmetic contract.
module dea8_matrix_engine #(
  parameter bit ENABLE_LOOKAHEAD = 0
) (
  input logic clk, rst_n,
  input logic job_valid, resources_ready,
  output logic job_ready, job_busy, job_done_valid,
  input logic job_done_ready,
  input matrix_job_t job,
  output matrix_job_t current_job,
  input logic next_job_valid,
  input matrix_job_t next_job,
  input logic b_valid,
  output logic b_ready,
  input logic [DW_ACT-1:0] b_data,
  input logic [SCALE_BITS-1:0] b_scale,
  output logic a_rd_en,
  output matrix_job_t a_read_job,
  output logic [QOZ_ADDR_BITS-1:0] a_rd_addr,
  input logic [DW_ACT-1:0] a_data,
  input logic [SCALE_BITS-1:0] a_scale,
  output logic mem_rd_en, mem_wr_en,
  output acc_sel_e mem_rd_sel, mem_wr_sel,
  output logic [ACC_ADDR_BITS-1:0] mem_rd_addr, mem_wr_addr,
  input logic [DW_VEC-1:0] mem_rd_data,
  output logic [DW_VEC-1:0] mem_wr_data,
  output logic [TILE-1:0] mem_wr_lane_en,
  output logic commit_valid,
  output pipe_tag_t commit_tag,
  output deq_dest_t commit_dest
);
  logic tile_last_mul_fire, active_bank, active_valid;
  logic load_bank, load_valid, scale_load_valid, load_tile_complete, bank_activate, new_active_bank;
  logic [TILE_IDX_BITS-1:0] load_weight_idx;
  logic signed [TILE-1:0][WEIGHT_BITS-1:0] load_weight_beat;
  logic [SCALE_WORD_BITS-1:0] load_scale_word;
  bank_state_e bank_state_a,bank_state_b;
  logic req_valid,req_ready,rsp_valid,mul_valid;
  pipe_tag_t req_tag,rsp_tag;
  deq_dest_t req_dest,rsp_dest;
  logic signed [TILE-1:0][PSUM_BITS-1:0] psum;
  logic [TILE-1:0][SCALE_BITS-1:0] e_stat;
  logic [SCALE_BITS-1:0] rsp_e_stream;
  mxu_rsp_t deq_req;
  b_entry_t entry;
  assign entry={b_data,b_scale};
  dea8_b_column_loader columns (.*);
  dea8_matrix_sequencer #(.ENABLE_LOOKAHEAD(ENABLE_LOOKAHEAD)) sequencer (.*);
  dea8_mxu #(.COLUMN_LOAD(1)) mxu (.activation(a_data),.e_stream(a_scale),.rsp_ready(1'b1),.*);
  assign deq_req='{psum:psum,e_stat:e_stat,e_stream:rsp_e_stream,tag:rsp_tag};
  dea8_deqacc deq (
    .clk,.rst_n,.req_valid(rsp_valid),.req(deq_req),.req_dest(rsp_dest),
    .mem_rd_en,.mem_rd_sel,.mem_rd_addr,.mem_rd_data,
    .mem_wr_en,.mem_wr_sel,.mem_wr_addr,.mem_wr_data,.mem_wr_lane_en,
    .commit_valid,.commit_tag,.commit_dest
  );
endmodule
