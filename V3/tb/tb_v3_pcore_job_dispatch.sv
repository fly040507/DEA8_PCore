`timescale 1ns/1ps
import pcore3_pkg::*;
module tb_v3_pcore_job_dispatch;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,job_done_valid,job_done_ready=0;
  pcore_job_t job,adapter_job;pcore_completion_t job_done,adapter_done[0:2];
  logic busy,protocol_error,operation_clear,fabric_error=0;logic [1:0] owner;
  logic [2:0] adapter_valid,adapter_ready=0,adapter_done_valid=0,adapter_done_ready,adapter_error=0;
  int accepts=0;
  dea8_pcore_ctrl_v3 dut(.*);
  always @(posedge clk)if(job_valid&&job_ready)accepts++;
  task automatic send(input pcore_op_e op,input int id);
    @(negedge clk);job.header='{job_id:16'(id),epoch:4'd5,head:3'd2,op:op};job_valid=1;
    do @(posedge clk);while(!job_ready);@(negedge clk);job_valid=0;
  endtask
  task automatic recover;
    @(negedge clk);clear=1;adapter_done_valid=0;adapter_ready=0;job_valid=0;adapter_error=0;fabric_error=0;
    @(negedge clk);clear=0;#1;
    if(!job_ready||protocol_error)$fatal(1,"dispatch clear recovery");
  endtask
  initial begin
    job='0;for(int i=0;i<3;i++)adapter_done[i]='0;
    repeat(5)@(negedge clk);reset=0;
    for(int i=0;i<3;i++)begin
      pcore_job_t held;
      send(i==0?OP_Q_PROJ:i==1?OP_ATTENTION:OP_GU,100+i);held=job;
      repeat(8)begin
        @(negedge clk);
        if(adapter_valid!==(3'b001<<i)||adapter_job!==held||owner!=i||job_ready||!busy)$fatal(1,"adapter dispatch/hold");
      end
      adapter_ready=3'b001<<i;@(negedge clk);adapter_ready=0;
      // A second Operation presented while busy must not be accepted.
      job_valid=1;job.header.job_id=999;
      repeat(9)begin @(negedge clk);if(job_ready||adapter_valid||adapter_job!==held)$fatal(1,"multiple operations in flight");end
      job_valid=0;
      adapter_done[i]='{header:held.header,status:JOB_OK};adapter_done_valid=3'b001<<i;
      do @(posedge clk);while(!adapter_done_ready[i]);@(negedge clk);adapter_done_valid=0;
      wait(job_done_valid);
      repeat(7)begin @(negedge clk);if(!job_done_valid||job_done!==adapter_done[i]||job_ready)$fatal(1,"completion hold/context");end
      job_done_ready=1;@(negedge clk);job_done_ready=0;
    end
    if(accepts!=3)$fatal(1,"accepted duplicate job");
    send(OP_DOWN_PROJ,104);wait(job_done_valid);
    if(job_done.status!=JOB_UNSUPPORTED||adapter_valid)$fatal(1,"unsupported operation dispatch");
    job_done_ready=1;@(negedge clk);job_done_ready=0;
    for(int bad=0;bad<2;bad++)begin
      send(OP_GU,200+bad);adapter_ready=4;@(negedge clk);adapter_ready=0;
      if(bad==0)begin adapter_done[2]='{header:job.header,status:JOB_OK};adapter_done[2].header.job_id=999;adapter_done_valid=4;end
      else begin adapter_done[0]='{header:job.header,status:JOB_OK};adapter_done_valid=1;end
      @(negedge clk);adapter_done_valid=0;#1;
      if(!protocol_error||job_ready||job_done_valid||!busy)$fatal(1,"bad completion escaped FAULT");
      recover();
    end
    for(int bad=0;bad<2;bad++)begin
      send(OP_GU,300+bad);adapter_ready=4;@(negedge clk);adapter_ready=0;
      adapter_error=1;
      repeat(3)begin @(negedge clk);if(protocol_error||job_done_valid||!adapter_done_ready[2])$fatal(1,"inactive adapter error affected owner");end
      adapter_error=bad==0?4:0;fabric_error=bad==1;
      repeat(3)begin @(negedge clk);if(!protocol_error||job_ready||job_done_valid||adapter_valid||adapter_done_ready)$fatal(1,"error escaped FAULT");end
      recover();
    end
    $display("tb_v3_pcore_job_dispatch PASS serial_ops=3 single_owner=1 stalled_commands=1 done_hold=1 wrong_context=1 wrong_adapter=1 unsupported=1 active_error=1 inactive_error_isolated=1 fabric_fault_clear=1");$finish;
  end
  initial begin #10000;$fatal(1,"dispatch watchdog");end
endmodule
