import pcore_pkg::*;

// QOZ and PBUF share a protocol, not payload RAM. A read source stays locked
// until its accepted replies have been consumed, preserving request order.
module dea8_local_memory (
  input logic clk,reset,clear,
  input logic acquire_valid,output logic acquire_ready,input logic acquire_set,
  input local_object_t acquire_object,input job_token_t producer_token,
  input logic bind_valid,output logic bind_ready,input logic bind_set,
  input local_object_t bind_object,input job_token_t consumer_token,
  input logic release_valid,output logic release_ready,input local_release_t release_request,
  input logic wr_valid,output logic wr_ready,input local_write_t wr,
  input logic rd_valid,output logic rd_ready,input local_read_t rd,
  output logic out_valid,input logic out_ready,output local_response_t out_response,
  output logic qoz_active,qoz_complete,qoz_bound,
  output logic [1:0] pbuf_active,pbuf_complete,pbuf_bound,
  output logic protocol_error,empty
);
  logic [1:0] ar,br,rr,wrdy,rdr,ov,oe,errors;
  local_response_t responses[0:1];
  logic read_source_q,select_read,read_allowed,enabled;
  logic [$clog2(3)-1:0] outstanding;
  assign select_read=rd.kind==LOCAL_P;
  assign read_allowed=outstanding==0||select_read==read_source_q;
  assign protocol_error=|errors;
  assign enabled=!reset&&!clear&&!protocol_error;
  assign empty=&oe;
  assign acquire_ready=enabled&&ar[acquire_object.kind==LOCAL_P];
  assign bind_ready=enabled&&br[bind_object.kind==LOCAL_P];
  assign release_ready=enabled&&rr[release_request.kind==LOCAL_P];
  assign wr_ready=enabled&&wrdy[wr.kind==LOCAL_P];
  assign rd_ready=read_allowed&&rdr[select_read]&&!protocol_error;
  assign out_valid=outstanding!=0&&ov[read_source_q]&&!protocol_error;
  always_comb begin
    out_response='0;
    if(outstanding!=0)out_response=responses[read_source_q];
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin outstanding<=0;read_source_q<=0;end
    else begin
      case({rd_valid&&rd_ready,out_valid&&out_ready})
        2'b10:outstanding<=outstanding+1'b1;
        2'b01:outstanding<=outstanding-1'b1;
        default:;
      endcase
      if(rd_valid&&rd_ready)read_source_q<=select_read;
    end
  end
  dea8_quant_store #(.QOZ(1)) qoz(.clk,.reset,.clear,
    .acquire_valid(acquire_valid&&enabled&&acquire_object.kind!=LOCAL_P),.acquire_ready(ar[0]),.acquire_set,
    .acquire_object,.producer_token,
    .bind_valid(bind_valid&&enabled&&bind_object.kind!=LOCAL_P),.bind_ready(br[0]),.bind_set,.bind_object,.consumer_token,
    .release_valid(release_valid&&enabled&&release_request.kind!=LOCAL_P),.release_ready(rr[0]),.release_request,
    .wr_valid(wr_valid&&enabled&&wr.kind!=LOCAL_P),.wr_ready(wrdy[0]),.wr,
    .rd_valid(rd_valid&&enabled&&read_allowed&&!select_read),.rd_ready(rdr[0]),.rd,
    .out_valid(ov[0]),.out_ready(out_ready&&enabled&&outstanding!=0&&!read_source_q),.out_response(responses[0]),
    .active(qoz_active),.complete(qoz_complete),.bound(qoz_bound),.protocol_error(errors[0]),.empty(oe[0]));
  dea8_quant_store #(.QOZ(0)) pbuf(.clk,.reset,.clear,
    .acquire_valid(acquire_valid&&enabled&&acquire_object.kind==LOCAL_P),.acquire_ready(ar[1]),.acquire_set,
    .acquire_object,.producer_token,
    .bind_valid(bind_valid&&enabled&&bind_object.kind==LOCAL_P),.bind_ready(br[1]),.bind_set,.bind_object,.consumer_token,
    .release_valid(release_valid&&enabled&&release_request.kind==LOCAL_P),.release_ready(rr[1]),.release_request,
    .wr_valid(wr_valid&&enabled&&wr.kind==LOCAL_P),.wr_ready(wrdy[1]),.wr,
    .rd_valid(rd_valid&&enabled&&read_allowed&&select_read),.rd_ready(rdr[1]),.rd,
    .out_valid(ov[1]),.out_ready(out_ready&&enabled&&outstanding!=0&&read_source_q),.out_response(responses[1]),
    .active(pbuf_active),.complete(pbuf_complete),.bound(pbuf_bound),.protocol_error(errors[1]),.empty(oe[1]));
endmodule
