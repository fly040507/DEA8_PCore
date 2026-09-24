import pcore2_pkg::*;
// Generates synchronous memory requests; response buffering is in the RAM.
module dea8_a_tile_reader (
  input logic clk,reset,clear,start,
  input job_t job,
  output a_source_t source,
  output logic rd_valid,
  input logic rd_ready,
  output logic rd_bank,rd_slot,
  output logic [TILE_BITS-1:0] rd_tile,rd_emit_tile,
  output logic [PAIR_BITS-1:0] rd_pair,
  output logic [EPOCH_BITS-1:0] rd_epoch
);
  job_t job_q;
  logic active;
  logic [TILE_BITS:0] tile_seq;
  assign source=job_q.a_source;
  assign rd_valid=active && !reset && !clear;
  assign rd_tile=job_q.a_source==A_QOZ ? job_q.a_mem_base+tile_seq : '0;
  assign rd_emit_tile=tile_seq[TILE_BITS-1:0];
  assign rd_bank=job_q.a_source==A_PBUF && job_q.pbuf_bank;
  assign rd_slot=job_q.slot;
  assign rd_epoch=job_q.epoch;
  always_ff @(posedge clk) begin
    if(reset || clear) begin active<=0;tile_seq<=0;rd_pair<=0;job_q<='0;end
    else if(start) begin
      job_q<=job;active<=job.a_source!=A_XBC;tile_seq<=0;rd_pair<=0;
    end else if(rd_valid && rd_ready) begin
      if(rd_pair==PAIRS-1) begin
        rd_pair<=0;tile_seq<=tile_seq+1'b1;
        if(tile_seq==job_q.tiles-1) active<=0;
      end else rd_pair<=rd_pair+1'b1;
    end
  end
endmodule
