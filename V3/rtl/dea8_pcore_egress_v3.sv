import pcore_control_pkg::*;

module dea8_pcore_egress_v3(
  input logic clk,reset,clear,
  input logic in_valid,output logic in_ready,input collective_packet_t in_packet,
  output logic out_valid,input logic out_ready,output collective_packet_t out_packet,
  output logic empty
);
  collective_packet_t entries[0:1];
  logic rd_q,wr_q;
  logic [1:0] count_q;
  logic push,pop;
  assign out_valid=count_q!=0&&!reset&&!clear;
  assign out_packet=entries[rd_q];
  assign pop=out_valid&&out_ready;
  assign in_ready=!reset&&!clear&&(count_q<2||pop);
  assign push=in_valid&&in_ready;
  assign empty=count_q==0;
  always_ff @(posedge clk)begin
    if(reset||clear)begin rd_q<=0;wr_q<=0;count_q<=0;end
    else begin
      if(push)begin entries[wr_q]<=in_packet;wr_q<=!wr_q;end
      if(pop)rd_q<=!rd_q;
      case({push,pop})
        2'b10:count_q<=count_q+1'b1;
        2'b01:count_q<=count_q-1'b1;
        default:;
      endcase
    end
  end
endmodule
