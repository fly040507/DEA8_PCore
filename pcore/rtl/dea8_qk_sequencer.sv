import dea8_pcore_pkg::*;

// One QK job in flight. Context survives issue and pipeline drain through L4.
module dea8_qk_sequencer (
  input logic clk, rst_n,
  input logic job_valid, resources_ready,
  output logic job_ready, job_busy, job_done,
  input logic [BLOCK_BITS-1:0] job_block_id,
  input logic [HEAD_BITS-1:0] job_head,
  input logic [EPOCH_BITS-1:0] job_epoch,
  input logic job_facc_bank,
  output logic [BLOCK_BITS-1:0] current_block_id,
  output logic [HEAD_BITS-1:0] current_head,
  output logic [EPOCH_BITS-1:0] current_epoch,
  output logic current_facc_bank,
  input logic load_valid,
  input logic [TILE_IDX_BITS-1:0] load_weight_idx,
  input logic bank_activate,
  input bank_state_e bank_state_a, bank_state_b,
  output logic bank_load_enable,
  output logic qoz_rd_en,
  output logic [QOZ_ADDR_BITS-1:0] qoz_rd_addr,
  output logic req_valid,
  input logic req_ready,
  output pipe_tag_t req_tag,
  output deq_dest_t req_dest,
  input logic commit_valid,
  input pipe_tag_t commit_tag,
  input deq_dest_t commit_dest
);
  localparam int TILE_COUNT_BITS = $clog2(HEAD_TILES+1);
  localparam int JOB_WORDS = SUFFIX_LEN*HEAD_TILES;
  localparam int WORD_COUNT_BITS = $clog2(JOB_WORDS+1);
  logic [ROW_BITS-1:0] row_q;
  logic [TOKEN_BITS-1:0] kt_q;
  logic [TILE_COUNT_BITS-1:0] loaded_tiles_q, activated_tiles_q;
  logic [WORD_COUNT_BITS-1:0] committed_q;
  logic issue_done_q, tile_available;
  pipe_tag_t read_tag;
  deq_dest_t read_dest;

  assign job_ready = rst_n && !job_busy && resources_ready;
  assign job_done = job_busy && commit_valid && commit_tag.last;
  assign bank_load_enable = job_busy && loaded_tiles_q < HEAD_TILES;
  // Read one edge before final bank load so Q_ACT_REG captures on load16.
  // On a continuous tile boundary, the READY bank covers the upcoming row0.
  assign tile_available = (activated_tiles_q > kt_q) ||
                          bank_state_a == BANK_READY || bank_state_b == BANK_READY ||
                          (load_valid && load_weight_idx == TILE-2);
  assign qoz_rd_en = rst_n && job_busy && !issue_done_q &&
                     ((row_q != 0) || tile_available);
  assign qoz_rd_addr = QOZ_ADDR_BITS'(row_q*QOZ_TILES + kt_q);

  always_comb begin
    read_tag = '0;
    read_tag.row = row_q;
    read_tag.kt = kt_q;
    read_tag.nt = '0;
    read_tag.head = current_head;
    read_tag.epoch = current_epoch;
    read_tag.lane_mask = '1;
    read_tag.exp_fold = EXP_FOLD_BITS'(QK_EXP_FOLD);
    read_tag.final_k = kt_q == HEAD_TILES-1;
    read_tag.last = read_tag.final_k && row_q == SUFFIX_LEN-1;
    read_dest.acc_sel = current_facc_bank ? ACC_FACC_B : ACC_FACC_A;
    read_dest.acc_addr = ACC_ADDR_BITS'(row_q);
    read_dest.acc_clear = kt_q == 0;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      job_busy <= 0;
      current_block_id <= '0; current_head <= '0;
      current_epoch <= '0; current_facc_bank <= 0;
      row_q <= '0; kt_q <= '0; issue_done_q <= 0;
      loaded_tiles_q <= '0; activated_tiles_q <= '0; committed_q <= '0;
      req_valid <= 0; req_tag <= '0; req_dest <= '0;
    end else begin
      // Same read edge as QOZ/E_QOZ; data and metadata reach MXU together.
      req_valid <= qoz_rd_en;
      if (qoz_rd_en) begin
        req_tag <= read_tag;
        req_dest <= read_dest;
        if (row_q == SUFFIX_LEN-1) begin
          row_q <= '0;
          if (kt_q == HEAD_TILES-1) issue_done_q <= 1;
          else kt_q <= kt_q + 1'b1;
        end else row_q <= row_q + 1'b1;
      end
      if (job_valid && job_ready) begin
        job_busy <= 1;
        current_block_id <= job_block_id;
        current_head <= job_head;
        current_epoch <= job_epoch;
        current_facc_bank <= job_facc_bank;
        row_q <= '0; kt_q <= '0; issue_done_q <= 0;
        loaded_tiles_q <= '0; activated_tiles_q <= '0; committed_q <= '0;
      end else if (job_busy) begin
        if (load_valid && load_weight_idx == 0) loaded_tiles_q <= loaded_tiles_q + 1'b1;
        if (bank_activate) activated_tiles_q <= activated_tiles_q + 1'b1;
        if (commit_valid) committed_q <= committed_q + 1'b1;
        if (job_done) job_busy <= 0;
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk) if (rst_n) begin
    if (req_valid && !req_ready) $fatal(1, "QK synchronous response not accepted");
    if (commit_valid) begin
      if (!job_busy || commit_tag.epoch != current_epoch || commit_tag.head != current_head ||
          commit_tag.row != committed_q % SUFFIX_LEN || commit_tag.kt != committed_q / SUFFIX_LEN ||
          commit_tag.exp_fold != QK_EXP_FOLD || commit_tag.nt != 0 ||
          commit_dest.acc_sel != (current_facc_bank ? ACC_FACC_B : ACC_FACC_A) ||
          commit_dest.acc_addr != commit_tag.row || commit_dest.acc_clear != (commit_tag.kt == 0))
        $fatal(1, "QK commit context mismatch");
      if (commit_tag.last != (committed_q == JOB_WORDS-1) ||
          commit_tag.final_k != (commit_tag.kt == HEAD_TILES-1))
        $fatal(1, "QK final_k/last mismatch");
    end
    if (job_done && (!issue_done_q || committed_q != JOB_WORDS-1))
      $fatal(1, "QK completed before all commits");
  end
  initial if ($bits(pipe_tag_t) != 58 || $bits(deq_dest_t) != 13)
    $fatal(1, "Frozen QK metadata widths changed");
  // synthesis translate_on
endmodule
