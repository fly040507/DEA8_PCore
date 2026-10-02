import pcore3_pkg::*;
// The sole physical Q/O/Z store. Producer job identity and consumer operation
// identity are different: Attention consumes Q produced by Q_PROJ in the same
// epoch/head, and releases only that committed region after its own completion.
module dea8_qoz_manager_v3(
  input logic clk,reset,clear,
  input logic req_valid,output logic req_ready,input qoz_region_req_t req,
  output logic region_active,region_complete,output qoz_region_req_t active_req,
  input logic release_valid,output logic release_ready,input job_header_t consumer,
  input logic wr_valid,output logic wr_ready,input post_result_t wr,
  input logic rd_valid,output logic rd_ready,input qoz_owner_e rd_owner,
  input logic [5:0] rd_tile,input logic [PAIR_BITS-1:0] rd_pair,input logic [TILE_BITS-1:0] rd_transport,
  output logic out_valid,input logic out_ready,output a2_t out_entry,
  output logic protocol_error
);
  logic store_error,store_begin_ready,store_release_ready,store_wr_ready;
  logic release_match,write_match,req_match;
  assign req_match=(req.owner==QOZ_Q&&req.tiles==QOZ_Q_TILES&&req.header.op==OP_Q_PROJ)||
    (req.owner==QOZ_Z&&req.tiles==QOZ_Z_TILES&&req.header.op==OP_GU)||
    (req.owner==QOZ_O&&req.tiles==QOZ_O_TILES&&req.header.op==OP_O_PROJ);
  assign write_match=wr.header==active_req.header&&wr.n==wr.pair_data.tile_idx&&
    wr.last==(wr.pair_data.pair_idx==PAIRS-1);
  assign release_match=consumer.epoch==active_req.header.epoch&&consumer.head==active_req.header.head&&
    ((active_req.owner==QOZ_Q&&consumer.op==OP_ATTENTION)||(active_req.owner==QOZ_Z&&consumer.op==OP_DOWN_PROJ));
  assign req_ready=store_begin_ready&&req_match&&!protocol_error;
  assign wr_ready=store_wr_ready&&write_match&&!protocol_error;
  assign release_ready=store_release_ready&&release_match&&!protocol_error;
  dea8_qoz_store_v3 store(.clk,.reset,.clear,
    .region_begin_valid(req_valid&&req_match&&!protocol_error),.region_begin_ready(store_begin_ready),
    .region_owner(req.owner),.region_epoch(req.header.epoch),.region_head(req.header.head),.region_tiles(req.tiles),
    .region_active,.region_complete,.region_release_valid(release_valid&&release_match&&!protocol_error),.region_release_ready(store_release_ready),
    .wr_valid(wr_valid&&write_match&&!protocol_error),.wr_ready(store_wr_ready),.wr_owner(active_req.owner),
    .wr_tile(wr.pair_data.tile_idx),.wr_pair(wr.pair_data.pair_idx),.wr_row_valid(wr.pair_data.row_valid),
    .wr_even(wr.pair_data.row[0]),.wr_odd(wr.pair_data.row[1]),.wr_epoch(wr.header.epoch),.wr_head(wr.header.head),
    .rd_valid,.rd_ready,.rd_owner,.rd_tile,.rd_pair,.rd_transport,.rd_out_valid(out_valid),.rd_out_ready(out_ready),.rd_entry(out_entry),
    .active_epoch(),.active_head(),.active_owner(),.protocol_error(store_error));
  always_ff @(posedge clk)begin
    if(reset||clear)begin active_req<='0;protocol_error<=0;end
    else begin
      if(req_valid&&req_ready)active_req<=req;
      if(store_error||(req_valid&&!req_match)||(wr_valid&&!write_match)||(release_valid&&!release_match))protocol_error<=1;
    end
  end
endmodule
