`timescale 1ns/1ps
import pcore3_pkg::*;
import dea8_fp32_v3_pkg::*;

module tb_v3_deqacc32;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0,rsp_valid;
  mxu_rsp_t rsp;
  logic commit_valid,done; pair_meta_t commit_meta;
  logic dbg_valid,dbg_parity; acc_sel_e dbg_sel; logic [9:0] dbg_addr; logic [3:0] dbg_lane; logic [31:0] dbg_data;
  int commits;
  dea8_deqacc32_v3 dut(.clk,.reset,.clear,.rsp_valid,.rsp,.commit_valid,.done,.commit_meta,
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);
  // Sample after NBA updates; commit_valid is the stage-4 registered output.
  always @(posedge clk) #1 if(commit_valid) commits++;
  initial begin
    rsp_valid=0;commits=0;dbg_valid=0;dbg_sel=ACC_FACC_A;dbg_parity=0;dbg_addr=0;dbg_lane=0;
    repeat(20) @(negedge clk);reset=0;
    for(int p=0;p<PAIRS;p++) begin
      @(negedge clk);rsp_valid=1;rsp='0;rsp.row_valid=row_mask(p);
      rsp.e_stream[0]=128;rsp.e_stream[1]=128;
      for(int n=0;n<16;n++) rsp.e_stat[n]=128;
      rsp.meta.epoch=1;rsp.meta.head=0;rsp.meta.tile_idx=0;rsp.meta.pair_idx=p;rsp.meta.nt=0;
      rsp.meta.final_k=1;rsp.meta.last=p==PAIRS-1;rsp.meta.exp_fold=0;rsp.meta.acc_sel=ACC_FACC_A;rsp.meta.acc_clear=p==0;
      for(int r=0;r<2;r++) for(int n=0;n<16;n++) rsp.psum[r][n]=32'sd16;
      @(posedge clk);
    end
    @(negedge clk);rsp_valid=0;
    wait(done);#1;
    if(commits!=PAIRS) $fatal(1,"DEQACC commit count=%0d",commits);
    dbg_valid=1;dbg_sel=ACC_FACC_A;dbg_parity=0;dbg_addr=0;dbg_lane=0;#1;
    if(dbg_data!==pack_scaled32(0,32'h80000000,-6,0,0)) $fatal(1,"FACC even value mismatch %h",dbg_data);
    dbg_parity=1;#1;
    if(dbg_data!==pack_scaled32(0,32'h80000000,-6,0,0)) $fatal(1,"FACC odd value mismatch %h",dbg_data);
    $display("tb_v3_deqacc32 PASS commits=%0d latency=5",commits);
    $finish;
  end
  initial begin #100000;$fatal(1,"v3 DEQACC watchdog"); end
endmodule
