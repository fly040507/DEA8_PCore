import pcore_pkg::*;
import dea8_tile_link_pkg::*;

// PCore-internal KV serializer. FP32 Reduce path will use a separate payload port.
module dea8_pcore_output (
  input logic clk,reset,clear,start_valid,
  input pcore_job_t context_job,input job_token_t context_token,
  input logic quant_valid,output logic quant_ready,input kv_quant_t quant,
  input logic [ROW_COUNT_BITS-1:0] context_rows,
  input logic capture_valid,output logic capture_ready,input pair_capture_t capture,
  output logic reduce_hdr_valid,input logic reduce_hdr_ready,output tile_header_t reduce_hdr,
  output logic reduce_out_valid,input logic reduce_out_ready,output logic [TILE*FP_BITS-1:0] reduce_out,
  output logic reduce_out_last,output logic fp_done,
  output logic kv_hdr_valid,input logic kv_hdr_ready,output tile_header_t kv_hdr,
  output logic kv_out_valid,input logic kv_out_ready,output logic [ROW_BITS-1:0] kv_out,
  output logic kv_out_last,
  input logic kv_commit_valid,output logic kv_commit_ready,input tile_commit_t kv_commit,
  output logic done,protocol_error
);
  typedef enum logic [1:0] {WAIT_INPUT,SEND_HEADER,SEND_FIRST,SEND_SECOND} state_e;
  state_e state;
  tile_header_t header_q,header;
  logic [ROW_LANES-1:0][ROW_BITS-1:0] words;
  logic second,last,active,sender_busy,sender_error,error_q;
  logic hv,hr,dv,dr,dl,legal;
  logic [1:0] next_tile;
  logic [5:0] next_index;
  logic [ROW_LANES-1:0] expected_mask;
  logic [TILE-1:0] expected_tokens;
  logic fp_active,fp_held,fp_header,fp_second,fp_tail,fp_legal,fp_pop,fp_bundle_pop;
  logic capture_second_q;
  logic [ROW_LANES-1:0][TILE*FP_BITS-1:0] fp_words;
  logic [6:0] fp_next_tile,fp_sent;
  logic [PAIR_BITS-1:0] fp_next_pair;
  tile_header_t fp_header_q;
  always_comb begin
    header='0;header.transfer_id=context_job.transfer_context;header.transfer_epoch=context_job.transfer_epoch;
    header.destination_id=context_job.data_context;header.token_origin=0;
    header.column_base=quant.tile==0?context_job.kv_column_base0:context_job.kv_column_base1;
    header.rows=ROW_COUNT_BITS'(ROWS);header.columns=5'(TILE);header.source_id=4'(context_job.core_id);
    header.tile_seq=quant.tile;header.kind=context_job.op==OP_K_PROJ?TILE_K:TILE_V;
    header.layout=context_job.op==OP_K_PROJ?LAYOUT_K_ROWS:LAYOUT_V_GROUPS;
    expected_mask=context_job.op==OP_K_PROJ?row_mask_for_rows(ROWS,quant.index):2'b11;
    expected_tokens='1;
    if(context_job.op==OP_V_PROJ)for(int i=0;i<TILE;i++)
      expected_tokens[i]=int'(quant.index)/(TILE/ROW_LANES)*TILE+i<ROWS;
    legal=(context_job.op==OP_K_PROJ||context_job.op==OP_V_PROJ)&&quant.token==context_token&&
      quant.tile==next_tile&&next_tile<2&&quant.index==next_index&&quant.mask==expected_mask&&
      quant.token_mask==expected_tokens&&quant.last==
        (quant.index==(context_job.op==OP_K_PROJ?PAIRS-1:V_PACKETS_PER_TILE-1));
  end
  assign quant_ready=active&&state==WAIT_INPUT&&!reset&&!clear&&!protocol_error;
  assign hv=state==SEND_HEADER&&!protocol_error;
  assign dv=(state==SEND_FIRST||state==SEND_SECOND)&&!protocol_error;
  assign dl=last&&(state==SEND_SECOND||!second);
  assign protocol_error=sender_error||error_q;
  assign done=active&&next_tile==2&&state==WAIT_INPUT&&!sender_busy&&!protocol_error;
  assign fp_pop=reduce_out_valid&&reduce_out_ready;
  assign fp_bundle_pop=fp_pop&&(fp_second||!capture_second_q);
  assign capture_ready=fp_active&&!reset&&!clear&&!protocol_error&&(!fp_held||fp_bundle_pop);
  assign fp_legal=capture.owner.token==context_token&&capture.owner.rows==context_rows&&
    capture.owner.nt==fp_next_tile&&capture.owner.work_seq==fp_next_tile&&fp_next_tile<64&&
    capture.pair_idx==fp_next_pair&&capture.mask==row_mask_for_rows(context_rows,fp_next_pair);
  assign reduce_hdr_valid=fp_held&&fp_header&&!reset&&!clear&&!protocol_error;
  assign reduce_hdr=fp_header_q;
  assign reduce_out_valid=fp_held&&!fp_header&&!reset&&!clear&&!protocol_error;
  assign reduce_out=fp_words[fp_second];
  assign reduce_out_last=fp_tail&&(fp_second||!capture_second_q);
  assign fp_done=fp_active&&fp_sent==64&&!fp_held&&!protocol_error;
  dea8_kv_tile_sender sender(.clk,.reset,.clear,
    .in_hdr_valid(hv),.in_hdr_ready(hr),.in_hdr(header_q),
    .in_valid(dv),.in_ready(dr),.in_data(words[state==SEND_SECOND]),.in_last(dl),
    .hdr_valid(kv_hdr_valid),.hdr_ready(kv_hdr_ready),.hdr(kv_hdr),
    .out_valid(kv_out_valid),.out_ready(kv_out_ready),.out_data(kv_out),.out_last(kv_out_last),
    .commit_valid(kv_commit_valid),.commit_ready(kv_commit_ready),.commit(kv_commit),
    .busy(sender_busy),.protocol_error(sender_error));
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      state<=WAIT_INPUT;next_tile<=0;next_index<=0;error_q<=0;active<=0;
      fp_active<=0;fp_held<=0;fp_header<=0;fp_second<=0;fp_tail<=0;capture_second_q<=0;
      fp_next_tile<=0;fp_next_pair<=0;fp_sent<=0;
    end
    else begin
      if(start_valid)begin
        active<=context_job.op==OP_K_PROJ||context_job.op==OP_V_PROJ;next_tile<=0;next_index<=0;
        fp_active<=context_job.op==OP_O_PROJ||context_job.op==OP_DOWN_PROJ;
        fp_next_tile<=0;fp_next_pair<=0;fp_sent<=0;
      end
      if(quant_valid&&quant_ready)begin
        if(!legal)error_q<=1;
        else begin
          for(int r=0;r<ROW_LANES;r++)begin
            words[r][ROW_BITS-1:DATA_BITS]<=quant.entry[r].scale;
            for(int i=0;i<TILE;i++)words[r][i*INT_BITS+:INT_BITS]<=
              expected_tokens[i]?quant.entry[r].data[i*INT_BITS+:INT_BITS]:'0;
          end
          header_q<=header;second<=quant.mask[1];last<=quant.last;
          state<=next_index==0?SEND_HEADER:SEND_FIRST;
          if(quant.last)begin next_tile<=next_tile+1'b1;next_index<=0;end
          else next_index<=next_index+1'b1;
        end
      end
      if(hv&&hr)state<=SEND_FIRST;
      if(dv&&dr)state<=state==SEND_FIRST&&second?SEND_SECOND:WAIT_INPUT;
      if(reduce_hdr_valid&&reduce_hdr_ready)fp_header<=0;
      if(fp_pop)begin
        if(fp_bundle_pop)begin fp_held<=0;fp_second<=0;if(fp_tail)fp_sent<=fp_sent+1'b1;end
        else fp_second<=1;
      end
      if(capture_valid&&capture_ready)begin
        if(!fp_legal)error_q<=1;
        else begin
          fp_words[0]<=capture.data[0];fp_words[1]<=capture.data[1];
          fp_held<=1;fp_second<=0;capture_second_q<=capture.mask[1];
          fp_tail<=int'(capture.pair_idx)+1==pairs_for_rows(context_rows);
          fp_header<=capture.pair_idx==0;
          if(capture.pair_idx==0)begin
            tile_header_t h;h='0;h.transfer_id=context_job.transfer_context;h.transfer_epoch=context_job.transfer_epoch;
            h.destination_id=context_job.data_context;h.rows=context_rows;h.columns=5'(TILE);
            h.kind=context_job.op==OP_O_PROJ?TILE_O:TILE_DOWN;h.layout=LAYOUT_FP_ROWS;
            h.source_id=4'(context_job.core_id);h.tile_seq=capture.owner.nt;h.column_base=16'(int'(capture.owner.nt)*TILE);
            fp_header_q<=h;
          end
          if(int'(capture.pair_idx)+1==pairs_for_rows(context_rows))begin fp_next_pair<=0;fp_next_tile<=fp_next_tile+1'b1;end
          else fp_next_pair<=fp_next_pair+1'b1;
        end
      end
    end
  end
endmodule
