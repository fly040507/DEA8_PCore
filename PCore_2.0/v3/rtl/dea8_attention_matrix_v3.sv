import pcore3_pkg::*;

// Block-level Attention adapter around the generic multi-Tile Matrix Core.
//
// QK command: one Matrix job containing 16 K Tiles, reduced into FACC.
// PV command: sixteen one-Tile Matrix jobs, one per output N Tile, reduced
// into OACC.  The adapter hides this internal distinction from the
// Attention scheduler, which sees one completion per QK/PV block.
module dea8_attention_matrix_v3 (
  input logic clk,reset,clear,
  input logic cmd_valid, output logic cmd_ready, input matrix_cmd_t cmd,
  output logic done_valid, input logic done_ready, output matrix_cmd_t done_cmd,
  input logic xbc_valid, output logic xbc_ready, input xbc4_t xbc_entry,
  input logic hbm_valid, output logic hbm_ready, input b2_t hbm_entry,
  input logic kv_valid, output logic kv_ready, input b2_t kv_entry,
  input b_source_e b_source,
  output logic a_protocol_error,b_protocol_error
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
  logic result_rd_data_valid;
  logic [15:0][31:0] result_even_data,result_odd_data;
  logic [3:0] current_nt;
  logic matrix_done_pulse;
  logic [TILE_BITS:0] matrix_job_tiles;

  assign cmd_ready=state_q==IDLE;
  assign done_valid=state_q==DONE;
  assign current_nt=(cmd_q.op==MATRIX_PV)?pv_tile_q:4'd0;
  assign matrix_done_pulse=matrix_done&&!matrix_done_q;
  assign matrix_job_tiles=(cmd_q.op==MATRIX_QK)?(TILE_BITS+1)'(ATTN_K_TILES):
                          (TILE_BITS+1)'(1);

  dea8_matrix_v3 matrix(
    .clk,.reset,.clear,
    .xbc_valid,.xbc_ready,.xbc_entry,
    .hbm_valid,.hbm_ready,.hbm_entry,
    .kv_valid,.kv_ready,.kv_entry,.b_source,
    .job_start(matrix_start_q),
    .job_tile_idx(cmd_q.a_tile+current_nt),
    .job_tiles(matrix_job_tiles),
    .job_epoch(cmd_q.epoch),.job_head(cmd_q.head),.job_nt(current_nt),
    .job_nt_per_tile(1'b0),.job_clear_each_tile(1'b0),
    .job_final_k(1'b1),.job_exp_fold(cmd_q.exp_fold),
    .job_acc_sel(cmd_q.acc_sel),.job_acc_clear(!cmd_q.add_old),
    .job_ready(matrix_ready),.job_busy(matrix_busy),
    .commit_valid(matrix_commit_valid),.done(matrix_done),
    .commit_meta(matrix_commit_meta),
    .result_rd_owner(ACC_READ_DEQACC),.result_rd_valid(1'b0),
    .result_rd_sel(ACC_FACC_A),.result_rd_addr('0),
    .result_rd_data_valid,.result_even_data,.result_odd_data,
    .dbg_valid(1'b0),.dbg_sel(ACC_FACC_A),.dbg_parity(1'b0),
    .dbg_addr('0),.dbg_lane('0),.dbg_data(unused_dbg),
    .a_protocol_error,.b_protocol_error);

  always_comb begin
    matrix_start_q=(state_q==RUN)&&!matrix_done_q&&!matrix_busy&&matrix_ready;
  end

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      state_q<=IDLE;cmd_q<='0;pv_tile_q<=0;matrix_done_q<=0;
      done_cmd<='0;
    end else begin
      matrix_done_q<=matrix_done;
      if(cmd_valid&&cmd_ready) begin
        cmd_q<=cmd;pv_tile_q<=0;state_q<=RUN;
      end
      if(matrix_start_q) matrix_done_q<=0;
      if(matrix_done_pulse) begin
        if(cmd_q.op==MATRIX_PV && pv_tile_q<15) begin
          pv_tile_q<=pv_tile_q+1'b1;
        end else begin
          done_cmd<=cmd_q;state_q<=DONE;
        end
      end
      if(done_valid&&done_ready) state_q<=IDLE;
    end
  end
endmodule
