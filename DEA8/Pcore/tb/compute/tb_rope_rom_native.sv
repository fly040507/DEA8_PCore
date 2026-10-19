`timescale 1ns/1ps
import pcore_pkg::*;
import pcore_control_pkg::*;

// The independent reference keeps the original four-pair image. Run the same
// checks against RTL and the actual post-synthesis RAM primitive netlist.
module tb_rope_rom_native;
  logic clk=0,reset=1,flush=0,flush_ack;
  always #2 clk=~clk;
  logic req_valid=0,req_ready,rsp_valid,rsp_ready=0,protocol_error;
  control_rope_req_t req='0;
  control_rope_rsp_t rsp;
  logic [255:0] original_words[0:51*32-1];
  int responses=0,checks=0,stall_cycles=0;
  dea8_sfu_rope_rom dut(.*);

  task automatic check_answer(input control_rope_req_t expected);
    int offset;
    if(rsp.request!==expected)$fatal(1,"RoPE request metadata mismatch");
    offset=(int'(expected.position)-816)*32+int'(expected.frequency_base)/4;
    for(int lane=0;lane<16;lane++)begin
      if(rsp.cosine[lane]!==original_words[offset+lane/4][64*(lane%4)+:32])
        $fatal(1,"RoPE cosine mismatch position=%0d frequency=%0d",expected.position,expected.frequency_base+lane);
      if(rsp.sine[lane]!==original_words[offset+lane/4][64*(lane%4)+32+:32])
        $fatal(1,"RoPE sine mismatch position=%0d frequency=%0d",expected.position,expected.frequency_base+lane);
      checks+=2;
    end
  endtask

  task automatic issue(input int address);
    @(negedge clk);
    req='0;req.token.generation=16'(address+1);req.token.command_id=16'(address+501);
    req.position=16'(816+address/8);req.row=6'(address/8);req.frequency_base=8'(16*(address%8));
    req_valid=1;
    #0.1;
    if(!req_ready)$fatal(1,"RoPE did not accept legal idle request address=%0d",address);
    @(negedge clk);req_valid=0;
  endtask

  task automatic wait_answer;
    int timeout_cycles;
    timeout_cycles=0;
    while(!rsp_valid)begin
      @(negedge clk);
      timeout_cycles++;
      if(timeout_cycles>8)$fatal(1,"RoPE response timeout");
    end
  endtask

  task automatic flush_and_check;
    flush=1;
    #0.1;
    if(!flush_ack||rsp_valid)$fatal(1,"RoPE flush did not suppress output");
    @(negedge clk);flush=0;
    @(negedge clk);
    if(rsp_valid||protocol_error||!req_ready)$fatal(1,"RoPE failed flush recovery");
  endtask

  initial begin
    control_rope_rsp_t held;
    $readmemh("units/rom/rope.mem",original_words);
    // glbl holds UNISIM sequential cells in GSR for the first 100 ns.
    repeat(35)@(negedge clk);
    reset=0;
    for(int address=0;address<408;address++)begin
      issue(address);wait_answer();check_answer(req);held=rsp;
      repeat(address%5)begin
        @(negedge clk);
        if(!rsp_valid||rsp!==held)$fatal(1,"RoPE response changed under backpressure");
        stall_cycles++;
      end
      rsp_ready=1;
      @(negedge clk);rsp_ready=0;responses++;
      if(protocol_error)$fatal(1,"RoPE protocol_error on legal traffic");
    end
    // Drop a pending read, then a held response, and prove subsequent recovery.
    issue(0);flush_and_check();
    issue(407);wait_answer();check_answer(req);flush_and_check();
    issue(17);wait_answer();check_answer(req);rsp_ready=1;
    @(negedge clk);rsp_ready=0;responses++;
    // Invalid positions are rejected and sticky errors clear on flush.
    @(negedge clk);req.position=815;req_valid=1;
    @(negedge clk);req_valid=0;
    if(!protocol_error||req_ready)$fatal(1,"RoPE accepted invalid position");
    req.position=816;
    flush_and_check();
    $display("tb_rope_rom_native PASS addresses=408 coefficient_checks=%0d responses=%0d stall_cycles=%0d flush=1 invalid_position=1",checks,responses,stall_cycles);
    $finish;
  end
  initial begin #100000;$fatal(1,"RoPE test watchdog");end
endmodule
