module dea8_gcore_fifo #(
  parameter int WIDTH=256,DEPTH=4,
  localparam int PTR_BITS=DEPTH>1?$clog2(DEPTH):1,
  localparam int COUNT_BITS=$clog2(DEPTH+1)
) (
  input logic clk,reset,clear,
  input logic in_valid,output logic in_ready,input logic [WIDTH-1:0] in_data,
  output logic out_valid,input logic out_ready,output logic [WIDTH-1:0] out_data,
  output logic [COUNT_BITS-1:0] occupancy
);
  (* ram_style="distributed" *) logic [WIDTH-1:0] memory[DEPTH];
  logic [PTR_BITS-1:0] head,tail;
  logic push,pop;
  assign out_valid=occupancy!=0&&!reset&&!clear;
  assign out_data=memory[head];
  assign pop=out_valid&&out_ready;
  assign in_ready=!reset&&!clear&&(occupancy<DEPTH||pop);
  assign push=in_valid&&in_ready;
  always_ff @(posedge clk) begin
    if(push)memory[tail]<=in_data;
    if(reset||clear)begin head<=0;tail<=0;occupancy<=0;end
    else begin
      if(push)tail<=tail==DEPTH-1?'0:tail+1'b1;
      if(pop)head<=head==DEPTH-1?'0:head+1'b1;
      case({push,pop})2'b10:occupancy<=occupancy+1'b1;2'b01:occupancy<=occupancy-1'b1;default:;endcase
    end
  end
endmodule
