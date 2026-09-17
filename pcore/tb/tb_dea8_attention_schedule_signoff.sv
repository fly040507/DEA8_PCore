`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// Focused schedule acceptance over the REAL core/queue/FIFO/MXU/DEQACC.
// Reuse the existing external behavioral clients; no timer-only matrix stub.
module tb_dea8_attention_schedule_signoff;
  tb_dea8_attention_core #(.SOFTMAX_MODEL(1),.SCHEDULE_SIGNOFF(1)) test();
  localparam int WORDS=HEAD_TILES*SUFFIX_LEN;
  int cycle=0,top_cycle=0,launches=0,finishes=0,issues=0,commits=0;
  int job_issues=0,job_commits=0,tiles=0,previous_done=0,normal_intervals=0;
  int logfd;
  function automatic matrix_op_e expected_op(input int job_index);
    return (job_index==0 || (job_index%2==1 && job_index!=MATRIX_JOB_COUNT-1)) ? MATRIX_QK : MATRIX_PV;
  endfunction
  function automatic int expected_block(input int job_index);
    if(job_index==0) return 0;
    if(job_index==MATRIX_JOB_COUNT-1) return N_KV_BLOCK-1;
    return job_index%2==1 ? (job_index+1)/2 : job_index/2-1;
  endfunction
  initial begin
    logfd=$fopen("attention_schedule_signoff.csv","w");
    $fdisplay(logfd,"job,op,block,head,epoch,issues,commits,done,interval");
  end
  always @(posedge test.clk) begin : check_schedule
    int expected_tile,expected_row,interval;
    cycle++;
    if(test.rst_n) begin
      if(test.start_valid && test.start_ready) top_cycle=cycle;
      if(test.dut.matrix_valid && test.dut.matrix_ready) begin
        if(test.dut.matrix_cmd.op!=expected_op(launches) ||
           test.dut.matrix_cmd.ctx.block_id!=expected_block(launches) ||
           test.dut.matrix_cmd.ctx.head!=test.start_head || test.dut.matrix_cmd.ctx.epoch!=test.start_epoch)
          $fatal(1,"Schedule signoff launch order/context mismatch");
        launches++;
      end
      if(test.dut.matrix.engine.load_valid && test.dut.matrix.engine.load_weight_idx==TILE-1) tiles++;
      if(test.dut.matrix.engine.req_valid && test.dut.matrix.engine.req_ready) begin
        expected_tile=job_issues/SUFFIX_LEN;expected_row=job_issues%SUFFIX_LEN;
        if(expected_tile>=HEAD_TILES || test.dut.matrix.engine.req_tag.row!=expected_row ||
           test.dut.matrix.engine.req_tag.head!=test.start_head || test.dut.matrix.engine.req_tag.epoch!=test.start_epoch ||
           test.current_job.op!=expected_op(finishes) || test.current_job.ctx.block_id!=expected_block(finishes) ||
           test.dut.matrix.engine.req_tag.last!=(job_issues==WORDS-1))
          $fatal(1,"Schedule signoff issue row/context mismatch");
        if(expected_op(finishes)==MATRIX_QK) begin
          if(test.dut.matrix.engine.req_tag.kt!=expected_tile || test.dut.matrix.engine.req_tag.nt!=0)
            $fatal(1,"Schedule signoff QK tile order");
        end else if(test.dut.matrix.engine.req_tag.nt!=expected_tile || test.dut.matrix.engine.req_tag.kt!=0)
          $fatal(1,"Schedule signoff PV tile order");
        job_issues++;issues++;
      end
      if(test.commit_valid) begin
        if(test.commit_tag.row!=job_commits%SUFFIX_LEN ||
           test.commit_tag.last!=(job_commits==WORDS-1) || test.commit_tag.head!=test.start_head ||
           test.commit_tag.epoch!=test.start_epoch) $fatal(1,"Schedule signoff commit order/context");
        job_commits++;commits++;
      end
      if(test.dut.matrix_done_valid && test.dut.matrix_done_ready) begin
        interval=previous_done==0 ? cycle-top_cycle : cycle-previous_done;
        if(job_issues!=WORDS || job_commits!=WORDS || test.current_job.op!=expected_op(finishes) ||
           test.current_job.ctx.block_id!=expected_block(finishes) || test.current_job.ctx.head!=test.start_head ||
           test.current_job.ctx.epoch!=test.start_epoch) $fatal(1,"Schedule signoff incomplete matrix job");
        if(finishes==0 && interval!=844) $fatal(1,"Schedule signoff cold budget");
        if(finishes>0 && finishes<MATRIX_JOB_COUNT-1) begin
          if(interval!=828 || interval>=850) $fatal(1,"Schedule signoff ordinary interval");
          normal_intervals++;
        end
        if(finishes==MATRIX_JOB_COUNT-1 && interval!=1656) $fatal(1,"Schedule signoff tail interval");
        $fdisplay(logfd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",finishes,
          test.current_job.op,test.current_job.ctx.block_id,test.current_job.ctx.head,test.current_job.ctx.epoch,
          job_issues,job_commits,cycle-top_cycle,interval);
        finishes++;previous_done=cycle;job_issues=0;job_commits=0;
        if(finishes==MATRIX_JOB_COUNT) begin
          if(launches!=110 || issues!=89760 || commits!=89760 || tiles!=1760 || normal_intervals!=108 ||
             cycle-top_cycle!=91924) $fatal(1,"Schedule signoff totals");
          $display("tb_dea8_attention_schedule_signoff PASS: 55 blocks,110 jobs,1760 tiles,89760 issues/commits; cold844 normal828 tail1656 final91924");
          $fclose(logfd);
        end
      end
    end
  end
endmodule
