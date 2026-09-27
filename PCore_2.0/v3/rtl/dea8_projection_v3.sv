import pcore3_pkg::*;

// Projection controller for [51,1024] x [1024,256].
// One output N Tile is a 64-Tile K reduction.  FACC-A is reused between N
// Tiles: after the final D4 commit, the 26 pair rows are streamed to the
// projection/VPU boundary before the next N Tile is launched.
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
  typedef enum logic [2:0] {S_IDLE,S_LAUNCH,S_RUN,S_READ_REQ,S_READ_WAIT,S_DONE} state_e;
  state_e state_q;
  logic [3:0] n_tile_q;
  logic [PAIR_BITS-1:0] pair_q;
  logic matrix_job_start,matrix_ready,matrix_busy,matrix_done;
  logic matrix_commit_valid;
  pair_meta_t matrix_commit_meta;
  logic proj_rd_valid,proj_rd_data_valid;
  logic [4:0] proj_rd_pair;
  logic [15:0][31:0] proj_even_data,proj_odd_data;
  logic [31:0] unused_dbg_data;

  dea8_matrix_v3 matrix(
    .clk,.reset,.clear,
    .xbc_valid,.xbc_ready,.xbc_entry,
    .hbm_valid,.hbm_ready,.hbm_entry,
    .kv_valid(1'b0),.kv_ready(),.kv_entry('0),.b_source(B_HBM),
    .job_start(matrix_job_start),.job_tile_idx('0),.job_tiles((TILE_BITS+1)'(K_TILES)),
    .job_epoch,.job_head,.job_final_k(1'b1),.job_exp_fold,
    .job_acc_sel(ACC_FACC_A),.job_acc_clear(1'b1),.job_ready(matrix_ready),
    .job_busy(matrix_busy),.commit_valid(matrix_commit_valid),.done(matrix_done),
    .commit_meta(matrix_commit_meta),
    .proj_rd_valid,.proj_rd_pair,.proj_rd_data_valid,
    .proj_even_data,.proj_odd_data,
    .dbg_valid(1'b0),.dbg_sel(ACC_FACC_A),.dbg_parity(1'b0),.dbg_addr('0),
    .dbg_lane('0),.dbg_data(unused_dbg_data),
    .a_protocol_error(matrix_a_protocol_error),.b_protocol_error(matrix_b_protocol_error));

  assign busy=(state_q!=S_IDLE)&&(state_q!=S_DONE);
  assign matrix_job_start=(state_q==S_LAUNCH)&&matrix_ready;
  assign proj_rd_valid=(state_q==S_READ_REQ);
  assign proj_rd_pair=pair_q;
  assign qoz_wr_valid=(state_q==S_READ_WAIT)&&proj_rd_data_valid;
  assign qoz_wr_tile=n_tile_q;
  assign qoz_wr_pair=pair_q;
  assign qoz_wr_row_valid=row_mask(pair_q);
  assign qoz_wr_even_fp32=proj_even_data;
  assign qoz_wr_odd_fp32=proj_odd_data;

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      state_q<=S_IDLE;n_tile_q<='0;pair_q<='0;done<=0;
    end else begin
      done<=0;
      case(state_q)
        S_IDLE: if(start) begin n_tile_q<=0;state_q<=S_LAUNCH;end
        S_LAUNCH: if(matrix_job_start) state_q<=S_RUN;
        S_RUN: if(matrix_done) begin pair_q<=0;state_q<=S_READ_REQ;end
        S_READ_REQ: state_q<=S_READ_WAIT;
        S_READ_WAIT: if(proj_rd_data_valid) begin
          if(pair_q==PAIRS-1) begin
            if(n_tile_q==N_TILES-1) state_q<=S_DONE;
            else begin n_tile_q<=n_tile_q+1'b1;pair_q<=0;state_q<=S_LAUNCH;end
          end else begin pair_q<=pair_q+1'b1;state_q<=S_READ_REQ;end
        end
        S_DONE: begin done<=1;state_q<=S_IDLE;end
        default: state_q<=S_IDLE;
      endcase
    end
  end
  initial if(K_TILES!=64||N_TILES!=16) $fatal(1,"Projection geometry must be 64x16 Tiles");
endmodule
