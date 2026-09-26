import pcore3_pkg::*;

// Minimal complete Matrix-side job path for the new data-plane contract.
//
// XBC4 -> AFIFO -> MXU and HBM/KVB(B2) -> BFIFO -> serializer -> B loader ->
// MXU are kept as independent streams.  The scheduler only reserves A after
// both the A Tile and its stationary B bank are ready.  MXU response metadata
// then enters the 32-lane DEQACC without a testbench-side golden injection.
module dea8_matrix_v3 (
  input logic clk,reset,clear,
  input logic xbc_valid,
  output logic xbc_ready,
  input xbc4_t xbc_entry,
  input logic hbm_valid,
  output logic hbm_ready,
  input b2_t hbm_entry,
  input logic kv_valid,
  output logic kv_ready,
  input b2_t kv_entry,
  input b_source_e b_source,
  input logic job_start,
  input logic [TILE_BITS-1:0] job_tile_idx,
  input logic [EPOCH_BITS-1:0] job_epoch,
  input logic [2:0] job_head,
  input logic job_final_k,
  input logic signed [EXP_FOLD_BITS-1:0] job_exp_fold,
  input acc_sel_e job_acc_sel,
  input logic job_acc_clear,
  output logic job_busy,
  output logic commit_valid,
  output logic done,
  output pair_meta_t commit_meta,
  input logic dbg_valid,
  input acc_sel_e dbg_sel,
  input logic dbg_parity,
  input logic [9:0] dbg_addr,
  input logic [3:0] dbg_lane,
  output logic [31:0] dbg_data,
  output logic a_protocol_error,
  output logic b_protocol_error
);
  // XBC4 adapter and A2 FIFO.
  logic [1:0] a2_valid,a2_ready;
  a2_t a2_entry[0:1];
  logic a_tile_available,a_running,a_out_valid;
  a2_t a_head;
  logic [6:0] a_count;
  logic [$clog2(AFIFO_DEPTH/PAIRS+1)-1:0] a_complete;
  logic a_reserve;

  dea8_xbc4_adapter_v3 xbc_adapter(
    .clk,.reset,.clear,.in_valid(xbc_valid),.in_ready(xbc_ready),
    .in_entry(xbc_entry),.out_valid(a2_valid),.out_ready(a2_ready),
    .out_entry(a2_entry));
  dea8_afifo_v3 a_fifo(
    .clk,.reset,.clear,.in_valid(a2_valid),.in_ready(a2_ready),
    .in_entry(a2_entry),.reserve_tile(a_reserve),
    .tile_available(a_tile_available),.running(a_running),
    .out_valid(a_out_valid),.out_entry(a_head),
    .protocol_error(a_protocol_error),.count(a_count),
    .complete_tiles(a_complete));

  // HBM and KVB are logical B2 sources at this boundary.  Physical HBM
  // repacking remains in the external controller, as specified by the plan.
  logic b_in_valid,b_in_ready;
  b2_t b_in_entry,b_head;
  logic b_out_valid,b_out_ready,b_tile_available,b_protocol;
  logic [6:0] b_count;
  logic [3:0] b_complete;
  assign b_in_valid=(b_source==B_KVB)?kv_valid:hbm_valid;
  assign b_in_entry=(b_source==B_KVB)?kv_entry:hbm_entry;
  assign hbm_ready=(b_source==B_HBM)&&b_in_ready;
  assign kv_ready=(b_source==B_KVB)&&b_in_ready;
  dea8_bfifo_v3 b_fifo(
    .clk,.reset,.clear,.in_valid(b_in_valid),.in_ready(b_in_ready),
    .in_entry(b_in_entry),.out_valid(b_out_valid),.out_ready(b_out_ready),
    .out_entry(b_head),.tile_available(b_tile_available),
    .protocol_error(b_protocol),.count(b_count),.complete_tiles(b_complete));
  assign b_protocol_error=b_protocol;

  // B2 -> B1 -> stationary bank loading.
  logic serializer_start,serializer_allow,serializer_in_ready;
  logic serializer_out_valid,serializer_out_ready,serializer_busy;
  b1_t serializer_out;
  logic [1:0] bank_ready;
  logic [TILE_BITS-1:0] bank_tile[0:1];
  logic load_valid,load_bank;
  logic [3:0] load_column;
  qvec16_t load_col;
  dea8_b_serializer_v3 b_serializer(
    .clk,.reset,.clear,.start_tile(serializer_allow),
    .in_valid(b_out_valid),.in_ready(serializer_in_ready),.in_entry(b_head),
    .out_valid(serializer_out_valid),.out_ready(serializer_out_ready),
    .out_entry(serializer_out),.busy(serializer_busy));
  assign b_out_ready=serializer_in_ready;
  dea8_b_loader_v3 b_loader(
    .clk,.reset,.clear,.enable(1'b1),.tile_available(b_tile_available),
    .bfifo_head(b_head),.serializer_busy(serializer_busy),
    .serializer_start(serializer_start),.serializer_allow(serializer_allow),
    .b1_valid(serializer_out_valid),.b1_ready(serializer_out_ready),
    .b1_entry(serializer_out),.release_valid(1'b0),.release_bank(1'b0),
    .bank_ready,.bank_tile,.load_valid,.load_bank,.load_column,.load_col);

  // One-job scheduler.  The AFIFO itself provides the exact 26-cycle issue
  // stream after reservation; no extra A-side staging register is inserted.
  logic job_pending;
  logic req_valid;
  pair_meta_t req_meta;
  logic req_bank;
  assign req_bank=job_tile_idx[0];
  assign a_reserve=job_pending&&!a_running&&a_tile_available&&bank_ready[req_bank];
  assign req_valid=a_running&&a_out_valid;
  assign job_busy=job_pending||a_running;
  always_comb begin
    req_meta='0;
    req_meta.epoch=job_epoch;
    req_meta.head=job_head;
    req_meta.tile_idx=job_tile_idx;
    req_meta.pair_idx=a_head.pair_idx;
    req_meta.nt=0;
    req_meta.final_k=job_final_k;
    req_meta.last=(a_head.pair_idx==PAIRS-1);
    req_meta.exp_fold=job_exp_fold;
    req_meta.acc_sel=job_acc_sel;
    req_meta.acc_clear=job_acc_clear&&(a_head.pair_idx==0);
  end
  always_ff @(posedge clk) begin
    if(reset||clear) job_pending<=0;
    else begin
      if(job_start) job_pending<=1;
      if(a_reserve||done) job_pending<=0;
    end
  end

  // MXU arithmetic and DEQACC storage/commit.
  logic mxu_rsp_valid;
  mxu_rsp_t mxu_rsp;
  dea8_mxu_2row_v3 mxu(
    .clk,.reset,.clear,.req_valid(req_valid),.req_bank(req_bank),
    .req(a_head),.req_meta(req_meta),.load_valid,.load_bank,
    .load_column,.load_entry(serializer_out),.rsp_valid(mxu_rsp_valid),
    .rsp(mxu_rsp));
  dea8_deqacc32_v3 deqacc(
    .clk,.reset,.clear,.rsp_valid(mxu_rsp_valid),.rsp(mxu_rsp),
    .commit_valid,.done,.commit_meta,
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);
endmodule
