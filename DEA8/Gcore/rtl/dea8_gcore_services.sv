module dea8_gcore_services (
  input logic arithmetic_fault,
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
  gcore_context_t active_context;
  logic context_valid,service_clear,clear_local;
  gcore_object_t objects [OBJECTS];
  logic [SERVICES-1:0] service_cmd_valid,service_cmd_ready,service_done_valid,service_done_ready,service_fault,flush_ack;
  gcore_cmd_t service_cmd;
  gcore_done_t service_done [SERVICES];
  logic import_cmd_ready,import_done_valid,import_busy;
  gcore_done_t import_done;
  logic import_wr_valid,import_wr_ready;
  logic [VECTOR_ADDR_BITS-1:0] import_wr_addr;
  logic [255:0] import_wr_data;
  logic compute_cmd_ready,compute_done_valid,compute_done_ready,compute_busy,compute_error,stats_valid;
  gcore_done_t compute_done;
  logic ram_rd_valid,ram_rd_ready,ram_rsp_valid,ram_rsp_ready,ram_wr_valid,ram_wr_ready;
  logic [VECTOR_ADDR_BITS-1:0] ram_rd_addr,ram_rsp_addr,ram_wr_addr;
  logic [255:0] ram_rsp_data,ram_wr_data;
  logic store_wr_valid,store_wr_ready,residual_error,activation_error;
  logic [VECTOR_ADDR_BITS-1:0] store_wr_addr;
  logic [255:0] store_wr_data;
  logic activation_valid,activation_ready;
  logic [VECTOR_ADDR_BITS-1:0] activation_index;
  logic [135:0] activation_word;
  logic xbc_cmd_ready,xbc_done_valid,xbc_busy,xbc_error,xbc_rd_valid,xbc_rd_ready,xbc_rsp_valid,xbc_rsp_ready;
  logic [5:0] xbc_rd_tile;
  logic [3:0] xbc_rd_group;
  pcore_pkg::xbc4_t xbc_rsp;
  gcore_done_t xbc_done;
  logic rx_cmd_ready,rx_done_valid,rx_busy;
  gcore_done_t rx_done;
  logic [CORES-1:0] kv_wr_valid,kv_wr_ready;
  kv_write_t kv_wr [CORES];
  logic kvb_cmd_ready,kvb_done_valid,kvb_busy,kvb_error,kv_rd_valid,kv_rd_ready,kv_rsp_valid,kv_rsp_ready,kv_store_error;
  kv_read_t kv_rd;
  pcore_pkg::b2_t kv_rsp;
  gcore_done_t kvb_done;
  logic prefix_reject_valid;
  gcore_done_t prefix_reject;
  logic compute_rsqrt_ready,local_rsqrt_error;
  logic [CORES-1:0] kv_header_valid,kv_header_ready,kv_data_valid,kv_data_ready,kv_last;
  dea8_tile_link_pkg::tile_header_t kv_header[CORES],fp_header[CORES];
  logic [CORES-1:0][135:0] kv_data;
  logic [CORES-1:0] fp_header_valid,fp_header_ready,fp_valid,fp_ready;
  logic [CORES-1:0][255:0] fp_data;
  logic fp_retire,packet_busy,packet_error,gamma_found,gamma_slot;
  logic [15:0] gamma_lookup_id;
  logic gamma_read_enable,gamma_read_slot;
  logic [GAMMA_INDEX_BITS-1:0] gamma_read_index;
  logic [31:0] gamma_read_data;
  assign rsqrt_out_ready=compute_rsqrt_ready;
  assign local_rsqrt_error=arithmetic_fault;

  assign clear_local=flush_valid||service_clear;
  // All local engines are synchronously reset at the first flush edge. External
  // PCore/external service sources must acknowledge their own drain before reuse.
  assign flush_ack={SERVICES{flush_valid}};
  dea8_gcore_control control (.*);
  always_comb begin
    service_cmd_ready=0; service_done_valid=0; service_fault=0;
    for(int s=0;s<SERVICES;s++) service_done[s]='0;
    service_cmd_ready[S_IMPORT]=import_cmd_ready;
    service_cmd_ready[S_PREFIX]=!prefix_reject_valid;
    service_cmd_ready[S_NORM]=compute_cmd_ready;
    service_cmd_ready[S_RESIDUAL]=compute_cmd_ready;
    service_cmd_ready[S_XBC]=xbc_cmd_ready;
    service_cmd_ready[S_KV_RX]=rx_cmd_ready;
    service_cmd_ready[S_KVB]=kvb_cmd_ready;
    service_done_valid[S_IMPORT]=import_done_valid; service_done[S_IMPORT]=import_done;
    service_done_valid[S_PREFIX]=prefix_reject_valid; service_done[S_PREFIX]=prefix_reject;
    service_done_valid[S_XBC]=xbc_done_valid; service_done[S_XBC]=xbc_done;
    service_done_valid[S_KV_RX]=rx_done_valid; service_done[S_KV_RX]=rx_done;
    service_done_valid[S_KVB]=kvb_done_valid; service_done[S_KVB]=kvb_done;
    if(compute_done.opcode==GC_RESIDUAL_APPLY) begin
      service_done_valid[S_RESIDUAL]=compute_done_valid; service_done[S_RESIDUAL]=compute_done;
      compute_done_ready=service_done_ready[S_RESIDUAL];
    end else begin
      service_done_valid[S_NORM]=compute_done_valid; service_done[S_NORM]=compute_done;
      compute_done_ready=service_done_ready[S_NORM];
    end
    service_fault[S_NORM]=compute_error||residual_error||activation_error||local_rsqrt_error||packet_error;
    service_fault[S_XBC]=xbc_error;
    service_fault[S_KVB]=kvb_error||kv_store_error;
  end
  // This build deliberately has no prefix receive protocol. Retain its opcode
  // only to reject a legacy request explicitly rather than silently hanging.
  always_ff @(posedge clk) begin
    if(reset||clear_local) begin prefix_reject_valid<=0; prefix_reject<='0; end
    else begin
      if(prefix_reject_valid&&service_done_ready[S_PREFIX]) prefix_reject_valid<=0;
      if(service_cmd_valid[S_PREFIX]&&service_cmd_ready[S_PREFIX]) begin
        prefix_reject<=make_done(service_cmd,GC_INVALID_CMD,0); prefix_reject_valid<=1;
      end
    end
  end
  dea8_gcore_residual_import importer (
    .clk,.reset,.clear(clear_local),.cmd_valid(service_cmd_valid[S_IMPORT]),.cmd_ready(import_cmd_ready),.cmd(service_cmd),
    .in_valid(import_valid),.in_ready(import_ready),.in_data(import_data),
    .wr_valid(import_wr_valid),.wr_ready(import_wr_ready),.wr_addr(import_wr_addr),.wr_data(import_wr_data),
    .done_valid(import_done_valid),.done_ready(service_done_ready[S_IMPORT]),.done(import_done),.busy(import_busy)
  );
  dea8_gcore_packet_rx packet_receiver (
    .clk,.reset,.clear(clear_local),.in_valid(rx_valid),.in_ready(rx_ready),.in_data(rx_data),.in_last(rx_last),
    .kv_header_valid,.kv_header_ready,.kv_header,.kv_valid(kv_data_valid),.kv_ready(kv_data_ready),.kv_data,.kv_last,
    .kv_retire(kv_commit_valid&kv_commit_ready),.fp_header_valid,.fp_header_ready,.fp_header,
    .fp_valid,.fp_ready,.fp_data,.fp_retire,.busy(packet_busy),.protocol_error(packet_error)
  );
  dea8_gcore_gamma gamma_store (
    .clk,.reset,.clear(clear_local),
    .allow_load(!compute_busy&&!service_cmd_valid[S_NORM]&&!service_cmd_valid[S_RESIDUAL]&&!flush_valid&&!fault),
    .context_valid,.context_data(active_context),
    .load_valid(gamma_load_valid),.load_ready(gamma_load_ready),.load(gamma_load),
    .done_valid(gamma_done_valid),.done_ready(gamma_done_ready),.status(gamma_status),.loaded_id(gamma_loaded_id),
    .lookup_id(gamma_lookup_id),.found(gamma_found),.slot(gamma_slot),.read_enable(gamma_read_enable),
    .read_slot(gamma_read_slot),.read_index(gamma_read_index),.read_data(gamma_read_data)
  );
  dea8_gcore_compute compute (
    .clk,.reset,.clear(clear_local),
    .invalidate_stats((service_cmd_valid[S_IMPORT]&&service_cmd_ready[S_IMPORT])||(preloaded_valid&&preloaded_ready)),
    .cmd_valid(service_cmd_valid[S_NORM]||service_cmd_valid[S_RESIDUAL]),.cmd_ready(compute_cmd_ready),.cmd(service_cmd),
    .context_data(active_context),.input_fault(packet_error),
    .header_valid(fp_header_valid),.header_ready(fp_header_ready),.header(fp_header),
    .data_valid(fp_valid),.data_ready(fp_ready),.data(fp_data),.tile_retire(fp_retire),
    .ram_rd_valid,.ram_rd_ready,.ram_rd_addr,.ram_rsp_valid,.ram_rsp_ready,.ram_rsp_addr,.ram_rsp_data,
    .ram_wr_valid,.ram_wr_ready,.ram_wr_addr,.ram_wr_data,
    .activation_valid,.activation_ready,.activation_index,.activation_word,
    .rsqrt_valid,.rsqrt_ready(rsqrt_ready),.rsqrt_request,
    .rsqrt_out_valid(rsqrt_out_valid),.rsqrt_out_ready(compute_rsqrt_ready),
    .rsqrt_response(rsqrt_response),
    .gamma_lookup_id,.gamma_found,.gamma_slot,.gamma_read_enable,.gamma_read_slot,.gamma_read_index,.gamma_read_data,
    .done_valid(compute_done_valid),.done_ready(compute_done_ready),.done(compute_done),.busy(compute_busy),.stats_valid,.protocol_error(compute_error)
  );
  assign store_wr_valid=import_wr_valid||ram_wr_valid;
  assign store_wr_addr=import_wr_valid?import_wr_addr:ram_wr_addr;
  assign store_wr_data=import_wr_valid?import_wr_data:ram_wr_data;
  assign import_wr_ready=store_wr_ready;
  assign ram_wr_ready=store_wr_ready&&!import_wr_valid;
  dea8_gcore_residual_store residual_store (
    .clk,.reset,.clear(clear_local),.wr_valid(store_wr_valid),.wr_ready(store_wr_ready),.wr_addr(store_wr_addr),.wr_data(store_wr_data),
    .rd_valid(ram_rd_valid),.rd_ready(ram_rd_ready),.rd_addr(ram_rd_addr),
    .rsp_valid(ram_rsp_valid),.rsp_ready(ram_rsp_ready),.rsp_data(ram_rsp_data),.rsp_addr(ram_rsp_addr),.protocol_error(residual_error)
  );
  dea8_gcore_activation_store activation_store (
    .clk,.reset,.clear(clear_local),.wr_valid(activation_valid),.wr_ready(activation_ready),.wr_index(activation_index),.wr_word(activation_word),
    .rd_valid(xbc_rd_valid),.rd_ready(xbc_rd_ready),.rd_tile(xbc_rd_tile),.rd_group(xbc_rd_group),
    .rsp_valid(xbc_rsp_valid),.rsp_ready(xbc_rsp_ready),.rsp(xbc_rsp),.protocol_error(activation_error)
  );
  dea8_gcore_xbc xbc_source (
    .clk,.reset,.clear(clear_local),.cmd_valid(service_cmd_valid[S_XBC]),.cmd_ready(xbc_cmd_ready),.cmd(service_cmd),
    .rd_valid(xbc_rd_valid),.rd_ready(xbc_rd_ready),.rd_tile(xbc_rd_tile),.rd_group(xbc_rd_group),
    .rsp_valid(xbc_rsp_valid),.rsp_ready(xbc_rsp_ready),.rsp(xbc_rsp),.xbc_valid,.xbc_ready,.xbc,
    .gu_prefetch_valid,.gu_prefetch_ready,.gu_prefetch_n,
    .done_valid(xbc_done_valid),.done_ready(service_done_ready[S_XBC]),.done(xbc_done),.busy(xbc_busy),.protocol_error(xbc_error)
  );
  dea8_gcore_kv_receive #(.BUFFERED(1'b0)) kv_receiver (
    .clk,.reset,.clear(clear_local),.cmd_valid(service_cmd_valid[S_KV_RX]),.cmd_ready(rx_cmd_ready),.cmd(service_cmd),.context_data(active_context),
    .header_valid(kv_header_valid),.header_ready(kv_header_ready),.header(kv_header),
    .data_valid(kv_data_valid),.data_ready(kv_data_ready),.data(kv_data),.last(kv_last),
    .commit_valid(kv_commit_valid),.commit_ready(kv_commit_ready),.commit(kv_commit),
    .wr_valid(kv_wr_valid),.wr_ready(kv_wr_ready),.wr(kv_wr),
    .done_valid(rx_done_valid),.done_ready(service_done_ready[S_KV_RX]),.done(rx_done),.busy(rx_busy)
  );
  dea8_gcore_kv_store kv_store (
    .clk,.reset,.clear(clear_local),.wr_valid(kv_wr_valid),.wr_ready(kv_wr_ready),.wr(kv_wr),
    .rd_valid(kv_rd_valid),.rd_ready(kv_rd_ready),.rd(kv_rd),.rsp_valid(kv_rsp_valid),.rsp_ready(kv_rsp_ready),.rsp(kv_rsp),.protocol_error(kv_store_error)
  );
  dea8_gcore_kvb kvb_source (
    .clk,.reset,.clear(clear_local),.cmd_valid(service_cmd_valid[S_KVB]),.cmd_ready(kvb_cmd_ready),.cmd(service_cmd),.context_data(active_context),
    .rd_valid(kv_rd_valid),.rd_ready(kv_rd_ready),.rd(kv_rd),.rsp_valid(kv_rsp_valid),.rsp_ready(kv_rsp_ready),.rsp(kv_rsp),
    .kv_valid,.kv_ready,.kv,.done_valid(kvb_done_valid),.done_ready(service_done_ready[S_KVB]),.done(kvb_done),.busy(kvb_busy),.protocol_error(kvb_error)
  );
endmodule
