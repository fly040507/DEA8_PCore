import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// Transport only: the stationary loader remains the sole bank owner.
module dea8_kvb_adapter #(
  parameter int FIFO_DEPTH = 512,
  // Enable only when GCore confirms V key_lane encodes feature offset.
  parameter bit V_KEY_LANE_IS_COLUMN = 0
) (
  input logic clk, rst_n,
  input logic kvb_valid,
  output logic kvb_ready,
  input logic [DW_ACT-1:0] kvb_q,
  input logic [SCALE_BITS-1:0] kvb_e,
  input logic kvb_kind,
  input logic [BLOCK_BITS-1:0] kvb_blk_id,
  input logic [TILE_IDX_BITS-1:0] kvb_key_lane, kvb_feat_blk,
  input logic [TILE-1:0] kvb_valid_mask,
  input logic kvb_last,
  input logic [EPOCH_BITS-1:0] kvb_epoch,
  input logic expect_valid,
  output logic expect_ready,
  input matrix_job_t expect_job,
  output logic b_valid,
  input logic b_ready,
  output logic [DW_ACT-1:0] b_data,
  output logic [SCALE_BITS-1:0] b_scale,
  input logic [BLOCK_BITS-1:0] mask_block,
  input logic [EPOCH_BITS-1:0] mask_epoch,
  output logic mask_valid,
  output logic [TILE-1:0] mask_data,
  output logic protocol_error
);
  typedef struct packed {
    logic [DW_ACT-1:0] q;
    logic [SCALE_BITS-1:0] e;
    logic kind;
    logic [BLOCK_BITS-1:0] block_id;
    logic [TILE_IDX_BITS-1:0] column, tile;
    logic [TILE-1:0] mask;
    logic last;
    logic [EPOCH_BITS-1:0] epoch;
  } transaction_t;
  localparam int ENTRIES = HEAD_TILES*TILE;
  localparam int INDEX_BITS = $clog2(ENTRIES);
  transaction_t incoming, front;
  logic fifo_valid, fifo_ready, active_q, bad;
  logic [INDEX_BITS-1:0] index_q;
  matrix_job_t context_q;
  logic [N_KV_BLOCK-1:0] mask_seen_q;
  logic [TILE-1:0] masks_q [0:N_KV_BLOCK-1];
  logic [EPOCH_BITS-1:0] epochs_q [0:N_KV_BLOCK-1];

  assign incoming = {kvb_q,kvb_e,kvb_kind,kvb_blk_id,kvb_key_lane,
                     kvb_feat_blk,kvb_valid_mask,kvb_last,kvb_epoch};
  // Packed data and metadata enter/leave on exactly the same handshake.
  dea8_stream_fifo #(.WIDTH($bits(transaction_t)),.DEPTH(FIFO_DEPTH)) kvfifo (
    .clk,.rst_n,.in_valid(kvb_valid),.in_ready(kvb_ready),.in_data(incoming),
    .out_valid(fifo_valid),.out_ready(fifo_ready),.out_data(front),.count()
  );
  assign expect_ready = rst_n && !active_q && !protocol_error;
  assign b_data = front.q;
  assign b_scale = front.e;
  assign b_valid = rst_n && active_q && fifo_valid && !bad && !protocol_error;
  assign fifo_ready = b_valid && b_ready;

  always_comb begin
    mask_valid = 0;
    mask_data = '0;
    if (mask_block < N_KV_BLOCK) begin
      mask_valid = mask_seen_q[mask_block] && epochs_q[mask_block]==mask_epoch;
      mask_data = masks_q[mask_block];
    end
    bad = 0;
    if (active_q && fifo_valid) begin
      bad = front.kind != (context_q.op==MATRIX_PV) ||
            front.block_id != context_q.ctx.block_id ||
            front.epoch != context_q.ctx.epoch || front.block_id >= N_KV_BLOCK ||
            front.tile != index_q/TILE || front.column != index_q%TILE ||
            front.last != (index_q==ENTRIES-1) ||
            (front.kind && !V_KEY_LANE_IS_COLUMN);
      if (front.block_id < N_KV_BLOCK) begin
        if (mask_seen_q[front.block_id] && epochs_q[front.block_id]==front.epoch)
          bad |= masks_q[front.block_id] != front.mask;
        for (int k=0;k<TILE;k++)
          if (int'(front.block_id)*TILE+k >= LOGICAL_SEQ && front.mask[k]) bad = 1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_q <= 0;
      context_q <= '0;
      index_q <= '0;
      mask_seen_q <= '0;
      protocol_error <= 0;
    end else begin
      if (expect_valid && expect_ready) begin
        active_q <= 1;
        context_q <= expect_job;
        index_q <= '0;
      end
      if (bad) protocol_error <= 1;
      if (fifo_ready) begin
        masks_q[front.block_id] <= front.mask;
        epochs_q[front.block_id] <= front.epoch;
        mask_seen_q[front.block_id] <= 1;
        if (index_q==ENTRIES-1) active_q <= 0;
        else index_q <= index_q+1'b1;
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk) if (rst_n && bad)
    $fatal(1,"KVB protocol/context/order/mask mismatch");
  // synthesis translate_on
endmodule
