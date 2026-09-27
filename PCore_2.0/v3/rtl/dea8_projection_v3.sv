import pcore3_pkg::*;

// Projection controller for [51,1024] x [1024,256].
// One output N Tile is a 64-Tile K reduction.  FACC-A/FACC-B ping-pong so the
// next N Tile can start while the completed N Tile is being read out.
module dea8_projection_v3 #(
  parameter int K_TILES=64,
  parameter int N_TILES=16
) (
  input logic clk,reset,clear,
  input logic start,
  input logic [EPOCH_BITS-1:0] job_epoch,
  input logic [2:0] job_head,
  input logic signed [EXP_FOLD_BITS-1:0] job_exp_fold,
  output logic busy,done,
  input logic xbc_valid, output logic xbc_ready, input xbc4_t xbc_entry,
  input logic hbm_valid, output logic hbm_ready, input b2_t hbm_entry,
  // Projection output stream.  VPU performs the later FP32-to-INT8
  // quantization before writing the physical QOZ buffer.
  output logic qoz_wr_valid,
  output logic [3:0] qoz_wr_tile,
  output logic [PAIR_BITS-1:0] qoz_wr_pair,
  output logic [1:0] qoz_wr_row_valid,
  output logic [15:0][31:0] qoz_wr_even_fp32,
  output logic [15:0][31:0] qoz_wr_odd_fp32,
  output logic matrix_a_protocol_error,
  output logic matrix_b_protocol_error
);
  typedef enum logic [2:0] {S_IDLE,S_LAUNCH,S_RUN,S_OVERLAP,S_DONE} state_e;
  state_e state_q;
  logic [3:0] matrix_tile_q,read_tile_q;
  logic [PAIR_BITS-1:0] read_pair_q,response_pair_q;
  logic matrix_finished_q,read_last_requested_q,read_finished_q,next_pending_q;
  logic matrix_job_start,matrix_ready,matrix_busy,matrix_done;
  logic matrix_commit_valid;
  pair_meta_t matrix_commit_meta;
  logic result_rd_valid,result_rd_data_valid;
  acc_sel_e result_rd_sel;
  logic [9:0] result_rd_addr;
  logic [15:0][31:0] result_even_data,result_odd_data;
  logic [31:0] unused_dbg_data;
  logic qoz_wr_valid_q;
  logic [3:0] qoz_wr_tile_q;
  logic [PAIR_BITS-1:0] qoz_wr_pair_q;
  logic [1:0] qoz_wr_row_valid_q;
  logic [15:0][31:0] qoz_wr_even_q,qoz_wr_odd_q;
  logic launch_next;
  logic [3:0] matrix_launch_tile;
  logic matrix_done_q;
  logic matrix_done_pulse;
  logic matrix_inflight_q;

  dea8_matrix_v3 matrix(
    .clk,.reset,.clear,
    .xbc_valid,.xbc_ready,.xbc_entry,
    .hbm_valid,.hbm_ready,.hbm_entry,
    .kv_valid(1'b0),.kv_ready(),.kv_entry('0),.b_source(B_HBM),
    .job_start(matrix_job_start),.job_tile_idx('0),.job_tiles((TILE_BITS+1)'(K_TILES)),
    .job_epoch,.job_head,.job_nt(matrix_launch_tile),
    .job_nt_per_tile(1'b0),.job_clear_each_tile(1'b0),
    .job_final_k(1'b1),.job_exp_fold,
    .job_acc_sel(matrix_launch_tile[0]?ACC_FACC_B:ACC_FACC_A),.job_acc_clear(1'b1),.job_ready(matrix_ready),
    .job_busy(matrix_busy),.commit_valid(matrix_commit_valid),.done(matrix_done),
    .commit_meta(matrix_commit_meta),
    .result_rd_owner(ACC_READ_RESULT),.result_rd_valid,.result_rd_sel,.result_rd_addr,
    .result_rd_data_valid,.result_even_data,.result_odd_data,
    .dbg_valid(1'b0),.dbg_sel(ACC_FACC_A),.dbg_parity(1'b0),.dbg_addr('0),
    .dbg_lane('0),.dbg_data(unused_dbg_data),
    .a_protocol_error(matrix_a_protocol_error),.b_protocol_error(matrix_b_protocol_error));

  assign busy=(state_q!=S_IDLE)&&(state_q!=S_DONE);
  assign launch_next=(state_q==S_OVERLAP)&&next_pending_q&&matrix_ready;
  assign matrix_job_start=((state_q==S_LAUNCH)||(launch_next))&&matrix_ready;
  assign matrix_launch_tile=(state_q==S_LAUNCH)?matrix_tile_q:(matrix_tile_q+1'b1);
  assign matrix_done_pulse=matrix_done&&!matrix_done_q;
  // The result port is a one-cycle request/response interface.  The pair
  // number is captured when the request is issued; the output pulse itself
  // is registered below so a simultaneous matrix completion cannot change
  // the tile tag seen by the consumer.
  assign result_rd_valid=(state_q==S_OVERLAP)&&matrix_finished_q&&!read_last_requested_q;
  assign result_rd_sel=read_tile_q[0]?ACC_FACC_B:ACC_FACC_A;
  assign result_rd_addr={{(10-PAIR_BITS){1'b0}},read_pair_q};
  assign qoz_wr_valid=qoz_wr_valid_q;
  assign qoz_wr_tile=qoz_wr_tile_q;
  assign qoz_wr_pair=qoz_wr_pair_q;
  assign qoz_wr_row_valid=qoz_wr_row_valid_q;
  assign qoz_wr_even_fp32=qoz_wr_even_q;
  assign qoz_wr_odd_fp32=qoz_wr_odd_q;

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      state_q<=S_IDLE;matrix_tile_q<='0;read_tile_q<='0;read_pair_q<='0;
      response_pair_q<='0;matrix_finished_q<=0;read_last_requested_q<=0;
      read_finished_q<=0;next_pending_q<=0;done<=0;
      matrix_done_q<=0;
      matrix_inflight_q<=0;
      qoz_wr_valid_q<=0;qoz_wr_tile_q<='0;qoz_wr_pair_q<='0;qoz_wr_row_valid_q<='0;
      qoz_wr_even_q<='0;qoz_wr_odd_q<='0;
    end else begin
      done<=0;
      matrix_done_q<=matrix_done;
      qoz_wr_valid_q<=0;
      if(result_rd_valid) begin
        response_pair_q<=read_pair_q;
        if(read_pair_q==PAIRS-1) read_last_requested_q<=1;
        else read_pair_q<=read_pair_q+1'b1;
      end
      if(result_rd_data_valid) begin
        qoz_wr_valid_q<=1;
        qoz_wr_tile_q<=read_tile_q;
        qoz_wr_pair_q<=response_pair_q;
        qoz_wr_row_valid_q<=row_mask(response_pair_q);
        qoz_wr_even_q<=result_even_data;
        qoz_wr_odd_q<=result_odd_data;
        if(read_last_requested_q) read_finished_q<=1;
      end
      case(state_q)
        S_IDLE: if(start) begin
          matrix_tile_q<=0;next_pending_q<=1;state_q<=S_LAUNCH;
        end
        S_LAUNCH: if(matrix_job_start) begin
          next_pending_q<=0;matrix_inflight_q<=1;state_q<=S_RUN;
        end
        S_RUN: if(matrix_done_pulse) begin
          read_tile_q<=matrix_tile_q;read_pair_q<=0;response_pair_q<=0;
          matrix_finished_q<=1;read_last_requested_q<=0;read_finished_q<=0;
          matrix_inflight_q<=0;
          next_pending_q<=matrix_tile_q<N_TILES-1;state_q<=S_OVERLAP;
        end
        S_OVERLAP: begin
          if(launch_next) begin
            matrix_tile_q<=matrix_tile_q+1'b1;
            // The reader belongs to the previously completed Tile and must
            // continue while the next Matrix job is running.  Do not clear
            // matrix_finished_q here; it is also the reader-active guard.
            next_pending_q<=0;matrix_inflight_q<=1;
          end
          if(matrix_done_pulse) begin
            read_tile_q<=matrix_tile_q;read_pair_q<=0;response_pair_q<=0;
            matrix_finished_q<=1;read_last_requested_q<=0;read_finished_q<=0;
            matrix_inflight_q<=0;
            next_pending_q<=matrix_tile_q<N_TILES-1;
          end
          if(matrix_tile_q==N_TILES-1 && !matrix_inflight_q &&
             matrix_finished_q && read_finished_q)
            state_q<=S_DONE;
        end
        // Keep completion asserted until the next request.  A level
        // completion is safer at the controller boundary than a one-clock
        // pulse that can be missed while the producer is still draining its
        // last input beat.
        S_DONE: begin
          done<=1;
          if(start) begin
            done<=0;matrix_tile_q<=0;next_pending_q<=1;state_q<=S_LAUNCH;
          end
        end
        default: state_q<=S_IDLE;
      endcase
    end
  end
  initial if(K_TILES<1||N_TILES<1||K_TILES>(1<<TILE_BITS)||N_TILES>16)
    $fatal(1,"Projection Tile parameters out of range");
endmodule
