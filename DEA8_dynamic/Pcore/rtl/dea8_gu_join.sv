import pcore_pkg::*;

// Two Up-vector credits; never a second whole-Pair or whole-Z buffer.
// The SFU may take four cycles per 16-element Gate vector. Replies are ordered.
module dea8_gu_join (
  input logic clk,reset,clear,start,input job_token_t vpu_token,sfu_token,
  input logic [ROW_COUNT_BITS-1:0] rows,input logic run,
  output logic pair_rd_valid,input logic pair_rd_ready,output pair_read_t pair_rd,
  input logic pair_out_valid,output logic pair_out_ready,input pair_reply_t pair_reply,
  output logic gate_valid,input logic gate_ready,output fp16_stream_t gate,
  input logic gelu_valid,output logic gelu_ready,input fp16_stream_t gelu,
  output logic join_valid,input logic join_ready,output pair_reply_t joined,
  output logic drained,sfu_drained,protocol_error
);
  logic [ROW_COUNT_BITS-1:0] requested,returned,consumed;
  logic [1:0] outstanding,up_count;
  logic up_read,up_write,gate_held,join_held;
  logic [TILE-1:0][FP_BITS-1:0] up[0:1];
  logic [ROW_COUNT_BITS-1:0] up_row[0:1];
  fp16_stream_t gate_q;
  pair_reply_t joined_q;
  logic request_fire,pair_fire,gelu_fire,join_fire,reply_legal;
  assign pair_rd_valid=run&&requested<rows&&outstanding<2&&!reset&&!clear&&!protocol_error;
  always_comb begin pair_rd='0;pair_rd.token=vpu_token;pair_rd.row=requested;end
  assign pair_out_ready=run&&(!gate_held||gate_ready)&&up_count<2&&!protocol_error;
  assign request_fire=pair_rd_valid&&pair_rd_ready;
  assign pair_fire=pair_out_valid&&pair_out_ready;
  assign gate_valid=run&&gate_held&&!protocol_error;
  assign gate=gate_q;
  assign join_valid=run&&join_held&&!protocol_error;
  assign joined=joined_q;
  assign join_fire=join_valid&&join_ready;
  assign gelu_ready=run&&up_count!=0&&(!join_held||join_ready)&&!protocol_error;
  assign gelu_fire=gelu_valid&&gelu_ready;
  assign reply_legal=gelu.token==sfu_token&&gelu.row<rows&&gelu.mask=='1&&
    gelu.row==up_row[up_read]&&gelu.last==(int'(gelu.row)+1==int'(rows));
  assign drained=consumed==rows&&outstanding==0&&up_count==0&&!gate_held&&!join_held;
  assign sfu_drained=returned==rows&&up_count==0&&!gate_held;
  always_ff @(posedge clk)begin
    if(reset||clear||start)begin
      requested<=0;returned<=0;consumed<=0;outstanding<=0;up_count<=0;
      up_read<=0;up_write<=0;gate_held<=0;join_held<=0;protocol_error<=0;
    end else begin
      if(gate_valid&&gate_ready)gate_held<=0;
      if(join_fire)begin join_held<=0;consumed<=consumed+1'b1;end
      case({request_fire,join_fire})
        2'b10:outstanding<=outstanding+1'b1;
        2'b01:outstanding<=outstanding-1'b1;
        default:;
      endcase
      case({pair_fire,gelu_fire})
        2'b10:up_count<=up_count+1'b1;
        2'b01:up_count<=up_count-1'b1;
        default:;
      endcase
      if(request_fire)requested<=requested+1'b1;
      if(pair_fire)begin
        fp16_stream_t g;g='0;g.token=sfu_token;g.row=pair_reply.request.row;
        g.mask='1;g.last=int'(g.row)+1==int'(rows);g.data=pair_reply.data[0];
        if(pair_reply.request.token!=vpu_token||pair_reply.request.row!=returned)protocol_error<=1;
        gate_q<=g;gate_held<=1;returned<=returned+1'b1;
        up[up_write]<=pair_reply.data[1];up_row[up_write]<=pair_reply.request.row;up_write<=!up_write;
      end
      if(gelu_valid&&(!run||up_count==0||!reply_legal))protocol_error<=1;
      if(gelu_fire&&reply_legal)begin
        pair_reply_t j;j='0;j.request.token=vpu_token;j.request.row=gelu.row;
        j.data[0]=gelu.data;j.data[1]=up[up_read];joined_q<=j;join_held<=1;up_read<=!up_read;
      end
    end
  end
endmodule
