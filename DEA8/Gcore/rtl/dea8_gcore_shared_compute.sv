module dea8_gcore_shared_compute (
  input logic clk,reset,clear,invalidate_stats,
  input logic cmd_valid,
  output logic cmd_ready,
  input gcore_pkg::gcore_cmd_t cmd,
  input gcore_pkg::gcore_context_t context_data,
  input logic header_valid,
  output logic header_ready,
  input dea8_tile_link_pkg::tile_header_t header,
  input logic data_valid,
  output logic data_ready,
  input logic [511:0] data,
  input logic last,
  output logic commit_valid,
  input logic commit_ready,
  output dea8_tile_link_pkg::tile_commit_t commit,
  output logic ram_rd_valid,
  input logic ram_rd_ready,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] ram_rd_addr,
  input logic ram_rsp_valid,
  output logic ram_rsp_ready,
  input logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] ram_rsp_addr,
  input logic [255:0] ram_rsp_data,
  output logic ram_wr_valid,
  input logic ram_wr_ready,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] ram_wr_addr,
  output logic [255:0] ram_wr_data,
  output logic activation_valid,
  input logic activation_ready,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] activation_index,
  output logic [135:0] activation_word,
  output logic rsqrt_valid,
  input logic rsqrt_ready,
  output gcore_pkg::rsqrt_packet_t rsqrt_request,
  input logic rsqrt_out_valid,
  output logic rsqrt_out_ready,
  input gcore_pkg::rsqrt_packet_t rsqrt_response,
  output logic done_valid,
  input logic done_ready,
  output gcore_pkg::gcore_done_t done,
  output logic busy,stats_valid,protocol_error
);
  import gcore_pkg::*;
  logic active_q,residual_q,abort_q;
  logic norm_cmd_ready,sink_cmd_ready,norm_done_valid,norm_done_ready,sink_done_valid,sink_done_ready;
  gcore_done_t norm_done,sink_done;
  logic work_valid,work_ready,written_valid,written_ready;
  residual_work_t work;
  residual_commit_t written;
  logic local_clear,error_completion;
  assign busy=active_q||done_valid;
  assign local_clear=clear||abort_q;
  assign cmd_ready=!busy&&!reset&&!clear&&!protocol_error&&norm_cmd_ready &&
    (cmd.opcode!=GC_RESIDUAL_APPLY||sink_cmd_ready);
  assign norm_done_ready=active_q&&norm_done_valid &&
    (norm_done.status!=GC_OK || !residual_q || sink_done_valid);
  assign sink_done_ready=active_q&&sink_done_valid &&
    (sink_done.status!=GC_OK || norm_done_valid);
  assign error_completion=active_q&&((norm_done_valid&&norm_done.status!=GC_OK)||
    (sink_done_valid&&sink_done.status!=GC_OK));
  dea8_gcore_norm norm (
    .clk,.reset,.clear(local_clear),.invalidate_stats,
    .cmd_valid(cmd_valid&&cmd_ready),.cmd_ready(norm_cmd_ready),.cmd,
    .ram_rd_valid,.ram_rd_ready,.ram_rd_addr,.ram_rsp_valid,.ram_rsp_ready,.ram_rsp_addr,.ram_rsp_data,
    .ram_wr_valid,.ram_wr_ready,.ram_wr_addr,.ram_wr_data,
    .activation_valid,.activation_ready,.activation_index,.activation_word,
    .work_valid,.work_ready,.work,.written_valid,.written_ready,.written,
    .rsqrt_valid,.rsqrt_ready,.rsqrt_request,.rsqrt_out_valid,.rsqrt_out_ready,.rsqrt_response,
    .done_valid(norm_done_valid),.done_ready(norm_done_ready),.done(norm_done),.busy(),.stats_valid,.protocol_error
  );
  dea8_gcore_reduce_sink sink (
    .clk,.reset,.clear(local_clear),
    .cmd_valid(cmd_valid&&cmd_ready&&cmd.opcode==GC_RESIDUAL_APPLY),.cmd_ready(sink_cmd_ready),.cmd,.context_data,
    .header_valid,.header_ready,.header,.data_valid,.data_ready,.data,.last,
    .commit_valid,.commit_ready,.commit,.work_valid,.work_ready,.work,
    .written_valid,.written_ready,.written,
    .done_valid(sink_done_valid),.done_ready(sink_done_ready),.done(sink_done),.busy()
  );
  always_ff @(posedge clk) begin
    if(reset||clear) begin active_q<=0; residual_q<=0; done_valid<=0; done<='0; abort_q<=0; end
    else begin
      abort_q<=0;
      if(done_valid&&done_ready) done_valid<=0;
      if(cmd_valid&&cmd_ready) begin active_q<=1; residual_q<=cmd.opcode==GC_RESIDUAL_APPLY; end
      if(active_q&&!done_valid) begin
        if(error_completion) begin
          done<=norm_done_valid&&norm_done.status!=GC_OK?norm_done:sink_done;
          done_valid<=1; active_q<=0; abort_q<=1;
        end else if(norm_done_valid&&(!residual_q||sink_done_valid)) begin
          done<=norm_done; done_valid<=1; active_q<=0;
        end
      end
    end
  end
endmodule
