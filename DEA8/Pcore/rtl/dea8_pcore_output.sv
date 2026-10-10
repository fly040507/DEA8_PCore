import pcore_pkg::*;
import pcore_control_pkg::*;
import dea8_tile_link_pkg::*;

// PCore-owned output stage: VPU quantized vectors or FACC read responses.
module dea8_pcore_output(
  input logic clk,reset,clear,
  input control_job_t job,
  input logic quant_valid,output logic quant_ready,input control_quant_result_t quant,
  input logic facc_valid,output logic facc_ready,input post_data_t facc,
  output logic kv_hdr_valid,input logic kv_hdr_ready,output tile_header_t kv_hdr,
  output logic kv_out_valid,input logic kv_out_ready,output logic [KV_WORD_BITS-1:0] kv_out,
  output logic kv_out_last,
  input logic kv_commit_valid,output logic kv_commit_ready,input tile_commit_t kv_commit,
  output logic reduce_hdr_valid,input logic reduce_hdr_ready,output tile_header_t reduce_hdr,
  output logic reduce_out_valid,input logic reduce_out_ready,output logic [FP_ROW_BITS-1:0] reduce_out,
  output logic reduce_out_last,
  output logic kv_empty,reduce_empty,busy,protocol_error
);
  typedef enum logic [1:0] {WAIT_INPUT,SEND_HEADER,SEND_FIRST,SEND_SECOND} phase_e;
  phase_e kphase_q,fphase_q;
  tile_header_t kheader_q,fheader_q,kheader,fheader;
  logic [KV_WORD_BITS-1:0] kword_q[ROW_LANES];
  logic [FP_ROW_BITS-1:0] fword_q[ROW_LANES];
  logic ksecond_q,fsecond_q,klast_q,flast_q,error_q;
  logic [5:0] kindex_q,findex_q;
  logic [6:0] ktile_q,ftile_q;
  logic khv,khr,kdv,kdr,kdl,sender_busy,sender_pending,sender_error;
  logic kv_legal,facc_legal;
  logic [ROW_LANES-1:0] expected_mask;
  logic [TILE-1:0] expected_tokens;

  always_comb begin
    kheader='0;fheader='0;
    kheader.transfer_id=job.transfer.transfer_id;kheader.transfer_epoch=job.transfer.transfer_epoch;
    kheader.destination_id=job.transfer.destination_id;kheader.token_origin=job.transfer.token_origin;
    kheader.rows=6'(ROWS);kheader.columns=5'(TILE);kheader.source_id=4'(job.core_id);
    kheader.tile_seq=quant.tile;
    kheader.kind=job.header.op==OP_K_PROJ?TILE_K:TILE_V;
    kheader.layout=job.header.op==OP_K_PROJ?LAYOUT_K_ROWS:LAYOUT_V_GROUPS;
    kheader.column_base=job.header.op==OP_K_PROJ?16'(job.rope_pair_base+quant.tile*128):
      16'(job.core_id*32+quant.tile*TILE);
    fheader=kheader;
    fheader.kind=job.header.op==OP_O_PROJ?TILE_O:TILE_DOWN;fheader.layout=LAYOUT_FP_ROWS;
    fheader.tile_seq=facc.n;fheader.column_base=16'(facc.n*TILE);
    expected_mask=job.header.op==OP_K_PROJ?row_mask(quant.index):2'b11;
    expected_tokens=job.header.op==OP_V_PROJ&&quant.index>=3*(TILE/ROW_LANES)?16'h0007:16'hffff;
    kv_legal=(job.header.op==OP_K_PROJ||job.header.op==OP_V_PROJ)&&quant.tile==ktile_q&&
      ktile_q<2&&quant.index==kindex_q&&quant.vector_valid==expected_mask&&quant.token_mask==expected_tokens&&
      quant.quant_axis==(job.header.op==OP_K_PROJ?QUANT_FEATURE_B16:QUANT_TOKEN_B16)&&
      quant.last==(quant.index==(job.header.op==OP_K_PROJ?PAIRS-1:V_PACKETS_PER_TILE-1));
    facc_legal=(job.header.op==OP_O_PROJ||job.header.op==OP_DOWN_PROJ)&&facc.header==job.header&&
      facc.n==ftile_q&&ftile_q<64&&facc.row==findex_q&&facc.row_valid==row_mask(findex_q)&&
      facc.last==(findex_q==PAIRS-1);
  end
  assign quant_ready=kphase_q==WAIT_INPUT&&!reset&&!clear&&!protocol_error;
  assign facc_ready=fphase_q==WAIT_INPUT&&!reset&&!clear&&!protocol_error;
  assign khv=kphase_q==SEND_HEADER&&!error_q;
  assign kdv=(kphase_q==SEND_FIRST||kphase_q==SEND_SECOND)&&!error_q;
  assign kdl=klast_q&&(kphase_q==SEND_SECOND||!ksecond_q);
  dea8_kv_tile_sender sender(.clk,.reset,.clear,
    .in_hdr_valid(khv),.in_hdr_ready(khr),.in_hdr(kheader_q),
    .in_data_valid(kdv),.in_data_ready(kdr),.in_data(kword_q[kphase_q==SEND_SECOND]),.in_last(kdl),
    .out_hdr_valid(kv_hdr_valid),.out_hdr_ready(kv_hdr_ready),.out_hdr(kv_hdr),
    .out_data_valid(kv_out_valid),.out_data_ready(kv_out_ready),.out_data(kv_out),.out_last(kv_out_last),
    .commit_valid(kv_commit_valid),.commit_ready(kv_commit_ready),.commit(kv_commit),
    .busy(sender_busy),.payload_pending(sender_pending),.protocol_error(sender_error));
  assign reduce_hdr=fheader_q;
  assign reduce_hdr_valid=fphase_q==SEND_HEADER&&!reset&&!clear&&!protocol_error;
  assign reduce_out_valid=(fphase_q==SEND_FIRST||fphase_q==SEND_SECOND)&&!reset&&!clear&&!protocol_error;
  assign reduce_out=fword_q[fphase_q==SEND_SECOND];
  assign reduce_out_last=flast_q&&(fphase_q==SEND_SECOND||!fsecond_q);
  assign kv_empty=kphase_q==WAIT_INPUT&&!sender_pending;
  assign reduce_empty=fphase_q==WAIT_INPUT;
  assign busy=kphase_q!=WAIT_INPUT||fphase_q!=WAIT_INPUT||sender_busy;
  assign protocol_error=error_q||sender_error;
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      kphase_q<=WAIT_INPUT;fphase_q<=WAIT_INPUT;kindex_q<=0;findex_q<=0;
      ktile_q<=0;ftile_q<=0;error_q<=0;
    end else begin
      if(quant_valid&&quant_ready)begin
        if(!kv_legal)error_q<=1;
        else begin
          for(int r=0;r<ROW_LANES;r++)begin
            kword_q[r][KV_WORD_BITS-1:128]<=quant.vector_data[r].scale;
            for(int i=0;i<TILE;i++)kword_q[r][INT_BITS*i+:INT_BITS]<=expected_tokens[i]?
              quant.vector_data[r].data[INT_BITS*i+:INT_BITS]:'0;
          end
          kheader_q<=kheader;ksecond_q<=quant.vector_valid[1];klast_q<=quant.last;
          kphase_q<=kindex_q==0?SEND_HEADER:SEND_FIRST;
          if(quant.last)begin kindex_q<=0;ktile_q<=ktile_q+1'b1;end
          else kindex_q<=kindex_q+1'b1;
        end
      end
      if(khv&&khr)kphase_q<=SEND_FIRST;
      if(kdv&&kdr)kphase_q<=kphase_q==SEND_FIRST&&ksecond_q?SEND_SECOND:WAIT_INPUT;
      if(facc_valid&&facc_ready)begin
        if(!facc_legal)error_q<=1;
        else begin
          fword_q[0]<=facc.first;fword_q[1]<=facc.second;
          fheader_q<=fheader;fsecond_q<=facc.row_valid[1];flast_q<=facc.last;
          fphase_q<=findex_q==0?SEND_HEADER:SEND_FIRST;
          if(facc.last)begin findex_q<=0;ftile_q<=ftile_q+1'b1;end
          else findex_q<=findex_q+1'b1;
        end
      end
      if(reduce_hdr_valid&&reduce_hdr_ready)fphase_q<=SEND_FIRST;
      if(reduce_out_valid&&reduce_out_ready)
        fphase_q<=fphase_q==SEND_FIRST&&fsecond_q?SEND_SECOND:WAIT_INPUT;
    end
  end
endmodule
