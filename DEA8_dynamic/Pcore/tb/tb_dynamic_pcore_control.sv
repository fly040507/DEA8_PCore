`timescale 1ns/1ps
import pcore_pkg::*;
module tb_dynamic_pcore_control;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,profile_valid=1,precondition_ok=1;
  pcore_job_t job='0,context_job;job_token_t context_token;
  logic [ROW_COUNT_BITS-1:0] profile_rows=11,context_rows;
  logic [15:0] profile_id=7,profile_version=9;
  logic [6:0] implemented_ops='1;
  logic [2:0] start_valid,start_ready='1,flush_ack=0;
  logic engine_done=0,fault=0,busy,flush_request,completion_valid,completion_ready=0;
  job_token_t engine_token=0;pcore_completion_t completion;
  dea8_pcore_control dut(.*);
  int jobs=0,dispatches=0,rejections=0;
  operation_profile_t op_profile;
  task automatic submit(input pcore_op_e op,input logic [2:0] core=0,input int position=0,input int layout1=-1);
    @(negedge clk);job='0;job.op=op;job.job_id=16'(jobs+10);job.user_tag=32'hffe00000+32'(jobs);
    job.profile_id=7;job.profile_version=9;job_valid=1;
    job.core_id=core;job.position_base=16'(position);
    job.kv_column_base1=op==OP_K_PROJ?16'd128:16'd16;
    if(layout1>=0)job.kv_column_base1=16'(layout1);
    @(posedge clk);if(!job_ready)$fatal(1,"Control refused job jobs=%0d op=%0d state=%0d completion=%0d cancel=%0d",jobs,op,dut.state,completion_valid,dut.cancel_pending);
    @(negedge clk);job_valid=0;jobs++;
  endtask
  task automatic expect_completion(input pcore_status_e status,input bit empty);
    pcore_completion_t held;
    while(!completion_valid)@(negedge clk);
    held=completion;
    if(held.status!=status||held.empty!=empty||held.job_id!=job.job_id||held.user_tag!=job.user_tag||held.op!=job.op)
      $fatal(1,"Control completion identity/status got=%0d expected=%0d",held.status,status);
    repeat(3)begin @(negedge clk);if(!completion_valid||completion!==held||job_ready)$fatal(1,"Control completion hold");end
    completion_ready=1;@(negedge clk);completion_ready=0;
  endtask
  task automatic flush;
    @(negedge clk);clear=1;flush_ack=0;
    @(negedge clk);clear=0;
    repeat(3)begin @(negedge clk);if(!flush_request||job_ready)$fatal(1,"Control skipped flush ack");end
    flush_ack=3'b011;repeat(2)begin @(negedge clk);if(!flush_request)$fatal(1,"Control ignored missing SFU ack");end
    flush_ack=3'b111;@(negedge clk);fault=0;engine_done=0;
  endtask
  initial begin
    repeat(32)@(negedge clk);reset=0;
    for(int op=0;op<7;op++)begin
      submit(pcore_op_e'(op));while(start_valid==0)@(negedge clk);
      op_profile=operation_profile(pcore_op_e'(op));
      if(start_valid!==(3'b001<<op_profile.mode))
        $fatal(1,"Control mode dispatch");
      if(context_rows!=(op==OP_K_PROJ||op==OP_V_PROJ?51:11))$fatal(1,"Control effective M");
      dispatches++;@(negedge clk);engine_token=context_token;engine_done=1;
      @(negedge clk);engine_done=0;expect_completion(PCORE_OK,0);
    end
    profile_rows=0;submit(OP_ATTENTION);expect_completion(PCORE_OK,1);
    profile_rows=11;implemented_ops=1;submit(OP_GU);expect_completion(PCORE_UNSUPPORTED,0);rejections++;
    precondition_ok=0;submit(OP_Q_PROJ);expect_completion(PCORE_PRECONDITION,0);rejections++;precondition_ok=1;
    profile_valid=0;submit(OP_Q_PROJ);expect_completion(PCORE_PRECONDITION,0);rejections++;profile_valid=1;
    submit(pcore_op_e'(7));expect_completion(PCORE_INVALID,0);rejections++;
    submit(OP_Q_PROJ,1);expect_completion(PCORE_INVALID,0);rejections++;
    submit(OP_Q_PROJ,0,65500);expect_completion(PCORE_INVALID,0);rejections++;
    submit(OP_K_PROJ,0,0,112);expect_completion(PCORE_INVALID,0);rejections++;
    submit(OP_V_PROJ,0,0,32);expect_completion(PCORE_INVALID,0);rejections++;
    submit(OP_Q_PROJ);while(start_valid==0)@(negedge clk);@(negedge clk);
    engine_token=context_token+1;engine_done=1;@(negedge clk);engine_done=0;
    expect_completion(PCORE_FAULT,0);repeat(3)begin @(negedge clk);if(job_ready||completion_valid)$fatal(1,"Fault completion repeated or job restarted");end
    flush();submit(OP_Q_PROJ);while(start_valid==0)@(negedge clk);@(negedge clk);
    flush();expect_completion(PCORE_CANCELLED,0);
    submit(OP_Q_PROJ);while(start_valid==0)@(negedge clk);@(negedge clk);engine_token=context_token;engine_done=1;
    @(negedge clk);engine_done=0;expect_completion(PCORE_OK,0);
    submit(OP_Q_PROJ);while(start_valid==0)@(negedge clk);@(negedge clk);engine_token=context_token;engine_done=1;
    @(negedge clk);engine_done=0;while(!completion_valid)@(negedge clk);fault=1;
    expect_completion(PCORE_OK,0);repeat(3)begin @(negedge clk);if(completion_valid||job_ready)$fatal(1,"Late fault duplicated completion");end
    flush();
    fault=1;repeat(3)begin @(negedge clk);if(completion_valid||job_ready)$fatal(1,"Idle fault invented a job completion");end
    flush();
    $display("tb_dynamic_pcore_control PASS jobs=%0d decoded_modes=%0d negative_checks=%0d wrong_done=1 flush_ack=1 cancel=1 completion_hold=1 late_fault_no_duplicate=1 idle_fault_no_job=1",jobs,dispatches,rejections);
    $finish;
  end
  initial begin #100000;$fatal(1,"Control watchdog");end
endmodule
