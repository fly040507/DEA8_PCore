import pcore3_pkg::*;

// One operation owns Matrix/post/QOZ until all Z commits and both post engines
// retire. No layer/denoise sequencer here. Unsupported operations complete with
// an explicit error rather than silently executing a Projection-shaped job.
module dea8_pcore_ctrl_v3 #(parameter int N_TILES=32)(
  input logic clk,reset,clear,
  input logic job_valid,output logic job_ready,input pcore_job_t job,
  output logic job_done_valid,input logic job_done_ready,output pcore_completion_t job_done,
  output logic busy,protocol_error,
  output logic matrix_job_valid,input logic matrix_job_ready,output pcore_matrix_job_t matrix_job,
  input logic matrix_done_valid,output logic matrix_done_ready,input pcore_matrix_job_t matrix_done,
  input logic pair_valid,output logic pair_ready,input logic [5:0] pair_n,
  input logic [EPOCH_BITS-1:0] pair_epoch,input logic [2:0] pair_head,
  output logic vpu_job_valid,input logic vpu_job_ready,output pcore_vpu_job_t vpu_job,
  input logic vpu_done_valid,output logic vpu_done_ready,input pcore_vpu_job_t vpu_done,
  output logic sfu_job_valid,input logic sfu_job_ready,output pcore_sfu_job_t sfu_job,
  input logic sfu_done_valid,output logic sfu_done_ready,input pcore_sfu_job_t sfu_done,
  output logic qoz_begin_valid,input logic qoz_begin_ready,
  output job_header_t active_header,
  input logic z_tile_commit,input logic [5:0] z_n,
  input logic [EPOCH_BITS-1:0] z_epoch,input logic [2:0] z_head,
  input logic qoz_complete,input logic engine_error
);
  typedef enum logic [2:0] {IDLE,BEGIN_REGION,START_GU,RUN,COMPLETE,FAULT} state_t;
  state_t state_q;
  job_header_t header_q;
  logic scheduler_start_ready,scheduler_busy,scheduler_all,scheduler_done,scheduler_error;
  logic tile_valid,tile_ready;logic [5:0] tile_n;
  logic [EPOCH_BITS-1:0] tile_epoch;logic [2:0] tile_head;
  logic matrix_inflight_q,post_active_q,vpu_sent_q,sfu_sent_q,vpu_finished_q,sfu_finished_q,z_seen_q;
  logic [5:0] post_n_q;logic [6:0] post_count_q;
  pcore_matrix_job_t matrix_q;
  logic matrix_match,vpu_match,sfu_match,z_match;
  assign active_header=header_q;
  assign busy=state_q!=IDLE;
  assign job_ready=state_q==IDLE&&!reset&&!clear;
  assign job_done_valid=state_q==COMPLETE&&!reset&&!clear;
  assign qoz_begin_valid=state_q==BEGIN_REGION&&!reset&&!clear;
  assign matrix_job_valid=state_q==RUN&&tile_valid&&!matrix_inflight_q;
  assign tile_ready=matrix_job_ready&&state_q==RUN&&!matrix_inflight_q;
  assign matrix_job='{header:header_q,mode:MAT_GU,n:tile_n,k_tiles:8'd64,m_rows:6'(ROWS)};
  assign matrix_done_ready=state_q==RUN&&matrix_inflight_q;
  assign matrix_match=matrix_done===matrix_q;
  assign pair_ready=state_q==RUN&&!post_active_q;
  assign vpu_job='{header:header_q,op:POST_GU,n:post_n_q};
  assign sfu_job='{header:header_q,op:GELU_GU,n:post_n_q};
  assign vpu_job_valid=state_q==RUN&&post_active_q&&!vpu_sent_q;
  assign sfu_job_valid=state_q==RUN&&post_active_q&&!sfu_sent_q;
  assign vpu_done_ready=state_q==RUN&&post_active_q&&vpu_sent_q&&!vpu_finished_q;
  assign sfu_done_ready=state_q==RUN&&post_active_q&&sfu_sent_q&&!sfu_finished_q;
  assign vpu_match=vpu_done===vpu_job;
  assign sfu_match=sfu_done===sfu_job;
  assign z_match=post_active_q&&!z_seen_q&&z_n==post_n_q&&z_epoch==header_q.epoch&&z_head==header_q.head;
  dea8_gu_scheduler_v3 #(.N_TILES(N_TILES)) gu(
    .clk,.reset,.clear,.start(state_q==START_GU),.start_ready(scheduler_start_ready),
    .job_epoch(header_q.epoch),.job_head(header_q.head),.tile_valid,.tile_ready,.tile_n,.tile_epoch,.tile_head,
    .prefetch_valid(),.prefetch_ready(1'b0),.prefetch_n(),.prefetch_epoch(),.prefetch_head(),
    .tile_matrix_done(matrix_done_valid&&matrix_done_ready&&matrix_match),
    .z_tile_commit(z_tile_commit&&z_match&&state_q==RUN),.z_n,.z_epoch,.z_head,
    .busy(scheduler_busy),.matrix_all_done(scheduler_all),.done(scheduler_done),.protocol_error(scheduler_error));
  always_ff @(posedge clk) begin
    if(reset||clear)begin
      state_q<=IDLE;header_q<='0;job_done<='0;protocol_error<=0;matrix_inflight_q<=0;matrix_q<='0;
      post_active_q<=0;post_n_q<=0;post_count_q<=0;vpu_sent_q<=0;sfu_sent_q<=0;
      vpu_finished_q<=0;sfu_finished_q<=0;z_seen_q<=0;
    end else begin
      if(job_valid&&job_ready)begin
        header_q<=job.header;job_done.header<=job.header;
        job_done.status<=job.header.op==OP_GU?JOB_OK:JOB_UNSUPPORTED;
        state_q<=job.header.op==OP_GU?BEGIN_REGION:COMPLETE;
        post_count_q<=0;
      end
      if(qoz_begin_valid&&qoz_begin_ready)state_q<=START_GU;
      if(state_q==START_GU&&scheduler_start_ready)state_q<=RUN;
      if(matrix_job_valid&&matrix_job_ready)begin matrix_inflight_q<=1;matrix_q<=matrix_job;end
      if(matrix_done_valid&&matrix_done_ready&&matrix_match)matrix_inflight_q<=0;
      if(pair_valid&&pair_ready)begin
        post_active_q<=1;post_n_q<=pair_n;vpu_sent_q<=0;sfu_sent_q<=0;
        vpu_finished_q<=0;sfu_finished_q<=0;z_seen_q<=0;
      end
      if(vpu_job_valid&&vpu_job_ready)vpu_sent_q<=1;
      if(sfu_job_valid&&sfu_job_ready)sfu_sent_q<=1;
      if(vpu_done_valid&&vpu_done_ready&&vpu_match)vpu_finished_q<=1;
      if(sfu_done_valid&&sfu_done_ready&&sfu_match)sfu_finished_q<=1;
      if(z_tile_commit&&z_match)z_seen_q<=1;
      if(post_active_q&&vpu_finished_q&&sfu_finished_q&&z_seen_q)begin post_active_q<=0;post_count_q<=post_count_q+1'b1;end
      if(state_q==RUN&&scheduler_all&&qoz_complete&&post_count_q==N_TILES&&!matrix_inflight_q&&!post_active_q)
        state_q<=COMPLETE;
      if(job_done_valid&&job_done_ready)state_q<=IDLE;
      if(state_q==RUN&&(scheduler_error||engine_error||
        (matrix_done_valid&&(!matrix_done_ready||!matrix_match))||
        (vpu_done_valid&&(!vpu_done_ready||!vpu_match||!(z_seen_q||(z_tile_commit&&z_match))))||
        (sfu_done_valid&&(!sfu_done_ready||!sfu_match))||
        (pair_valid&&pair_ready&&(pair_n!=post_count_q||pair_epoch!=header_q.epoch||pair_head!=header_q.head))||
        (z_tile_commit&&!z_match)))begin
        protocol_error<=1;job_done.status<=JOB_PROTOCOL_ERROR;state_q<=FAULT;
      end
      // Fault is sticky until clear: do not release resources with work in flight.
    end
  end
endmodule
