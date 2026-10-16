module dea8_gcore_quant8 (
  input logic clk,reset,clear,
  input logic in_valid,output logic in_ready,
  input logic [15:0][31:0] values,
  input logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] index,
  output logic out_valid,input logic out_ready,
  output logic [135:0] result,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] out_index,
  output logic numeric_fault
);
  import gcore_fp_pkg::*;
  logic busy_q,high_half,advance;
  logic [15:0][31:0] values_q;
  logic [7:0] scale_q;
  logic [3:0][30:0] maximum4;
  logic [7:0][7:0] quantized;
  logic bad;
  logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] index_q;
  for(genvar i=0;i<8;i++)assign quantized[i]=quant_lane(values_q[8*int'(high_half)+i],scale_q);
  always_comb begin
    bad=0;
    for(int q=0;q<4;q++)begin
      logic [3:0][30:0] group_values;
      for(int j=0;j<4;j++)begin group_values[j]=values[4*q+j][30:0];if(!finite32(values[4*q+j]))bad=1;end
      maximum4[q]=max4(group_values);
    end
  end
  assign advance=(!out_valid||out_ready)&&!reset&&!clear;
  assign in_ready=advance&&(!busy_q||high_half);
  always_ff @(posedge clk)begin
    if(reset||clear)begin busy_q<=0;high_half<=0;values_q<=0;scale_q<=0;result<=0;out_index<=0;index_q<=0;numeric_fault<=0;out_valid<=0;end
    else if(advance)begin
      out_valid<=0;
      if(busy_q&&!high_half)begin result[63:0]<=quantized;high_half<=1;end
      if(busy_q&&high_half)begin
        result[127:64]<=quantized;result[135:128]<=scale_q;out_index<=index_q;
        out_valid<=1;busy_q<=0;high_half<=0;
      end
      if(in_valid&&in_ready)begin
        values_q<=bad?'0:values;scale_q<=bad?8'b0:quant_scale(max4(maximum4));index_q<=index;
        numeric_fault<=numeric_fault||bad;busy_q<=1;high_half<=0;
      end
    end
  end
endmodule
