import pcore3_pkg::*;

// Multi-Tile Matrix job shell.  A job latches its configuration once, then
// advances one A Tile per 26 row-pair issues.  The AFIFO supports rollover
// reservation on the last pair, while the B loader releases a stationary bank
// one cycle after the final S1 multiply has consumed it.
module dea8_matrix_v3 (
  input logic clk,reset,clear,
  input logic xbc_valid, output logic xbc_ready, input xbc4_t xbc_entry,
  input logic hbm_valid, output logic hbm_ready, input b2_t hbm_entry,
  input logic kv_valid, output logic kv_ready, input b2_t kv_entry,
  input b_source_e b_source,
  input logic job_start,
  input logic [TILE_BITS-1:0] job_tile_idx,
  input logic [TILE_BITS:0] job_tiles,
  input logic [EPOCH_BITS-1:0] job_epoch,
  input logic [2:0] job_head,
  input logic job_final_k,
  input logic signed [EXP_FOLD_BITS-1:0] job_exp_fold,
  input acc_sel_e job_acc_sel,
  input logic job_acc_clear,
  output logic job_ready,job_busy,
  output logic commit_valid,done,
  output pair_meta_t commit_meta,
  input logic dbg_valid,input acc_sel_e dbg_sel,input logic dbg_parity,
  input logic [9:0] dbg_addr,input logic [3:0] dbg_lane,
  output logic [31:0] dbg_data,
  output logic a_protocol_error,b_protocol_error
);
  logic [1:0] a2_valid,a2_ready; a2_t a2_entry[0:1];
  logic a_tile_available,a_running,a_out_valid,a_reserve; a2_t a_head;
  logic [6:0] a_count;
  logic [$clog2(AFIFO_DEPTH/PAIRS+1)-1:0] a_complete;
  dea8_xbc4_adapter_v3 xbc_adapter(
    .clk,.reset,.clear,.in_valid(xbc_valid),.in_ready(xbc_ready),.in_entry(xbc_entry),
    .out_valid(a2_valid),.out_ready(a2_ready),.out_entry(a2_entry));
  dea8_afifo_v3 a_fifo(
    .clk,.reset,.clear,.in_valid(a2_valid),.in_ready(a2_ready),.in_entry(a2_entry),
    .reserve_tile(a_reserve),.tile_available(a_tile_available),.running(a_running),
    .out_valid(a_out_valid),.out_entry(a_head),.protocol_error(a_protocol_error),
    .count(a_count),.complete_tiles(a_complete));

  logic b_in_valid,b_in_ready,b_out_valid,b_out_ready,b_tile_available,b_protocol;
  b2_t b_in_entry,b_head; logic [6:0] b_count; logic [3:0] b_complete;
  assign b_in_valid=(b_source==B_KVB)?kv_valid:hbm_valid;
  assign b_in_entry=(b_source==B_KVB)?kv_entry:hbm_entry;
  assign hbm_ready=(b_source==B_HBM)&&b_in_ready;
  assign kv_ready=(b_source==B_KVB)&&b_in_ready;
  dea8_bfifo_v3 b_fifo(
    .clk,.reset,.clear,.in_valid(b_in_valid),.in_ready(b_in_ready),.in_entry(b_in_entry),
    .out_valid(b_out_valid),.out_ready(b_out_ready),.out_entry(b_head),
    .tile_available(b_tile_available),.protocol_error(b_protocol),.count(b_count),
    .complete_tiles(b_complete));
  assign b_protocol_error=b_protocol;

  logic serializer_start,serializer_allow,serializer_in_ready;
  logic serializer_out_valid,serializer_out_ready,serializer_busy;
  b1_t serializer_out; logic [1:0] bank_ready; logic [TILE_BITS-1:0] bank_tile[0:1];
  logic load_valid,load_bank; logic [3:0] load_column; qvec16_t load_col;
  dea8_b_serializer_v3 b_serializer(
    .clk,.reset,.clear,.start_tile(serializer_allow),.in_valid(b_out_valid),
    .in_ready(serializer_in_ready),.in_entry(b_head),.out_valid(serializer_out_valid),
    .out_ready(serializer_out_ready),.out_entry(serializer_out),.busy(serializer_busy));
  assign b_out_ready=serializer_in_ready;

  logic release_valid_q,release_bank_q;
  dea8_b_loader_v3 b_loader(
    .clk,.reset,.clear,.enable(1'b1),.tile_available(b_tile_available),.bfifo_head(b_head),
    .serializer_busy(serializer_busy),.serializer_start(serializer_start),.serializer_allow(serializer_allow),
    .b1_valid(serializer_out_valid),.b1_ready(serializer_out_ready),.b1_entry(serializer_out),
    .release_valid(release_valid_q),.release_bank(release_bank_q),.bank_ready,.bank_tile,
    .load_valid,.load_bank,.load_column,.load_col);

  // Latched job configuration and Tile sequence.
  logic job_busy_q;
  logic [TILE_BITS-1:0] base_tile_q;
  logic [TILE_BITS:0] tiles_q,tile_seq_q;
  logic [EPOCH_BITS-1:0] epoch_q; logic [2:0] head_q;
  logic final_k_q; logic signed [EXP_FOLD_BITS-1:0] exp_fold_q;
  acc_sel_e acc_sel_q; logic acc_clear_q;
  logic job_accept,tile_issue_last;
  logic [TILE_BITS:0] current_tile_ext,next_tile_ext;
  logic [TILE_BITS-1:0] current_tile,next_tile;
  logic req_valid,req_bank; pair_meta_t req_meta;
  assign job_ready=!job_busy_q;
  assign job_busy=job_busy_q;
  assign job_accept=job_start&&job_ready&&(job_tiles!=0);
  assign current_tile_ext={1'b0,base_tile_q}+tile_seq_q;
  assign next_tile_ext=current_tile_ext+1'b1;
  assign current_tile=current_tile_ext[TILE_BITS-1:0];
  assign next_tile=next_tile_ext[TILE_BITS-1:0];
  assign req_bank=current_tile[0];
  assign a_reserve=job_busy_q&&(
    (!a_running&&tile_seq_q<tiles_q&&a_tile_available&&
      bank_ready[req_bank]&&bank_tile[req_bank]==current_tile) ||
    (a_running&&a_out_valid&&a_head.pair_idx==PAIRS-1&&
      tile_seq_q+1'b1<tiles_q&&a_tile_available&&
      bank_ready[next_tile[0]]&&bank_tile[next_tile[0]]==next_tile));
  assign req_valid=job_busy_q&&a_running&&a_out_valid;
  assign tile_issue_last=req_valid&&(a_head.pair_idx==PAIRS-1);
  always_comb begin
    req_meta='0;req_meta.epoch=epoch_q;req_meta.head=head_q;req_meta.tile_idx=current_tile;
    req_meta.pair_idx=a_head.pair_idx;req_meta.nt=0;req_meta.final_k=final_k_q;
    req_meta.last=(tile_seq_q+1'b1>=tiles_q)&&(a_head.pair_idx==PAIRS-1);
    req_meta.exp_fold=exp_fold_q;req_meta.acc_sel=acc_sel_q;
    // init_acc applies to every pair in the first K Tile, not only pair0.
    req_meta.acc_clear=acc_clear_q&&(tile_seq_q==0);
  end
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      job_busy_q<=0;base_tile_q<=0;tiles_q<=0;tile_seq_q<=0;epoch_q<=0;head_q<=0;
      final_k_q<=0;exp_fold_q<=0;acc_sel_q<=ACC_FACC_A;acc_clear_q<=0;
      release_valid_q<=0;release_bank_q<=0;
    end else begin
      release_valid_q<=tile_issue_last;release_bank_q<=req_bank;
      if(job_accept) begin
        job_busy_q<=1;base_tile_q<=job_tile_idx;tiles_q<=job_tiles;tile_seq_q<=0;
        epoch_q<=job_epoch;head_q<=job_head;final_k_q<=job_final_k;exp_fold_q<=job_exp_fold;
        acc_sel_q<=job_acc_sel;acc_clear_q<=job_acc_clear;
      end
      if(tile_issue_last&&tile_seq_q+1'b1<tiles_q) tile_seq_q<=tile_seq_q+1'b1;
      if(done) job_busy_q<=0;
    end
  end

  logic mxu_rsp_valid; mxu_rsp_t mxu_rsp;
  dea8_mxu_2row_v3 mxu(
    .clk,.reset,.clear,.req_valid(req_valid),.req_bank(req_bank),.req(a_head),.req_meta(req_meta),
    .load_valid,.load_bank,.load_column,.load_entry(serializer_out),.rsp_valid(mxu_rsp_valid),.rsp(mxu_rsp));
  dea8_deqacc32_v3 deqacc(
    .clk,.reset,.clear,.rsp_valid(mxu_rsp_valid),.rsp(mxu_rsp),.commit_valid,.done,.commit_meta,
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);
endmodule
