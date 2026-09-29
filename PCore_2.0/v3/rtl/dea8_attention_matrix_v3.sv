import pcore3_pkg::*;

// Block-level Attention adapter around the generic multi-Tile Matrix Core.
//
// Each QK/PV block is one 16-Tile Matrix job. QK reduces along K into FACC;
// PV advances the OACC N-Tile address each Tile while replaying the same P.
module dea8_attention_matrix_v3 (
  input logic clk,reset,clear,
  input logic cmd_valid, output logic cmd_ready, input matrix_cmd_t cmd,
  output logic done_valid, input logic done_ready, output matrix_cmd_t done_cmd,
  input logic xbc_valid, output logic xbc_ready, input xbc4_t xbc_entry,
  // P is produced once by VPU and then replayed for all sixteen V tiles.
  // This side stream is deliberately separate from the live Q/K XBC stream.
  input logic replay_load_valid, output logic replay_load_ready,
  input xbc4_t replay_load_entry,
  input logic hbm_valid, output logic hbm_ready, input b2_t hbm_entry,
  input logic kv_valid, output logic kv_ready, input b2_t kv_entry,
  input b_source_e b_source,
  output logic a_protocol_error,b_protocol_error,
  input acc_read_owner_e result_rd_owner,
  input logic result_rd_valid,
  input acc_sel_e result_rd_sel,
  input logic [9:0] result_rd_addr,
  output logic result_rd_data_valid,
  output logic [15:0][31:0] result_even_data,result_odd_data,
  input logic dbg_valid,input acc_sel_e dbg_sel,input logic dbg_parity,
  input logic [9:0] dbg_addr,input logic [3:0] dbg_lane,
  output logic [31:0] dbg_data
);
  typedef enum logic [1:0] {IDLE,RUN,DONE} state_e;
  state_e state_q;
  matrix_cmd_t cmd_q;
  logic [3:0] pv_tile_q;
  logic matrix_start_q,matrix_done,matrix_done_q;
  logic matrix_ready,matrix_busy;
  logic matrix_commit_valid;
  pair_meta_t matrix_commit_meta;
  logic [31:0] unused_dbg;
  logic matrix_done_pulse;
  logic [TILE_BITS:0] matrix_job_tiles;
  xbc4_t replay_mem[0:1][0:XBC_GROUPS-1];
  logic [1:0] replay_loaded_q;
  logic [3:0] replay_expect_group_q[0:1];
  logic replay_active_q;
  logic [3:0] replay_group_q;
  logic replay_bank_q;
  logic replay_protocol_error;
  logic [TILE_BITS-1:0] a_stream_next_q,b_stream_next_q;
  logic [TILE_BITS-1:0] a_stream_base_q,b_stream_base_q;
  logic [LOGICAL_ID_BITS-1:0] current_logical_b;
  logic replay_valid,replay_ready;
  xbc4_t core_xbc_entry;
  logic core_xbc_valid,core_xbc_ready;
  logic use_replay;
  logic matrix_a_protocol_error;

  assign use_replay=(state_q==RUN)&&(cmd_q.op==MATRIX_PV);
  assign cmd_ready=(state_q==IDLE)&&(!cmd_valid || cmd.op!=MATRIX_PV ||
    replay_loaded_q[cmd.a_id[0]]);
  assign done_valid=state_q==DONE;
  assign current_logical_b=cmd_q.b_id;
  // dea8_matrix_v3 exposes a one-cycle D4 completion pulse.  Gate the next
  // launch with the pulse itself; a delayed edge detector could launch a
  // second job before pv_tile_q has advanced.
  assign matrix_done_pulse=matrix_done;
  assign matrix_job_tiles=(TILE_BITS+1)'(ATTN_K_TILES);
  assign replay_load_ready=!reset&&!clear&&
    !replay_loaded_q[replay_load_entry.slot]&&
    replay_expect_group_q[replay_load_entry.slot]==replay_load_entry.group_idx&&
    replay_load_entry.group_idx<XBC_GROUPS&&
    !(use_replay&&replay_bank_q==replay_load_entry.slot);
  assign replay_valid=use_replay&&replay_active_q&&replay_loaded_q[replay_bank_q];
  assign replay_ready=core_xbc_ready;
  always_comb begin
    core_xbc_entry=use_replay?replay_mem[replay_bank_q][replay_group_q]:xbc_entry;
    if(use_replay) begin
      // The logical P address remains fixed for the whole PV block.  The
      // transport sequence is independent and advances one A Tile per N Tile.
      core_xbc_entry.tile_idx=a_stream_base_q+pv_tile_q;
      core_xbc_entry.group_idx=replay_group_q;
    end
    core_xbc_valid=use_replay?replay_valid:xbc_valid;
    xbc_ready=use_replay?1'b0:core_xbc_ready;
  end

  dea8_matrix_v3 matrix(
    .clk,.reset,.clear,
    .xbc_valid(core_xbc_valid),.xbc_ready(core_xbc_ready),.xbc_entry(core_xbc_entry),
    .hbm_valid,.hbm_ready,.hbm_entry,
    .kv_valid,.kv_ready,.kv_entry,.b_source,
    .job_start(matrix_start_q),
    .job_a_tile_idx(cmd_q.a_id[TILE_BITS-1:0]),
    .job_b_tile_idx(current_logical_b[TILE_BITS-1:0]),
    .job_a_stream_idx(a_stream_base_q),
    .job_b_stream_idx(b_stream_base_q),
    .job_tiles(matrix_job_tiles),
    .job_m_rows(cmd_q.m_rows),
    .job_epoch(cmd_q.epoch),.job_head(cmd_q.head),.job_nt(4'd0),
    .job_nt_per_tile(cmd_q.op==MATRIX_PV),
    .job_clear_each_tile(cmd_q.op==MATRIX_PV),
    .job_final_k(1'b1),.job_exp_fold(cmd_q.exp_fold),
    .job_acc_sel(cmd_q.acc_sel),.job_add_old(cmd_q.add_old),
    .job_ready(matrix_ready),.job_busy(matrix_busy),
    .commit_valid(matrix_commit_valid),.done(matrix_done),
    .commit_meta(matrix_commit_meta),
    .result_rd_owner,.result_rd_valid,.result_rd_sel,.result_rd_addr,
    .result_rd_data_valid,.result_even_data,.result_odd_data,
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data,
    .a_protocol_error(matrix_a_protocol_error),.b_protocol_error);

  assign a_protocol_error=matrix_a_protocol_error|replay_protocol_error;

  always_comb begin
    matrix_start_q=(state_q==RUN)&&!matrix_done&&!matrix_busy&&matrix_ready;
  end

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      state_q<=IDLE;cmd_q<='0;pv_tile_q<=0;matrix_done_q<=0;
      replay_loaded_q<=0;replay_active_q<=0;replay_group_q<=0;replay_bank_q<=0;
      replay_expect_group_q[0]<=0;replay_expect_group_q[1]<=0;
      replay_protocol_error<=0;a_stream_next_q<=0;b_stream_next_q<=0;
      a_stream_base_q<=0;b_stream_base_q<=0;
      done_cmd<='0;
    end else begin
      if(replay_load_valid&&replay_load_ready) begin
        replay_mem[replay_load_entry.slot][replay_load_entry.group_idx]<=replay_load_entry;
        if(replay_load_entry.group_idx==XBC_GROUPS-1) begin
          replay_loaded_q[replay_load_entry.slot]<=1;
          replay_expect_group_q[replay_load_entry.slot]<=0;
        end else replay_expect_group_q[replay_load_entry.slot]<=replay_load_entry.group_idx+1'b1;
      end
      matrix_done_q<=matrix_done;
      if(cmd_valid&&cmd_ready) begin
        cmd_q<=cmd;pv_tile_q<=0;state_q<=RUN;replay_active_q<=0;replay_group_q<=0;
        // PV selects its PBUF bank from the logical A source ID.  block_id is
        // an algorithm context tag and is intentionally not reused for this
        // physical source selection.
        replay_bank_q<=cmd.op==MATRIX_PV ? cmd.a_id[0] : cmd.block_id[0];
        a_stream_base_q<=a_stream_next_q;
        b_stream_base_q<=b_stream_next_q;
        a_stream_next_q<=a_stream_next_q+TILE_BITS'(ATTN_K_TILES);
        b_stream_next_q<=b_stream_next_q+TILE_BITS'(ATTN_K_TILES);
      end
      if(matrix_start_q) begin
        matrix_done_q<=0;replay_active_q<=cmd_q.op==MATRIX_PV;replay_group_q<=0;
      end
      if(replay_valid&&replay_ready) begin
        if(replay_group_q==XBC_GROUPS-1) begin
          replay_group_q<=0;
          if(pv_tile_q==ATTN_K_TILES-1) replay_active_q<=0;
          else pv_tile_q<=pv_tile_q+1'b1;
        end
        else replay_group_q<=replay_group_q+1'b1;
      end
      if(matrix_done_pulse) begin
        done_cmd<=cmd_q;state_q<=DONE;replay_active_q<=0;
        if(cmd_q.op==MATRIX_PV) begin
          replay_loaded_q[replay_bank_q]<=0;
          replay_expect_group_q[replay_bank_q]<=0;
        end
      end
      if(done_valid&&done_ready) state_q<=IDLE;
    end
  end
endmodule
