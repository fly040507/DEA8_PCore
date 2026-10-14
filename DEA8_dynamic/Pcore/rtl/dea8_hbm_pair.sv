import pcore_pkg::*;

// Logical PC beats, not raw AXI bursts: upstream supplies paired beat identity.
module dea8_hbm_pair #(
  parameter int DEPTH=2,
  parameter int PTR_BITS=(DEPTH>1)?$clog2(DEPTH):1
) (
  input logic clk,reset,clear,
  input logic [1:0] in_valid,output logic [1:0] in_ready,
  input logic [1:0][B_BEAT_BITS/2-1:0] in_data,
  input b_beat_tag_t in_tag[0:1],
  output logic out_valid,input logic out_ready,
  output logic [B_BEAT_BITS-1:0] out_data,output b_beat_tag_t out_tag,
  output logic empty,protocol_error
);
  logic [B_BEAT_BITS/2-1:0] data_q[0:1][0:DEPTH-1];
  b_beat_tag_t tag_q[0:1][0:DEPTH-1];
  logic [PTR_BITS-1:0] rptr[0:1],wptr[0:1];
  logic [$clog2(DEPTH+1)-1:0] count[0:1];
  logic mismatch,pop;
  function automatic logic [PTR_BITS-1:0] advance(input logic [PTR_BITS-1:0] p);
    return p==DEPTH-1?'0:p+1'b1;
  endfunction
  assign mismatch=count[0]!=0&&count[1]!=0&&tag_q[0][rptr[0]]!=tag_q[1][rptr[1]];
  assign out_valid=!reset&&!clear&&!protocol_error&&!mismatch&&count[0]!=0&&count[1]!=0;
  assign out_data={data_q[1][rptr[1]],data_q[0][rptr[0]]};
  assign out_tag=tag_q[0][rptr[0]];
  assign pop=out_valid&&out_ready;
  assign empty=count[0]==0&&count[1]==0;
  for(genvar p=0;p<2;p++)begin: pcs
    assign in_ready[p]=!reset&&!clear&&!protocol_error&&!mismatch&&(count[p]<DEPTH||pop);
    always_ff @(posedge clk)begin
      if(reset||clear)begin rptr[p]<=0;wptr[p]<=0;count[p]<=0;end
      else begin
        case({in_valid[p]&&in_ready[p],pop})
          2'b10:count[p]<=count[p]+1'b1;
          2'b01:count[p]<=count[p]-1'b1;
          default:;
        endcase
        if(in_valid[p]&&in_ready[p])begin
          data_q[p][wptr[p]]<=in_data[p];tag_q[p][wptr[p]]<=in_tag[p];wptr[p]<=advance(wptr[p]);
        end
        if(pop)rptr[p]<=advance(rptr[p]);
      end
    end
  end
  always_ff @(posedge clk)begin
    if(reset||clear)protocol_error<=0;
    else if(mismatch)protocol_error<=1;
  end
endmodule
