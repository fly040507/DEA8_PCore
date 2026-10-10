module dea8_reduce_fifo #(
  parameter int WIDTH=32, DEPTH=2,
  localparam int PTR_BITS=(DEPTH>1)?$clog2(DEPTH):1,
  localparam int COUNT_BITS=$clog2(DEPTH+1)
)(
  input logic clk,reset,clear,
  input logic in_valid,output logic in_ready,input logic [WIDTH-1:0] in_data,
  output logic out_valid,input logic out_ready,output logic [WIDTH-1:0] out_data,
  output logic empty,output logic [COUNT_BITS-1:0] occupancy
);
  logic [WIDTH-1:0] storage[DEPTH];
  logic [PTR_BITS-1:0] rd_q,wr_q;
  logic push,pop;
  assign empty=occupancy==0;
  assign out_valid=!empty&&!reset&&!clear;
  assign out_data=storage[rd_q];
  assign pop=out_valid&&out_ready;
  assign in_ready=!reset&&!clear&&(occupancy<DEPTH||pop);
  assign push=in_valid&&in_ready;
  always_ff @(posedge clk)begin
    if(reset||clear)begin rd_q<=0;wr_q<=0;occupancy<=0;end
    else begin
      if(push)begin storage[wr_q]<=in_data;wr_q<=(wr_q==DEPTH-1)?'0:wr_q+1'b1;end
      if(pop)rd_q<=(rd_q==DEPTH-1)?'0:rd_q+1'b1;
      case({push,pop})
        2'b10:occupancy<=occupancy+1'b1;
        2'b01:occupancy<=occupancy-1'b1;
        default:;
      endcase
    end
  end
endmodule
