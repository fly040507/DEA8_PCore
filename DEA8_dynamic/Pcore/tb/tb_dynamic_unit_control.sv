`timescale 1ns/1ps
import pcore_pkg::*;

module tb_dynamic_unit_control;
  logic clk=0;
  always #2 clk=~clk;
  logic reset=1,clear=0,offer_valid=0,offer_ready,cmd_valid,cmd_ready=1;
  unit_cmd_t offer='0,cmd,current,prepared,retired;
  logic armed_valid=0,armed_ready,go_valid,go_ready=1,grant=0;
  job_token_t armed_token=0,go_token,done_token=0;
  logic done_valid=0,done_ready,done_error=0,drained=1;
  unit_function_e done_function=UNIT_QK_POST;
  logic active,running,prepared_valid,retired_valid,protocol_error;
  int retire_count=0,negative_checks=0,overlap_checks=0;
  dea8_unit_control dut(.*);

  task automatic flush;
    @(negedge clk);clear=1;
    @(negedge clk);clear=0;offer_valid=0;armed_valid=0;done_valid=0;
    grant=0;cmd_ready=1;drained=1;done_error=0;
    if(active||running||prepared_valid||protocol_error)$fatal(1,"Unit clear left stale ownership");
  endtask

  task automatic enqueue(input job_token_t token);
    @(negedge clk);offer='0;offer.token=token;offer.parent_token=32'h12000001;
    offer.function_id=UNIT_QK_POST;offer_valid=1;
    @(posedge clk);if(!offer_ready)$fatal(1,"Unit offer unexpectedly blocked");
    @(negedge clk);offer_valid=0;
  endtask

  task automatic arm(input job_token_t token);
    while(!((active&&current.token==token&&dut.sent)||
            (prepared_valid&&prepared.token==token&&dut.prepared_sent)))@(negedge clk);
    armed_valid=1;armed_token=token;
    @(posedge clk);if(!armed_ready)$fatal(1,"Unit arm rejected token=%h",token);
    @(negedge clk);armed_valid=0;
  endtask

  task automatic launch(input job_token_t token);
    grant=1;
    @(posedge clk);
    if(!go_valid||go_token!=token)$fatal(1,"Unit go wrong owner/not ready");
    @(negedge clk);grant=0;
    if(!running)$fatal(1,"Unit did not start");
  endtask

  task automatic finish(input job_token_t token);
    done_token=token;done_valid=1;done_function=UNIT_QK_POST;
    @(posedge clk);
    if(!done_ready||!retired_valid||retired.token!=token)$fatal(1,"Unit retirement mismatch");
    retire_count++;
    @(negedge clk);done_valid=0;
  endtask

  initial begin
    repeat(32)@(negedge clk);reset=0;
    // The prepared armed handshake and current retirement share one edge.
    enqueue(1);arm(1);launch(1);enqueue(2);
    while(!dut.prepared_sent)@(negedge clk);
    armed_valid=1;armed_token=2;done_valid=1;done_token=1;
    @(posedge clk);if(!armed_ready||!retired_valid)$fatal(1,"Unit overlap setup failed");
    retire_count++;
    @(negedge clk);armed_valid=0;done_valid=0;grant=1;
    if(!active||current.token!=2||!dut.armed||running)$fatal(1,"Prepared armed lost at retirement boundary");
    overlap_checks++;launch(2);finish(2);

    // A prepared command accepted on the retirement edge must not be resent.
    enqueue(3);arm(3);launch(3);cmd_ready=0;enqueue(4);
    while(!cmd_valid)@(negedge clk);
    if(cmd.token!=4)$fatal(1,"Prepared command identity");
    repeat(2)begin @(negedge clk);if(!cmd_valid||cmd.token!=4)$fatal(1,"Command hold");end
    cmd_ready=1;done_token=3;done_valid=1;
    @(posedge clk);if(!cmd_valid||!retired_valid)$fatal(1,"Command overlap setup failed");
    retire_count++;
    @(negedge clk);done_valid=0;
    if(cmd_valid)$fatal(1,"Prepared command resent after retirement boundary");
    overlap_checks++;arm(4);launch(4);finish(4);

    // A new offer can replace a retiring command without a prepared entry.
    enqueue(5);arm(5);launch(5);
    offer='0;offer.token=6;offer.function_id=UNIT_QK_POST;offer_valid=1;
    done_token=5;done_valid=1;
    @(posedge clk);if(!offer_ready||!retired_valid)$fatal(1,"Replacement overlap setup failed");
    retire_count++;
    @(negedge clk);offer_valid=0;done_valid=0;
    if(!active||current.token!=6||prepared_valid||running)$fatal(1,"Retire/offer replacement");
    overlap_checks++;arm(6);launch(6);finish(6);
    if(active||prepared_valid)$fatal(1,"Unit failed to become idle");

    enqueue(7);arm(7);
    repeat(3)begin @(negedge clk);if(go_valid||running)$fatal(1,"Prepare granted access before dependency");end
    launch(7);enqueue(8);arm(8);flush();
    repeat(3)begin @(negedge clk);if(cmd_valid||go_valid||retired_valid)$fatal(1,"Unit clear replayed command");end

    // Invalid completion/arming must fault, not silently retire or hang.
    enqueue(10);armed_valid=1;armed_token=11;
    @(negedge clk);armed_valid=0;if(!protocol_error)$fatal(1,"Wrong armed token accepted");negative_checks++;flush();
    enqueue(12);arm(12);launch(12);drained=0;done_valid=1;done_token=12;
    @(negedge clk);done_valid=0;if(!protocol_error||retired_valid)$fatal(1,"Early done accepted");negative_checks++;flush();
    enqueue(13);arm(13);launch(13);done_valid=1;done_token=14;
    @(negedge clk);done_valid=0;if(!protocol_error||retired_valid)$fatal(1,"Wrong done token accepted");negative_checks++;flush();
    enqueue(15);arm(15);launch(15);done_valid=1;done_token=15;done_function=UNIT_P_POST;
    @(negedge clk);done_valid=0;if(!protocol_error||retired_valid)$fatal(1,"Wrong done function accepted");negative_checks++;flush();
    enqueue(16);arm(16);launch(16);done_valid=1;done_token=16;done_function=UNIT_QK_POST;done_error=1;
    @(negedge clk);done_valid=0;if(!protocol_error||retired_valid)$fatal(1,"Unit error status accepted");negative_checks++;flush();
    enqueue(17);arm(17);launch(17);finish(17);
    $display("tb_dynamic_unit_control PASS retires=%0d same_edge_checks=%0d negative_checks=%0d prepare_no_access=1 clear_active_prepared=1",retire_count,overlap_checks,negative_checks);
    $finish;
  end
  initial begin #10000;$fatal(1,"Unit control watchdog");end
endmodule
