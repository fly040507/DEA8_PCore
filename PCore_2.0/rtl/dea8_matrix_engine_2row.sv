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
  wire [2:0] a_valid;
  logic [2:0] a_ready;
  a2_t a_entry[0:2];
  logic [EPOCH_BITS-1:0] a_epoch[0:2];
  a_write_t writes[1:2];
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
  assign protocol_error=frontend_error || config_error;
  assign job_ready=frontend_ready && !config_error;
  assign start=job_valid && job_ready && !config_bad;
  always_ff @(posedge clk) begin
    if(reset || clear) config_error<=0;
    else if(job_valid && job_ready && config_bad) config_error<=1;
  end
  assign a_valid[0]=xbc_valid;
  assign a_entry[0]=xbc_entry;
  assign a_epoch[0]=xbc_epoch;
  assign xbc_ready=a_ready[0];
  assign writes[1]=qoz_write;
  assign writes[2]=pbuf_write;
  assign rd_ready=source==A_QOZ ? memory_ready[1] :
                  source==A_PBUF ? memory_ready[2] : 1'b0;
  dea8_a_tile_reader reader (
    .clk,.reset,.clear,.start,.job,.source,.rd_valid,.rd_ready,
    .rd_bank,.rd_slot,.rd_tile,.rd_emit_tile,.rd_pair,.rd_epoch
  );
  for(genvar s=1;s<=2;s++) begin : g_memory
    dea8_a_pair_buffer #(.MEM_TILES(s==1 ? QOZ_TILES : 1),.BANKS(s==1 ? 1 : 2)) buffer (
      .clk,.reset,.clear,.wr_mask(writes[s].mask),.wr_bank(writes[s].bank),
      .wr_tile(writes[s].tile_idx),.wr_pair(writes[s].pair_idx),
      .wr_data(writes[s].data),.wr_scale(writes[s].scale),
      .rd_valid(rd_valid && source==s),.rd_ready(memory_ready[s]),
      .rd_bank,.rd_tile,.rd_emit_tile,.rd_pair,.rd_slot,.rd_epoch,
      .out_valid(a_valid[s]),.out_ready(a_ready[s]),.out_entry(a_entry[s]),.out_epoch(a_epoch[s])
    );
  end
  dea8_matrix_frontend_2row frontend (
    .clk,.reset,.clear,.job_valid(job_valid && !config_bad && !config_error),
    .job_ready(frontend_ready),.busy,.done,.protocol_error(frontend_error),.job,
    .a_valid,.a_ready,.a_entry,.a_epoch,.hbm_valid,.hbm_ready,.hbm_data,
    .kv_valid,.kv_ready,.kv_entry,.rsp_valid,.rsp_row_valid,.psum,.rsp_scale,.rsp_e_stat,
    .rsp_tag,.rsp_dest
  );
endmodule
