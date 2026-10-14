// 16 columns x 8 sources. Each node retains the existing 4-stage FP32 adder.
module dea8_reduce_tree(
  input logic clk,reset,clear,
  input logic in_valid,output logic in_ready,
  input logic [7:0][511:0] in_data,input logic [5:0] in_row,
  output logic out_valid,input logic out_ready,
  output logic [511:0] out_data,output logic [5:0] out_row,
  output logic empty
);
  localparam int STAGES=12;
  logic advance;
  logic [STAGES-1:0] valid_q;
  logic [5:0] row_q[0:STAGES-1];
  wire [31:0] first[0:3][0:15],second[0:1][0:15],third[0:15];
  assign out_valid=valid_q[STAGES-1]&&!reset&&!clear;
  assign out_row=row_q[STAGES-1];
  assign advance=(!out_valid||out_ready)&&!reset&&!clear;
  assign in_ready=advance;
  assign empty=!(|valid_q);
  always_ff @(posedge clk)begin
    if(reset||clear)valid_q<='0;
    else if(advance)begin
      valid_q<={valid_q[STAGES-2:0],in_valid};
      row_q[0]<=in_row;
      for(int i=1;i<STAGES;i++)row_q[i]<=row_q[i-1];
    end
  end
  for(genvar lane=0;lane<16;lane++)begin:lane_gen
    for(genvar node=0;node<4;node++)begin:first_gen
      dea8_reduce_fp_add add(.clk,.advance,
        .a(in_data[2*node][32*lane+:32]),.b(in_data[2*node+1][32*lane+:32]),
        .result(first[node][lane]));
    end
    for(genvar node=0;node<2;node++)begin:second_gen
      dea8_reduce_fp_add add(.clk,.advance,
        .a(first[2*node][lane]),.b(first[2*node+1][lane]),.result(second[node][lane]));
    end
    dea8_reduce_fp_add add(.clk,.advance,.a(second[0][lane]),.b(second[1][lane]),.result(third[lane]));
    assign out_data[32*lane+:32]=third[lane];
  end
endmodule
