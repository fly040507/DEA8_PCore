// Fixed-M=51 layer fabric. DEA8's global policy is outside this block; both
// GCore and eight PCores expose their real job/completion interfaces to it.
module dea8_layer_top #(
  parameter int ROPE_POSITION_BASE=816,
  parameter logic [15:0] ROPE_VERSION=1,
  parameter MASK_FILE="Pcore/units/rom/mask.mem",ROPE_FILE="Pcore/units/rom/rope.mem"
)(
  input logic clk,reset,
  input logic [7:0] pc_config_valid,output logic [7:0] pc_config_ready,pc_configured,
  input logic [15:0] pc_config_context,pc_mask_version,pc_rope_version,pc_position,
  input logic [7:0] pc_job_valid,output logic [7:0] pc_job_ready,
  input pcore_control_pkg::control_job_t pc_job[8],
  output logic [7:0] pc_done_valid,input logic [7:0] pc_done_ready,
  output pcore_control_pkg::control_completion_t pc_done[8],
  output logic [7:0] pc_busy,pc_fault,
  input logic [7:0] hbm_valid,output logic [7:0] hbm_ready,input pcore_pkg::b2_t hbm[8],
  input logic gc_config_valid,output logic gc_config_ready,
  input gcore_pkg::gcore_context_t gc_config,
  output logic gc_config_done_valid,input logic gc_config_done_ready,output gcore_pkg::gcore_status_e gc_config_status,
  input logic preloaded_valid,output logic preloaded_ready,input gcore_pkg::gcore_preloaded_t preloaded,
  output logic preloaded_done_valid,input logic preloaded_done_ready,output gcore_pkg::gcore_status_e preloaded_status,
  input logic layer_valid,output logic layer_ready,input gcore_pkg::gcore_layer_t layer_data,
  output logic layer_done_valid,input logic layer_done_ready,output gcore_pkg::gcore_status_e layer_status,
  input logic gc_job_valid,output logic gc_job_ready,input gcore_pkg::gcore_job_t gc_job,
  output logic gc_job_done_valid,input logic gc_job_done_ready,output gcore_pkg::gcore_job_done_t gc_job_done,
  output logic gc_job_busy,output gcore_pkg::gcore_xhat_t xhat_status,
  output logic gamma_fetch_valid,input logic gamma_fetch_ready,output gcore_pkg::gamma_fetch_t gamma_fetch,
  input logic gamma_data_valid,output logic gamma_data_ready,input gcore_pkg::gamma_beat_t gamma_data,
  output logic final_valid,input logic final_ready,output gcore_pkg::gcore_final_t final_data,
  input logic cmd_valid,output logic cmd_ready,input gcore_pkg::gcore_cmd_t cmd,
  output logic done_valid,input logic done_ready,output gcore_pkg::gcore_done_t done,
  input logic import_valid,output logic import_ready,input gcore_pkg::residual_import_t import_data,
  input logic gamma_load_valid,output logic gamma_load_ready,input gcore_pkg::gamma_load_t gamma_load,
  output logic gamma_done_valid,input logic gamma_done_ready,output gcore_pkg::gcore_status_e gamma_status,
  output logic [15:0] gamma_loaded_id,
  input logic invalidate_valid,output logic invalidate_ready,input logic [gcore_pkg::OBJECTS-1:0] invalidate_mask,
  input logic kv_release_valid,output logic kv_release_ready,kv_lease,
  input logic cancel_valid,output logic cancel_ready,cancel_done_valid,input logic cancel_done_ready,
  output logic hbm_flush_valid,input logic hbm_flush_ack,
  output logic [gcore_pkg::SERVICES-1:0] gc_busy,output logic gc_fault
);
  import pcore_pkg::*;import pcore_control_pkg::*;import gcore_pkg::*;import dea8_tile_link_pkg::*;
  logic [7:0] xbc_valid,xbc_ready,kv_valid,kv_ready,tx_valid,tx_ready,tx_last;
  logic [7:0][255:0] tx_data;
  xbc4_t xbc;b2_t kv;
  logic [7:0] kv_commit_valid,kv_commit_ready,gu_prefetch_valid,gu_prefetch_ready;
  tile_commit_t kv_commit[8];logic [7:0][5:0] gu_prefetch_n;
  logic gc_flush,cluster_cancel_ready,cluster_cancel_done,cluster_flush,cluster_fault_event;
  logic [7:0] cluster_fault_mask;
  logic gc_cancel_pending,gc_cancel_ready,gc_fault_seen;
  logic external_ack;
  wire cancel_request=cancel_valid||gc_flush;
  assign cancel_ready=cluster_cancel_ready&&gc_cancel_ready;
  assign cancel_done_valid=cluster_cancel_done;
  assign hbm_flush_valid=cluster_flush||gc_flush;
  assign external_ack=cluster_cancel_done&&hbm_flush_ack;
  // Remember a PCore fault until GCore accepts cancellation. Never acknowledge
  // an external flush by simply wiring GCore's request back to its own ack.
  always_ff @(posedge clk)begin
    if(reset)begin gc_cancel_pending<=0;gc_fault_seen<=0;end
    else begin
      if(!gc_fault)gc_fault_seen<=0;
      if((cancel_valid&&cancel_ready)||cluster_fault_event||(gc_fault&&!gc_fault_seen))gc_cancel_pending<=1;
      if(gc_fault)gc_fault_seen<=1;
      if(gc_cancel_pending&&gc_cancel_ready)gc_cancel_pending<=0;
    end
  end
  dea8_pcore_cluster #(.ROPE_POSITION_BASE(ROPE_POSITION_BASE),.ROPE_VERSION(ROPE_VERSION),
    .MASK_FILE(MASK_FILE),.ROPE_FILE(ROPE_FILE)) cluster(
    .clk,.reset,.clear(1'b0),.config_valid(pc_config_valid),.config_ready(pc_config_ready),.configured(pc_configured),
    .config_context(pc_config_context),.config_mask_version(pc_mask_version),.config_rope_version(pc_rope_version),.config_position(pc_position),
    .job_valid(pc_job_valid),.job_ready(pc_job_ready),.job(pc_job),
    .done_valid(pc_done_valid),.done_ready(pc_done_ready),.done(pc_done),.busy(pc_busy),.core_fault(pc_fault),
    .xbc_valid,.xbc_ready,.xbc,.hbm_valid,.hbm_ready,.hbm,.kv_valid,.kv_ready,.kv,
    .tx_valid,.tx_ready,.tx_data,.tx_last,.kv_commit_valid,.kv_commit_ready,.kv_commit,
    .gu_prefetch_valid,.gu_prefetch_ready,.gu_prefetch_n,
    .cancel_valid(cancel_request),.cancel_ready(cluster_cancel_ready),
    .cancel_done_valid(cluster_cancel_done),.cancel_done_ready(cancel_done_ready&&!gc_flush),
    .external_flush_req(cluster_flush),.external_flush_ack(hbm_flush_ack),
    .fault_event(cluster_fault_event),.fault_mask(cluster_fault_mask));
  dea8_gcore #(.INTERNAL_RSQRT(1)) gcore(
    .clk,.reset,.config_valid(gc_config_valid),.config_ready(gc_config_ready),.config_data(gc_config),
    .config_done_valid(gc_config_done_valid),.config_done_ready(gc_config_done_ready),.config_status(gc_config_status),
    .preloaded_valid,.preloaded_ready,.preloaded,.preloaded_done_valid,.preloaded_done_ready,.preloaded_status,
    .layer_valid,.layer_ready,.layer_data,.layer_done_valid,.layer_done_ready,.layer_status,
    .job_valid(gc_job_valid),.job_ready(gc_job_ready),.job(gc_job),
    .job_done_valid(gc_job_done_valid),.job_done_ready(gc_job_done_ready),.job_done(gc_job_done),.job_busy(gc_job_busy),.xhat_status,
    .gamma_fetch_valid,.gamma_fetch_ready,.gamma_fetch,.gamma_data_valid,.gamma_data_ready,.gamma_data,
    .final_valid,.final_ready,.final_data,.cmd_valid,.cmd_ready,.cmd,.done_valid,.done_ready,.done,
    .import_valid,.import_ready,.import_data,.xbc_valid,.xbc_ready,.xbc,
    .gu_prefetch_valid,.gu_prefetch_ready,.gu_prefetch_n,
    .rx_valid(tx_valid),.rx_ready(tx_ready),.rx_data(tx_data),.rx_last(tx_last),
    .kv_commit_valid,.kv_commit_ready,.kv_commit,.kv_valid,.kv_ready,.kv,
    .gamma_load_valid,.gamma_load_ready,.gamma_load,.gamma_done_valid,.gamma_done_ready,.gamma_status,.gamma_loaded_id,
    .rsqrt_valid(),.rsqrt_ready(1'b0),.rsqrt_request(),.rsqrt_out_valid(1'b0),.rsqrt_out_ready(),.rsqrt_response('0),
    .invalidate_valid,.invalidate_ready,.invalidate_mask,.kv_release_valid,.kv_release_ready,.kv_lease,
    .cancel_valid(gc_cancel_pending),.cancel_ready(gc_cancel_ready),.flush_valid(gc_flush),.external_flush_ack(external_ack),
    .busy(gc_busy),.fault(gc_fault));
endmodule
