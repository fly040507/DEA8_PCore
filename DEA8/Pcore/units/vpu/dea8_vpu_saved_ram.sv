// Two physical RAM ports: each writes one RoPE half, or reads one row.
// Payload is never reset; TOP invalidates request metadata on reset/flush.
module dea8_vpu_saved_ram(
 input logic clk,lo_we,hi_we,rd_en,
 input logic [5:0] lo_row,hi_row,
 input logic [511:0] lo_data,hi_data,
 input logic rd_half,input logic [4:0] rd_pair,
 output logic [1:0][15:0][31:0] rd_data
);
 (* ram_style="block" *) logic [511:0] mem[0:127];
 wire [6:0] ra={rd_half,rd_pair,1'b0};
 wire [6:0] rb={rd_half,rd_pair,1'b1};
 wire [6:0] aa=lo_we?{1'b0,lo_row}:ra;
 wire [6:0] ab=hi_we?{1'b1,hi_row}:rb;
 // Each BRAM port has one address for its read and write operation.
 always_ff @(posedge clk)if(lo_we||rd_en)begin
  if(lo_we)mem[aa]<=lo_data;
  rd_data[0]<=mem[aa];
 end
 always_ff @(posedge clk)if(hi_we||rd_en)begin
  if(hi_we)mem[ab]<=hi_data;
  rd_data[1]<=mem[ab];
 end
 // synthesis translate_off
 always @(posedge clk)if(rd_en)assert(!lo_we&&!hi_we)else $fatal(1,"saved RAM phase collision");
 // synthesis translate_on
endmodule
