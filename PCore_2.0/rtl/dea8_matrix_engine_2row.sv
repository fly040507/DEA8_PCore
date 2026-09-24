import pcore2_pkg::*;
// Synthesizable integration boundary for A memories, readers, loading and MXU.
// Caller owns QOZ/PBUF producer/consumer lifetime. No DEQACC is instantiated.
(* use_dsp="no" *) module dea8_matrix_engine_2row #(parameter int QOZ_TILES=32) (
  input logic clk,reset,clear,job_valid,
  output logic job_ready,busy,done,protocol_error,
  input job_t job,
  input logic xbc_valid,
  output logic xbc_ready,
  input a2_t xbc_entry,
  input logic [EPOCH_BITS-1:0] xbc_epoch,
  input a_write_t qoz_write,pbuf_write,
  input a_bank_ctrl_t qoz_begin,qoz_commit,pbuf_begin,pbuf_commit,
  input logic hbm_valid,
  output logic hbm_ready,
  input logic [HBM_BITS-1:0] hbm_data,
  input logic kv_valid,
  output logic kv_ready,
  input b_t kv_entry,
  output logic rsp_valid,
  output logic [1:0] rsp_row_valid,
  output logic signed [1:0][TILE-1:0][PSUM_BITS-1:0] psum,
  output logic [1:0][SCALE_BITS-1:0] rsp_scale,
  output logic [TILE-1:0][SCALE_BITS-1:0] rsp_e_stat,
  output tag_t rsp_tag[0:1],
  output dest_t rsp_dest[0:1]
);
  logic frontend_ready,frontend_error,config_error,config_bad,start;
  logic [1:2] memory_error;
  logic [0:0] qoz_complete;
  logic [1:0] pbuf_complete;
  logic [EPOCH_BITS-1:0] qoz_epoch[0:0],pbuf_epoch[0:1];
  logic [TILE_BITS-1:0] qoz_base[0:0],pbuf_base[0:1];
  logic [TILE_BITS:0] qoz_tiles[0:0],pbuf_tiles[0:1];
  logic qoz_region_bad,pbuf_region_bad,memory_config_bad;
  wire [2:0] a_valid;
  logic [2:0] a_ready;
  a2_t a_entry[0:2];
  logic [EPOCH_BITS-1:0] a_epoch[0:2];
  a_write_t writes[1:2];
  a_bank_ctrl_t begins[1:2],commits[1:2];
  a_source_t source;
  logic rd_valid,rd_ready,rd_bank,rd_slot;
  logic [1:2] memory_ready;
  logic [TILE_BITS-1:0] rd_tile,rd_emit_tile;
  logic [PAIR_BITS-1:0] rd_pair;
  logic [EPOCH_BITS-1:0] rd_epoch;
  assign config_bad=job.tiles==0 || job.tiles>(1<<TILE_BITS) || job.a_source>A_PBUF ||
    (job.a_source==A_QOZ && int'(job.a_mem_base)+int'(job.tiles)>QOZ_TILES) ||
    int'(job.dest_base)+(ROWS-1)*int'(job.dest_stride)+(job.along_n ? int'(job.tiles)-1 : 0)>1023 ||
    int'(job.kt_base)+(job.along_n ? 0 : int'(job.tiles)-1)>255 ||
    int'(job.nt_base)+(job.along_n ? int'(job.tiles)-1 : 0)>255;
  assign qoz_region_bad=job.a_source==A_QOZ &&
    !(qoz_complete[0] && qoz_epoch[0]==job.epoch &&
      job.a_mem_base>=qoz_base[0] &&
      job.a_mem_base+job.tiles<=qoz_base[0]+qoz_tiles[0]);
  // PBUF execution Tiles reuse one physical Tile, so the requested
  // physical span is one Tile even when job.tiles is larger.
  assign pbuf_region_bad=job.a_source==A_PBUF &&
    !(pbuf_complete[job.pbuf_bank] && pbuf_epoch[job.pbuf_bank]==job.epoch &&
      pbuf_base[job.pbuf_bank]==0 && pbuf_tiles[job.pbuf_bank]>=1);
  assign memory_config_bad=qoz_region_bad || pbuf_region_bad;
  assign protocol_error=frontend_error || config_error || memory_error[1] || memory_error[2];
  assign job_ready=frontend_ready && !config_error && !config_bad && !memory_config_bad;
  assign start=job_valid && job_ready;
  always_ff @(posedge clk) begin
    if(reset || clear) config_error<=0;
    else if(job_valid && frontend_ready && !config_error && (config_bad || memory_config_bad)) config_error<=1;
  end
  assign a_valid[0]=xbc_valid;
  assign a_entry[0]=xbc_entry;
  assign a_epoch[0]=xbc_epoch;
  assign xbc_ready=a_ready[0];
  assign writes[1]=qoz_write;
  assign writes[2]=pbuf_write;
  assign begins[1]=qoz_begin;
  assign begins[2]=pbuf_begin;
  assign commits[1]=qoz_commit;
  assign commits[2]=pbuf_commit;
  assign rd_ready=source==A_QOZ ? memory_ready[1] :
                  source==A_PBUF ? memory_ready[2] : 1'b0;
  dea8_a_tile_reader reader (
    .clk,.reset,.clear,.start,.job,.source,.rd_valid,.rd_ready,
    .rd_bank,.rd_slot,.rd_tile,.rd_emit_tile,.rd_pair,.rd_epoch
  );
  dea8_a_pair_buffer #(.MEM_TILES(QOZ_TILES),.BANKS(1)) qoz_buffer (
    .clk,.reset,.clear,.wr_mask(writes[1].mask),.wr_bank(writes[1].bank),
    .wr_tile(writes[1].tile_idx),.wr_pair(writes[1].pair_idx),
    .wr_data(writes[1].data),.wr_scale(writes[1].scale),
    .begin_bank(begins[1]),.commit_bank(commits[1]),.protocol_error(memory_error[1]),
    .bank_complete(qoz_complete),.committed_epoch(qoz_epoch),
    .committed_base(qoz_base),.committed_tiles(qoz_tiles),
    .rd_valid(rd_valid && source==A_QOZ),.rd_ready(memory_ready[1]),
    .rd_bank,.rd_tile,.rd_emit_tile,.rd_pair,.rd_slot,.rd_epoch,
    .out_valid(a_valid[1]),.out_ready(a_ready[1]),.out_entry(a_entry[1]),.out_epoch(a_epoch[1])
  );
  dea8_a_pair_buffer #(.MEM_TILES(1),.BANKS(2)) pbuf_buffer (
    .clk,.reset,.clear,.wr_mask(writes[2].mask),.wr_bank(writes[2].bank),
    .wr_tile(writes[2].tile_idx),.wr_pair(writes[2].pair_idx),
    .wr_data(writes[2].data),.wr_scale(writes[2].scale),
    .begin_bank(begins[2]),.commit_bank(commits[2]),.protocol_error(memory_error[2]),
    .bank_complete(pbuf_complete),.committed_epoch(pbuf_epoch),
    .committed_base(pbuf_base),.committed_tiles(pbuf_tiles),
    .rd_valid(rd_valid && source==A_PBUF),.rd_ready(memory_ready[2]),
    .rd_bank,.rd_tile,.rd_emit_tile,.rd_pair,.rd_slot,.rd_epoch,
    .out_valid(a_valid[2]),.out_ready(a_ready[2]),.out_entry(a_entry[2]),.out_epoch(a_epoch[2])
  );
  dea8_matrix_frontend_2row frontend (
    .clk,.reset,.clear,.job_valid(job_valid && !config_bad && !memory_config_bad && !config_error),
    .job_ready(frontend_ready),.busy,.done,.protocol_error(frontend_error),.job,
    .a_valid,.a_ready,.a_entry,.a_epoch,.hbm_valid,.hbm_ready,.hbm_data,
    .kv_valid,.kv_ready,.kv_entry,.rsp_valid,.rsp_row_valid,.psum,.rsp_scale,.rsp_e_stat,
    .rsp_tag,.rsp_dest
  );
endmodule
