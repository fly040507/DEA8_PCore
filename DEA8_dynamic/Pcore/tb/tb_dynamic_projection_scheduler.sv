`timescale 1ns/1ps
import pcore_pkg::*;
// Protocol-only scheduler test. Matrix retirement is modeled, not arithmetic.
module tb_dynamic_projection_scheduler;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,start_valid=0,start_ready;
  pcore_job_t context_job='0;job_token_t context_token=32'h11112222;
  logic [ROW_COUNT_BITS-1:0] context_rows=11;
  logic matrix_valid,matrix_ready,matrix_done=0,matrix_done_ready;
  capture_desc_t capture_desc,captured='0;
  compute_job_t matrix_job;
  logic capture_valid,capture_ready=0,capture_done=0,done,protocol_error;
  dea8_projection_scheduler dut(.*);
  int works=0,captures=0,cases=0,cycle=0,delay_count=0,read_delay=0;
  capture_desc_t reading_owner;
  operation_profile_t contract;
  assign matrix_ready=delay_count==0&&!matrix_done&&cycle%5!=2;
  always @(posedge clk)begin
    cycle++;
    if(reset||clear)begin delay_count=0;read_delay=0;matrix_done<=0;capture_done<=0;capture_ready<=0;end
    else begin
      capture_done<=0;
      if(delay_count>0)begin delay_count--;if(delay_count==0)matrix_done<=1;end
      if(matrix_done&&matrix_done_ready)matrix_done<=0;
      if(matrix_valid&&matrix_ready)begin
        if(matrix_job.work_seq!=works||matrix_job.tiles!=contract.k_tiles||matrix_job.m_rows!=context_rows||
          matrix_job.nt!=(context_job.op==OP_Q_PROJ?works/2+(works%2)*8:works)||
          matrix_job.acc_sel!=acc_sel_e'(works%2))$fatal(1,"Projection work identity");
        works++;delay_count=3;
      end
      if(capture_valid&&capture_ready)begin
        if(capture_desc.token!=context_token||capture_desc.rows!=context_rows||capture_desc.work_seq!=captures||
          capture_desc.sel!=acc_sel_e'(captures%2))
          $fatal(1,"Projection capture owner got=%h owner0=%h owner1=%h committed=%b selected=%b",capture_desc,dut.owners[0],dut.owners[1],dut.committed,dut.selected);
        reading_owner=capture_desc;captures++;read_delay=4;capture_ready<=0;
      end
      if(read_delay>0)begin
        read_delay--;if(read_delay==0)begin captured<=reading_owner;capture_done<=1;end
      end else if(!capture_done)capture_ready<=cycle%4!=1;
      if(protocol_error)$fatal(1,"Projection scheduler protocol");
    end
  end
  task automatic run_case(input pcore_op_e op);
    @(negedge clk);clear=1;@(negedge clk);clear=0;context_job.op=op;
    contract=operation_profile(op);works=0;captures=0;start_valid=1;
    @(posedge clk);if(!start_ready)$fatal(1,"Projection scheduler start");
    @(negedge clk);start_valid=0;while(!done)@(negedge clk);
    if(works!=contract.n_tiles||captures!=works)$fatal(1,"Projection scheduler counts");
    repeat(3)begin @(negedge clk);if(!done)$fatal(1,"Projection done not held");end
    cases++;
  endtask
  initial begin
    repeat(32)@(negedge clk);reset=0;
    run_case(OP_Q_PROJ);run_case(OP_K_PROJ);run_case(OP_V_PROJ);run_case(OP_O_PROJ);run_case(OP_DOWN_PROJ);
    $display("tb_dynamic_projection_scheduler PASS geometries=%0d canonical_Q_order=1 alternating_FACC=1 two_bank_owner=1 retirement=1",cases);$finish;
  end
  initial begin #100000;$fatal(1,"Projection scheduler watchdog");end
endmodule
