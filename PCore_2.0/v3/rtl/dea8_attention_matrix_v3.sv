import pcore3_pkg::*;

// One current descriptor plus one pending descriptor. Command acceptance
// reserves the transport window; Matrix launch waits for complete source
// context and uses the old job's final drain window for A prefetch.
module dea8_attention_matrix_v3 (
  input logic clk,reset,clear,
  input logic cmd_valid,output logic cmd_ready,input matrix_cmd_t cmd,
  // Only the job_last descriptor is gated; prefetch proceeds while false.
  input logic tail_launch_ready,
  output logic done_valid,input logic done_ready,output matrix_cmd_t done_cmd,
  input logic qoz_load_valid,output logic qoz_load_ready,input a2_t qoz_load_entry,
  input logic [EPOCH_BITS-1:0] qoz_load_epoch,input logic [2:0] qoz_load_head,
  input logic replay_load_valid,output logic replay_load_ready,input a2_t replay_load_entry,
  input logic [EPOCH_BITS-1:0] replay_load_epoch,input logic [2:0] replay_load_head,
  input logic [5:0] replay_load_block,
  input logic hbm_valid,output logic hbm_ready,input b2_t hbm_entry,
  input logic kv_valid,output logic kv_ready,input b2_t kv_entry,input b_source_e b_source,
  output logic a_protocol_error,b_protocol_error,
  input acc_read_owner_e result_rd_owner,
  input logic result_rd_valid,output logic result_rd_ready,
  input acc_sel_e result_rd_sel,input logic [9:0] result_rd_addr,
  output logic result_rd_data_valid,output logic [15:0][31:0] result_even_data,result_odd_data,
  input logic vpu_wr_valid,output logic vpu_wr_ready,input acc_write_t vpu_wr,
  input logic dbg_valid,input acc_sel_e dbg_sel,input logic dbg_parity,
  input logic [9:0] dbg_addr,input logic [3:0] dbg_lane,output logic [31:0] dbg_data
);
  matrix_cmd_t cmd_q,pending_cmd_q,reader_cmd_q;
  logic current_valid_q,pending_valid_q,prefetched_q,issue_done_q,done_hold_q;
  logic [TILE_BITS-1:0] stream_q,pending_base_q,reader_base_q;
  logic [3:0] tile_q;
  logic [PAIR_BITS-1:0] pair_q;
  logic reading_q,matrix_ready,matrix_busy,matrix_done,matrix_issue_done,commit_valid;
  pair_meta_t commit_meta;
  logic q_complete,q_error,p_error,cmd_error,matrix_error;
  logic [1:0] p_complete,p_active,p_release;
  logic [EPOCH_BITS-1:0] q_epoch[0:0],p_epoch[0:1];
  logic [2:0] q_head[0:0],p_head[0:1];
  logic [5:0] q_block[0:0],p_block[0:1];
  logic q_rd_ready,p_rd_ready,q_out_valid,p_out_valid,local_ready;
  a2_t q_entry,p_entry,local_entry;
  logic source_ready,command_bad,reader_is_pv,read_fire;
  logic cmd_accept,launch_valid,launch_fire,read_start;

  logic cmd_source_ready,cmd_source_stale,pending_source_stale;
  // Readiness changes when a producer commits, even when the descriptor is
  // unchanged. Keep every RAM descriptor dependency explicit in the logic.
  assign cmd_source_ready=(cmd.op==MATRIX_PV)?
    (p_complete[cmd.a_id[0]]&&p_epoch[cmd.a_id[0]]==cmd.epoch&&
     p_head[cmd.a_id[0]]==cmd.head&&p_block[cmd.a_id[0]]==cmd.block_id):
    (q_complete&&q_epoch[0]==cmd.epoch&&q_head[0]==cmd.head);
  assign cmd_source_stale=((cmd.op==MATRIX_PV)?p_complete[cmd.a_id[0]]:q_complete)&&!cmd_source_ready;
  assign pending_source_stale=((pending_cmd_q.op==MATRIX_PV)?p_complete[pending_cmd_q.a_id[0]]:q_complete)&&!source_ready;

  assign reader_is_pv=reader_cmd_q.op==MATRIX_PV;
  assign command_bad=cmd.mode!=MAT_ATTENTION||cmd.m_rows!=ROWS||
    (cmd.op==MATRIX_QK&&cmd.a_id!=0)||
    (cmd.op==MATRIX_PV&&cmd.a_id!=LOGICAL_ID_BITS'(cmd.block_id));
  assign source_ready=(pending_cmd_q.op==MATRIX_PV)?
    (p_complete[pending_cmd_q.a_id[0]]&&p_epoch[pending_cmd_q.a_id[0]]==pending_cmd_q.epoch&&
     p_head[pending_cmd_q.a_id[0]]==pending_cmd_q.head&&p_block[pending_cmd_q.a_id[0]]==pending_cmd_q.block_id):
    (q_complete&&q_epoch[0]==pending_cmd_q.epoch&&q_head[0]==pending_cmd_q.head);
  assign cmd_ready=!reset&&!clear&&!a_protocol_error&&!pending_valid_q&&
    !command_bad&&!cmd_source_stale;
  assign cmd_accept=cmd_valid&&cmd_ready;
  assign launch_valid=!reset&&!clear&&!a_protocol_error&&pending_valid_q&&
    source_ready&&(!pending_cmd_q.job_last||tail_launch_ready);
  assign launch_fire=launch_valid&&matrix_ready&&
    (!current_valid_q||(done_valid&&done_ready));
  assign done_valid=!reset&&!clear&&current_valid_q&&(matrix_done||done_hold_q);
  assign done_cmd=cmd_q;

  // Start reading the pending source after the current source has drained.
  // For a QK->QK handoff this wraps QOZ to tile zero; for QK->PV it switches
  // to the already committed PBUF bank.
  assign p_active=((current_valid_q&&cmd_q.op==MATRIX_PV)?
    (2'b01<<cmd_q.a_id[0]):2'b0)|
    ((pending_valid_q&&prefetched_q&&pending_cmd_q.op==MATRIX_PV)?
    (2'b01<<pending_cmd_q.a_id[0]):2'b0);
  assign p_release=(matrix_done&&cmd_q.op==MATRIX_PV)?
    (2'b01<<cmd_q.a_id[0]):2'b0;
  assign local_entry=reader_is_pv?p_entry:q_entry;
  assign read_fire=reading_q&&(reader_is_pv?p_rd_ready:q_rd_ready);
  assign read_start=!reading_q&&pending_valid_q&&!prefetched_q&&
    (issue_done_q||matrix_issue_done||!current_valid_q)&&source_ready;

  dea8_local_a_store_v3 #(.TILES(ATTN_K_TILES),.BANKS(1)) qoz(
    .clk,.reset,.clear,.load_valid(qoz_load_valid),.load_ready(qoz_load_ready),.load_entry(qoz_load_entry),
    .load_epoch(qoz_load_epoch),.load_head(qoz_load_head),.load_block(6'b0),
    .active(current_valid_q||pending_valid_q),.release_bank(1'b0),.complete(q_complete),
    .epoch(q_epoch),.head(q_head),.block_id(q_block),.protocol_error(q_error),
    .rd_valid(reading_q&&!reader_is_pv),.rd_ready(q_rd_ready),.rd_bank(1'b0),
    .rd_tile(tile_q),.rd_pair(pair_q),.rd_transport(reader_base_q+TILE_BITS'(tile_q)),
    .out_valid(q_out_valid),.out_ready(local_ready&&!reader_is_pv),.out_entry(q_entry));
  dea8_local_a_store_v3 #(.TILES(1),.BANKS(2)) pbuf(
    .clk,.reset,.clear,.load_valid(replay_load_valid),.load_ready(replay_load_ready),.load_entry(replay_load_entry),
    .load_epoch(replay_load_epoch),.load_head(replay_load_head),.load_block(replay_load_block),
    .active(p_active),.release_bank(p_release),.complete(p_complete),
    .epoch(p_epoch),.head(p_head),.block_id(p_block),.protocol_error(p_error),
    .rd_valid(reading_q&&reader_is_pv),.rd_ready(p_rd_ready),.rd_bank(reader_cmd_q.a_id[0]),
    .rd_tile(4'b0),.rd_pair(pair_q),.rd_transport(reader_base_q+TILE_BITS'(tile_q)),
    .out_valid(p_out_valid),.out_ready(local_ready&&reader_is_pv),.out_entry(p_entry));

  dea8_matrix_v3 #(.LOCAL_A(1'b1)) matrix(
    .clk,.reset,.clear,.xbc_valid(1'b0),.xbc_ready(),.xbc_entry('0),
    .local_a_valid(reader_is_pv?p_out_valid:q_out_valid),.local_a_ready(local_ready),
    .local_a_entry(local_entry),.hbm_valid,.hbm_ready,.hbm_entry,
    .kv_valid,.kv_ready,.kv_entry,.b_source,
    .job_start(launch_fire),.job_a_tile_idx('0),.job_b_tile_idx('0),
    .job_a_stream_idx(pending_base_q),.job_b_stream_idx(pending_base_q),
    .job_tiles((TILE_BITS+1)'(ATTN_K_TILES)),.job_m_rows(pending_cmd_q.m_rows),
    .job_epoch(pending_cmd_q.epoch),.job_head(pending_cmd_q.head),.job_nt(4'b0),
    .job_nt_per_tile(pending_cmd_q.op==MATRIX_PV),.job_clear_each_tile(pending_cmd_q.op==MATRIX_PV),
    .job_final_k(pending_cmd_q.result_last),.job_exp_fold(pending_cmd_q.exp_fold),
    .job_mode(MAT_ATTENTION),.job_gu_n('0),.gu_slot_ready(1'b1),
    .job_acc_sel(pending_cmd_q.acc_sel),.job_add_old(pending_cmd_q.add_old),
    .job_ready(matrix_ready),.job_busy(matrix_busy),.matrix_issue_done,
    .commit_valid,.done(matrix_done),.commit_meta,
    .commit_write_valid(),.commit_write(),.gu_slot_reserve(),
    .result_rd_owner,.result_rd_valid,.result_rd_ready,.result_rd_sel,.result_rd_addr,
    .result_rd_data_valid,.result_even_data,.result_odd_data,.vpu_wr_valid,.vpu_wr_ready,.vpu_wr,
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data,
    .a_protocol_error(matrix_error),.b_protocol_error);
  assign a_protocol_error=q_error|p_error|cmd_error|matrix_error;

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      cmd_q<='0;pending_cmd_q<='0;reader_cmd_q<='0;
      current_valid_q<=0;pending_valid_q<=0;prefetched_q<=0;
      issue_done_q<=0;done_hold_q<=0;stream_q<=0;pending_base_q<=0;reader_base_q<=0;
      tile_q<=0;pair_q<=0;reading_q<=0;cmd_error<=0;
    end else begin
      if(cmd_valid&&!pending_valid_q&&(command_bad||cmd_source_stale)) cmd_error<=1;
      if(pending_valid_q&&pending_source_stale) cmd_error<=1;
      if(cmd_accept) begin
        pending_cmd_q<=cmd;pending_base_q<=stream_q;pending_valid_q<=1;
        stream_q<=stream_q+TILE_BITS'(ATTN_K_TILES);prefetched_q<=0;
      end
      if(matrix_issue_done) issue_done_q<=1;
      if(matrix_done) done_hold_q<=1;
      if(read_fire) begin
        if(pair_q==PAIRS-1) begin
          pair_q<=0;
          if(tile_q==ATTN_K_TILES-1) reading_q<=0;
          else tile_q<=tile_q+1'b1;
        end else pair_q<=pair_q+1'b1;
      end
      if(read_start) begin
        reader_cmd_q<=pending_cmd_q;reader_base_q<=pending_base_q;
        tile_q<=0;pair_q<=0;reading_q<=1;prefetched_q<=1;
      end
      if(launch_fire) begin
        cmd_q<=pending_cmd_q;current_valid_q<=1;pending_valid_q<=0;
        issue_done_q<=0;done_hold_q<=0;
      end
      // A lookahead command may launch on the same edge that the previous
      // Matrix job commits.  That edge reports the old descriptor upstream,
      // but the new descriptor must remain the wrapper's current owner.
      if(done_valid&&done_ready&&!launch_fire) begin
        current_valid_q<=0;done_hold_q<=0;
      end
    end
  end
endmodule
