module dea8_gcore_tree8 (
  input logic clk,reset,clear,advance,input logic [7:0][31:0] data,
  output logic [31:0] result
);
  logic [3:0][31:0] first;
  logic [1:0][31:0] second;
  for(genvar i=0;i<4;i++)begin:a
    dea8_gcore_fp_add add(.clk,.reset,.clear,.advance,.a(data[2*i]),.b(data[2*i+1]),.result(first[i]));
  end
  for(genvar i=0;i<2;i++)begin:b
    dea8_gcore_fp_add add(.clk,.reset,.clear,.advance,.a(first[2*i]),.b(first[2*i+1]),.result(second[i]));
  end
  dea8_gcore_fp_add last(.clk,.reset,.clear,.advance,.a(second[0]),.b(second[1]),.result);
endmodule
