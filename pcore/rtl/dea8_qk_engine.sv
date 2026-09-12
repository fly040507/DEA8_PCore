import dea8_pcore_pkg::*;

// QK-only execution top. External scheduling reserves QOZ and the FACC bank.
// The HBM stream must contain this job's 16 B tiles in kt order.
module dea8_qk_engine (
  input logic clk, rst_n,
  input logic job_valid, resources_ready,
  output logic job_ready, job_busy, job_done,
  input logic [BLOCK_BITS-1:0] job_block_id,
  input logic [HEAD_BITS-1:0] job_head,
  input logic [EPOCH_BITS-1:0] job_epoch,
  input logic job_facc_bank,
  output logic [BLOCK_BITS-1:0] current_block_id,
  input logic hbm_valid,
  output logic hbm_ready,
  input logic [HBM_BITS-1:0] hbm_data,
  input logic qoz_wr_en,
  input logic [QOZ_ADDR_BITS-1:0] qoz_wr_addr,
  input logic [DW_ACT-1:0] qoz_wr_data,
  input logic [SCALE_BITS-1:0] qoz_wr_scale,
  input logic facc_rd_en, facc_rd_bank,
  input logic [ROW_BITS-1:0] facc_rd_addr,
  output logic facc_rd_valid,
  output logic [DW_VEC-1:0] facc_rd_data,
  output logic commit_valid,
  output pipe_tag_t commit_tag,
  output deq_dest_t commit_dest
);
  logic [HEAD_BITS-1:0] current_head;
  logic [EPOCH_BITS-1:0] current_epoch;
  logic current_facc_bank;
  logic load_valid, load_bank, scale_load_valid, load_tile_complete;
  logic [TILE_IDX_BITS-1:0] load_weight_idx;
  logic signed [TILE-1:0][WEIGHT_BITS-1:0] load_weight_beat;
  logic [SCALE_WORD_BITS-1:0] load_scale_word;
  logic bank_load_enable, bank_activate, new_active_bank, active_bank, active_valid;
  logic tile_last_mul_fire, mul_valid;
  bank_state_e bank_state_a, bank_state_b;
  logic qoz_rd_en, req_valid, req_ready, rsp_valid;
  logic [QOZ_ADDR_BITS-1:0] qoz_rd_addr;
  logic [DW_ACT-1:0] activation;
  logic [SCALE_BITS-1:0] e_stream, rsp_e_stream;
  pipe_tag_t req_tag, rsp_tag;
  deq_dest_t req_dest, rsp_dest;
  logic signed [TILE-1:0][PSUM_BITS-1:0] psum;
  logic [TILE-1:0][SCALE_BITS-1:0] e_stat;
  mxu_rsp_t deq_req;
  logic mem_rd_en, mem_wr_en;
  acc_sel_e mem_rd_sel, mem_wr_sel;
  logic [ACC_ADDR_BITS-1:0] mem_rd_addr, mem_wr_addr;
  logic [DW_VEC-1:0] mem_rd_data, mem_wr_data;
  logic [TILE-1:0] mem_wr_lane_en;

  dea8_qk_sequencer sequencer (.*);
  dea8_w_loader loader (.*);
  dea8_qoz_buffer qoz (
    .clk, .wr_en(qoz_wr_en && !job_busy), .wr_addr(qoz_wr_addr),
    .wr_data(qoz_wr_data), .wr_scale(qoz_wr_scale),
    .rd_en(qoz_rd_en), .rd_addr(qoz_rd_addr), .rd_data(activation), .rd_scale(e_stream)
  );
  dea8_mxu mxu (.rsp_ready(1'b1), .*);
  assign deq_req = '{psum:psum, e_stat:e_stat, e_stream:rsp_e_stream, tag:rsp_tag};
  dea8_deqacc deq (
    .clk, .rst_n, .req_valid(rsp_valid), .req(deq_req), .req_dest(rsp_dest),
    .mem_rd_en, .mem_rd_sel, .mem_rd_addr, .mem_rd_data,
    .mem_wr_en, .mem_wr_sel, .mem_wr_addr, .mem_wr_lane_en, .mem_wr_data,
    .commit_valid, .commit_tag, .commit_dest
  );
  dea8_accumulator_storage accum (
    .clk, .rd_en(job_busy ? mem_rd_en : facc_rd_en),
    .rd_sel(job_busy ? mem_rd_sel : (facc_rd_bank ? ACC_FACC_B : ACC_FACC_A)),
    .rd_addr(job_busy ? mem_rd_addr : ACC_ADDR_BITS'(facc_rd_addr)), .rd_data(mem_rd_data),
    .wr_en(mem_wr_en), .wr_sel(mem_wr_sel), .wr_addr(mem_wr_addr),
    .wr_lane_en(mem_wr_lane_en), .wr_data(mem_wr_data)
  );
  assign facc_rd_data = mem_rd_data;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) facc_rd_valid <= 0;
    else facc_rd_valid <= !job_busy && facc_rd_en;
  // synthesis translate_off
  always @(posedge clk) if (rst_n) begin
    if (job_busy && qoz_wr_en) $fatal(1, "QOZ write during reserved QK job");
    if (job_busy && facc_rd_en) $fatal(1, "FACC read during reserved QK job");
  end
  // synthesis translate_on
endmodule
