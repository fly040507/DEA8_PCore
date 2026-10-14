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
  input logic kv_in_valid,output logic kv_in_ready,input logic [B_BEAT_BITS-1:0] kv_in_data,input b_beat_tag_t kv_in_tag,
  output logic unit_cmd_valid,input logic unit_cmd_ready,output unit_cmd_t unit_cmd,
  input logic unit_armed_valid,output logic unit_armed_ready,input job_token_t unit_armed_token,
  output logic unit_go_valid,input logic unit_go_ready,output job_token_t unit_go_token,
  input logic unit_rd_valid,output logic unit_rd_ready,input pair_read_t unit_rd,
  output logic unit_out_valid,input logic unit_out_ready,output pair_reply_t unit_out_reply,
  input logic unit_wr_valid,output logic unit_wr_ready,input local_write_t unit_wr,
  input logic unit_quant_valid,output logic unit_quant_ready,input kv_quant_t unit_quant,
  input logic local_import_valid,output logic local_import_ready,input local_object_t local_import_object,
  input job_token_t local_import_token,
  input logic local_import_wr_valid,output logic local_import_wr_ready,input local_write_t local_import_wr,
  output logic reduce_hdr_valid,input logic reduce_hdr_ready,output tile_header_t reduce_hdr,
  output logic reduce_out_valid,input logic reduce_out_ready,output logic [TILE*FP_BITS-1:0] reduce_out,
  output logic reduce_out_last,
  output logic kv_hdr_valid,input logic kv_hdr_ready,output tile_header_t kv_hdr,
  output logic kv_out_valid,input logic kv_out_ready,output logic [ROW_BITS-1:0] kv_out,
  output logic kv_out_last,
  input logic kv_commit_valid,output logic kv_commit_ready,input tile_commit_t kv_commit,
  input logic unit_done_valid,output logic unit_done_ready,input job_token_t unit_done_token,
  input unit_function_e unit_done_function,input logic unit_done_error,
  output logic function_cmd_valid,input logic function_cmd_ready,output unit_cmd_t function_cmd,
  input logic function_armed_valid,output logic function_armed_ready,input job_token_t function_armed_token,
  output logic function_go_valid,input logic function_go_ready,output job_token_t function_go_token,
  output logic function_data_valid,input logic function_data_ready,output fp16_stream_t function_data,
  input logic function_result_valid,output logic function_result_ready,input fp16_stream_t function_result,
  input logic function_done_valid,output logic function_done_ready,input job_token_t function_done_token,
  input unit_function_e function_done_function,input logic function_done_error,
  input logic unit_ws_valid,output logic unit_ws_ready,input workspace_req_t unit_ws,
  output logic unit_ws_out_valid,input logic unit_ws_out_ready,output workspace_rsp_t unit_ws_out,
  input logic function_ws_valid,output logic function_ws_ready,input sfu_workspace_req_t function_ws,
  output logic function_ws_out_valid,input logic function_ws_out_ready,output sfu_workspace_rsp_t function_ws_out,
  input logic unit_acc_valid,output logic unit_acc_ready,input unit_acc_read_t unit_acc,
  output logic unit_acc_out_valid,input logic unit_acc_out_ready,output unit_acc_reply_t unit_acc_out,
  input logic unit_acc_wr_valid,output logic unit_acc_wr_ready,input unit_acc_write_t unit_acc_wr,
  input logic function_exp_valid,output logic function_exp_ready,input fp4_stream_t function_exp,
  output logic unit_p_valid,input logic unit_p_ready,output fp4_stream_t unit_p,
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
  operation_profile_t operation;
  local_object_t qoz_object,pbuf_object[0:1],source_object,mem_acquire_object;
  logic is_fp,is_pair,source_bound,source_released,source_match,precondition_ok;
  logic mem_bind_valid,mem_bind_ready,mem_release_valid,mem_release_ready;
  logic local_cmd_valid,local_cmd_ready,local_work_ready,local_loader_error;
  local_load_cmd_t local_cmd;
  logic local_rd_valid,local_rd_ready,local_out_valid,local_out_ready,source_read_closed;
  local_read_t local_rd;local_response_t local_response;
  local_release_t release_request;
  logic fp_capture_ready,fp_done,mem_acquire_valid,mem_acquire_ready,mem_wr_valid,mem_wr_ready,import_allowed;
  logic raw_reduce_hdr_valid,raw_reduce_out_valid;
  job_token_t mem_producer_token;
  local_write_t mem_wr;
  logic is_gu,gu_start_fire,gu_start_ready,gu_matrix_valid,gu_matrix_done_ready,gu_done,gu_error,gu_reserve_valid;
  logic proj_matrix_valid,proj_matrix_done_ready,proj_done;
  compute_job_t proj_work,gu_work;
  capture_desc_t gu_reserve,post_capture_cmd;
  pair_capture_t post_capture;
  logic post_capture_valid,post_capture_cmd_valid,post_data_ready;
  logic raw_function_cmd_valid,raw_function_armed_ready,raw_function_go_valid,raw_function_data_valid,raw_function_result_ready,raw_function_done_ready;
  logic is_attn,attn_start_fire,attn_start_ready,attn_matrix_valid,attn_matrix_done_ready,attn_done,attn_error,attn_launch,attn_work_ready;
  compute_job_t attn_work,matrix_completed;
  logic attn_acquire_valid,attn_acquire_set,attn_bind_valid,attn_bind_set,attn_release_valid,attn_store_valid;
  local_object_t attn_acquire_object,attn_bind_object,mem_bind_object;
  local_release_t attn_release,fp_release;
  local_write_t attn_store;
  logic mem_acquire_set,mem_bind_set,local_source_bound,raw_kv_in_ready;
  local_kind_e local_kind;logic [15:0] local_version;
  logic reader_rd_valid;acc_sel_e reader_rd_sel;logic [9:0] reader_rd_addr;
  logic attn_rd_valid,attn_wr_valid,attn_wr_ready;acc_sel_e attn_rd_sel;logic [9:0] attn_rd_addr;acc_write_t attn_write;
  logic attn_v_cmd_valid,attn_v_armed_ready,attn_v_go_valid,attn_v_done_ready,attn_v_running,attn_quant_ready;
  logic attn_f_cmd_valid,attn_f_armed_ready,attn_f_go_valid,attn_f_done_ready;
  unit_cmd_t attn_v_cmd,attn_f_cmd,attn_v_current,post_v_cmd,post_f_cmd;
  job_token_t attn_v_go_token,attn_f_go_token,post_v_go_token,post_f_go_token,post_active_token;
  logic post_running;
  pair_reply_t post_reply;fp16_stream_t post_function_data;
  logic attn_v_ws_ready,attn_v_ws_out_valid,attn_f_ws_ready,attn_f_ws_out_valid;
  logic attn_acc_ready,attn_acc_out_valid,attn_acc_wr_ready,attn_exp_ready,attn_p_valid;
  logic interface_error;
  assign operation=operation_profile(context_job.op);
  assign is_gu=context_job.op==OP_GU;
  assign is_attn=context_job.op==OP_ATTENTION;
  assign matrix_valid=is_attn?attn_matrix_valid:(is_gu?gu_matrix_valid:proj_matrix_valid);
  assign source_work=is_attn?attn_work:(is_gu?gu_work:proj_work);
  assign scheduler_done=is_attn?attn_done:(is_gu?gu_done:proj_done);
  assign matrix_done_ready=is_attn?attn_matrix_done_ready:(is_gu?gu_matrix_done_ready:proj_matrix_done_ready);
  assign is_fp=context_job.op==OP_O_PROJ||context_job.op==OP_DOWN_PROJ;
  assign is_pair=context_job.op==OP_Q_PROJ||context_job.op==OP_K_PROJ||context_job.op==OP_V_PROJ;
  always_comb begin
    source_object='0;source_object.kind=is_attn?LOCAL_Q:(context_job.op==OP_O_PROJ?LOCAL_O:LOCAL_Z);
    source_object.content_version=context_job.input_version;source_object.data_context=context_job.data_context;
    source_object.profile_id=context_job.profile_id;source_object.profile_version=context_job.profile_version;
    source_object.head=context_job.head;source_object.m_rows=context_rows;
    fp_release='0;fp_release.token=context_token;fp_release.kind=source_object.kind;
    fp_release.content_version=source_object.content_version;
  end
  assign source_match=qoz_active&&qoz_complete&&!qoz_bound&&qoz_object==source_object;
  assign precondition_ok=(context_job.op==OP_Q_PROJ||is_gu)?!qoz_active:((is_fp||is_attn)?source_match:1'b1);
  assign import_allowed=enabled&&!busy&&!job_valid&&!profile_begin_valid&&!profile_wr_valid&&!profile_commit_valid;
  assign local_import_ready=import_allowed&&mem_acquire_ready;
  assign local_import_wr_ready=import_allowed&&mem_wr_ready;
  assign mem_acquire_valid=enabled&&(import_allowed?local_import_valid:(is_attn?attn_acquire_valid:acquire_valid));
  assign mem_acquire_object=import_allowed?local_import_object:(is_attn?attn_acquire_object:acquire_object);
  assign mem_acquire_set=!import_allowed&&is_attn&&attn_acquire_set;
  assign mem_producer_token=import_allowed?local_import_token:context_token;
  assign mem_wr_valid=enabled&&(import_allowed?local_import_wr_valid:(is_attn?attn_store_valid:store_valid));
  assign mem_wr=import_allowed?local_import_wr:(is_attn?attn_store:store_write);
  assign mem_bind_valid=(start_fire&&is_fp)||attn_start_fire||(enabled&&is_attn&&attn_bind_valid);
  assign mem_bind_set=is_attn&&!start_valid[MAT_ATTENTION]&&attn_bind_set;
  assign mem_bind_object=is_attn&&!start_valid[MAT_ATTENTION]?attn_bind_object:source_object;
  assign mem_release_valid=enabled&&(is_attn?attn_release_valid:(is_fp&&source_bound&&!source_released&&scheduler_done&&fp_done));
  assign release_request=is_attn?attn_release:fp_release;
  assign local_kind=is_attn?(source_work.role==ROLE_K?LOCAL_Q:LOCAL_P):source_object.kind;
  assign local_version=is_attn&&source_work.role==ROLE_V?16'(int'(source_work.block_id)+1):context_job.input_version;
  assign local_source_bound=local_cmd.kind!=LOCAL_P||pbuf_bound[local_cmd.set_id];
  assign result_rd_valid=is_attn?attn_rd_valid:reader_rd_valid;
  assign result_rd_sel=is_attn?attn_rd_sel:reader_rd_sel;
  assign result_rd_addr=is_attn?attn_rd_addr:reader_rd_addr;
  assign unit_running=is_attn?attn_v_running:post_running;
  assign active_unit_token=is_attn?attn_v_current.token:post_active_token;
  always_ff @(posedge clk)begin
    if(reset||flush_request)begin source_bound<=0;source_released<=0;end
    else begin
      if(start_fire)begin source_bound<=is_fp;source_released<=0;end
      if(mem_release_valid&&mem_release_ready)begin source_released<=1;source_bound<=0;end
    end
  end
  assign protocol_error=profile_error||matrix_error||scheduler_error||reader_error||post_error||memory_error||
    output_error||gu_error||attn_error||local_loader_error||interface_error||
    (unit_profile_valid&&!profile_access_legal&&!reset&&!clear&&!flush_request)||
    (is_gu&&commit_valid&&commit_meta.final_k&&!post_data_ready);
  assign profile_access_legal=unit_running&&unit_profile_token==active_unit_token&&unit_profile_index<context_rows&&
    (context_job.op==OP_Q_PROJ||context_job.op==OP_K_PROJ||(is_attn&&attn_v_current.function_id==UNIT_QK_POST));
  assign enabled=!reset&&!clear&&!flush_request&&!protocol_error;
  assign unit_profile_ready=enabled&&profile_access_legal&&(context_job.op==OP_K_PROJ?
    (!identity_profile_pending||unit_profile_out_ready):profile_rd_ready);
  assign raw_profile_out_valid=raw_dynamic_profile_valid||identity_profile_pending;
  assign unit_profile_out_index=identity_profile_pending?identity_profile_index:dynamic_profile_index;
  assign unit_profile_original=identity_profile_pending?identity_profile_index:dynamic_profile_original;
  assign unit_profile_out_valid=enabled&&raw_profile_out_valid;
  assign job_ready=control_job_ready&&!profile_begin_valid&&!profile_wr_valid&&!profile_commit_valid;
  assign start_ready={gu_start_ready&&post_start_ready,attn_start_ready&&mem_bind_ready,scheduler_start_ready&&(is_fp?mem_bind_ready:post_start_ready)};
  assign start_fire=enabled&&start_valid[MAT_PROJECTION]&&start_ready[MAT_PROJECTION];
  assign gu_start_fire=enabled&&start_valid[MAT_GU]&&start_ready[MAT_GU];
  assign attn_start_fire=enabled&&start_valid[MAT_ATTENTION]&&start_ready[MAT_ATTENTION];
  assign source_work_valid=enabled&&matrix_valid&&matrix_ready&&(operation.matrix_a==A_XBC||local_work_ready)&&(!is_attn||attn_work_ready);
  assign source_context=context_job;
  assign a_desc_ready=enabled&&raw_a_desc_ready;
  assign a_in_ready=enabled&&raw_a_in_ready;
  assign b_desc_ready=enabled&&raw_b_desc_ready;
  assign hbm_ready={2{enabled}}&raw_hbm_ready;
  assign kv_in_ready=enabled&&is_attn&&raw_kv_in_ready;
  assign acquire_ready=enabled&&!import_allowed&&mem_acquire_ready;
  assign store_ready=enabled&&!import_allowed&&mem_wr_ready;
  assign result_rd_ready=enabled&&raw_res_ready;
  assign capture_ready=enabled&&(is_fp||post_capture_ready)&&reader_cmd_ready;
  assign reader_out_ready=enabled&&(is_fp?fp_capture_ready:raw_reader_out_ready);
  assign unit_cmd_valid=enabled&&(is_attn?attn_v_cmd_valid:raw_cmd_valid);
  assign unit_cmd=is_attn?attn_v_cmd:post_v_cmd;
  assign unit_armed_ready=enabled&&(is_attn?attn_v_armed_ready:raw_armed_ready);
  assign unit_go_valid=enabled&&(is_attn?attn_v_go_valid:raw_go_valid);
  assign unit_go_token=is_attn?attn_v_go_token:post_v_go_token;
  assign unit_rd_ready=enabled&&!is_attn&&raw_unit_rd_ready;
  assign unit_out_valid=enabled&&!is_attn&&raw_unit_out_valid;
  assign unit_out_reply=post_reply;
  assign unit_wr_ready=enabled&&(is_attn?attn_quant_ready:raw_unit_wr_ready);
  assign unit_quant_ready=enabled&&!is_attn&&raw_quant_ready;
  assign unit_done_ready=enabled&&(is_attn?attn_v_done_ready:raw_unit_done_ready);
  assign kv_hdr_valid=enabled&&raw_kv_hdr_valid;
  assign kv_out_valid=enabled&&raw_kv_out_valid;
  assign kv_commit_ready=enabled&&raw_kv_commit_ready;
  assign reduce_hdr_valid=enabled&&raw_reduce_hdr_valid;
  assign reduce_out_valid=enabled&&raw_reduce_out_valid;
  assign function_cmd_valid=enabled&&(is_attn?attn_f_cmd_valid:raw_function_cmd_valid);
  assign function_cmd=is_attn?attn_f_cmd:post_f_cmd;
  assign function_armed_ready=enabled&&(is_attn?attn_f_armed_ready:raw_function_armed_ready);
  assign function_go_valid=enabled&&(is_attn?attn_f_go_valid:raw_function_go_valid);
  assign function_go_token=is_attn?attn_f_go_token:post_f_go_token;
  assign function_data_valid=enabled&&!is_attn&&raw_function_data_valid;
  assign function_data=post_function_data;
  assign function_result_ready=enabled&&!is_attn&&raw_function_result_ready;
  assign function_done_ready=enabled&&(is_attn?attn_f_done_ready:raw_function_done_ready);
  assign unit_ws_ready=enabled&&is_attn&&attn_v_ws_ready;
  assign unit_ws_out_valid=enabled&&is_attn&&attn_v_ws_out_valid;
  assign function_ws_ready=enabled&&is_attn&&attn_f_ws_ready;
  assign function_ws_out_valid=enabled&&is_attn&&attn_f_ws_out_valid;
  assign unit_acc_ready=enabled&&is_attn&&attn_acc_ready;
  assign unit_acc_out_valid=enabled&&is_attn&&attn_acc_out_valid;
  assign unit_acc_wr_ready=enabled&&is_attn&&attn_acc_wr_ready;
  assign function_exp_ready=enabled&&is_attn&&attn_exp_ready;
  assign unit_p_valid=enabled&&is_attn&&attn_p_valid;
  always_ff @(posedge clk)begin
    if(reset||flush_request)interface_error<=0;
    else if(!clear&&unit_profile_valid&&!profile_access_legal)interface_error<=1;
  end
  dea8_pcore_control #(.CORE_ID(CORE_ID)) control(.clk,.reset,.clear,
    .job_valid(job_valid&&job_ready),.job_ready(control_job_ready),.job,
    .profile_valid,.profile_rows,.profile_id,.profile_version,
    .precondition_ok,.implemented_ops(7'b1111111),
    .context_job,.context_token,.context_rows,.start_valid,.start_ready,
    .engine_done(is_attn?attn_done:(is_fp?(scheduler_done&&fp_done&&source_released):(scheduler_done&&post_done))),.engine_token(context_token),.fault(protocol_error),
    .busy,.flush_request,.flush_ack,.completion_valid,.completion_ready,.completion);
  dea8_profile profile(.clk,.reset,.clear(flush_request),.in_use(busy||qoz_active),
    .begin_valid(profile_begin_valid),.begin_ready(profile_begin_ready),.begin_rows(profile_begin_rows),
    .begin_id(profile_begin_id),.begin_version(profile_begin_version),
    .wr_valid(profile_wr_valid),.wr_ready(profile_wr_ready),.wr_index(profile_wr_index),.wr_original(profile_wr_original),
    .commit_valid(profile_commit_valid),.commit_ready(profile_commit_ready),
    .profile_valid,.protocol_error(profile_error),.m_rows(profile_rows),.profile_id,.profile_version,
    .rd_valid(unit_profile_valid&&profile_access_legal&&enabled&&context_job.op!=OP_K_PROJ),.rd_ready(profile_rd_ready),.rd_index(unit_profile_index),
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
    .matrix_valid(proj_matrix_valid),.matrix_ready(!is_gu&&!is_attn&&matrix_ready&&source_work_ready&&enabled&&(operation.matrix_a==A_XBC||local_work_ready)),.matrix_job(proj_work),
    .matrix_done(matrix_done&&!is_gu&&!is_attn),.matrix_done_ready(proj_matrix_done_ready),.capture_valid,.capture_ready,.capture_desc,
    .capture_done,.captured,.done(proj_done),.protocol_error(scheduler_error));
  dea8_gu_scheduler gu_scheduler(.clk,.reset,.clear(flush_request),.start_valid(gu_start_fire),.start_ready(gu_start_ready),
    .context_job,.context_token,.context_rows,.matrix_valid(gu_matrix_valid),
    .matrix_ready(is_gu&&matrix_ready&&source_work_ready&&enabled),.matrix_job(gu_work),
    .matrix_done(matrix_done&&is_gu),.matrix_done_ready(gu_matrix_done_ready),.reserve_valid(gu_reserve_valid),.reserve_desc(gu_reserve),
    .done(gu_done),.protocol_error(gu_error));
  dea8_matrix_frontend matrix(.clk,.reset,.clear(flush_request),
    .gu_capture_ready(!is_gu||post_capture_ready),.launch_allow(!is_attn||attn_launch),.done_work(matrix_completed),
    .job_valid(source_work_valid&&source_work_ready),.job_ready(matrix_ready),.job(source_work),
    .job_b_source(operation.b_source),.job_a_source(operation.matrix_a),.busy(matrix_busy),.done_valid(matrix_done),
    .done_ready(matrix_done_ready),.protocol_error(matrix_error),
    .a_desc_valid(a_desc_valid&&enabled),.a_desc_ready(raw_a_desc_ready),.a_desc,
    .a_in_valid(a_in_valid&&enabled),.a_in_ready(raw_a_in_ready),.a_in,
    .local_cmd_valid(local_cmd_valid&&enabled&&local_source_bound),.local_cmd_ready,.local_cmd,
    .local_rd_valid,.local_rd_ready,.local_rd,.local_out_valid,.local_out_ready,
    .local_out_response(local_response),.source_read_closed,
    .b_desc_valid(b_desc_valid&&enabled),.b_desc_ready(raw_b_desc_ready),.b_desc,
    .hbm_valid(hbm_valid&{2{enabled}}),.hbm_ready(raw_hbm_ready),.hbm_data,.hbm_tag,
    .kv_valid(kv_in_valid&&enabled&&is_attn),.kv_ready(raw_kv_in_ready),.kv_data(kv_in_data),.kv_tag(kv_in_tag),
    .result_rd_valid(result_rd_valid&&enabled),.result_rd_ready(raw_res_ready),.result_rd_sel,.result_rd_addr,.result_rd_data_valid,.result_even_data,.result_odd_data,
    .vpu_wr_valid(attn_wr_valid&&enabled&&is_attn),.vpu_wr_ready(attn_wr_ready),.vpu_wr(attn_write),
    .issue_valid,.issue_meta,.psum_valid,.psum_rsp,.commit_valid,.commit_meta,
    .commit_write_valid(),.commit_write);
  dea8_result_reader reader(.clk,.reset,.clear(flush_request),
    .cmd_valid(capture_valid&&(is_fp||post_capture_ready)&&enabled),.cmd_ready(reader_cmd_ready),.cmd(capture_desc),
    .rd_valid(reader_rd_valid),.rd_ready(result_rd_ready&&!is_attn),.rd_sel(reader_rd_sel),.rd_addr(reader_rd_addr),
    .response_valid(result_rd_data_valid&&!is_attn),.response_data({result_odd_data,result_even_data}),
    .out_valid(reader_out_valid),.out_ready(reader_out_ready),.out_capture(reader_capture),
    .done(capture_done),.completed(captured),.protocol_error(reader_error));
  assign post_capture_cmd=is_gu?gu_reserve:capture_desc;
  assign post_capture_cmd_valid=enabled&&(is_gu?gu_reserve_valid:(capture_valid&&reader_cmd_ready&&is_pair));
  assign post_capture_valid=enabled&&(is_gu?(commit_valid&&commit_meta.final_k):(reader_out_valid&&is_pair));
  assign raw_reader_out_ready=post_data_ready;
  always_comb begin
    post_capture=reader_capture;
    if(is_gu)begin
      post_capture='0;post_capture.owner.token=commit_meta.token;post_capture.owner.work_seq=commit_meta.work_seq;
      post_capture.owner.sel=commit_meta.acc_sel;post_capture.owner.rows=commit_meta.m_rows;post_capture.owner.nt=commit_meta.nt;
      post_capture.owner.pair_seq=commit_meta.gu_n;post_capture.owner.half=commit_meta.role==ROLE_UP;
      post_capture.pair_idx=commit_meta.pair_idx;post_capture.mask=commit_write.row_valid;post_capture.data=commit_write.data;
    end
  end
  dea8_projection_post post(.clk,.reset,.clear(flush_request),
    .start_valid((start_fire&&is_pair)||gu_start_fire),.start_ready(post_start_ready),.context_job,.context_token,.context_rows,
    .capture_cmd_valid(post_capture_cmd_valid),.capture_cmd_ready(post_capture_ready),.capture_cmd(post_capture_cmd),
    .capture_valid(post_capture_valid),.capture_ready(post_data_ready),.capture(post_capture),
    .acquire_valid,.acquire_ready,.acquire_object,.store_valid,.store_ready,.store_write,.store_complete(qoz_complete),
    .unit_cmd_valid(raw_cmd_valid),.unit_cmd_ready(unit_cmd_ready&&enabled&&!is_attn),.unit_cmd(post_v_cmd),
    .unit_armed_valid(unit_armed_valid&&enabled&&!is_attn),.unit_armed_ready(raw_armed_ready),.unit_armed_token,
    .unit_go_valid(raw_go_valid),.unit_go_ready(unit_go_ready&&enabled&&!is_attn),.unit_go_token(post_v_go_token),
    .unit_rd_valid(unit_rd_valid&&enabled&&!is_attn),.unit_rd_ready(raw_unit_rd_ready),.unit_rd,
    .unit_out_valid(raw_unit_out_valid),.unit_out_ready(unit_out_ready&&enabled&&!is_attn),.unit_out_reply(post_reply),
    .unit_wr_valid(unit_wr_valid&&enabled&&!is_attn),.unit_wr_ready(raw_unit_wr_ready),.unit_wr,
    .unit_quant_valid(unit_quant_valid&&enabled&&!is_attn),.unit_quant_ready(raw_quant_ready),.unit_quant,
    .kv_quant_valid,.kv_quant_ready,.kv_quant,.kv_output_done,
    .unit_done_valid(unit_done_valid&&enabled&&!is_attn),.unit_done_ready(raw_unit_done_ready),.unit_done_token,.unit_done_function,.unit_done_error,
    .function_cmd_valid(raw_function_cmd_valid),.function_cmd_ready(function_cmd_ready&&enabled&&!is_attn),.function_cmd(post_f_cmd),
    .function_armed_valid(function_armed_valid&&enabled&&!is_attn),.function_armed_ready(raw_function_armed_ready),.function_armed_token,
    .function_go_valid(raw_function_go_valid),.function_go_ready(function_go_ready&&enabled&&!is_attn),.function_go_token(post_f_go_token),
    .function_data_valid(raw_function_data_valid),.function_data_ready(function_data_ready&&enabled&&!is_attn),.function_data(post_function_data),
    .function_result_valid(function_result_valid&&enabled&&!is_attn),.function_result_ready(raw_function_result_ready),.function_result,
    .function_done_valid(function_done_valid&&enabled&&!is_attn),.function_done_ready(raw_function_done_ready),.function_done_token,.function_done_function,.function_done_error,
    .profile_pending(raw_profile_out_valid),.unit_running(post_running),.active_unit_token(post_active_token),.done(post_done),.protocol_error(post_error));
  dea8_pcore_output output_stage(.clk,.reset,.clear(flush_request),
    .start_valid(start_fire&&context_job.op!=OP_Q_PROJ),.context_job,.context_token,
    .context_rows,.capture_valid(reader_out_valid&&enabled&&is_fp),.capture_ready(fp_capture_ready),.capture(reader_capture),
    .reduce_hdr_valid(raw_reduce_hdr_valid),.reduce_hdr_ready(reduce_hdr_ready&&enabled),.reduce_hdr,
    .reduce_out_valid(raw_reduce_out_valid),.reduce_out_ready(reduce_out_ready&&enabled),.reduce_out,.reduce_out_last,.fp_done,
    .quant_valid(kv_quant_valid&&enabled),.quant_ready(kv_quant_ready),.quant(kv_quant),
    .kv_hdr_valid(raw_kv_hdr_valid),.kv_hdr_ready(kv_hdr_ready&&enabled),.kv_hdr,
    .kv_out_valid(raw_kv_out_valid),.kv_out_ready(kv_out_ready&&enabled),.kv_out,.kv_out_last,
    .kv_commit_valid(kv_commit_valid&&enabled),.kv_commit_ready(raw_kv_commit_ready),.kv_commit,
    .done(kv_output_done),.protocol_error(output_error));
  dea8_local_memory memory(.clk,.reset,.clear(flush_request),
    .acquire_valid(mem_acquire_valid),.acquire_ready(mem_acquire_ready),.acquire_set(mem_acquire_set),.acquire_object(mem_acquire_object),.producer_token(mem_producer_token),
    .bind_valid(mem_bind_valid),.bind_ready(mem_bind_ready),.bind_set(mem_bind_set),.bind_object(mem_bind_object),.consumer_token(context_token),
    .release_valid(mem_release_valid),.release_ready(mem_release_ready),.release_request,
    .wr_valid(mem_wr_valid),.wr_ready(mem_wr_ready),.wr(mem_wr),
    .rd_valid(local_rd_valid&&enabled),.rd_ready(local_rd_ready),.rd(local_rd),.out_valid(local_out_valid),.out_ready(local_out_ready&&enabled),.out_response(local_response),
    .qoz_active,.qoz_complete,.qoz_bound,.qoz_object,.pbuf_active,.pbuf_complete,.pbuf_bound,.pbuf_object,.protocol_error(memory_error),.empty(memory_empty));
  dea8_local_job_loader local_jobs(.clk,.reset,.clear(flush_request),
    .work_valid(source_work_valid&&source_work_ready&&operation.matrix_a==A_LOCAL),.work_ready(local_work_ready),.work(source_work),
    .kind(local_kind),.content_version(local_version),.cmd_valid(local_cmd_valid),.cmd_ready(local_cmd_ready&&local_source_bound),.cmd(local_cmd),
    .protocol_error(local_loader_error));
  dea8_attention_engine attention(.clk,.reset,.clear(flush_request),.start_valid(attn_start_fire),.start_ready(attn_start_ready),
    .context_job,.context_token,.rows(context_rows),.matrix_valid(attn_matrix_valid),
    .matrix_ready(is_attn&&source_work_valid&&source_work_ready),.matrix_job(attn_work),
    .matrix_done(matrix_done&&is_attn),.matrix_done_ready(attn_matrix_done_ready),.matrix_completed,
    .issue_valid(issue_valid&&is_attn),.issue_meta,.launch_allow(attn_launch),
    .qoz_active,.qoz_complete,.qoz_object,.pbuf_active,.pbuf_complete,.pbuf_bound,.pbuf_object,
    .work_ready(attn_work_ready),.work_accepted(is_attn&&source_work_valid&&source_work_ready),
    .acquire_valid(attn_acquire_valid),.acquire_ready(mem_acquire_ready&&enabled&&is_attn&&!import_allowed),
    .acquire_set(attn_acquire_set),.acquire_object(attn_acquire_object),
    .bind_valid(attn_bind_valid),.bind_ready(mem_bind_ready&&enabled&&is_attn&&!attn_start_fire),
    .bind_set(attn_bind_set),.bind_object(attn_bind_object),
    .release_valid(attn_release_valid),.release_ready(mem_release_ready&&enabled&&is_attn),.release_request(attn_release),
    .store_valid(attn_store_valid),.store_ready(mem_wr_ready&&enabled&&is_attn&&!import_allowed),.store(attn_store),
    .v_cmd_valid(attn_v_cmd_valid),.v_cmd_ready(unit_cmd_ready&&enabled&&is_attn),.v_cmd(attn_v_cmd),
    .v_armed_valid(unit_armed_valid&&enabled&&is_attn),.v_armed_ready(attn_v_armed_ready),.v_armed_token(unit_armed_token),
    .v_go_valid(attn_v_go_valid),.v_go_ready(unit_go_ready&&enabled&&is_attn),.v_go_token(attn_v_go_token),
    .v_done_valid(unit_done_valid&&enabled&&is_attn),.v_done_ready(attn_v_done_ready),.v_done_token(unit_done_token),.v_done_function(unit_done_function),.v_done_error(unit_done_error),
    .f_cmd_valid(attn_f_cmd_valid),.f_cmd_ready(function_cmd_ready&&enabled&&is_attn),.f_cmd(attn_f_cmd),
    .f_armed_valid(function_armed_valid&&enabled&&is_attn),.f_armed_ready(attn_f_armed_ready),.f_armed_token(function_armed_token),
    .f_go_valid(attn_f_go_valid),.f_go_ready(function_go_ready&&enabled&&is_attn),.f_go_token(attn_f_go_token),
    .f_done_valid(function_done_valid&&enabled&&is_attn),.f_done_ready(attn_f_done_ready),.f_done_token(function_done_token),.f_done_function(function_done_function),.f_done_error(function_done_error),
    .v_ws_valid(unit_ws_valid&&enabled&&is_attn),.v_ws_ready(attn_v_ws_ready),.v_ws(unit_ws),.v_ws_out_valid(attn_v_ws_out_valid),.v_ws_out_ready(unit_ws_out_ready&&enabled&&is_attn),.v_ws_out(unit_ws_out),
    .f_ws_valid(function_ws_valid&&enabled&&is_attn),.f_ws_ready(attn_f_ws_ready),.f_ws(function_ws),.f_ws_out_valid(attn_f_ws_out_valid),.f_ws_out_ready(function_ws_out_ready&&enabled&&is_attn),.f_ws_out(function_ws_out),
    .acc_req_valid(unit_acc_valid&&enabled&&is_attn),.acc_req_ready(attn_acc_ready),.acc_req(unit_acc),.acc_out_valid(attn_acc_out_valid),.acc_out_ready(unit_acc_out_ready&&enabled&&is_attn),.acc_out(unit_acc_out),
    .acc_write_valid(unit_acc_wr_valid&&enabled&&is_attn),.acc_write_ready(attn_acc_wr_ready),.acc_write(unit_acc_wr),
    .raw_rd_valid(attn_rd_valid),.raw_rd_ready(result_rd_ready&&is_attn),.raw_rd_sel(attn_rd_sel),.raw_rd_addr(attn_rd_addr),
    .raw_out_valid(result_rd_data_valid&&is_attn),.raw_data({result_odd_data,result_even_data}),
    .raw_wr_valid(attn_wr_valid),.raw_wr_ready(attn_wr_ready&&is_attn),.raw_write(attn_write),
    .exp_valid(function_exp_valid&&enabled&&is_attn),.exp_ready(attn_exp_ready),.exp(function_exp),.p_valid(attn_p_valid),.p_ready(unit_p_ready&&enabled&&is_attn),.p(unit_p),
    .quant_valid(unit_wr_valid&&enabled&&is_attn),.quant_ready(attn_quant_ready),.quant(unit_wr),
    .v_running(attn_v_running),.v_current(attn_v_current),.done(attn_done),.protocol_error(attn_error),.slot_cycles(),.matrix_started(),.matrix_retired());
endmodule
