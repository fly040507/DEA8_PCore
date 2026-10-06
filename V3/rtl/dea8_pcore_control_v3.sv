import pcore3_pkg::*;
import pcore_control_pkg::*;

// PCore internal control center, V3.
//
// DEA8 owns layer/denoise sequencing and submits one logical job at a time.
// This wrapper preserves the complete DEA8 context and exposes the ownership
// boundary to the external VPU/SFU and collective units.  It does not contain
// a concatenation tree or a reduction tree.
//
// Interface contract:
//   post_*             : VPU/SFU command, input data, and completion.
//   collective_cmd_*  : K/V concat or O/Down reduction tile command.
//   collective_data_* : O/Down FP32 partial stream sent to the reducer.
//   collective_result_*: K/V quantized result returned by VPU/SFU and
//                        forwarded to the concat unit.
//   collective_done_* : O/Down reduction completion returned to PCore.
//
// For K/V, a post command is accepted only when both the VPU/SFU and the
// concat command receiver are ready.  A K/V result is accepted only when the
// concat receiver is ready; therefore the external VPU/SFU must hold its
// result until post_result_ready is asserted.  For O/Down, the collective
// unit directly owns the post command/data/done handshake.
module dea8_pcore_control_v3 #(
  parameter bit PAIRED_Q_POST=0
) (
  input logic clk,reset,clear,
  input logic job_valid,output logic job_ready,input control_job_t job,
  output logic done_valid,input logic done_ready,
  output control_completion_t done,
  output logic busy,output logic protocol_error,
  output logic [1:0] active_adapter,

  // Matrix-side streams. The selected V3 adapter owns their timing.
  input logic xbc_valid,output logic xbc_ready,input xbc4_t xbc_entry,
  input logic hbm_valid,output logic hbm_ready,input b2_t hbm_entry,
  input logic kv_valid,output logic kv_ready,input b2_t kv_entry,

  // VPU/SFU post-processing command and input stream.
  output logic post_valid,input logic post_ready,output pcore_post_job_t post_job,
  input logic post_done_valid,output logic post_done_ready,input pcore_post_job_t post_done,
  output logic post_data_valid,input logic post_data_ready,output post_data_t post_data,
  input logic post_result_valid,output logic post_result_ready,input post_result_t post_result,

  // K/V concat and O/Down reduction boundary.
  output logic collective_cmd_valid,input logic collective_cmd_ready,
  output pcore_post_job_t collective_cmd,
  output logic collective_data_valid,input logic collective_data_ready,
  output post_data_t collective_data,
  output logic collective_result_valid,input logic collective_result_ready,
  output post_result_t collective_result,
  input logic collective_done_valid,output logic collective_done_ready,
  input pcore_post_job_t collective_done,

  // Attention VPU/SFU command ports. Their implementations and latency are
  // external; PCore only supplies context and checks the returned token.
  output logic vpu_valid,input logic vpu_ready,output vpu_cmd_t vpu_cmd,
  input logic vpu_done_valid,output logic vpu_done_ready,input vpu_cmd_t vpu_done,
  output logic sfu_valid,input logic sfu_ready,output sfu_cmd_t sfu_cmd,
  input logic sfu_done_valid,output logic sfu_done_ready,input sfu_cmd_t sfu_done,

  // Attention P/S sideband and accumulator ports.
  input logic p_valid,output logic p_ready,input a2_t p_entry,input logic [5:0] p_block,
  input logic [EPOCH_BITS-1:0] p_epoch,input logic [2:0] p_head,
  input logic acc_rd_valid,output logic acc_rd_ready,input acc_sel_e acc_rd_sel,input logic [9:0] acc_rd_addr,
  output logic acc_data_valid,output logic [15:0][31:0] acc_even,acc_odd,
  input logic acc_wr_valid,output logic acc_wr_ready,input acc_write_t acc_wr,

  // QOZ local reader and region boundary.
  input logic z_rd_valid,output logic z_rd_ready,input logic [5:0] z_rd_tile,
  input logic [PAIR_BITS-1:0] z_rd_pair,output logic z_out_valid,input logic z_out_ready,output a2_t z_entry,
  output logic qoz_complete,output qoz_region_req_t qoz_region,
  input logic ext_qoz_region_valid,output logic ext_qoz_region_ready,input qoz_region_req_t ext_qoz_region,
  input logic ext_qoz_wr_valid,output logic ext_qoz_wr_ready,input post_result_t ext_qoz_wr,
  output logic gu_prefetch_valid,input logic gu_prefetch_ready,output logic [5:0] gu_prefetch_n
);
  pcore_job_t legacy_job;
  pcore_completion_t legacy_done;
  logic legacy_job_ready,legacy_done_valid,legacy_done_ready;
  logic legacy_busy,legacy_error;
  logic [1:0] legacy_owner;
  logic control_stream_error;
  control_job_t job_q;

  // The adapter keeps the live operation header. The wrapper retains the
  // opaque DEA8 context and restores it on completion.
  logic is_kv_job,is_reduce_job,is_collective_job;
  logic exec_post_valid,exec_post_ready;
  pcore_post_job_t exec_post_job;
  logic exec_post_done_valid,exec_post_done_ready;
  pcore_post_job_t exec_post_done;
  logic exec_post_data_valid,exec_post_data_ready;
  post_data_t exec_post_data;
  logic exec_post_result_valid,exec_post_result_ready;
  post_result_t exec_post_result;

  assign legacy_job='{header:job.header};
  assign job_ready=legacy_job_ready;
  assign legacy_done_ready=done_ready;
  assign busy=legacy_busy;
  assign protocol_error=legacy_error||control_stream_error;
  assign active_adapter=legacy_owner;

  assign is_kv_job=(job_q.header.op==OP_K_PROJ)||(job_q.header.op==OP_V_PROJ);
  assign is_reduce_job=(job_q.header.op==OP_O_PROJ)||(job_q.header.op==OP_DOWN_PROJ);
  assign is_collective_job=is_kv_job||is_reduce_job;

  // Start command fan-out. K/V needs an atomic command acceptance by both
  // the post unit and the concat receiver. O/Down is owned by the reducer.
  assign post_valid=(!is_reduce_job)&&exec_post_valid;
  assign post_job=exec_post_job;
  assign collective_cmd_valid=is_collective_job&&exec_post_valid;
  assign collective_cmd=exec_post_job;
  always_comb begin
    if(is_reduce_job) exec_post_ready=collective_cmd_ready;
    else if(is_kv_job) exec_post_ready=post_ready&&collective_cmd_ready;
    else exec_post_ready=post_ready;
  end

  // O/Down data goes directly to the external reduction tree. K/V and Q/GU
  // data goes to the external VPU/SFU through the legacy post_data port.
  assign post_data_valid=(!is_reduce_job)&&exec_post_data_valid;
  assign post_data=exec_post_data;
  assign collective_data_valid=is_reduce_job&&exec_post_data_valid;
  assign collective_data=exec_post_data;
  assign exec_post_data_ready=is_reduce_job?collective_data_ready:post_data_ready;

  // O/Down completion is returned by the reduction tree. Other operations
  // use the VPU/SFU post_done port.
  assign post_done_ready=(!is_reduce_job)&&exec_post_done_ready;
  assign collective_done_ready=is_reduce_job&&exec_post_done_ready;
  assign exec_post_done_valid=is_reduce_job?collective_done_valid:post_done_valid;
  assign exec_post_done=is_reduce_job?collective_done:post_done;

  // For K/V, the result is simultaneously consumed by the concat boundary
  // and by the projection adapter. Backpressure is shared, so no result is
  // lost when the concat unit stalls.
  assign collective_result_valid=is_kv_job&&post_result_valid;
  assign collective_result=post_result;
  assign exec_post_result_valid=post_result_valid&&(!is_kv_job||collective_result_ready);
  assign post_result_ready=is_kv_job?(collective_result_ready&&exec_post_result_ready):exec_post_result_ready;

  always_comb begin
    done='0;
    done.job=job_q;
    done.status=CONTROL_CHILD_ERROR;
    case(legacy_done.status)
      JOB_OK:done.status=CONTROL_OK;
      JOB_UNSUPPORTED:done.status=CONTROL_UNSUPPORTED;
      JOB_PROTOCOL_ERROR:done.status=CONTROL_CONTEXT_ERROR;
      default:done.status=CONTROL_CHILD_ERROR;
    endcase
    if(control_stream_error) done.status=CONTROL_STREAM_ERROR;
  end
  assign done_valid=legacy_done_valid;

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      job_q<='0;
      control_stream_error<=1'b0;
    end else begin
      if(job_valid&&job_ready) job_q<=job;
      // K/V results cross two independent boundaries. Check the context at
      // the forwarding point so a stale VPU result cannot reach concat.
      if(is_kv_job&&post_result_valid&&post_result_ready&&
         post_result.header!=job_q.header)
        control_stream_error<=1'b1;
    end
  end

  dea8_pcore_exec_v3 #(.PAIRED_Q_POST(PAIRED_Q_POST)) exec(
    .clk,.reset,.clear,
    .job_valid,.job_ready(legacy_job_ready),.job(legacy_job),
    .job_done_valid(legacy_done_valid),.job_done_ready(legacy_done_ready),.job_done(legacy_done),
    .busy(legacy_busy),.protocol_error(legacy_error),.active_adapter(legacy_owner),
    .xbc_valid,.xbc_ready,.xbc_entry,
    .hbm_valid,.hbm_ready,.hbm_entry,
    .kv_valid,.kv_ready,.kv_entry,
    .post_valid(exec_post_valid),.post_ready(exec_post_ready),.post_job(exec_post_job),
    .post_done_valid(exec_post_done_valid),.post_done_ready(exec_post_done_ready),.post_done(exec_post_done),
    .post_data_valid(exec_post_data_valid),.post_data_ready(exec_post_data_ready),.post_data(exec_post_data),
    .post_result_valid(exec_post_result_valid),.post_result_ready(exec_post_result_ready),.post_result(post_result),
    .vpu_valid,.vpu_ready,.vpu_cmd,
    .vpu_done_valid,.vpu_done_ready,.vpu_done,
    .sfu_valid,.sfu_ready,.sfu_cmd,
    .sfu_done_valid,.sfu_done_ready,.sfu_done,
    .p_valid,.p_ready,.p_entry,.p_block,.p_epoch,.p_head,
    .acc_rd_valid,.acc_rd_ready,.acc_rd_sel,.acc_rd_addr,
    .acc_data_valid,.acc_even,.acc_odd,
    .acc_wr_valid,.acc_wr_ready,.acc_wr,
    .z_rd_valid,.z_rd_ready,.z_rd_tile,.z_rd_pair,.z_out_valid,.z_out_ready,.z_entry,
    .qoz_complete,.qoz_region,
    .ext_qoz_region_valid,.ext_qoz_region_ready,.ext_qoz_region,
    .ext_qoz_wr_valid,.ext_qoz_wr_ready,.ext_qoz_wr,
    .gu_prefetch_valid,.gu_prefetch_ready,.gu_prefetch_n
  );
endmodule
