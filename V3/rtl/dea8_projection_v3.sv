import pcore3_pkg::*;

// Projection controller for [51,1024] x [1024,256].
// One output N Tile is a 64-Tile K reduction.  FACC-A/FACC-B ping-pong so the
// next N Tile can start while the completed N Tile is being read out.
module dea8_projection_v3 #(
  parameter int K_TILES=64,
  parameter int N_TILES=16,
  parameter bit EXTERNAL_MATRIX=0
) (
  input logic clk,reset,clear,
  output matrix_service_req_t service_req,input matrix_service_rsp_t service_rsp,
  input logic start,
  input logic [MATRIX_TILE_COUNT_BITS-1:0] job_k_tiles,
  input logic [MATRIX_TILE_COUNT_BITS-1:0] job_n_tiles,
  input a_source_e job_a_source,input b_source_e job_b_source,
  input logic local_a_valid,input a2_t local_a_entry,
  output logic local_a_ready,
  output logic local_rd_valid,input logic local_rd_ready,
  output logic [TILE_BITS-1:0] local_rd_tile,
  output logic [PAIR_BITS-1:0] local_rd_pair,
  output logic [TILE_BITS-1:0] local_rd_transport,
  input logic [EPOCH_BITS-1:0] job_epoch,
  input logic [2:0] job_head,
  input logic signed [EXP_FOLD_BITS-1:0] job_exp_fold,
  output logic busy,done,
  input logic xbc_valid, output logic xbc_ready, input xbc4_t xbc_entry,
  input logic hbm_valid, output logic hbm_ready, input b2_t hbm_entry,
  // Projection output stream.  VPU performs the later FP32-to-INT8
  // quantization before writing the physical QOZ buffer.
  output logic qoz_wr_valid,
  input logic qoz_wr_ready,
  output logic [TILE_BITS-1:0] qoz_wr_tile,
  output logic [PAIR_BITS-1:0] qoz_wr_pair,
  output logic [1:0] qoz_wr_row_valid,
  output logic [15:0][31:0] qoz_wr_even_fp32,
  output logic [15:0][31:0] qoz_wr_odd_fp32,
  output logic matrix_a_protocol_error,
  output logic matrix_b_protocol_error
);
  typedef enum logic [2:0] {S_IDLE,S_LAUNCH,S_RUN,S_OVERLAP,S_DONE} state_e;
  state_e state_q;
  logic [TILE_BITS-1:0] matrix_tile_q,read_tile_q;
  logic [PAIR_BITS-1:0] read_pair_q,response_pair_q;
  logic matrix_finished_q,read_last_requested_q,read_finished_q,next_pending_q;
  logic matrix_job_start,matrix_ready,matrix_busy,matrix_done;
  logic matrix_commit_valid;
  pair_meta_t matrix_commit_meta;
  logic result_rd_valid,result_rd_ready,result_rd_data_valid;
  acc_sel_e result_rd_sel;
  logic [9:0] result_rd_addr;
  logic [15:0][31:0] result_even_data,result_odd_data;
  logic [31:0] unused_dbg_data;
  logic qoz_wr_valid_q;
  logic [TILE_BITS-1:0] qoz_wr_tile_q;
  logic [PAIR_BITS-1:0] qoz_wr_pair_q;
  logic [1:0] qoz_wr_row_valid_q;
  logic [15:0][31:0] qoz_wr_even_q,qoz_wr_odd_q;
  logic launch_next;
  logic [TILE_BITS-1:0] matrix_launch_tile;
  logic matrix_done_q;
  logic matrix_done_pulse;
  logic matrix_inflight_q;
  logic read_pending_q,completion_pending_q;
  logic [MATRIX_TILE_COUNT_BITS-1:0] k_tiles_q;
  logic [MATRIX_TILE_COUNT_BITS-1:0] n_tiles_q;
  logic [TILE_BITS-1:0] local_tile_q;
  logic [PAIR_BITS-1:0] local_pair_q;
  logic local_active_q;
  logic [TILE_BITS-1:0] stream_base_q;

  always_comb begin
    service_req='0;service_req.start=matrix_job_start;service_req.mode=MAT_PROJECTION;
    service_req.a_source=job_a_source;service_req.a_streaming=job_a_source==A_LOCAL;service_req.b_source=job_b_source;
    service_req.local_valid=local_a_valid;service_req.local_entry=local_a_entry;
    service_req.a_stream=stream_base_q;service_req.b_stream=stream_base_q;
    service_req.tiles=k_tiles_q;service_req.rows=ROWS;
    service_req.epoch=job_epoch;service_req.head=job_head;service_req.nt=matrix_launch_tile;
    service_req.final_k=1;service_req.exp_fold=job_exp_fold;service_req.slot_ready=1;
    service_req.acc_sel=matrix_launch_tile[0]?ACC_FACC_B:ACC_FACC_A;
    service_req.rd_valid=result_rd_valid;service_req.rd_sel=result_rd_sel;service_req.rd_addr=result_rd_addr;
  end
  // The QOZ response register supplies backpressure through local_rd_ready.
  // Advance the request address on acceptance, allowing consume/refill each
  // cycle instead of serializing request, response and consumption.
  assign local_rd_valid=local_active_q&&job_a_source==A_LOCAL&&k_tiles_q!=0;
  assign local_rd_tile=local_tile_q;
  assign local_rd_pair=local_pair_q;
  assign local_rd_transport=stream_base_q+local_tile_q;
  if(EXTERNAL_MATRIX) begin: external_matrix
    assign matrix_ready=service_rsp.ready;assign matrix_busy=service_rsp.busy;
    assign local_a_ready=service_rsp.local_ready;
    assign matrix_done=service_rsp.done;assign matrix_commit_valid=service_rsp.commit_valid;
    assign matrix_commit_meta=service_rsp.meta;
    assign result_rd_ready=service_rsp.rd_ready;assign result_rd_data_valid=service_rsp.rd_valid;
    assign result_even_data=service_rsp.even_data;assign result_odd_data=service_rsp.odd_data;
    assign matrix_a_protocol_error=service_rsp.a_error;assign matrix_b_protocol_error=service_rsp.b_error;
    assign xbc_ready=0;assign hbm_ready=0;assign unused_dbg_data=0;
  end else begin: private_matrix
  dea8_matrix_v3 #(.SHARED_MODE(1)) matrix(
    .clk,.reset,.clear,
    .runtime_local_a(job_a_source==A_LOCAL),.runtime_streaming(job_a_source==A_LOCAL),
    .xbc_valid,.xbc_ready,.xbc_entry,
    .local_a_valid,.local_a_entry,.local_a_ready,
    .vpu_wr_valid(1'b0),.vpu_wr('0),.vpu_wr_ready(),
    .hbm_valid,.hbm_ready,.hbm_entry,
    .kv_valid(1'b0),.kv_ready(),.kv_entry('0),.b_source(job_b_source),
    .job_start(matrix_job_start),.job_a_tile_idx('0),.job_b_tile_idx('0),
    .job_a_stream_idx(stream_base_q),.job_b_stream_idx(stream_base_q),
    .job_tiles(k_tiles_q),.job_m_rows((PAIR_BITS+1)'(ROWS)),
    .job_epoch,.job_head,.job_nt(matrix_launch_tile),
    .job_nt_per_tile(1'b0),.job_clear_each_tile(1'b0),
    .job_final_k(1'b1),.job_exp_fold,
    .job_mode(MAT_PROJECTION),.job_gu_n('0),.gu_slot_ready(1'b1),
    .job_acc_sel(matrix_launch_tile[0]?ACC_FACC_B:ACC_FACC_A),.job_add_old(1'b0),.job_ready(matrix_ready),
    .job_busy(matrix_busy),.commit_valid(matrix_commit_valid),.done(matrix_done),
    .commit_meta(matrix_commit_meta),.commit_write_valid(),.commit_write(),.gu_slot_reserve(),
    .result_rd_owner(ACC_READ_RESULT),.result_rd_valid,.result_rd_ready,.result_rd_sel,.result_rd_addr,
    .result_rd_data_valid,.result_even_data,.result_odd_data,
    .dbg_valid(1'b0),.dbg_sel(ACC_FACC_A),.dbg_parity(1'b0),.dbg_addr('0),
    .dbg_lane('0),.dbg_data(unused_dbg_data),
    .a_protocol_error(matrix_a_protocol_error),.b_protocol_error(matrix_b_protocol_error));
  end

  assign busy=(state_q!=S_IDLE)&&(state_q!=S_DONE);
  assign launch_next=(state_q==S_OVERLAP)&&next_pending_q&&matrix_ready;
  assign matrix_job_start=((state_q==S_LAUNCH)||(launch_next))&&matrix_ready;
  assign matrix_launch_tile=(state_q==S_LAUNCH)?matrix_tile_q:(matrix_tile_q+1'b1);
  assign matrix_done_pulse=matrix_done&&!matrix_done_q;
  // The result port is a one-cycle request/response interface.  The pair
  // number is captured when the request is issued; the output pulse itself
  // is registered below so a simultaneous matrix completion cannot change
  // the tile tag seen by the consumer.
  assign result_rd_valid=(state_q==S_OVERLAP)&&matrix_finished_q&&!read_last_requested_q&&
    !read_pending_q&&(!qoz_wr_valid_q||qoz_wr_ready);
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
      read_pending_q<=0;completion_pending_q<=0;
      k_tiles_q<=MATRIX_TILE_COUNT_BITS'(K_TILES);n_tiles_q<=MATRIX_TILE_COUNT_BITS'(N_TILES);
      local_tile_q<=0;local_pair_q<=0;
      local_active_q<=0;stream_base_q<=0;
      qoz_wr_valid_q<=0;qoz_wr_tile_q<='0;qoz_wr_pair_q<='0;qoz_wr_row_valid_q<='0;
      qoz_wr_even_q<='0;qoz_wr_odd_q<='0;
    end else begin
      done<=0;
      matrix_done_q<=matrix_done;
      if(qoz_wr_valid_q&&qoz_wr_ready) begin
        qoz_wr_valid_q<=0;
        if(qoz_wr_pair_q==PAIRS-1) read_finished_q<=1;
      end
      if(result_rd_valid&&result_rd_ready) begin
        read_pending_q<=1;
        response_pair_q<=read_pair_q;
        if(read_pair_q==PAIRS-1) read_last_requested_q<=1;
        else read_pair_q<=read_pair_q+1'b1;
      end
      if(result_rd_data_valid) begin
        read_pending_q<=0;
        qoz_wr_valid_q<=1;
        qoz_wr_tile_q<=read_tile_q;
        qoz_wr_pair_q<=response_pair_q;
        qoz_wr_row_valid_q<=row_mask(response_pair_q);
        qoz_wr_even_q<=result_even_data;
        qoz_wr_odd_q<=result_odd_data;
      end
      if(local_rd_valid&&local_rd_ready) begin
        if(local_pair_q==PAIRS-1) begin
          local_pair_q<=0;local_tile_q<=local_tile_q+1'b1;
          if({1'b0,local_tile_q}+1'b1==k_tiles_q) local_active_q<=0;
        end
        else local_pair_q<=local_pair_q+1'b1;
      end
      if(matrix_done_pulse) begin
        stream_base_q<=stream_base_q+TILE_BITS'(k_tiles_q);
        local_tile_q<=0;local_pair_q<=0;
        local_active_q<=matrix_tile_q<n_tiles_q-1;
      end
      case(state_q)
        S_IDLE: if(start) begin
          k_tiles_q<=job_k_tiles;n_tiles_q<=job_n_tiles;
          local_tile_q<=0;local_pair_q<=0;
          local_active_q<=1;stream_base_q<=0;
          matrix_tile_q<=0;next_pending_q<=1;state_q<=S_LAUNCH;
        end
        S_LAUNCH: if(matrix_job_start) begin
          next_pending_q<=0;matrix_inflight_q<=1;state_q<=S_RUN;
        end
        S_RUN: if(matrix_done_pulse) begin
          read_tile_q<=matrix_tile_q;read_pair_q<=0;response_pair_q<=0;
          matrix_finished_q<=1;read_last_requested_q<=0;read_finished_q<=0;
          matrix_inflight_q<=0;
          local_tile_q<=0;local_pair_q<=0;
          next_pending_q<=matrix_tile_q<n_tiles_q-1;state_q<=S_OVERLAP;
        end
        S_OVERLAP: begin
          if(launch_next) begin
            matrix_tile_q<=matrix_tile_q+1'b1;
            // The reader belongs to the previously completed Tile and must
            // continue while the next Matrix job is running.  Do not clear
            // matrix_finished_q here; it is also the reader-active guard.
            next_pending_q<=0;matrix_inflight_q<=1;
          end
          if(matrix_done_pulse) begin completion_pending_q<=1;matrix_inflight_q<=0;end
          if((matrix_done_pulse||completion_pending_q)&&read_finished_q) begin
            completion_pending_q<=0;
            read_tile_q<=matrix_tile_q;read_pair_q<=0;response_pair_q<=0;
            matrix_finished_q<=1;read_last_requested_q<=0;read_finished_q<=0;
            matrix_inflight_q<=0;
            next_pending_q<=matrix_tile_q<n_tiles_q-1;
          end
          if(matrix_tile_q==n_tiles_q-1 && !matrix_inflight_q &&
              matrix_finished_q && read_finished_q && read_tile_q==matrix_tile_q && !completion_pending_q)
            state_q<=S_DONE;
        end
        // Keep completion asserted until the next request.  A level
        // completion is safer at the controller boundary than a one-clock
        // pulse that can be missed while the producer is still draining its
        // last input beat.
        S_DONE: begin
          done<=1;
          if(start) begin
            k_tiles_q<=job_k_tiles;n_tiles_q<=job_n_tiles;
            local_tile_q<=0;local_pair_q<=0;
            local_active_q<=1;stream_base_q<=0;
            done<=0;matrix_tile_q<=0;next_pending_q<=1;state_q<=S_LAUNCH;
          end
        end
        default: state_q<=S_IDLE;
      endcase
    end
  end
  initial if(K_TILES<1||N_TILES<1||K_TILES>(1<<TILE_BITS)||N_TILES>(1<<TILE_BITS))
    $fatal(1,"Projection Tile parameters out of range");
endmodule
