import pcore3_pkg::*;

// Multi-Tile Matrix job shell.  A job latches its configuration once, then
// advances one A Tile per configured row-pair count.  The AFIFO supports rollover
// reservation on the last pair, while the B loader releases a stationary bank
// one cycle after the final S1 multiply has consumed it.
module dea8_matrix_v3 (
  input logic clk,reset,clear,
  input logic xbc_valid, output logic xbc_ready, input xbc4_t xbc_entry,
  input logic hbm_valid, output logic hbm_ready, input b2_t hbm_entry,
  input logic kv_valid, output logic kv_ready, input b2_t kv_entry,
  input b_source_e b_source,
  input logic job_start,
  input logic [TILE_BITS-1:0] job_a_tile_idx,
  input logic [TILE_BITS-1:0] job_b_tile_idx,
  // Logical matrix IDs and FIFO transport IDs are independent.  The latter
  // are used only for ingress ordering and stationary-bank ownership.
  input logic [TILE_BITS-1:0] job_a_stream_idx,
  input logic [TILE_BITS-1:0] job_b_stream_idx,
  input logic [TILE_BITS:0] job_tiles,
  input logic [PAIR_BITS:0] job_m_rows,
  input logic [EPOCH_BITS-1:0] job_epoch,
  input logic [2:0] job_head,
  input logic [3:0] job_nt,
  input logic job_nt_per_tile,
  input logic job_clear_each_tile,
  input logic job_final_k,
  input logic signed [EXP_FOLD_BITS-1:0] job_exp_fold,
  input acc_sel_e job_acc_sel,
  input logic job_add_old,
  output logic job_ready,job_busy,
  output logic commit_valid,done,
  output pair_meta_t commit_meta,
  input acc_read_owner_e result_rd_owner,
  input logic result_rd_valid,
  input acc_sel_e result_rd_sel,
  input logic [9:0] result_rd_addr,
  output logic result_rd_data_valid,
  output logic [15:0][31:0] result_even_data,result_odd_data,
  input logic dbg_valid,input acc_sel_e dbg_sel,input logic dbg_parity,
  input logic [9:0] dbg_addr,input logic [3:0] dbg_lane,
  output logic [31:0] dbg_data,
  output logic a_protocol_error,b_protocol_error
);
  logic [1:0] a2_valid,a2_ready; a2_t a2_entry[0:1];
  logic a_tile_available,a_running,a_out_valid,a_reserve; a2_t a_head;
  logic [PAIR_BITS:0] rows_q,pairs_q;
  logic [6:0] a_count;
  logic [$clog2(AFIFO_DEPTH+1)-1:0] a_complete;
  dea8_xbc4_adapter_v3 xbc_adapter(
    .clk,.reset,.clear,.in_valid(xbc_valid),.in_ready(xbc_ready),.in_entry(xbc_entry),
    .out_valid(a2_valid),.out_ready(a2_ready),.out_entry(a2_entry));
  dea8_afifo_v3 a_fifo(
    .clk,.reset,.clear,.pairs_cfg(pairs_q),.rows_cfg(rows_q),
    .in_valid(a2_valid),.in_ready(a2_ready),.in_entry(a2_entry),
    .reserve_tile(a_reserve),.tile_available(a_tile_available),.running(a_running),
    .out_valid(a_out_valid),.out_entry(a_head),.protocol_error(a_protocol_error),
    .count(a_count),.complete_tiles(a_complete));

  logic b_in_valid,b_in_ready,b_out_valid,b_out_ready,b_tile_available,b_protocol;
  b2_t b_in_entry,b_head; logic [6:0] b_count; logic [3:0] b_complete;
  b_source_e b_source_q;
  // A matrix Job owns its B source for its entire lifetime.  Live switching
  // between HBM and KVB would make the FIFO order depend on an asynchronous
  // external control signal.
  assign b_in_valid=(b_source_q==B_KVB)?kv_valid:hbm_valid;
  assign b_in_entry=(b_source_q==B_KVB)?kv_entry:hbm_entry;
  assign hbm_ready=(b_source_q==B_HBM)&&b_in_ready;
  assign kv_ready=(b_source_q==B_KVB)&&b_in_ready;
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
  logic [TILE_BITS-1:0] base_a_tile_q,base_b_tile_q;
  logic [TILE_BITS-1:0] base_a_stream_q,base_b_stream_q;
  logic [TILE_BITS:0] tiles_q,tile_seq_q;
  logic tile_started_q;
  logic [EPOCH_BITS-1:0] epoch_q; logic [2:0] head_q;
  logic final_k_q; logic [3:0] nt_q;
  logic nt_per_tile_q,clear_each_tile_q;
  logic signed [EXP_FOLD_BITS-1:0] exp_fold_q;
  acc_sel_e acc_sel_q; logic add_old_q;
  logic job_accept,tile_issue_last;
  logic [TILE_BITS:0] current_a_ext,current_b_ext,next_a_ext,next_b_ext;
  logic [TILE_BITS:0] current_a_stream_ext,current_b_stream_ext;
  logic [TILE_BITS:0] next_a_stream_ext,next_b_stream_ext;
  logic [TILE_BITS-1:0] current_a,current_b,next_a,next_b;
  logic [TILE_BITS-1:0] current_a_stream,current_b_stream;
  logic [TILE_BITS-1:0] next_a_stream,next_b_stream;
  logic req_valid,req_bank; pair_meta_t req_meta;
  assign job_ready=!job_busy_q;
  assign job_busy=job_busy_q;
  assign job_accept=job_start&&job_ready&&(job_tiles!=0);
  assign current_a_ext={1'b0,base_a_tile_q}+tile_seq_q;
  assign current_b_ext={1'b0,base_b_tile_q}+tile_seq_q;
  assign current_a_stream_ext={1'b0,base_a_stream_q}+tile_seq_q;
  assign current_b_stream_ext={1'b0,base_b_stream_q}+tile_seq_q;
  assign next_a_ext=current_a_ext+1'b1;
  assign next_b_ext=current_b_ext+1'b1;
  assign next_a_stream_ext=current_a_stream_ext+1'b1;
  assign next_b_stream_ext=current_b_stream_ext+1'b1;
  assign current_a=current_a_ext[TILE_BITS-1:0];
  assign current_b=current_b_ext[TILE_BITS-1:0];
  assign current_a_stream=current_a_stream_ext[TILE_BITS-1:0];
  assign current_b_stream=current_b_stream_ext[TILE_BITS-1:0];
  assign next_a=next_a_ext[TILE_BITS-1:0];
  assign next_b=next_b_ext[TILE_BITS-1:0];
  assign next_a_stream=next_a_stream_ext[TILE_BITS-1:0];
  assign next_b_stream=next_b_stream_ext[TILE_BITS-1:0];
  assign req_bank=current_b_stream[0];
  logic a_tile_match;
  assign a_tile_match=a_head.tile_idx==current_a_stream;
  assign a_reserve=job_busy_q&&(
     (!tile_started_q&&!a_running&&tile_seq_q<tiles_q&&a_tile_available&&
      a_tile_match&&bank_ready[req_bank]&&bank_tile[req_bank]==current_b_stream) ||
    (a_running&&a_out_valid&&a_head.pair_idx==pairs_q-1&&
      tile_seq_q+1'b1<tiles_q&&a_tile_available&&
      a_head.tile_idx==current_a_stream&&
      bank_ready[next_b_stream[0]]&&bank_tile[next_b_stream[0]]==next_b_stream));
  assign req_valid=job_busy_q&&a_running&&a_out_valid&&a_tile_match;
  assign tile_issue_last=req_valid&&(a_head.pair_idx==pairs_q-1);
  always_comb begin
    req_meta='0;req_meta.epoch=epoch_q;req_meta.head=head_q;req_meta.tile_idx=current_b;
    req_meta.pair_idx=a_head.pair_idx;
    req_meta.nt=nt_per_tile_q?(nt_q+4'(tile_seq_q)):nt_q;
    req_meta.final_k=final_k_q;
    req_meta.last=(tile_seq_q+1'b1>=tiles_q)&&(a_head.pair_idx==pairs_q-1);
    req_meta.exp_fold=exp_fold_q;req_meta.acc_sel=acc_sel_q;
    // add_old applies to every pair in the job's first/next reduction tile.
    req_meta.add_old=add_old_q || ((tile_seq_q!=0)&&!clear_each_tile_q);
  end
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      job_busy_q<=0;base_a_tile_q<=0;base_b_tile_q<=0;base_a_stream_q<=0;base_b_stream_q<=0;
      tiles_q<=0;tile_seq_q<=0;tile_started_q<=0;epoch_q<=0;head_q<=0;b_source_q<=B_HBM;
      rows_q<=ROWS;pairs_q<=PAIRS;
      final_k_q<=0;nt_q<=0;nt_per_tile_q<=0;clear_each_tile_q<=0;
      exp_fold_q<=0;acc_sel_q<=ACC_FACC_A;add_old_q<=0;
      release_valid_q<=0;release_bank_q<=0;
    end else begin
      release_valid_q<=tile_issue_last;release_bank_q<=req_bank;
      if(job_accept) begin
        job_busy_q<=1;
        base_a_tile_q<=job_a_tile_idx;
        base_b_tile_q<=job_b_tile_idx;
        base_a_stream_q<=job_a_stream_idx;
        base_b_stream_q<=job_b_stream_idx;
        b_source_q<=b_source;
        tiles_q<=job_tiles;tile_seq_q<=0;tile_started_q<=0;
        rows_q<=(job_m_rows==0)?ROWS:job_m_rows;
        pairs_q<=(((job_m_rows==0)?ROWS:job_m_rows) + 1'b1)>>1;
        epoch_q<=job_epoch;head_q<=job_head;nt_q<=job_nt;final_k_q<=job_final_k;exp_fold_q<=job_exp_fold;
        nt_per_tile_q<=job_nt_per_tile;clear_each_tile_q<=job_clear_each_tile;
        acc_sel_q<=job_acc_sel;add_old_q<=job_add_old;
      end
      if(tile_issue_last&&tile_seq_q+1'b1<tiles_q) begin
        tile_seq_q<=tile_seq_q+1'b1;
        // The next Tile may be reserved on the same edge as the current
        // Tile's last issue.  Preserve that reservation instead of clearing
        // the guard and allowing the final Tile to be issued twice.
        tile_started_q<=a_reserve;
      end else if(a_reserve) begin
        tile_started_q<=1;
      end
      if(done) job_busy_q<=0;
    end
  end

  logic mxu_rsp_valid; mxu_rsp_t mxu_rsp;
  dea8_mxu_2row_v3 mxu(
    .clk,.reset,.clear,.req_valid(req_valid),.req_bank(req_bank),.req(a_head),.req_meta(req_meta),
    .load_valid,.load_bank,.load_column,.load_entry(serializer_out),.rsp_valid(mxu_rsp_valid),.rsp(mxu_rsp));
  dea8_deqacc32_v3 deqacc(
    .clk,.reset,.clear,.rsp_valid(mxu_rsp_valid),.rsp(mxu_rsp),.commit_valid,.done,.commit_meta,
    .result_rd_owner,.result_rd_valid,.result_rd_sel,.result_rd_addr,
    .result_rd_data_valid,.result_even_data,.result_odd_data,
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);
endmodule
