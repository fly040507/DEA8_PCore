import pcore_pkg::*;

// Attention mode owner: normalized matrix jobs, unit contracts and memory
// lifetimes. It contains no SFU/VPU arithmetic and no extra ACC/QOZ/P copies.
module dea8_attention_engine (
  input logic clk,reset,clear,start_valid,output logic start_ready,
  input pcore_job_t context_job,input job_token_t context_token,input logic [ROW_COUNT_BITS-1:0] rows,
  output logic matrix_valid,input logic matrix_ready,output compute_job_t matrix_job,
  input logic matrix_done,output logic matrix_done_ready,input compute_job_t matrix_completed,
  input logic issue_valid,input pair_meta_t issue_meta,output logic launch_allow,
  input logic qoz_active,qoz_complete,input local_object_t qoz_object,
  input logic [1:0] pbuf_active,pbuf_complete,pbuf_bound,input local_object_t pbuf_object[0:1],
  output logic work_ready,input logic work_accepted,
  output logic acquire_valid,input logic acquire_ready,output logic acquire_set,output local_object_t acquire_object,
  output logic bind_valid,input logic bind_ready,output logic bind_set,output local_object_t bind_object,
  output logic release_valid,input logic release_ready,output local_release_t release_request,
  output logic store_valid,input logic store_ready,output local_write_t store,
  output logic v_cmd_valid,input logic v_cmd_ready,output unit_cmd_t v_cmd,
  input logic v_armed_valid,output logic v_armed_ready,input job_token_t v_armed_token,
  output logic v_go_valid,input logic v_go_ready,output job_token_t v_go_token,
  input logic v_done_valid,output logic v_done_ready,input job_token_t v_done_token,input unit_function_e v_done_function,input logic v_done_error,
  output logic f_cmd_valid,input logic f_cmd_ready,output unit_cmd_t f_cmd,
  input logic f_armed_valid,output logic f_armed_ready,input job_token_t f_armed_token,
  output logic f_go_valid,input logic f_go_ready,output job_token_t f_go_token,
  input logic f_done_valid,output logic f_done_ready,input job_token_t f_done_token,input unit_function_e f_done_function,input logic f_done_error,
  input logic v_ws_valid,output logic v_ws_ready,input workspace_req_t v_ws,
  output logic v_ws_out_valid,input logic v_ws_out_ready,output workspace_rsp_t v_ws_out,
  input logic f_ws_valid,output logic f_ws_ready,input sfu_workspace_req_t f_ws,
  output logic f_ws_out_valid,input logic f_ws_out_ready,output sfu_workspace_rsp_t f_ws_out,
  input logic acc_req_valid,output logic acc_req_ready,input unit_acc_read_t acc_req,
  output logic acc_out_valid,input logic acc_out_ready,output unit_acc_reply_t acc_out,
  input logic acc_write_valid,output logic acc_write_ready,input unit_acc_write_t acc_write,
  output logic raw_rd_valid,input logic raw_rd_ready,output acc_sel_e raw_rd_sel,output logic [9:0] raw_rd_addr,
  input logic raw_out_valid,input logic [1:0][15:0][31:0] raw_data,
  output logic raw_wr_valid,input logic raw_wr_ready,output acc_write_t raw_write,
  input logic exp_valid,output logic exp_ready,input fp4_stream_t exp,
  output logic p_valid,input logic p_ready,output fp4_stream_t p,
  input logic quant_valid,output logic quant_ready,input local_write_t quant,
  output logic v_running,output unit_cmd_t v_current,
  output logic done,protocol_error,output logic [15:0] slot_cycles,
  output logic [6:0] matrix_started,matrix_retired
);
  logic scheduler_start_ready,v_offer_valid,v_offer_ready,f_offer_valid,f_offer_ready;
  unit_cmd_t v_offer,f_offer,f_current,v_completed,f_completed;
  logic v_active,f_active,f_running,v_grant,f_grant,v_retired,f_retired,units_idle;
  logic p_fence,scale_fence,q_release_request,o_acquire_request,q_released,o_acquired,memory_empty;
  logic [5:0] p_fence_block,scale_fence_block;
  logic scheduler_done,scheduler_error,units_error,memory_error,o_complete;
  assign start_ready=scheduler_start_ready&&units_idle;
  assign o_complete=qoz_active&&qoz_complete&&qoz_object.kind==LOCAL_O&&qoz_object.content_version==context_job.output_version;
  assign done=scheduler_done&&memory_empty&&units_idle;
  assign protocol_error=scheduler_error||units_error||memory_error;
  dea8_attention_scheduler scheduler(.clk,.reset,.clear,.start_valid(start_valid&&start_ready),.start_ready(scheduler_start_ready),
    .context_job,.context_token,.context_rows(rows),.matrix_valid,.matrix_ready,.matrix_job,.matrix_done,.matrix_done_ready,.matrix_completed,
    .issue_valid,.issue_meta,.launch_allow,.launch_meta(issue_meta),
    .v_offer_valid,.v_offer_ready,.v_offer,.f_offer_valid,.f_offer_ready,.f_offer,
    .v_active,.v_running,.f_active,.f_running,.v_current,.f_current,.v_grant,.f_grant,
    .v_retired,.f_retired,.v_completed,.f_completed,.p_fence,.scale_fence,.p_fence_block,.scale_fence_block,
    .q_released,.o_acquired,.o_complete,.units_idle,.q_release_request,.o_acquire_request,
    .done(scheduler_done),.protocol_error(scheduler_error),.slot_cycles,.matrix_started,.matrix_retired);
  dea8_attention_units units(.clk,.reset,.clear,.begin_job(start_valid&&start_ready),.context_job,.context_token,.rows,
    .v_offer_valid,.v_offer_ready,.v_offer,.v_grant,.f_offer_valid,.f_offer_ready,.f_offer,.f_grant,
    .v_cmd_valid,.v_cmd_ready,.v_cmd,.v_armed_valid,.v_armed_ready,.v_armed_token,.v_go_valid,.v_go_ready,.v_go_token,
    .v_done_valid,.v_done_ready,.v_done_token,.v_done_function,.v_done_error,
    .f_cmd_valid,.f_cmd_ready,.f_cmd,.f_armed_valid,.f_armed_ready,.f_armed_token,.f_go_valid,.f_go_ready,.f_go_token,
    .f_done_valid,.f_done_ready,.f_done_token,.f_done_function,.f_done_error,
    .v_ws_valid,.v_ws_ready,.v_ws,.v_ws_out_valid,.v_ws_out_ready,.v_ws_out,
    .f_ws_valid,.f_ws_ready,.f_ws,.f_ws_out_valid,.f_ws_out_ready,.f_ws_out,
    .acc_req_valid,.acc_req_ready,.acc_req,.acc_out_valid,.acc_out_ready,.acc_out,
    .acc_write_valid,.acc_write_ready,.acc_write,.raw_rd_valid,.raw_rd_ready,.raw_rd_sel,.raw_rd_addr,.raw_out_valid,.raw_data,
    .raw_wr_valid,.raw_wr_ready,.raw_write,.exp_valid,.exp_ready,.exp,.p_valid,.p_ready,.p,
    .quant_valid,.quant_ready,.quant,.store_valid,.store_ready,.store,
    .pbuf_active,.pbuf_complete,.pbuf_object,.o_complete,.p_fence,.scale_fence,.p_fence_block,.scale_fence_block,
    .v_active,.v_running,.f_active,.f_running,.v_current,.f_current,.v_retired,.f_retired,.v_completed,.f_completed,
    .idle(units_idle),.protocol_error(units_error));
  dea8_attention_memory memory(.clk,.reset,.clear,.start(start_valid&&start_ready),.context_job,.context_token,.rows,
    .v_offer_valid,.v_offer_ready,.v_offer,.work_valid(work_accepted),.work_ready,.work(matrix_job),
    .matrix_done(matrix_done&&matrix_done_ready),.completed(matrix_completed),.q_release_request,.o_acquire_request,
    .qoz_active,.qoz_complete,.qoz_object,.pbuf_active,.pbuf_complete,.pbuf_bound,.pbuf_object,
    .acquire_valid,.acquire_ready,.acquire_set,.acquire_object,.bind_valid,.bind_ready,.bind_set,.bind_object,
    .release_valid,.release_ready,.release_request,.q_released,.o_acquired,.empty(memory_empty),.protocol_error(memory_error));
endmodule
