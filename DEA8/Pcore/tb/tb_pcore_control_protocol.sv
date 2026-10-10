`timescale 1ns/1ps
import pcore_pkg::*;
import pcore_control_pkg::*;
module tb_pcore_control_protocol;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,done_valid,done_ready=0,busy,protocol_error;
  control_job_t job;control_completion_t done;
  logic flush_valid,vpu_flush_ack=0,sfu_flush_ack=0;
  logic bad_result=0,result_ready,kv_out_valid;
  control_quant_result_t vector_result;
  control_completion_t completion_hold;
  dea8_pcore_control dut(.clk,.reset,.clear,.job_valid,.job_ready,.job,.done_valid,.done_ready,.done,
    .busy,.protocol_error,.active_adapter(),.flush_valid,.vpu_flush_ack,.sfu_flush_ack,
    .xbc_valid(1'b0),.xbc_entry('0),.xbc_ready(),.hbm_valid(1'b0),.hbm_entry('0),.hbm_ready(),
    .kv_valid(1'b0),.kv_entry('0),.kv_ready(),.vector_valid(),.vector_ready(1'b0),.vector_cmd(),
    .vector_done_valid(1'b0),.vector_done_ready(),.vector_done('0),
    .function_valid(),.function_ready(1'b0),.function_cmd(),.function_done_valid(1'b0),.function_done_ready(),.function_done('0),
    .vector_data_valid(),.vector_data_ready(1'b0),.vector_data(),
    .function_data_valid(),.function_data_ready(1'b0),.function_data(),
    .function_result_valid(1'b0),.function_result_ready(),.function_result('0),
    .vector_result_valid(bad_result),.vector_result_ready(result_ready),.vector_result,
    .vector_mem_valid(1'b0),.vector_mem_req('0),.vector_mem_ready(),.vector_mem_out_valid(),.vector_mem_out_ready(1'b0),.vector_mem_out(),
    .function_mem_valid(1'b0),.function_mem_req('0),.function_mem_ready(),.function_mem_out_valid(),.function_mem_out_ready(1'b0),.function_mem_out(),
    .rope_req_valid(1'b0),.rope_req_ready(),.rope_req('0),.rope_sfu_valid(),.rope_sfu_ready(1'b0),.rope_sfu_req(),
    .rope_sfu_out_valid(1'b0),.rope_sfu_out_ready(),.rope_sfu_out('0),.rope_out_valid(),.rope_out_ready(1'b0),.rope_out(),
    .kv_out_valid,.kv_out_ready(1'b1),.kv_out(),.kv_out_last(),
    .kv_hdr_valid(),.kv_hdr_ready(1'b1),.kv_hdr(),.kv_commit_valid(1'b0),.kv_commit_ready(),.kv_commit('0),
    .reduce_hdr_valid(),.reduce_hdr_ready(1'b1),.reduce_hdr(),
    .reduce_out_valid(),.reduce_out_ready(1'b1),.reduce_out(),.reduce_out_last(),
    .acc_rd_valid(1'b0),.acc_rd_ready(),.acc_rd_sel(ACC_OACC),.acc_rd_addr('0),.acc_token('0),
    .acc_data_valid(),.acc_data_ready(1'b0),.acc_even(),.acc_odd(),.acc_wr_valid(1'b0),.acc_wr_ready(),.acc_wr('0),
    .qoz_complete(),.qoz_region(),.ext_qoz_region_valid(1'b0),.ext_qoz_region_ready(),.ext_qoz_region('0),.ext_qoz_context('0),
    .ext_qoz_wr_valid(1'b0),.ext_qoz_wr_ready(),.ext_qoz_wr('0),.gu_prefetch_valid(),.gu_prefetch_ready(1'b0),.gu_prefetch_n());
  task automatic send(input pcore_op_e op,input logic [CORE_BITS-1:0] core='0);
    @(negedge clk);job='0;job.header.op=op;job.header.job_id=9;job.user_tag=64'h1234567890abcdef;job.data_context=16'hffff;
    job.core_id=core;
    job_valid=1;do @(posedge clk);while(!job_ready);@(negedge clk);job_valid=0;
  endtask
  task automatic retire(input control_status_e status);
    wait(done_valid);
    if(done.job!==job||done.status!=status)$fatal(1,"protocol completion mismatch");
    repeat(3)begin @(negedge clk);if(!done_valid||job_ready||done.job!==job)$fatal(1,"held completion");end
    done_ready=1;@(negedge clk);done_ready=0;@(negedge clk);
  endtask
  initial begin
    job='0;vector_result='0;repeat(35)@(negedge clk);reset=0;
    send(OP_ATTENTION);retire(CONTROL_PRECONDITION);
    send(OP_O_PROJ);retire(CONTROL_PRECONDITION);
    send(OP_DOWN_PROJ);retire(CONTROL_PRECONDITION);
    send(pcore_op_e'(7));retire(CONTROL_UNSUPPORTED);
    for(int core=1;core<8;core++)begin send(OP_K_PROJ,CORE_BITS'(core));retire(CONTROL_CONTEXT_ERROR);end
    send(pcore_op_e'(7));wait(done_valid);completion_hold=done;
    @(negedge clk);job.header.job_id=77;job.core_id=7;job_valid=1;
    repeat(17)begin
      @(negedge clk);
      if(job_ready||!done_valid||done!==completion_hold)$fatal(1,"queued Job crossed completion barrier");
    end
    done_ready=1;@(negedge clk);done_ready=0;
    do @(posedge clk);while(!job_ready);
    @(negedge clk);job_valid=0;retire(CONTROL_CONTEXT_ERROR);
    send(OP_K_PROJ);
    repeat(5)@(negedge clk);bad_result=1;@(negedge clk);bad_result=0;
    if(result_ready||kv_out_valid)$fatal(1,"stale packet escaped");
    retire(CONTROL_UNIT_ERROR);
    if(job_ready||!protocol_error)$fatal(1,"fault did not retain ownership");
    clear=1;@(negedge clk);clear=0;
    repeat(3)begin @(negedge clk);if(job_ready||!flush_valid)$fatal(1,"flush barrier missing");end
    vpu_flush_ack=1;@(negedge clk);vpu_flush_ack=0;
    repeat(3)begin @(negedge clk);if(job_ready||!flush_valid)$fatal(1,"one unit flush insufficient");end
    sfu_flush_ack=1;@(negedge clk);sfu_flush_ack=0;@(negedge clk);
    if(!job_ready||protocol_error||flush_valid)$fatal(1,"flush recovery failed");
    send(pcore_op_e'(7));retire(CONTROL_UNSUPPORTED);
    send(pcore_op_e'(7));wait(done_valid);completion_hold=done;
    @(negedge clk);bad_result=1;@(negedge clk);bad_result=0;
    repeat(17)begin
      @(negedge clk);
      if(!done_valid||done!==completion_hold||job_ready||!protocol_error)$fatal(1,"late fault rewrote held completion");
    end
    retire(CONTROL_UNSUPPORTED);
    if(job_ready||!protocol_error)$fatal(1,"late fault allowed next job");
    @(negedge clk);clear=1;@(negedge clk);clear=0;vpu_flush_ack=1;sfu_flush_ack=1;
    repeat(3)@(negedge clk);
    if(!job_ready||protocol_error||flush_valid)$fatal(1,"late-fault clear recovery");
    $display("tb_pcore_control_protocol PASS preconditions=3 unsupported=1 wrong_core=7 completion_hold=1 queued_job_wait=17 stale_rejected=1 fault_hold=1 independent_flush_ack=1 late_fault_completion_immutable=1");$finish;
  end
  initial begin #20000;$fatal(1,"protocol watchdog");end
endmodule
