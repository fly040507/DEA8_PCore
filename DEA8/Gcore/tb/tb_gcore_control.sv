`timescale 1ns/1ps
module tb_gcore_control;
  import gcore_pkg::*;
  import pcore_pkg::*;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,config_valid=0,config_ready,config_done_valid,config_done_ready=0,context_valid;
  gcore_context_t config_data,active_context;
  gcore_status_e config_status;
  logic preloaded_valid=0,preloaded_ready,preloaded_done_valid,preloaded_done_ready=1;
  gcore_preloaded_t preloaded='0;
  gcore_status_e preloaded_status;
  logic cmd_valid=0,cmd_ready,done_valid,done_ready=0;
  gcore_cmd_t cmd,service_cmd,issued[SERVICES];
  gcore_done_t done,service_done[SERVICES];
  logic [SERVICES-1:0] service_cmd_valid,service_cmd_ready='1,service_done_valid=0,service_done_ready,busy;
  logic [SERVICES-1:0] service_fault=0;
  gcore_object_t objects[OBJECTS];
  logic invalidate_valid=0,invalidate_ready;
  logic [OBJECTS-1:0] invalidate_mask=0;
  logic kv_release_valid=0,kv_release_ready,kv_lease;
  logic cancel_valid=0,cancel_ready,flush_valid,external_flush_ack=0,service_clear,fault;
  logic [SERVICES-1:0] flush_ack=0;
  int starts[SERVICES],completions=0,blocked=0,rejections=0;
  bit was_stalled=0;
  gcore_done_t held;

  dea8_gcore_control dut (.*);
  always @(posedge clk) if(!reset) begin
    for(int s=0;s<SERVICES;s++) if(service_cmd_valid[s]&&service_cmd_ready[s]) begin
      if(int'(service_cmd.opcode)!=s) $fatal(1,"command routed to wrong service");
      issued[s]=service_cmd; starts[s]++;
    end
    if(was_stalled&&(!done_valid||done!==held)) $fatal(1,"host completion changed while stalled");
    was_stalled=done_valid&&!done_ready; held=done;
    if(done_valid&&done_ready) completions++;
  end
  function automatic gcore_cmd_t command(input gcore_opcode_e op,input int id,
      input pcore_op_e p=OP_Q_PROJ);
    gcore_cmd_t c;
    c='0; c.opcode=op; c.command_id=16'(id); c.context_id=9; c.generation=2;
    c.core_mask='1; c.pcore_op=p;
    case(op)
      GC_IMPORT_RESID:begin c.dst_object=100; c.dst_version=1; end
      GC_PREFIX_LOAD:begin c.dst_object=300; c.dst_version=7; end
      GC_NORM:begin c.src_object=100; c.src_version=1; c.dst_object=200; c.dst_version=1; c.epsilon_fp32=32'h358637bd; end
      GC_XBC_RUN:begin c.src_object=200; c.src_version=1; end
      GC_KV_RX:begin c.dst_object=p==OP_K_PROJ?400:500; c.dst_version=8; end
      GC_KVB_RUN:begin c.src_object=300; c.src_version=7; end
      GC_RESIDUAL_APPLY:begin c.src_object=100; c.src_version=1; c.dst_object=100; c.dst_version=2; end
      default:;
    endcase
    return c;
  endfunction
  task automatic configure(input bit good);
    @(negedge clk); config_data='0;
    config_data.context_id=9; config_data.generation=2; config_data.gamma_online=good;
    config_data.prefix_version=7; config_data.suffix_version=8;
    config_data.k_transfer.transfer_id=1; config_data.v_transfer.transfer_id=2;
    config_data.o_transfer.transfer_id=3; config_data.down_transfer.transfer_id=4;
    config_valid=1;
    do @(posedge clk); while(!config_ready);
    @(negedge clk); config_valid=0;
    wait(config_done_valid);
    repeat(3) begin
      @(negedge clk);
      if(!config_done_valid||config_status!=(good?GC_OK:GC_BAD_CONTEXT)) $fatal(1,"configuration result changed");
    end
    config_done_ready=1; @(posedge clk); @(negedge clk); config_done_ready=0;
    if(context_valid!=good) $fatal(1,"configuration validity mismatch");
  endtask
  task automatic send(input gcore_cmd_t c);
    @(negedge clk); cmd=c; cmd_valid=1;
    do @(posedge clk); while(!cmd_ready);
    @(negedge clk); cmd_valid=0;
  endtask
  task automatic finish(input int s,input gcore_status_e status=GC_OK,input bit bad_count=0);
    @(negedge clk); service_done[s]=make_done(issued[s],status,expected_items(issued[s])-(bad_count?1:0));
    service_done_valid[s]=1;
    do @(posedge clk); while(!service_done_ready[s]);
    @(negedge clk); service_done_valid[s]=0;
  endtask
  task automatic expect_done(input int id,input gcore_status_e status);
    wait(done_valid); @(negedge clk);
    if(done.command_id!=id||done.status!=status) $fatal(1,"host completion expected id=%0d status=%0d got id=%0d status=%0d",id,status,done.command_id,done.status);
    repeat(4) @(negedge clk);
    done_ready=1; @(posedge clk); @(negedge clk); done_ready=0;
    if(status!=GC_OK) rejections++;
  endtask
  task automatic assert_blocked(input gcore_cmd_t c);
    @(negedge clk); cmd=c; cmd_valid=1;
    repeat(5) begin @(posedge clk); if(cmd_ready||(|service_cmd_valid)) $fatal(1,"resource exclusion failed opcode=%0d",c.opcode); end
    @(negedge clk); cmd_valid=0; blocked++;
  endtask
  task automatic flush_services;
    @(negedge clk); cancel_valid=1;
    do @(posedge clk); while(!cancel_ready);
    @(negedge clk); cancel_valid=0;
    if(!flush_valid) $fatal(1,"cancel did not request flush");
    flush_ack=7'b0001111;
    @(negedge clk); flush_ack=0;
    repeat(3) @(negedge clk);
    if(!flush_valid||service_clear) $fatal(1,"flush completed before all acks");
    flush_ack=7'b1110000;
    @(negedge clk); flush_ack=0;
    repeat(3) @(negedge clk);
    if(!flush_valid||service_clear) $fatal(1,"flush ignored external source ack");
    external_flush_ack=1;
    @(negedge clk); external_flush_ack=0;
    if(flush_valid||!service_clear||context_valid||kv_lease||fault) $fatal(1,"flush completion mismatch");
    for(int o=0;o<OBJECTS;o++) if(objects[o].state!=OBJECT_INVALID) $fatal(1,"cancel left an object valid");
  endtask

  initial begin
    gcore_cmd_t c;
    cmd='0; config_data='0;
    for(int s=0;s<SERVICES;s++) begin issued[s]='0; service_done[s]='0; starts[s]=0; end
    repeat(5) @(negedge clk); reset=0;
    send(command(GC_IMPORT_RESID,90)); expect_done(90,GC_BAD_CONTEXT);
    configure(0); configure(1);
    send(command(GC_NORM,91)); expect_done(91,GC_PRECONDITION);
    c=command(GC_IMPORT_RESID,92); c.reserved=1; send(c); expect_done(92,GC_INVALID_CMD);
    send(command(GC_IMPORT_RESID,1));
    send(command(GC_PREFIX_LOAD,1)); expect_done(1,GC_INVALID_CMD);
    if(starts[S_PREFIX]!=0) $fatal(1,"duplicate command token reached another service");
    send(command(GC_PREFIX_LOAD,2));
    if(busy!=7'b0000011) $fatal(1,"independent services were serialized");
    finish(S_IMPORT); wait(done_valid);
    finish(S_PREFIX);
    if(config_ready) $fatal(1,"active context was mutable");
    expect_done(1,GC_OK); expect_done(2,GC_OK);
    if(objects[OBJ_RESID].state!=OBJECT_COMPLETE||objects[OBJ_PREFIX].state!=OBJECT_COMPLETE)
      $fatal(1,"source objects not published");

    c=command(GC_NORM,93); c.epsilon_fp32=32'h7f800000; send(c); expect_done(93,GC_INVALID_CMD);
    send(command(GC_NORM,3)); assert_blocked(command(GC_IMPORT_RESID,94));
    finish(S_NORM); expect_done(3,GC_OK);
    send(command(GC_XBC_RUN,4,OP_K_PROJ));
    send(command(GC_KV_RX,5,OP_K_PROJ));
    assert_blocked(command(GC_NORM,95));
    finish(S_XBC); finish(S_KV_RX); expect_done(4,GC_OK); expect_done(5,GC_OK);
    send(command(GC_KV_RX,6,OP_V_PROJ)); finish(S_KV_RX); expect_done(6,GC_OK);
    send(command(GC_KVB_RUN,7,OP_ATTENTION));
    if(!kv_lease) $fatal(1,"KVB did not acquire KV objects");
    assert_blocked(command(GC_PREFIX_LOAD,96));
    finish(S_KVB); expect_done(7,GC_OK);
    assert_blocked(command(GC_PREFIX_LOAD,97));
    @(negedge clk); kv_release_valid=1;
    do @(posedge clk); while(!kv_release_ready);
    @(negedge clk); kv_release_valid=0;
    if(kv_lease) $fatal(1,"KV reference release failed");

    send(command(GC_RESIDUAL_APPLY,8,OP_O_PROJ)); finish(S_RESIDUAL); expect_done(8,GC_OK);
    c=command(GC_RESIDUAL_APPLY,9,OP_DOWN_PROJ); c.src_version=2; c.dst_version=3;
    send(c); finish(S_RESIDUAL);
    // Cancel another active service while a successful completion is stalled.
    send(command(GC_XBC_RUN,10,OP_Q_PROJ));
    wait(done_valid); flush_services();
    expect_done(9,GC_OK); expect_done(10,GC_CANCELLED);
    configure(1);

    // A success with the wrong work count must not publish an object.
    send(command(GC_IMPORT_RESID,11)); finish(S_IMPORT,GC_OK,1);
    expect_done(11,GC_SOURCE_PROTOCOL);
    if(!fault||objects[OBJ_RESID].state!=OBJECT_INVALID||cmd_ready) $fatal(1,"invalid completion did not latch fault");
    flush_services(); configure(1);
    send(command(GC_IMPORT_RESID,12)); finish(S_IMPORT); expect_done(12,GC_OK);
    @(negedge clk); invalidate_mask='1; invalidate_valid=1;
    do @(posedge clk); while(!invalidate_ready);
    @(negedge clk); invalidate_valid=0;
    @(negedge clk);
    if(!config_ready) $fatal(1,"idle invalidated context could not be reconfigured");
    for(int s=0;s<SERVICES;s++) if(starts[s]==0) $fatal(1,"untested service=%0d",s);
    @(negedge clk); service_fault[S_NORM]=1;
    repeat(4) @(negedge clk);
    if(!fault||done_valid||cmd_ready) $fatal(1,"asynchronous service fault generated a duplicate completion or failed to stop commands");
    service_fault=0; flush_services();
    $display("tb_gcore_control PASS services=7 completions=%0d exclusion_checks=%0d rejected=%0d cancel_recovery=3 asynchronous_fault=1 routing_only=1",completions,blocked,rejections);
    $finish;
  end
  initial begin #200000; $fatal(1,"control watchdog"); end
endmodule
