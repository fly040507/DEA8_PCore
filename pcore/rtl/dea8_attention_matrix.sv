import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// Matrix-only Top Job endpoint. AUTO_LAUNCH is for reserved-input cycle tests;
// the full Attention core uses the scheduler's dependency-qualified permit.
module dea8_attention_matrix #(
  parameter bit AUTO_LAUNCH = 0,
  parameter bit ENABLE_LOOKAHEAD = 1
) (
  input logic clk,rst_n,start,
  input logic [HEAD_BITS-1:0] head,
  input logic [EPOCH_BITS-1:0] epoch,
  input logic launch_valid,resources_ready,
  input matrix_job_t launch_job,
  output logic launch_ready,
  output logic job_busy,job_done_valid,
  input logic job_done_ready,
  output matrix_job_t current_job,
  output logic matrix_done,
  input logic b_valid,
  output logic b_ready,
  input logic [DW_ACT-1:0] b_data,
  input logic [SCALE_BITS-1:0] b_scale,
  output logic a_rd_en,
  output matrix_job_t a_read_job,
  output logic [QOZ_ADDR_BITS-1:0] a_rd_addr,
  input logic [DW_ACT-1:0] a_data,
  input logic [SCALE_BITS-1:0] a_scale,
  output logic mem_rd_en,mem_wr_en,
  output acc_sel_e mem_rd_sel,mem_wr_sel,
  output logic [ACC_ADDR_BITS-1:0] mem_rd_addr,mem_wr_addr,
  input logic [DW_VEC-1:0] mem_rd_data,
  output logic [DW_VEC-1:0] mem_wr_data,
  output logic [TILE-1:0] mem_wr_lane_en,
  output logic commit_valid,
  output pipe_tag_t commit_tag,
  output deq_dest_t commit_dest
);
  logic current_valid,next_valid,job_valid,job_ready,pop;
  logic [1:0] queue_count;
  matrix_block_job_t queued_current,queued_next;
  matrix_job_t job,next_job;
  assign pop=job_done_valid && job_done_ready;
  dea8_block_job_queue queue (
    .clk,.rst_n,.start,.head,.epoch,.pop,.current_valid,.next_valid,
    .current(queued_current),.next(queued_next),.count(queue_count)
  );
  assign job=expand_matrix_job(pop ? queued_next : queued_current);
  assign next_job=expand_matrix_job(queued_next);
  assign job_valid=(pop ? next_valid : current_valid) && (!job_busy || pop) && (AUTO_LAUNCH || launch_valid);
  assign launch_ready=(pop ? next_valid : current_valid) && (!job_busy || pop) && job_ready;
  dea8_matrix_engine #(.ENABLE_LOOKAHEAD(ENABLE_LOOKAHEAD)) engine (
    .next_job_valid(next_valid),.*
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) matrix_done<=0;
    else if(start) matrix_done<=0;
    else if(pop && current_job.op==MATRIX_PV && current_job.ctx.block_id==N_KV_BLOCK-1)
      matrix_done<=1;
  end
  // synthesis translate_off
  always @(posedge clk) if(rst_n) begin
    if(start && (job_busy || current_valid)) $fatal(1,"Attention Top Job overlap");
    if(!AUTO_LAUNCH && launch_valid && launch_ready && launch_job!==job)
      $fatal(1,"Matrix launch does not match queued order");
  end
  // synthesis translate_on
endmodule
