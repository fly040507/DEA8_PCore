import pcore_pkg::*;
import dea8_tile_link_pkg::*;

// Structural top: one external-job FSM, one shared projection datapath.
module pcore_top #(parameter logic [2:0] CORE_ID=3'd0) (
  input logic clk,reset,clear,
  input logic job_valid,output logic job_ready,input pcore_job_t job,
  output logic completion_valid,input logic completion_ready,output pcore_completion_t completion,
  output logic busy,flush_request,input logic [2:0] flush_ack,
  input logic profile_begin_valid,output logic profile_begin_ready,
  input logic [ROW_COUNT_BITS-1:0] profile_begin_rows,
  input logic [15:0] profile_begin_id,profile_begin_version,
  input logic profile_wr_valid,output logic profile_wr_ready,
  input logic [ROW_COUNT_BITS-1:0] profile_wr_index,profile_wr_original,
  input logic profile_commit_valid,output logic profile_commit_ready,
  input logic unit_profile_valid,output logic unit_profile_ready,input job_token_t unit_profile_token,
  input logic [ROW_COUNT_BITS-1:0] unit_profile_index,
  output logic unit_profile_out_valid,input logic unit_profile_out_ready,
  output logic [ROW_COUNT_BITS-1:0] unit_profile_out_index,unit_profile_original,
  output logic source_work_valid,input logic source_work_ready,output compute_job_t source_work,
  output pcore_job_t source_context,
  input logic a_desc_valid,output logic a_desc_ready,input a_slot_desc_t a_desc,
  input logic a_in_valid,output logic a_in_ready,input a3_beat_t a_in,
  input logic b_desc_valid,output logic b_desc_ready,input b_packet_desc_t b_desc,
  input logic [1:0] hbm_valid,output logic [1:0] hbm_ready,
  input logic [1:0][B_BEAT_BITS/2-1:0] hbm_data,input b_beat_tag_t hbm_tag[0:1],
  output logic unit_cmd_valid,input logic unit_cmd_ready,output unit_cmd_t unit_cmd,
  input logic unit_armed_valid,output logic unit_armed_ready,input job_token_t unit_armed_token,
  output logic unit_go_valid,input logic unit_go_ready,output job_token_t unit_go_token,
  input logic unit_rd_valid,output logic unit_rd_ready,input pair_read_t unit_rd,
  output logic unit_out_valid,input logic unit_out_ready,output pair_reply_t unit_out_reply,
  input logic unit_wr_valid,output logic unit_wr_ready,input local_write_t unit_wr,
  input logic unit_quant_valid,output logic unit_quant_ready,input kv_quant_t unit_quant,
  output logic kv_hdr_valid,input logic kv_hdr_ready,output tile_header_t kv_hdr,
  output logic kv_out_valid,input logic kv_out_ready,output logic [ROW_BITS-1:0] kv_out,
  output logic kv_out_last,
  input logic kv_commit_valid,output logic kv_commit_ready,input tile_commit_t kv_commit,
  input logic unit_done_valid,output logic unit_done_ready,input job_token_t unit_done_token,
  input unit_function_e unit_done_function,input logic unit_done_error,
  output logic protocol_error,qoz_complete,
  output logic issue_valid,psum_valid,commit_valid,output pair_meta_t issue_meta,commit_meta,
  output mxu_rsp_t psum_rsp,output acc_write_t commit_write
);
  pcore_job_t context_job;job_token_t context_token,active_unit_token;
  logic [ROW_COUNT_BITS-1:0] context_rows,profile_rows;
  logic [15:0] profile_id,profile_version;
  logic profile_valid,profile_error,profile_rd_ready,raw_profile_out_valid;
  logic [2:0] start_valid,start_ready;
  logic scheduler_start_ready,post_start_ready,start_fire;
  logic matrix_valid,matrix_ready,matrix_done,matrix_done_ready,matrix_busy,matrix_error;
  logic capture_valid,capture_ready,capture_done,post_capture_ready,reader_cmd_ready;
  capture_desc_t capture_desc,captured;
  logic reader_out_valid,reader_out_ready,reader_error;
  pair_capture_t reader_capture;
  logic result_rd_valid,result_rd_ready,result_rd_data_valid;
  acc_sel_e result_rd_sel;logic [9:0] result_rd_addr;
  logic [15:0][31:0] result_even_data,result_odd_data;
  logic scheduler_done,scheduler_error,post_done,post_error,unit_running;
  logic acquire_valid,acquire_ready,store_valid,store_ready,memory_error,memory_empty,qoz_active,qoz_bound;
  logic [1:0] pbuf_active,pbuf_complete,pbuf_bound;
  local_object_t acquire_object;local_write_t store_write;
  logic control_job_ready,profile_access_legal;
  logic enabled;
  logic raw_a_desc_ready,raw_a_in_ready,raw_b_desc_ready;
  logic [1:0] raw_hbm_ready;
  logic raw_acquire_ready,raw_store_ready,raw_res_ready,raw_reader_out_ready;
  logic raw_cmd_valid,raw_armed_ready,raw_go_valid,raw_unit_rd_ready,raw_unit_out_valid;
  logic raw_unit_wr_ready,raw_unit_done_ready;
  logic raw_quant_ready,kv_quant_valid,kv_quant_ready,kv_output_done,output_error;
  logic identity_profile_pending,raw_dynamic_profile_valid;
  logic [ROW_COUNT_BITS-1:0] identity_profile_index,dynamic_profile_index,dynamic_profile_original;
  kv_quant_t kv_quant;
  logic raw_kv_hdr_valid,raw_kv_out_valid,raw_kv_commit_ready;
  assign protocol_error=profile_error||matrix_error||scheduler_error||reader_error||post_error||memory_error||
    output_error||(unit_profile_valid&&!profile_access_legal);
  assign profile_access_legal=unit_running&&unit_profile_token==active_unit_token&&unit_profile_index<context_rows&&
    (context_job.op==OP_Q_PROJ||context_job.op==OP_K_PROJ);
  assign enabled=!reset&&!clear&&!flush_request&&!protocol_error;
  assign unit_profile_ready=enabled&&profile_access_legal&&(context_job.op==OP_K_PROJ?
    (!identity_profile_pending||unit_profile_out_ready):profile_rd_ready);
  assign raw_profile_out_valid=raw_dynamic_profile_valid||identity_profile_pending;
  assign unit_profile_out_index=identity_profile_pending?identity_profile_index:dynamic_profile_index;
  assign unit_profile_original=identity_profile_pending?identity_profile_index:dynamic_profile_original;
  assign unit_profile_out_valid=enabled&&raw_profile_out_valid;
  assign job_ready=control_job_ready&&!profile_begin_valid&&!profile_wr_valid&&!profile_commit_valid;
  assign start_ready={2'b00,scheduler_start_ready&&post_start_ready};
  assign start_fire=enabled&&start_valid[MAT_PROJECTION]&&start_ready[MAT_PROJECTION];
  assign source_work_valid=enabled&&matrix_valid&&matrix_ready;
  assign source_context=context_job;
  assign a_desc_ready=enabled&&raw_a_desc_ready;
  assign a_in_ready=enabled&&raw_a_in_ready;
  assign b_desc_ready=enabled&&raw_b_desc_ready;
  assign hbm_ready={2{enabled}}&raw_hbm_ready;
  assign acquire_ready=enabled&&raw_acquire_ready;
  assign store_ready=enabled&&raw_store_ready;
  assign result_rd_ready=enabled&&raw_res_ready;
  assign reader_out_ready=enabled&&raw_reader_out_ready;
  assign capture_ready=enabled&&post_capture_ready&&reader_cmd_ready;
  assign unit_cmd_valid=enabled&&raw_cmd_valid;
  assign unit_armed_ready=enabled&&raw_armed_ready;
  assign unit_go_valid=enabled&&raw_go_valid;
  assign unit_rd_ready=enabled&&raw_unit_rd_ready;
  assign unit_out_valid=enabled&&raw_unit_out_valid;
  assign unit_wr_ready=enabled&&raw_unit_wr_ready;
  assign unit_quant_ready=enabled&&raw_quant_ready;
  assign unit_done_ready=enabled&&raw_unit_done_ready;
  assign kv_hdr_valid=enabled&&raw_kv_hdr_valid;
  assign kv_out_valid=enabled&&raw_kv_out_valid;
  assign kv_commit_ready=enabled&&raw_kv_commit_ready;
  dea8_pcore_control #(.CORE_ID(CORE_ID)) control(.clk,.reset,.clear,
    .job_valid(job_valid&&job_ready),.job_ready(control_job_ready),.job,
    .profile_valid,.profile_rows,.profile_id,.profile_version,
    .precondition_ok(context_job.op==OP_Q_PROJ?!qoz_active:1'b1),.implemented_ops(7'b0000111),
    .context_job,.context_token,.context_rows,.start_valid,.start_ready,
    .engine_done(scheduler_done&&post_done),.engine_token(context_token),.fault(protocol_error),
    .busy,.flush_request,.flush_ack,.completion_valid,.completion_ready,.completion);
  dea8_profile profile(.clk,.reset,.clear(flush_request),.in_use(busy||qoz_active),
    .begin_valid(profile_begin_valid),.begin_ready(profile_begin_ready),.begin_rows(profile_begin_rows),
    .begin_id(profile_begin_id),.begin_version(profile_begin_version),
    .wr_valid(profile_wr_valid),.wr_ready(profile_wr_ready),.wr_index(profile_wr_index),.wr_original(profile_wr_original),
    .commit_valid(profile_commit_valid),.commit_ready(profile_commit_ready),
    .profile_valid,.protocol_error(profile_error),.m_rows(profile_rows),.profile_id,.profile_version,
    .rd_valid(unit_profile_valid&&profile_access_legal&&enabled&&context_job.op==OP_Q_PROJ),.rd_ready(profile_rd_ready),.rd_index(unit_profile_index),
    .out_valid(raw_dynamic_profile_valid),.out_ready(unit_profile_out_ready&&enabled),
    .out_index(dynamic_profile_index),.out_original(dynamic_profile_original));
  always_ff @(posedge clk)begin
    if(reset||flush_request)begin identity_profile_pending<=0;identity_profile_index<=0;end
    else if(enabled)begin
      if(identity_profile_pending&&unit_profile_out_ready)identity_profile_pending<=0;
      if(unit_profile_valid&&unit_profile_ready&&context_job.op==OP_K_PROJ)begin
        identity_profile_pending<=1;identity_profile_index<=unit_profile_index;
      end
    end
  end
  dea8_projection_scheduler scheduler(.clk,.reset,.clear(flush_request),
    .start_valid(start_fire),.start_ready(scheduler_start_ready),.context_job,.context_token,.context_rows,
    .matrix_valid,.matrix_ready(matrix_ready&&source_work_ready&&enabled),.matrix_job(source_work),
    .matrix_done,.matrix_done_ready,.capture_valid,.capture_ready,.capture_desc,
    .capture_done,.captured,.done(scheduler_done),.protocol_error(scheduler_error));
  dea8_matrix_frontend matrix(.clk,.reset,.clear(flush_request),
    .job_valid(source_work_valid&&source_work_ready),.job_ready(matrix_ready),.job(source_work),
    .job_b_source(B_HBM),.job_a_source(A_XBC),.busy(matrix_busy),.done_valid(matrix_done),
    .done_ready(matrix_done_ready),.protocol_error(matrix_error),
    .a_desc_valid(a_desc_valid&&enabled),.a_desc_ready(raw_a_desc_ready),.a_desc,
    .a_in_valid(a_in_valid&&enabled),.a_in_ready(raw_a_in_ready),.a_in,
    .local_cmd_valid(1'b0),.local_cmd_ready(),.local_cmd(local_load_cmd_t'('0)),
    .local_rd_valid(),.local_rd_ready(1'b0),.local_rd(),.local_out_valid(1'b0),.local_out_ready(),
    .local_out_response(local_response_t'('0)),.source_read_closed(),
    .b_desc_valid(b_desc_valid&&enabled),.b_desc_ready(raw_b_desc_ready),.b_desc,
    .hbm_valid(hbm_valid&{2{enabled}}),.hbm_ready(raw_hbm_ready),.hbm_data,.hbm_tag,
    .kv_valid(1'b0),.kv_ready(),.kv_data(B_BEAT_BITS'('0)),.kv_tag(b_beat_tag_t'('0)),
    .result_rd_valid(result_rd_valid&&enabled),.result_rd_ready(raw_res_ready),.result_rd_sel,.result_rd_addr,.result_rd_data_valid,.result_even_data,.result_odd_data,
    .vpu_wr_valid(1'b0),.vpu_wr_ready(),.vpu_wr(acc_write_t'('0)),
    .issue_valid,.issue_meta,.psum_valid,.psum_rsp,.commit_valid,.commit_meta,
    .commit_write_valid(),.commit_write);
  dea8_result_reader reader(.clk,.reset,.clear(flush_request),
    .cmd_valid(capture_valid&&post_capture_ready&&enabled),.cmd_ready(reader_cmd_ready),.cmd(capture_desc),
    .rd_valid(result_rd_valid),.rd_ready(result_rd_ready),.rd_sel(result_rd_sel),.rd_addr(result_rd_addr),
    .response_valid(result_rd_data_valid),.response_data({result_odd_data,result_even_data}),
    .out_valid(reader_out_valid),.out_ready(reader_out_ready),.out_capture(reader_capture),
    .done(capture_done),.completed(captured),.protocol_error(reader_error));
  dea8_projection_post post(.clk,.reset,.clear(flush_request),
    .start_valid(start_fire),.start_ready(post_start_ready),.context_job,.context_token,.context_rows,
    .capture_cmd_valid(capture_valid&&reader_cmd_ready&&enabled),.capture_cmd_ready(post_capture_ready),.capture_cmd(capture_desc),
    .capture_valid(reader_out_valid&&enabled),.capture_ready(raw_reader_out_ready),.capture(reader_capture),
    .acquire_valid,.acquire_ready,.acquire_object,.store_valid,.store_ready,.store_write,.store_complete(qoz_complete),
    .unit_cmd_valid(raw_cmd_valid),.unit_cmd_ready(unit_cmd_ready&&enabled),.unit_cmd,
    .unit_armed_valid(unit_armed_valid&&enabled),.unit_armed_ready(raw_armed_ready),.unit_armed_token,
    .unit_go_valid(raw_go_valid),.unit_go_ready(unit_go_ready&&enabled),.unit_go_token,
    .unit_rd_valid(unit_rd_valid&&enabled),.unit_rd_ready(raw_unit_rd_ready),.unit_rd,
    .unit_out_valid(raw_unit_out_valid),.unit_out_ready(unit_out_ready&&enabled),.unit_out_reply,
    .unit_wr_valid(unit_wr_valid&&enabled),.unit_wr_ready(raw_unit_wr_ready),.unit_wr,
    .unit_quant_valid(unit_quant_valid&&enabled),.unit_quant_ready(raw_quant_ready),.unit_quant,
    .kv_quant_valid,.kv_quant_ready,.kv_quant,.kv_output_done,
    .unit_done_valid(unit_done_valid&&enabled),.unit_done_ready(raw_unit_done_ready),.unit_done_token,.unit_done_function,.unit_done_error,
    .profile_pending(raw_profile_out_valid),.unit_running,.active_unit_token,.done(post_done),.protocol_error(post_error));
  dea8_pcore_output output_stage(.clk,.reset,.clear(flush_request),
    .start_valid(start_fire&&context_job.op!=OP_Q_PROJ),.context_job,.context_token,
    .quant_valid(kv_quant_valid&&enabled),.quant_ready(kv_quant_ready),.quant(kv_quant),
    .kv_hdr_valid(raw_kv_hdr_valid),.kv_hdr_ready(kv_hdr_ready&&enabled),.kv_hdr,
    .kv_out_valid(raw_kv_out_valid),.kv_out_ready(kv_out_ready&&enabled),.kv_out,.kv_out_last,
    .kv_commit_valid(kv_commit_valid&&enabled),.kv_commit_ready(raw_kv_commit_ready),.kv_commit,
    .done(kv_output_done),.protocol_error(output_error));
  dea8_local_memory memory(.clk,.reset,.clear(flush_request),
    .acquire_valid(acquire_valid&&enabled),.acquire_ready(raw_acquire_ready),.acquire_set(1'b0),.acquire_object,.producer_token(context_token),
    .bind_valid(1'b0),.bind_ready(),.bind_set(1'b0),.bind_object(local_object_t'('0)),.consumer_token(TOKEN_BITS'('0)),
    .release_valid(1'b0),.release_ready(),.release_request(local_release_t'('0)),
    .wr_valid(store_valid&&enabled),.wr_ready(raw_store_ready),.wr(store_write),
    .rd_valid(1'b0),.rd_ready(),.rd(local_read_t'('0)),.out_valid(),.out_ready(1'b0),.out_response(),
    .qoz_active,.qoz_complete,.qoz_bound,.pbuf_active,.pbuf_complete,.pbuf_bound,.protocol_error(memory_error),.empty(memory_empty));
endmodule
