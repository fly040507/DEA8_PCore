import dea8_pcore_pkg::*;

// 16x16 INT8 MXU.
// t0: activation/E_stream/Tag enter; t1: PE MUL; t2: L1;
// t3: L2; t4: L3; t5: L4 writes Psum_out_REG.
module dea8_mxu #(
  parameter bit COLUMN_LOAD = 0
) (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic                         clear,
  input  logic                         req_valid,
  output logic                         req_ready,
  input logic active_bank, active_valid,
  input logic bank_activate, new_active_bank,
  output logic tile_last_mul_fire, mul_valid,
  input  logic signed [TILE-1:0][ACT_BITS-1:0] activation,
  input  logic        [SCALE_BITS-1:0]         e_stream,
  input  pipe_tag_t                    req_tag,
  input  deq_dest_t                    req_dest,
  input  logic                         load_valid,
  input  logic                         load_bank,
  input  logic [TILE_IDX_BITS-1:0]    load_weight_idx,
  input  logic signed [TILE-1:0][WEIGHT_BITS-1:0] load_weight_beat,
  input  logic                         scale_load_valid,
  input  logic [SCALE_WORD_BITS-1:0]   load_scale_word,
  output logic                         rsp_valid,
  input  logic                         rsp_ready,
  output logic signed [TILE-1:0][PSUM_BITS-1:0] psum,
  output logic        [TILE-1:0][SCALE_BITS-1:0] e_stat,
  output logic        [SCALE_BITS-1:0]            rsp_e_stream,
  output pipe_tag_t                    rsp_tag,
  output deq_dest_t                    rsp_dest
);

  logic [TILE-1:0][SCALE_BITS-1:0] E_STAT_BANK [0:BANK_COUNT-1];
  logic [TILE-1:0][SCALE_BITS-1:0] E_STAT_ACTIVE_REG;
  logic [SCALE_BITS-1:0] E_STREAM_REG;
  pipe_tag_t ACT_TAG_REG;
  deq_dest_t DEQ_DEST_REG;
  logic ACT_VALID_REG;
  logic signed [ACT_BITS-1:0] Q_ACT_REG [0:TILE-1];
  logic signed [PRODUCT_BITS-1:0] product_q [0:TILE-1][0:TILE-1];
  logic signed [TREE_SUM_BITS-1:0] tree_l1_q [0:TILE-1][0:L1_COUNT-1];
  logic signed [TREE_SUM_BITS-1:0] tree_l2_q [0:TILE-1][0:L2_COUNT-1];
  logic signed [TREE_SUM_BITS-1:0] tree_l3_q [0:TILE-1][0:L3_COUNT-1];
  logic signed [PSUM_BITS-1:0] Psum_out_reg [0:TILE-1];
  logic valid_q [1:MXU_STAGES-1];
  pipe_tag_t tag_q [1:MXU_STAGES-1];
  deq_dest_t dest_q [1:MXU_STAGES-1];
  logic [SCALE_BITS-1:0] stream_q [1:MXU_STAGES-1];
  logic [TILE-1:0][SCALE_BITS-1:0] estat_q [1:MXU_STAGES-1];
  logic [ROW_BITS-1:0] expected_row_q;
  logic req_fire;
  assign mul_valid = !clear && ACT_VALID_REG && active_valid;
  assign tile_last_mul_fire = mul_valid && (ACT_TAG_REG.row == SUFFIX_LEN-1);
  assign req_ready = rst_n && !clear && (bank_activate || (active_valid && !tile_last_mul_fire));
  assign req_fire = req_valid && req_ready;
  assign rsp_valid = !clear && valid_q[MXU_STAGES-1];
  assign rsp_tag = tag_q[MXU_STAGES-1];
  assign rsp_dest = dest_q[MXU_STAGES-1];
  assign rsp_e_stream = stream_q[MXU_STAGES-1];
  assign e_stat = estat_q[MXU_STAGES-1];

  // 256 PE array. Weights are stored in each PE; activation is broadcast.
  genvar k_idx;
  genvar n_idx;
  generate
    for (k_idx = 0; k_idx < TILE; k_idx = k_idx + 1) begin : gen_pe_k
      for (n_idx = 0; n_idx < TILE; n_idx = n_idx + 1) begin : gen_pe_n
        dea8_pe #(.PE_INDEX(k_idx*TILE + n_idx)) u_pe (
          .clk         (clk),
          .rst_n       (rst_n),
          .ce          (mul_valid),
          .active_bank (active_bank),
          .load_we     (load_valid && (load_weight_idx == (COLUMN_LOAD ? n_idx : k_idx))),
          .load_bank   (load_bank),
          .load_weight (load_weight_beat[COLUMN_LOAD ? k_idx : n_idx]),
          .activation  (Q_ACT_REG[k_idx]),
          .product     (product_q[k_idx][n_idx])
        );
      end
    end
    for (n_idx = 0; n_idx < TILE; n_idx = n_idx + 1) begin : gen_output_lane
      assign psum[n_idx] = Psum_out_reg[n_idx];
    end
  endgenerate

  integer k;
  integer n;
  integer level;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ACT_VALID_REG <= 1'b0;
      ACT_TAG_REG <= '0;
      DEQ_DEST_REG <= '0;
      E_STREAM_REG <= '0;
      E_STAT_ACTIVE_REG <= '0;
      expected_row_q <= '0;
      for (level=1; level<MXU_STAGES; level++) begin
        valid_q[level] <= 1'b0;
        tag_q[level] <= '0;
        dest_q[level] <= '0;
        stream_q[level] <= '0;
        estat_q[level] <= '0;
      end
      for (n=0; n<TILE; n++) begin
        Q_ACT_REG[n] <= '0;
        Psum_out_reg[n] <= '0;
      end
    end else if (clear) begin
      ACT_VALID_REG <= 0;
      expected_row_q <= '0;
      for (level=1; level<MXU_STAGES; level++) valid_q[level] <= 0;
    end else begin
      if (scale_load_valid) begin
        if (COLUMN_LOAD)
          E_STAT_BANK[load_bank][load_weight_idx] <= load_scale_word[0+:SCALE_BITS];
        else E_STAT_BANK[load_bank] <= load_scale_word;
      end
      // Activation edge: sample new bank scales. The retiring multiply and
      // pipe[1] below still use pre-edge ACTIVE scales and pre-edge weights.
      if (bank_activate) begin
        E_STAT_ACTIVE_REG <= E_STAT_BANK[new_active_bank];
        // The final column and activation may arrive on the same edge.
        if (COLUMN_LOAD && scale_load_valid && load_bank == new_active_bank)
          E_STAT_ACTIVE_REG[load_weight_idx] <= load_scale_word[0+:SCALE_BITS];
      end
      ACT_VALID_REG <= req_fire;
      if (req_fire) begin
        for (k=0; k<TILE; k++) Q_ACT_REG[k] <= activation[k];
        E_STREAM_REG <= e_stream;
        ACT_TAG_REG <= req_tag;
        DEQ_DEST_REG <= req_dest;
      end
      valid_q[1] <= mul_valid;
      if (mul_valid) begin
        tag_q[1] <= ACT_TAG_REG;
        dest_q[1] <= DEQ_DEST_REG;
        stream_q[1] <= E_STREAM_REG;
        estat_q[1] <= E_STAT_ACTIVE_REG;
        expected_row_q <= tile_last_mul_fire ? '0 : expected_row_q + 1'b1;
      end
      for (level=2; level<MXU_STAGES; level++) begin
        valid_q[level] <= valid_q[level-1];
        tag_q[level] <= tag_q[level-1];
        dest_q[level] <= dest_q[level-1];
        stream_q[level] <= stream_q[level-1];
        estat_q[level] <= estat_q[level-1];
      end
        // Registered reduction tree. Nonblocking assignments consume the
        // previous stage, giving one enabled cycle per reduction level.
        for (n = 0; n < TILE; n = n + 1) begin
          for (level = 0; level < L1_COUNT; level = level + 1) begin
            tree_l1_q[n][level] <=
              product_q[2*level][n] + product_q[2*level+1][n];
          end
          for (level = 0; level < L2_COUNT; level = level + 1) begin
            tree_l2_q[n][level] <=
              tree_l1_q[n][2*level] + tree_l1_q[n][2*level+1];
          end
          for (level = 0; level < L3_COUNT; level = level + 1) begin
            tree_l3_q[n][level] <=
              tree_l2_q[n][2*level] + tree_l2_q[n][2*level+1];
          end

          // Adder_L4 is part of this same four-level tree. It consumes the
          // previous-cycle L3 result and writes Psum_out_REG directly.
          // There is no independent tree_l4 register.
          Psum_out_reg[n] <= tree_l3_q[n][0] + tree_l3_q[n][1];
        end

    end
  end
  always @(posedge clk) if (rst_n && !clear) begin
    if (ACT_VALID_REG && !active_valid) $fatal(1, "Activation without ACTIVE bank");
    if (mul_valid && ACT_TAG_REG.row != expected_row_q) $fatal(1, "Nonconsecutive row");
    if (expected_row_q != 0 && !mul_valid) $fatal(1, "Local stall inside tile");
    if (rsp_valid && !rsp_ready) $fatal(1, "Result capacity not reserved");
    if (load_valid && active_valid && load_bank == active_bank) $fatal(1, "Write ACTIVE bank");
  end
  initial begin
    if ($bits(pipe_tag_t) != 58 || $bits(deq_dest_t) != 13)
      $fatal(1, "Frozen transaction widths require Tag=58, Dest=13");
    if (TILE != 16 || MXU_STAGES != 6) $fatal(1, "Tree requires TILE=16, MXU_STAGES=6");
  end
endmodule
