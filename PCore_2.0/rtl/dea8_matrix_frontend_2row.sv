import pcore2_pkg::*;
// Matrix frontend only. The response is fixed-rate, not a ready/valid sink.
// HBM/KV payloads are ordered within the accepted job; AXI requests stay outside.
(* use_dsp="no" *) module dea8_matrix_frontend_2row (
  input logic clk,reset,clear,job_valid,
  output logic job_ready,busy,done,protocol_error,
  input job_t job,
  input logic [2:0] a_valid,
  output logic [2:0] a_ready,
  input a2_t a_entry[0:2],
  input logic [EPOCH_BITS-1:0] a_epoch[0:2],
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
  job_t job_q;
  logic start,flush,adapter_valid,adapter_ready,adapter_in_ready,adapter_error,a_error;
  a2_t adapter_entry,issue_entry;
  logic a_complete,a_running,issue_valid,reserve;
  logic [$clog2(A_DEPTH+1)-1:0] a_count,a_tiles;
  logic asm_valid,asm_ready,asm_hbm_ready,w_ready,w_valid,kv_fifo_ready,kv_fifo_valid;
  b_t asm_entry,w_entry,kv_fifo_entry,b_entry,load_entry;
  logic [$clog2(B_DEPTH+1)-1:0] w_count,kv_count,b_count;
  logic b_valid,b_ready,load_valid,load_bank;
  logic [$clog2(TILE)-1:0] load_column;
  logic [1:0] bank_ready;
  logic [TILE_BITS-1:0] bank_tile[0:1];
  logic [TILE_BITS:0] issue_tile,hbm_tiles,kv_tiles;
  logic [$clog2(HBM_BEATS)-1:0] hbm_beat;
  logic [$clog2(TILE)-1:0] kv_column;
  logic active_bank,last_s0_q,last_bank_q;
  logic [9:0] pair_dest_address;
  tag_t issue_tag[0:1];
  dest_t issue_dest[0:1];
  logic config_bad;
  assign config_bad=job.tiles==0 || job.tiles>(1<<TILE_BITS) || job.a_source>A_PBUF ||
    int'(job.dest_base)+(ROWS-1)*int'(job.dest_stride)+(job.along_n ? int'(job.tiles)-1 : 0)>1023 ||
    int'(job.kt_base)+(job.along_n ? 0 : int'(job.tiles)-1)>255 ||
    int'(job.nt_base)+(job.along_n ? int'(job.tiles)-1 : 0)>255;
  assign job_ready=!reset && !clear && !busy && !protocol_error;
  assign start=job_valid && job_ready && !config_bad;
  assign flush=clear || start;
  always_comb begin
    a_ready='0;
    a_ready[job_q.a_source]=adapter_in_ready;
  end
  dea8_xbc_a2_adapter adapter (
    .clk,.reset,.clear(flush),.enable(busy && !protocol_error),.job(job_q),
    .in_valid(a_valid[job_q.a_source]),.in_ready(adapter_in_ready),
    .in_entry(a_entry[job_q.a_source]),.in_epoch(a_epoch[job_q.a_source]),
    .out_valid(adapter_valid),.out_ready(adapter_ready),.out_entry(adapter_entry),
    .protocol_error(adapter_error)
  );
  dea8_a2_fifo a_fifo (
    .clk,.reset,.clear(flush),.in_valid(adapter_valid),.in_ready(adapter_ready),
    .in_entry(adapter_entry),.reserve_tile(reserve),.tile_available(a_complete),
    .running(a_running),.out_valid(issue_valid),.out_entry(issue_entry),
    .protocol_error(a_error),.count(a_count),.complete_tiles(a_tiles)
  );

  // Separate ordered FIFOs preserve independent HBM/KV backpressure.
  assign hbm_ready=busy && !protocol_error && !job_q.b_from_kv &&
                   hbm_tiles<job_q.tiles && asm_hbm_ready;
  dea8_w_tile_assembler_pp assembler (
    .clk,.reset,.clear(flush),.hbm_valid(hbm_valid && hbm_ready),.hbm_ready(asm_hbm_ready),
    .hbm_data,.out_valid(asm_valid),.out_ready(asm_ready),.out_entry(asm_entry)
  );
  pcore2_fifo #(.WIDTH($bits(b_t)),.DEPTH(B_DEPTH)) w_fifo (
    .clk,.reset,.clear(flush),.in_valid(asm_valid),.in_ready(asm_ready),.in_data(asm_entry),
    .out_valid(w_valid),.out_ready(w_ready),.out_data(w_entry),.count(w_count)
  );
  assign kv_ready=busy && !protocol_error && job_q.b_from_kv &&
                  kv_tiles<job_q.tiles && kv_fifo_ready;
  pcore2_fifo #(.WIDTH($bits(b_t)),.DEPTH(B_DEPTH)) kv_fifo (
    .clk,.reset,.clear(flush),.in_valid(kv_valid && kv_ready),.in_ready(kv_fifo_ready),.in_data(kv_entry),
    .out_valid(kv_fifo_valid),.out_ready(b_ready && job_q.b_from_kv),
    .out_data(kv_fifo_entry),.count(kv_count)
  );
  assign b_entry=job_q.b_from_kv ? kv_fifo_entry : w_entry;
  assign b_count=job_q.b_from_kv ? kv_count : w_count;
  assign b_valid=job_q.b_from_kv ? kv_fifo_valid : w_valid;
  assign w_ready=b_ready && !job_q.b_from_kv;
  dea8_b_column_loader loader (
    .clk,.reset,.clear(flush),.enable(busy && !protocol_error),.tiles(job_q.tiles),
    .fifo_valid(b_valid),.fifo_ready(b_ready),.fifo_entry(b_entry),.fifo_count(b_count),
    .release_valid(last_s0_q),.release_bank(last_bank_q),.bank_ready,.bank_tile,
    .load_valid,.load_bank,.load_column,.load_entry
  );

  // Bank release occurs at the final S1 multiply, not at the final S0 capture.
  assign reserve=busy && !protocol_error && issue_tile<job_q.tiles && a_complete &&
                 bank_ready[issue_tile[0]] &&
                 bank_tile[issue_tile[0]]==issue_tile[TILE_BITS-1:0];
  always_comb begin
    for(int r=0;r<ROW_LANES;r++) begin
      issue_tag[r]='0;
      issue_tag[r].epoch=job_q.epoch;issue_tag[r].head=job_q.head;
      issue_tag[r].row=ROW_LANES*issue_entry.pair_idx+r;
      issue_tag[r].kt=job_q.kt_base+(job_q.along_n ? 0 : issue_entry.tile_idx);
      issue_tag[r].nt=job_q.nt_base+(job_q.along_n ? issue_entry.tile_idx : 0);
      issue_tag[r].final_k=job_q.along_n || issue_tile==job_q.tiles-1;
      issue_tag[r].last=issue_tile==job_q.tiles-1 && issue_entry.pair_idx==PAIRS-1;
      issue_dest[r]='0;
      issue_dest[r].bank=job_q.dest_bank;
      issue_dest[r].address=pair_dest_address+(r==0 ? 10'd0 : job_q.dest_stride);
      issue_dest[r].zero=job_q.along_n || issue_entry.tile_idx==0;
    end
  end
  dea8_mxu_2row mxu (
    .clk,.reset,.clear(flush),.req_valid(issue_valid),.req_bank(active_bank),.req(issue_entry),
    .req_tag(issue_tag),.req_dest(issue_dest),.load_valid,.load_bank,.load_column,.load_entry,
    .rsp_valid,.rsp_row_valid,.psum,.rsp_scale,.rsp_e_stat,.rsp_tag,.rsp_dest
  );
  always_ff @(posedge clk) begin
    if(reset || clear) begin
      busy<=0;done<=0;protocol_error<=0;job_q<='0;
      issue_tile<=0;active_bank<=0;last_s0_q<=0;last_bank_q<=0;pair_dest_address<=0;
      hbm_tiles<=0;hbm_beat<=0;kv_tiles<=0;kv_column<=0;
    end else begin
      done<=0;
      if(job_valid && job_ready && config_bad) protocol_error<=1;
      if(adapter_error || a_error) protocol_error<=1;
      if(start) begin
        job_q<=job;busy<=1;issue_tile<=0;
        hbm_tiles<=0;hbm_beat<=0;kv_tiles<=0;kv_column<=0;
      end
      if(hbm_valid && hbm_ready) begin
        if(hbm_beat==HBM_BEATS-1) begin hbm_beat<=0;hbm_tiles<=hbm_tiles+1'b1;end
        else hbm_beat<=hbm_beat+1'b1;
      end
      if(kv_valid && kv_ready) begin
        if(kv_column==TILE-1) begin kv_column<=0;kv_tiles<=kv_tiles+1'b1;end
        else kv_column<=kv_column+1'b1;
      end
      if(reserve) begin
        active_bank<=issue_tile[0];
        pair_dest_address<=job_q.dest_base+(job_q.along_n ? issue_tile : 0);
      end else if(issue_valid) begin
        // Consecutive row pairs avoid a dynamic row*stride multiplier.
        pair_dest_address<=pair_dest_address+(job_q.dest_stride<<1);
      end
      last_s0_q<=issue_valid && issue_entry.pair_idx==PAIRS-1;
      if(issue_valid && issue_entry.pair_idx==PAIRS-1) begin
        last_bank_q<=active_bank;issue_tile<=issue_tile+1'b1;
      end
      if(rsp_valid && rsp_tag[0].last) begin busy<=0;done<=1;end
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(!reset && !flush) begin
    if(issue_valid && (issue_entry.tile_idx!=issue_tile[TILE_BITS-1:0] || issue_entry.slot!=job_q.slot))
      $fatal(1,"A/B tile ownership mismatch");
    if(issue_valid && (!bank_ready[active_bank] || bank_tile[active_bank]!=issue_entry.tile_idx))
      $fatal(1,"Issue before matching B ready");
  end
  // synthesis translate_on
endmodule
