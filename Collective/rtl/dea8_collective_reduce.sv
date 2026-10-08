module dea8_collective_reduce(
  input logic clk,reset,clear,
  input logic in_valid,output logic in_ready,
  input logic [7:0][1023:0] in_data,
  input logic [10:0] in_sequence,
  output logic out_valid,input logic out_ready,
  output logic [1023:0] out_data,output logic [10:0] out_sequence,
  output logic empty
);
  import dea8_collective_pkg::*;
  logic advance;
  logic [TREE_STAGES-1:0] valid_q;
  logic [SEQ_BITS-1:0] sequence_q[TREE_STAGES];
  wire [31:0] first[4][LANES],second[2][LANES],third[LANES];
  assign out_valid=valid_q[TREE_STAGES-1]&&!reset&&!clear;
  assign out_sequence=sequence_q[TREE_STAGES-1];
  assign advance=(!out_valid||out_ready)&&!reset&&!clear;
  assign in_ready=advance;
  assign empty=!(|valid_q);
  always_ff @(posedge clk)begin
    if(reset||clear)valid_q<='0;
    else if(advance)begin
      valid_q<={valid_q[TREE_STAGES-2:0],in_valid};
      sequence_q[0]<=in_sequence;
      for(int i=1;i<TREE_STAGES;i++)sequence_q[i]<=sequence_q[i-1];
    end
  end
  for(genvar lane=0;lane<LANES;lane++)begin:lanes
    for(genvar node=0;node<4;node++)begin:l1
      dea8_collective_fp_add add(.clk,.advance,
        .a(in_data[2*node][32*lane+:32]),.b(in_data[2*node+1][32*lane+:32]),.result(first[node][lane]));
    end
    for(genvar node=0;node<2;node++)begin:l2
      dea8_collective_fp_add add(.clk,.advance,
        .a(first[2*node][lane]),.b(first[2*node+1][lane]),.result(second[node][lane]));
    end
    dea8_collective_fp_add add(.clk,.advance,.a(second[0][lane]),.b(second[1][lane]),.result(third[lane]));
    assign out_data[32*lane+:32]=third[lane];
  end
endmodule
