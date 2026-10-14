`timescale 1ns/1ps
import pcore_pkg::*;

// Reuse the real matrix/unit agents, then interrupt a held workspace reply.
// No internal DUT state or arithmetic result is forced by this test.
module tb_dynamic_attention_cancel;
  tb_dynamic_attention scenario();

  task automatic check_service_closed;
    if(scenario.unit_ws_ready||scenario.unit_ws_out_valid||scenario.function_ws_ready||
       scenario.function_ws_out_valid||scenario.unit_acc_ready||scenario.unit_acc_out_valid||
       scenario.unit_acc_wr_ready||scenario.function_exp_ready||scenario.unit_p_valid||
       scenario.unit_cmd_valid||scenario.function_cmd_valid||scenario.unit_go_valid||scenario.function_go_valid)
      $fatal(1,"Attention service handshake escaped fault/clear gate");
  endtask

  initial begin
    // The default scenario completes M=0, then starts a real M=1 Attention.
    wait(scenario.rows==1&&scenario.unit_ws_out_valid);
    @(negedge scenario.clk);
    scenario.agents=0;
    disable scenario.transport_agent;
    disable scenario.vector_agent;
    disable scenario.function_agent;
    disable scenario.main;
    scenario.qk_stream=0;scenario.transform_stream=0;scenario.exp_stream=0;
    scenario.source_work_ready=0;scenario.b_desc_valid=0;scenario.kv_in_valid=0;
    scenario.unit_cmd_ready=0;scenario.function_cmd_ready=0;
    scenario.unit_armed_valid=0;scenario.function_armed_valid=0;
    scenario.unit_go_ready=0;scenario.function_go_ready=0;
    scenario.unit_ws_valid=0;scenario.unit_ws_out_ready=0;
    scenario.function_ws_valid=0;scenario.function_ws_out_ready=0;
    scenario.unit_acc_valid=0;scenario.normal_acc_out_ready=0;scenario.unit_acc_wr_valid=0;
    scenario.unit_wr_valid=0;scenario.unit_p_ready=0;
    scenario.unit_done_valid=0;scenario.function_done_valid=0;
    if(!scenario.dut.attn_v_ws_out_valid)$fatal(1,"Cancel test did not hold a real workspace reply");
    scenario.allow_error=1;
    scenario.unit_profile_token=scenario.dut.active_unit_token+1'b1;
    scenario.unit_profile_valid=1;
    #1;
    if(!scenario.protocol_error)$fatal(1,"Wrong profile token did not fault");
    check_service_closed();
    @(posedge scenario.clk);
    @(negedge scenario.clk);scenario.unit_profile_valid=0;
    #1;
    if(!scenario.protocol_error)$fatal(1,"Transient interface fault was not latched");
    check_service_closed();
    while(!scenario.completion_valid)@(negedge scenario.clk);
    if(scenario.completion.status!=PCORE_FAULT)$fatal(1,"Wrong fault completion");
    repeat(3)begin @(negedge scenario.clk);check_service_closed();end
    scenario.completion_ready=1;
    @(negedge scenario.clk);scenario.completion_ready=0;
    if(scenario.job_ready)$fatal(1,"Fault accepted another job without flush");

    scenario.flush_ack=0;scenario.clear=1;
    #1;check_service_closed();
    repeat(3)@(negedge scenario.clk);
    scenario.clear=0;
    repeat(3)begin
      @(negedge scenario.clk);check_service_closed();
      if(!scenario.flush_request||scenario.job_ready||scenario.completion_valid)
        $fatal(1,"Fault flush completed before source/unit acknowledgements");
    end
    scenario.flush_ack=3'b011;
    repeat(2)begin @(negedge scenario.clk);if(!scenario.flush_request)$fatal(1,"Flush ignored SFU ack");end
    scenario.flush_ack=3'b111;
    while(!scenario.job_ready)@(negedge scenario.clk);
    if(scenario.protocol_error||scenario.completion_valid||scenario.dut.qoz_active||scenario.dut.pbuf_active!=0)
      $fatal(1,"Flush left stale fault, completion or local owner");
    scenario.allow_error=0;
    // Recovery must complete all 55 QK + 55 PV and AFIN, not only accept a job.
    scenario.run_attention(1);
    $display("tb_dynamic_attention_cancel PASS held_real_workspace=1 fault_ports_closed=1 sticky_interface_fault=1 three_ack_flush=1 no_duplicate_completion=1 full_M1_recovery=1");
    $finish;
  end
  initial begin #500000;$fatal(1,"Attention cancel watchdog");end
endmodule
