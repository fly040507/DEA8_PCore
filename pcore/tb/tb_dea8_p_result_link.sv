`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;
module tb_dea8_p_result_link;
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,init=0,job_start=0,job_end=0,sfu_p_valid=0,sfu_p_ready,vpu_p_valid,vpu_p_ready=0;
  job_context_t job_ctx;
  p_result_t sfu_p_data,vpu_p_data,held;
  int sent=0,received=0,cycles=0;
  bit was_stalled=0,wrong_epoch,input_accepted=0;
  dea8_p_result_link dut (.*);
  always @(posedge clk) if(rst_n) begin
    cycles++;
    if(was_stalled && (!vpu_p_valid || vpu_p_data!==held)) $fatal(1,"P payload not held under backpressure");
    was_stalled=vpu_p_valid && !vpu_p_ready;held=vpu_p_data;
    input_accepted=sfu_p_valid && sfu_p_ready;
    if(input_accepted) sent++;
    if(vpu_p_valid && vpu_p_ready) begin
      if(vpu_p_data.data!==64'(received)) $fatal(1,"P value lost or repeated");
      received++;
    end
  end
  initial begin
    wrong_epoch=$test$plusargs("WRONG_EPOCH");
    job_ctx='{block_id:6'd3,head:3'd2,epoch:4'd5};sfu_p_data='0;
    repeat(3) @(negedge clk);rst_n=1;job_start=1;
    @(negedge clk);job_start=0;
    if($test$plusargs("EARLY_DONE")) begin job_end=1;@(negedge clk);$fatal(1,"Missing P completion assertion");end
    while(received<SUFFIX_LEN*PAIRS_PER_ROW) begin
      vpu_p_ready=cycles%7!=0 && cycles%7!=1;
      if(!sfu_p_valid || input_accepted) begin
        sfu_p_valid=sent<SUFFIX_LEN*PAIRS_PER_ROW && cycles%5!=0;
        sfu_p_data.ctx=job_ctx;
        if(wrong_epoch) sfu_p_data.ctx.epoch=0;
        sfu_p_data.row=ROW_BITS'(sent/PAIRS_PER_ROW);
        sfu_p_data.pair_index=PAIR_BITS'(sent%PAIRS_PER_ROW);
        sfu_p_data.lane_mask='1;sfu_p_data.data=64'(sent);
        sfu_p_data.last=sent==SUFFIX_LEN*PAIRS_PER_ROW-1;
      end
      @(negedge clk);
    end
    sfu_p_valid=0;job_end=1;
    @(negedge clk);job_end=0;
    if(sent!=received) $fatal(1,"P accepted/delivered count mismatch");
    rst_n=0;@(negedge clk);
    if(vpu_p_valid || sfu_p_ready) $fatal(1,"P reset failed");
    $display("tb_dea8_p_result_link PASS: 408 pairs, producer/consumer stalls, metadata and reset");
    $finish;
  end
  initial begin #50000;$fatal(1,"P link timeout");end
endmodule
