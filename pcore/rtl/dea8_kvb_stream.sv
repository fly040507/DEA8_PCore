import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// One Top Job starts all 110 K/V blocks. Entries are already B columns.
// No block request, transpose, full-tile staging, or wait-for-256 gate.
module dea8_kvb_stream #(
  parameter int FIFO_DEPTH = KVFIFO_DEPTH
) (
  input logic clk, rst_n, start,
  input logic [HEAD_BITS-1:0] head,
  input logic [EPOCH_BITS-1:0] epoch,
  input logic kvb_valid,
  output logic kvb_ready,
  input logic [DW_ACT-1:0] kvb_q,
  input logic [SCALE_BITS-1:0] kvb_e,
  input logic kvb_kind,
  input logic [BLOCK_BITS-1:0] kvb_blk_id,
  input logic [TILE_IDX_BITS-1:0] kvb_key_lane,kvb_feat_blk,
  input logic [TILE-1:0] kvb_valid_mask,
  input logic kvb_last,
  input logic [EPOCH_BITS-1:0] kvb_epoch,
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
    logic [TILE_IDX_BITS-1:0] column,tile;
    logic [TILE-1:0] mask;
    logic last;
    logic [EPOCH_BITS-1:0] epoch;
  } entry_t;
  localparam int TOTAL_ENTRIES=MATRIX_JOB_COUNT*HEAD_TILES*TILE;
  logic [$clog2(TOTAL_ENTRIES+1)-1:0] received_q;
  entry_t incoming,front;
  logic fifo_valid,fifo_ready,input_ready,active_q,bad;
  logic [MATRIX_JOB_INDEX_BITS-1:0] stream_job_q;
  logic [$clog2(HEAD_TILES*TILE)-1:0] entry_q;
  logic [HEAD_BITS-1:0] head_q;
  logic [EPOCH_BITS-1:0] epoch_q;
  matrix_block_job_t expected;
  logic [N_KV_BLOCK-1:0] mask_seen_q;
  logic [TILE-1:0] masks_q[0:N_KV_BLOCK-1];
  logic [EPOCH_BITS-1:0] epochs_q[0:N_KV_BLOCK-1];
  assign incoming={kvb_q,kvb_e,kvb_kind,kvb_blk_id,kvb_key_lane,kvb_feat_blk,
                   kvb_valid_mask,kvb_last,kvb_epoch};
  dea8_stream_fifo #(.WIDTH($bits(entry_t)),.DEPTH(FIFO_DEPTH)) kvfifo (
    .clk,.rst_n(rst_n && !start),
    .in_valid(kvb_valid && active_q && !protocol_error && received_q<TOTAL_ENTRIES),
    .in_ready(input_ready),.in_data(incoming),.out_valid(fifo_valid),
    .out_ready(fifo_ready),.out_data(front),.count()
  );
  assign kvb_ready=active_q && !protocol_error && input_ready && received_q<TOTAL_ENTRIES;
  assign expected=attention_block_job(int'(stream_job_q),head_q,epoch_q);
  assign b_valid=active_q && fifo_valid && !bad && !protocol_error;
  assign fifo_ready=b_valid && b_ready;
  assign b_data=front.q;
  assign b_scale=front.e;
  always_comb begin
    mask_valid=0; mask_data='0;
    if(mask_block<N_KV_BLOCK) begin
      mask_valid=mask_seen_q[mask_block] && epochs_q[mask_block]==mask_epoch;
      mask_data=masks_q[mask_block];
    end
    bad=0;
    if(active_q && fifo_valid) begin
      bad=front.kind!=(expected.op==MATRIX_PV) || front.block_id!=expected.ctx.block_id ||
          front.epoch!=epoch_q || front.tile!=entry_q/TILE || front.column!=entry_q%TILE ||
          front.last!=(entry_q==HEAD_TILES*TILE-1);
      if(front.block_id<N_KV_BLOCK) begin
        if(mask_seen_q[front.block_id] && epochs_q[front.block_id]==epoch_q)
          bad|=masks_q[front.block_id]!=front.mask;
        for(int k=0;k<TILE;k++)
          if(int'(front.block_id)*TILE+k>=LOGICAL_SEQ && front.mask[k]) bad=1;
      end else bad=1;
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      active_q<=0; stream_job_q<='0; entry_q<='0; head_q<='0; epoch_q<='0;
      mask_seen_q<='0; protocol_error<=0; received_q<='0;
    end else if(start) begin
      active_q<=1; stream_job_q<='0; entry_q<='0; head_q<=head; epoch_q<=epoch;
      mask_seen_q<='0; protocol_error<=0; received_q<='0;
    end else begin
      if(bad) protocol_error<=1;
      if(kvb_valid && kvb_ready) received_q<=received_q+1'b1;
      if(fifo_ready) begin
        masks_q[front.block_id]<=front.mask; epochs_q[front.block_id]<=epoch_q;
        mask_seen_q[front.block_id]<=1;
        if(entry_q==HEAD_TILES*TILE-1) begin
          entry_q<='0; stream_job_q<=stream_job_q+1'b1;
          if(stream_job_q==MATRIX_JOB_COUNT-1) active_q<=0;
        end else entry_q<=entry_q+1'b1;
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(rst_n && bad) $fatal(1,"Continuous KVB protocol/order/mask mismatch");
  // synthesis translate_on
endmodule
