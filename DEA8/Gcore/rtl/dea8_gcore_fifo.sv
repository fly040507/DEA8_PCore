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
  // Same synchronous BRAM head-cache implementation as PCore. The shallow
  // receive queues intentionally spend RAM capacity to save U50 LUTs.
  dea8_ram_fifo #(.WIDTH(WIDTH),.DEPTH(DEPTH)) storage(
    .clk,.reset,.clear,.in_valid,.in_ready,.in_data,
    .out_valid,.out_ready,.out_data,.count(occupancy));
endmodule
