import pcore3_pkg::*;

// One Gate/Up output tile: 64 K tiles, interleaved as G(k), U(k).
// A is supplied as 128 ordered A2 tiles by the upstream QOZ/replay path.
// The wrapper owns the GU result slot and exposes a 51-cycle row stream to
// the VPU.  Z is deliberately left as a QOZ-facing stream owned by the
// downstream VPU/QOZ wrapper.
module dea8_gu_matrix_v3 #(
  parameter int K_TILES=64,
  parameter int GU_TILES=128
) (
  input logic clk,reset,clear,
  input logic start,
  output logic start_ready,
  input logic [EPOCH_BITS-1:0] job_epoch,
  input logic [2:0] job_head,
  input logic [5:0] job_n,
  input logic local_a_valid,
  output logic local_a_ready,
  input a2_t local_a_entry,
  input logic hbm_valid,
  output logic hbm_ready,
  input b2_t hbm_entry,
  output logic gu_busy,
  output logic gu_matrix_done,
  output logic gu_pair_ready,
  input logic gu_pair_ready_accept,
  output logic gu_out_valid,
  input logic gu_out_ready,
  output logic [5:0] gu_out_row,
  output logic [EPOCH_BITS-1:0] gu_out_epoch,
  output logic [2:0] gu_out_head,
  output logic [5:0] gu_out_n,
  output logic [15:0][31:0] gu_gate,
  output logic [15:0][31:0] gu_up,
  output logic [1:0] gu_out_row_valid,
  output logic gu_out_last,
  output logic gu_out_consumed,
  // VPU/SFU returns quantized Z here.  The wrapper forwards it directly to
  // the existing QOZ owner; no independent Z buffer is instantiated.
  input logic vpu_z_valid,
  output logic vpu_z_ready,
  input logic [5:0] vpu_z_tile,
  input logic [PAIR_BITS-1:0] vpu_z_pair,
  input logic [1:0] vpu_z_row_valid,
  input logic [135:0] vpu_z_even,
  input logic [135:0] vpu_z_odd,
  input logic [EPOCH_BITS-1:0] vpu_z_epoch,
  input logic [2:0] vpu_z_head,
  input logic [5:0] vpu_z_n,
  input logic vpu_z_last,
  output logic qoz_z_wr_valid,
  input logic qoz_z_wr_ready,
  output logic [5:0] qoz_z_wr_tile,
  output logic [PAIR_BITS-1:0] qoz_z_wr_pair,
  output logic [1:0] qoz_z_wr_row_valid,
  output logic [135:0] qoz_z_wr_even,
  output logic [135:0] qoz_z_wr_odd,
  output logic [EPOCH_BITS-1:0] qoz_z_wr_epoch,
  output logic [2:0] qoz_z_wr_head,
  output logic [5:0] qoz_z_wr_n,
  output logic qoz_z_wr_last,
  output logic a_protocol_error,
  output logic b_protocol_error,
  output logic gu_protocol_error
);
  logic matrix_job_start,matrix_ready,matrix_busy,matrix_done;
  logic replay_in_ready,replay_out_valid,replay_out_ready,replay_error;
  a2_t replay_out_entry;
  logic matrix_commit_valid,matrix_commit_write_valid,matrix_gu_slot_reserve;
  logic matrix_a_error;
  pair_meta_t matrix_commit_meta;
  acc_write_t matrix_commit_write;
  logic matrix_gu_slot_ready;
  logic result_rd_ready;
  logic [15:0][31:0] result_even_data,result_odd_data;
  logic [31:0] dbg_data;
  logic pair_reserve_ready,pair_reserve_valid,pair_capture_ready;
  logic pair_complete,pair_error;
  logic pair_input_consumed;
  logic pair_out_valid,read_enabled_q;
  logic [EPOCH_BITS-1:0] active_epoch_q;
  logic [2:0] active_head_q;
  logic [5:0] active_n_q;

  assign start_ready=matrix_ready;
  assign matrix_job_start=start&&matrix_ready;
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      active_epoch_q<=0;active_head_q<=0;active_n_q<=0;read_enabled_q<=0;
    end else begin
      if(matrix_job_start) begin
        active_epoch_q<=job_epoch;active_head_q<=job_head;active_n_q<=job_n;
      end
      if(gu_pair_ready&&gu_pair_ready_accept) read_enabled_q<=1;
      if(gu_out_consumed) read_enabled_q<=0;
    end
  end
  assign gu_busy=matrix_busy||matrix_job_start||!pair_reserve_ready;
  assign gu_matrix_done=matrix_done;
  assign gu_pair_ready=pair_complete;
  assign gu_out_valid=pair_out_valid&&read_enabled_q;
  assign gu_out_consumed=gu_out_valid&&gu_out_ready&&gu_out_last;
  assign qoz_z_wr_valid=vpu_z_valid;
  assign vpu_z_ready=qoz_z_wr_ready;
  // Z has one physical 512-column tile per N tile.  Keep the legacy tile
  // field on the input for interface compatibility, but the wrapper owns the
  // physical address and derives it from the checked N context.
  assign qoz_z_wr_tile=vpu_z_n;
  assign qoz_z_wr_pair=vpu_z_pair;
  assign qoz_z_wr_row_valid=vpu_z_row_valid;
  assign qoz_z_wr_even=vpu_z_even;
  assign qoz_z_wr_odd=vpu_z_odd;
  assign qoz_z_wr_epoch=vpu_z_epoch;
  assign qoz_z_wr_head=vpu_z_head;
  assign qoz_z_wr_n=vpu_z_n;
  assign qoz_z_wr_last=vpu_z_last;
  // synthesis translate_off
  always_ff @(posedge clk) if(!reset&&!clear&&vpu_z_valid&&vpu_z_ready&&
                              vpu_z_tile!=vpu_z_n)
    $fatal(1,"GU Z tile/n address mismatch tile=%0d n=%0d",vpu_z_tile,vpu_z_n);
  // synthesis translate_on
  assign pair_input_consumed=gu_out_consumed;

  // The external source supplies one physical A tile.  Replay expands it
  // to Gate(k) and Up(k) transport tiles before the common matrix ingress.
  dea8_gu_a_replay_v3 a_replay(
    .clk,.reset,.clear,.in_valid(local_a_valid),.in_ready(replay_in_ready),
    .in_entry(local_a_entry),.out_valid(replay_out_valid),.out_ready(replay_out_ready),
    .out_entry(replay_out_entry),.protocol_error(replay_error));
  assign local_a_ready=replay_in_ready;

  dea8_matrix_v3 #(.LOCAL_A(1'b1),.A_STREAMING(1'b0)) matrix(
    .clk,.reset,.clear,.xbc_valid(1'b0),.xbc_ready(),.xbc_entry('0),
    .local_a_valid(replay_out_valid),.local_a_ready(replay_out_ready),.local_a_entry(replay_out_entry),
    .hbm_valid,.hbm_ready,.hbm_entry,
    .kv_valid(1'b0),.kv_ready(),.kv_entry('0),.b_source(B_HBM),
    .job_start(matrix_job_start),.job_a_tile_idx('0),.job_b_tile_idx('0),
    .job_a_stream_idx('0),.job_b_stream_idx('0),
    .job_tiles(MATRIX_TILE_COUNT_BITS'(GU_TILES)),.job_m_rows((PAIR_BITS+1)'(ROWS)),
    .job_epoch,.job_head,.job_nt('0),.job_nt_per_tile(1'b0),
    .job_clear_each_tile(1'b0),.job_final_k(1'b1),.job_exp_fold('0),
    .job_mode(MAT_GU),.job_gu_n(job_n),.gu_slot_ready(matrix_gu_slot_ready),
    .job_acc_sel(ACC_FACC_A),.job_add_old(1'b0),
    .job_ready(matrix_ready),.job_busy(matrix_busy),.commit_valid(matrix_commit_valid),
    .done(matrix_done),.matrix_issue_done(),.gu_slot_reserve(matrix_gu_slot_reserve),
    .commit_meta(matrix_commit_meta),.commit_write_valid(matrix_commit_write_valid),
    .commit_write(matrix_commit_write),
    .result_rd_owner(ACC_READ_DEQACC),.result_rd_valid(1'b0),.result_rd_ready,
    .result_rd_sel(ACC_FACC_A),.result_rd_addr('0),.result_rd_data_valid(),
    .result_even_data,.result_odd_data,
    .vpu_wr_valid(1'b0),.vpu_wr_ready(),.vpu_wr('0),
    .dbg_valid(1'b0),.dbg_sel(ACC_FACC_A),.dbg_parity(1'b0),.dbg_addr('0),.dbg_lane('0),.dbg_data,
    .a_protocol_error(matrix_a_error),.b_protocol_error);

  // Reserve before G63, including a delayed reservation after B loading.
  // The pair buffer
  // does not need a second copy: its 51-cycle read window is far below the
  // 3276 issue cycles available before the next output tile's final K.
  assign pair_reserve_valid=matrix_gu_slot_reserve;
  assign matrix_gu_slot_ready=pair_reserve_ready;
  dea8_gu_pair_buffer_v3 pair_buffer(
    .clk,.reset,.clear,.reserve_valid(pair_reserve_valid),.reserve_ready(pair_reserve_ready),
    .reserve_epoch(active_epoch_q),.reserve_head(active_head_q),.reserve_n(active_n_q),
    .capture_valid(matrix_commit_write_valid&&matrix_commit_meta.mode==MAT_GU&&
                   matrix_commit_meta.final_k),.capture_ready(pair_capture_ready),
    .capture_branch(matrix_commit_meta.acc_sel==ACC_FACC_B),
    .capture_pair(matrix_commit_meta.pair_idx),.capture_row_valid(matrix_commit_write.row_valid),
    .capture_even(matrix_commit_write.data[0]),.capture_odd(matrix_commit_write.data[1]),
    .capture_epoch(matrix_commit_meta.epoch),.capture_head(matrix_commit_meta.head),
    .capture_n(matrix_commit_meta.gu_n),.input_consumed(pair_input_consumed),
    .out_valid(pair_out_valid),.out_ready(gu_out_ready&&read_enabled_q),.out_row(gu_out_row),
    .out_gate(gu_gate),.out_up(gu_up),.out_row_valid(gu_out_row_valid),
    .out_epoch(gu_out_epoch),.out_head(gu_out_head),.out_n(gu_out_n),
    .out_last(gu_out_last),.complete(pair_complete),
    .protocol_error(pair_error));
  assign a_protocol_error=matrix_a_error||replay_error;
  assign gu_protocol_error=pair_error||(!pair_capture_ready&&matrix_commit_write_valid&&
    matrix_commit_meta.mode==MAT_GU&&matrix_commit_meta.final_k);
  initial if(GU_TILES!=2*K_TILES) $fatal(1,"GU tile geometry must be 2*K");
endmodule
