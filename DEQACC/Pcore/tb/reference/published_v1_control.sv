import pcore_pkg::*;
import deqacc_v1_pkg::*;

module published_v1_control(
  input logic clk,reset,clear,in_valid,input mxu_rsp_t rsp,
  output logic generation,
  output logic [5:0] valid_pipe,
  output pair_meta_t meta_pipe[0:5],
  output logic [5:0][1:0] rows_pipe,
  output logic commit_valid,done,output pair_meta_t commit_meta
);
  always_ff @(posedge clk)begin
    meta_pipe[0]<=rsp.meta;
    rows_pipe[0]<=rsp.row_valid;
    for(int s=1;s<6;s++)meta_pipe[s]<=meta_pipe[s-1];
    for(int s=1;s<6;s++)rows_pipe[s]<=rows_pipe[s-1];
    commit_meta<=meta_pipe[5];
    if(reset)generation<=0;
    else if(clear)generation<=!generation;
    if(reset||clear)begin valid_pipe<=0;commit_valid<=0;done<=0;end
    else begin
      valid_pipe<={valid_pipe[4:0],in_valid};
      commit_valid<=valid_pipe[5];done<=valid_pipe[5]&&meta_pipe[5].last;
    end
  end
endmodule
