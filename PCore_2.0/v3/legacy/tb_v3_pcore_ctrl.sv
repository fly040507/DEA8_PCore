`timescale 1ns/1ps
import pcore3_pkg::*;
import pcore3_legacy_pkg::*;
module tb_v3_pcore_ctrl;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,job_done_valid,job_done_ready=0,busy,protocol_error;
  pcore_job_t job;pcore_completion_t job_done;job_header_t active_header;
  logic matrix_job_valid,matrix_job_ready=0,matrix_done_valid=0,matrix_done_ready;
  pcore_matrix_job_t matrix_job,matrix_done;
  logic pair_valid=0,pair_ready;logic [5:0] pair_n=0;logic [EPOCH_BITS-1:0] pair_epoch=1;logic [2:0] pair_head=2;
  logic vpu_job_valid,vpu_job_ready=0,vpu_done_valid=0,vpu_done_ready;
  pcore_vpu_job_t vpu_job,vpu_done;
  logic sfu_job_valid,sfu_job_ready=0,sfu_done_valid=0,sfu_done_ready;
  pcore_sfu_job_t sfu_job,sfu_done;
  logic qoz_begin_valid,qoz_begin_ready=0,z_tile_commit=0,qoz_complete=0,engine_error=0;
  logic [5:0] z_n=0;logic [EPOCH_BITS-1:0] z_epoch=1;logic [2:0] z_head=2;
  dea8_gu_ctrl_legacy #(.N_TILES(2)) dut(.*);
  task automatic launch(input pcore_op_e op,input int id);
    @(negedge clk);job.header='{job_id:16'(id),epoch:4'd1,head:3'd2,op:op};job_valid=1;
    do @(posedge clk);while(!job_ready);
    @(negedge clk);job_valid=0;
  endtask
  task automatic clean;
    @(negedge clk);clear=1;matrix_done_valid=0;vpu_done_valid=0;sfu_done_valid=0;
    pair_valid=0;z_tile_commit=0;qoz_complete=0;matrix_job_ready=0;vpu_job_ready=0;sfu_job_ready=0;
    @(negedge clk);clear=0;
  endtask
  task automatic begin_region;
    wait(qoz_begin_valid);repeat(3)@(negedge clk);
    if(!busy||job_ready||matrix_job_valid)$fatal(1,"region ownership not held");
    qoz_begin_ready=1;@(negedge clk);qoz_begin_ready=0;
  endtask
  initial begin
    job='0;repeat(5)@(negedge clk);reset=0;
    launch(OP_DOWN_PROJ,7);wait(job_done_valid);
    if(job_done.status!=JOB_UNSUPPORTED||job_done.header!==job.header)$fatal(1,"unsupported completion");
    repeat(3)@(negedge clk);job_done_ready=1;@(negedge clk);job_done_ready=0;
    launch(OP_GU,8);begin_region();
    for(int n=0;n<2;n++)begin
      wait(matrix_job_valid);matrix_done=matrix_job;
      repeat(4)begin @(negedge clk);if(matrix_job!==matrix_done)$fatal(1,"matrix descriptor changed under stall");end
      if(matrix_job.mode!=MAT_GU||matrix_job.n!=n||matrix_job.header.job_id!=8)$fatal(1,"subjob contract");
      matrix_job_ready=1;@(negedge clk);matrix_job_ready=0;
      repeat(4)@(negedge clk);matrix_done_valid=1;@(negedge clk);matrix_done_valid=0;
      pair_n=6'(n);pair_valid=1;do @(posedge clk);while(!pair_ready);@(negedge clk);pair_valid=0;
      wait(vpu_job_valid&&sfu_job_valid);vpu_done=vpu_job;sfu_done=sfu_job;
      repeat(4)begin @(negedge clk);if(vpu_job!==vpu_done||sfu_job!==sfu_done)$fatal(1,"post command changed under stall");end
      vpu_job_ready=1;sfu_job_ready=1;@(negedge clk);vpu_job_ready=0;sfu_job_ready=0;
      sfu_done_valid=1;@(negedge clk);sfu_done_valid=0;
      repeat(8)begin @(negedge clk);if(job_done_valid)$fatal(1,"operation ended at matrix/SFU done");end
      z_n=6'(n);z_tile_commit=1;@(negedge clk);z_tile_commit=0;
      repeat(3)@(negedge clk);vpu_done_valid=1;@(negedge clk);vpu_done_valid=0;
    end
    repeat(5)@(negedge clk);if(job_done_valid)$fatal(1,"operation ended before QOZ region complete");
    qoz_complete=1;wait(job_done_valid);
    if(job_done.header!==job.header||job_done.status!=JOB_OK||protocol_error)$fatal(1,"GU completion mismatch");
    repeat(7)begin @(negedge clk);if(!job_done_valid||job_ready)$fatal(1,"operation completion not held");end
    job_done_ready=1;@(negedge clk);job_done_ready=0;clean();
    // Wrong generation must fault and retain resources until explicit clear.
    launch(OP_GU,9);begin_region();wait(matrix_job_valid);matrix_done=matrix_job;
    @(negedge clk);matrix_job_ready=1;@(negedge clk);matrix_job_ready=0;
    matrix_done.header.job_id=10;matrix_done_valid=1;@(negedge clk);matrix_done_valid=0;
    if(!protocol_error||job_ready||job_done_valid)$fatal(1,"bad completion not quarantined");
    clean();#1;if(!job_ready||protocol_error)$fatal(1,"clear did not recover");
    $display("tb_v3_pcore_ctrl PASS unsupported=1 stall=1 commit_barrier=1 done_hold=1 wrong_job_id=1 clear=1");$finish;
  end
  initial begin #20000;$fatal(1,"PCore ctrl watchdog");end
endmodule
