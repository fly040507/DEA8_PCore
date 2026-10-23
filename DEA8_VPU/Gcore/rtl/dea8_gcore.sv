module dea8_gcore #(
  parameter bit INTERNAL_RSQRT=1'b1
) (
  input logic clk,reset,
  input logic config_valid,
  output logic config_ready,
  input gcore_pkg::gcore_context_t config_data,
  output logic config_done_valid,
  input logic config_done_ready,
  output gcore_pkg::gcore_status_e config_status,
  input logic preloaded_valid,
  output logic preloaded_ready,
  input gcore_pkg::gcore_preloaded_t preloaded,
  output logic preloaded_done_valid,
  input logic preloaded_done_ready,
  output gcore_pkg::gcore_status_e preloaded_status,
  input logic layer_valid,
  output logic layer_ready,
  input gcore_pkg::gcore_layer_t layer_data,
  output logic layer_done_valid,
  input logic layer_done_ready,
  output gcore_pkg::gcore_status_e layer_status,
  input logic job_valid,
  output logic job_ready,
  input gcore_pkg::gcore_job_t job,
  output logic job_done_valid,
  input logic job_done_ready,
  output gcore_pkg::gcore_job_done_t job_done,
  output logic job_busy,
  output gcore_pkg::gcore_xhat_t xhat_status,
  output logic gamma_fetch_valid,
  input logic gamma_fetch_ready,
  output gcore_pkg::gamma_fetch_t gamma_fetch,
  input logic gamma_data_valid,
  output logic gamma_data_ready,
  input gcore_pkg::gamma_beat_t gamma_data,
  output logic final_valid,
  input logic final_ready,
  output gcore_pkg::gcore_final_t final_data,
  input logic cmd_valid,
  output logic cmd_ready,
  input gcore_pkg::gcore_cmd_t cmd,
  output logic done_valid,
  input logic done_ready,
  output gcore_pkg::gcore_done_t done,
  input logic import_valid,
  output logic import_ready,
  input gcore_pkg::residual_import_t import_data,
  output logic [gcore_pkg::CORES-1:0] xbc_valid,
  input logic [gcore_pkg::CORES-1:0] xbc_ready,
  output pcore_pkg::xbc4_t xbc,
  input logic [gcore_pkg::CORES-1:0] gu_prefetch_valid,
  output logic [gcore_pkg::CORES-1:0] gu_prefetch_ready,
  input logic [gcore_pkg::CORES-1:0][5:0] gu_prefetch_n,
  input logic [gcore_pkg::CORES-1:0] rx_valid,
  output logic [gcore_pkg::CORES-1:0] rx_ready,
  input logic [gcore_pkg::CORES-1:0][255:0] rx_data,
  input logic [gcore_pkg::CORES-1:0] rx_last,
  output logic [gcore_pkg::CORES-1:0] kv_commit_valid,
  input logic [gcore_pkg::CORES-1:0] kv_commit_ready,
  output dea8_tile_link_pkg::tile_commit_t kv_commit [gcore_pkg::CORES],
  output logic [gcore_pkg::CORES-1:0] kv_valid,
  input logic [gcore_pkg::CORES-1:0] kv_ready,
  output pcore_pkg::b2_t kv,
  input logic gamma_load_valid,
  output logic gamma_load_ready,
  input gcore_pkg::gamma_load_t gamma_load,
  output logic gamma_done_valid,
  input logic gamma_done_ready,
  output gcore_pkg::gcore_status_e gamma_status,
  output logic [15:0] gamma_loaded_id,
  output logic rsqrt_valid,
  input logic rsqrt_ready,
  output gcore_pkg::rsqrt_packet_t rsqrt_request,
  input logic rsqrt_out_valid,
  output logic rsqrt_out_ready,
  input gcore_pkg::rsqrt_packet_t rsqrt_response,
  input logic invalidate_valid,
  output logic invalidate_ready,
  input logic [gcore_pkg::OBJECTS-1:0] invalidate_mask,
  input logic kv_release_valid,
  output logic kv_release_ready,
  output logic kv_lease,
  input logic cancel_valid,
  output logic cancel_ready,
  output logic flush_valid,
  input logic external_flush_ack,
  output logic [gcore_pkg::SERVICES-1:0] busy,
  output logic fault
);
  import gcore_pkg::*;
  logic selected_ready,selected_valid,compute_rsqrt_ready;
  logic local_rsqrt_ready,local_rsqrt_valid,local_rsqrt_error;
  rsqrt_packet_t local_rsqrt_response,selected_response;
  // Keep the mixed-language vendor IP beside the pure-SV service hierarchy.
  dea8_gcore_services services (
    .arithmetic_fault(local_rsqrt_error),.rsqrt_ready(selected_ready),
    .rsqrt_out_valid(selected_valid),.rsqrt_out_ready(compute_rsqrt_ready),
    .rsqrt_response(selected_response),.*
  );
  if(INTERNAL_RSQRT)begin:native_rsqrt
    assign selected_ready=local_rsqrt_ready;
    assign selected_valid=local_rsqrt_valid;
    assign selected_response=local_rsqrt_response;
    assign rsqrt_out_ready=0;
    dea8_gcore_rsqrt engine (
      .clk,.reset,.clear(flush_valid),.in_valid(rsqrt_valid),.in_ready(local_rsqrt_ready),
      .request(rsqrt_request),.out_valid(local_rsqrt_valid),.out_ready(compute_rsqrt_ready),
      .response(local_rsqrt_response),.empty(),.protocol_error(local_rsqrt_error)
    );
  end else begin:external_rsqrt
    assign selected_ready=rsqrt_ready;
    assign selected_valid=rsqrt_out_valid;
    assign selected_response=rsqrt_response;
    assign rsqrt_out_ready=compute_rsqrt_ready;
    assign local_rsqrt_ready=0;assign local_rsqrt_valid=0;
    assign local_rsqrt_response='0;assign local_rsqrt_error=0;
  end
endmodule
