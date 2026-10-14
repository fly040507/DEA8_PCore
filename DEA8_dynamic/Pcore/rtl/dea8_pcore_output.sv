import pcore_pkg::*;
import dea8_tile_link_pkg::*;

// PCore-internal KV serializer. FP32 Reduce path will use a separate payload port.
module dea8_pcore_output (
  input logic clk,reset,clear,start_valid,
  input pcore_job_t context_job,input job_token_t context_token,
  input logic quant_valid,output logic quant_ready,input kv_quant_t quant,
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
  dea8_kv_tile_sender sender(.clk,.reset,.clear,
    .in_hdr_valid(hv),.in_hdr_ready(hr),.in_hdr(header_q),
    .in_valid(dv),.in_ready(dr),.in_data(words[state==SEND_SECOND]),.in_last(dl),
    .hdr_valid(kv_hdr_valid),.hdr_ready(kv_hdr_ready),.hdr(kv_hdr),
    .out_valid(kv_out_valid),.out_ready(kv_out_ready),.out_data(kv_out),.out_last(kv_out_last),
    .commit_valid(kv_commit_valid),.commit_ready(kv_commit_ready),.commit(kv_commit),
    .busy(sender_busy),.protocol_error(sender_error));
  always_ff @(posedge clk)begin
    if(reset||clear)begin state<=WAIT_INPUT;next_tile<=0;next_index<=0;error_q<=0;active<=0;end
    else begin
      if(start_valid)begin active<=1;next_tile<=0;next_index<=0;end
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
    end
  end
endmodule
