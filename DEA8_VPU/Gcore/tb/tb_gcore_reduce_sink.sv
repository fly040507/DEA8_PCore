`timescale 1ns/1ps
module tb_gcore_reduce_sink;
  import gcore_pkg::*;
  import dea8_tile_link_pkg::*;
  import pcore_pkg::OP_O_PROJ;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0,cmd_valid=0,cmd_ready;
  gcore_cmd_t cmd;
  gcore_context_t context_data;
  logic header_valid=0,header_ready,data_valid=0,data_ready,last=0;
  tile_header_t header;
  logic [511:0] data=0;
  logic commit_valid,commit_ready=0,work_valid,work_ready=0,written_valid=0,written_ready;
  tile_commit_t commit;
  residual_work_t work;
  residual_commit_t written;
  logic done_valid,done_ready=0,busy;
  gcore_done_t done;
  int consumed=0,rejected=0;
  dea8_gcore_reduce_sink dut(.*);
  always @(posedge clk) if(!reset&&!clear&&work_valid&&work_ready) consumed++;
  task automatic start(input int id);
    @(negedge clk); cmd='0; cmd.opcode=GC_RESIDUAL_APPLY; cmd.pcore_op=OP_O_PROJ;
    cmd.command_id=16'(id); cmd.generation=3; cmd_valid=1;
    do @(posedge clk); while(!cmd_ready);
    @(negedge clk); cmd_valid=0;
  endtask
  task automatic send_header(input bit bad=0);
    @(negedge clk); header='0;
    header.transfer_id=17; header.transfer_epoch=9; header.destination_id=5; header.token_origin=11;
    header.rows=ROWS; header.columns=TILE; header.kind=TILE_O; header.layout=LAYOUT_FP_ROWS;
    header.source_id=bad?4'd7:4'd8; header_valid=1;
    do @(posedge clk); while(!header_ready);
    @(negedge clk); header_valid=0;
  endtask
  task automatic send_data(input int row,input bit bad_last=0,input bit nonfinite=0);
    @(negedge clk); data='0; data[31:0]=nonfinite?32'h7f800000:32'h3f800000;
    data_valid=1; last=bad_last?1'b1:row==ROWS-1;
    do @(posedge clk); while(!data_ready);
    @(negedge clk); data_valid=0;
  endtask
  task automatic write_complete(input int row,input bit bad_token=0);
    @(negedge clk); written.token=command_token(cmd)+(bad_token?1:0);
    written.index=VECTOR_ADDR_BITS'(row); written_valid=1;
    do @(posedge clk); while(!written_ready);
    @(negedge clk); written_valid=0;
  endtask
  task automatic rejected_done(input gcore_status_e status,input int items);
    wait(done_valid); @(negedge clk);
    if(done.status!=status||done.completed_items!=items||commit_valid) $fatal(1,"Reduce sink rejection mismatch");
    repeat(4) @(negedge clk);
    done_ready=1; @(posedge clk); @(negedge clk); done_ready=0; rejected++;
  endtask
  initial begin
    tile_commit_t held;
    cmd='0; context_data='0; header='0; written='0;
    context_data.o_transfer.transfer_id=17; context_data.o_transfer.transfer_epoch=9;
    context_data.o_transfer.destination_id=5; context_data.o_transfer.token_origin=11;
    repeat(5) @(negedge clk); reset=0;
    start(1); send_header(1); rejected_done(GC_BAD_HEADER,0);
    start(2); send_header(); send_data(0,1); rejected_done(GC_BAD_LENGTH,0);
    start(3); send_header(); send_data(0,0,1); rejected_done(GC_NUMERIC_FAULT,0);
    if(consumed!=0) $fatal(1,"invalid payload reached residual compute");
    start(4); send_header(); work_ready=1; send_data(0); wait(consumed==1);
    write_complete(0,1); rejected_done(GC_SOURCE_PROTOCOL,0);

    start(5); send_header();
    fork
      begin for(int row=0;row<ROWS;row++) send_data(row); end
      begin
        for(int row=0;row<ROWS-1;row++) begin
          wait(consumed>=row+2); write_complete(row);
        end
      end
    join
    repeat(12) begin @(negedge clk); if(commit_valid) $fatal(1,"Reduce commit ignored missing final write"); end
    wait(consumed==ROWS+1); write_complete(ROWS-1);
    wait(commit_valid); @(negedge clk); held=commit;
    if(!commit_matches(commit,header)) $fatal(1,"Reduce commit identity mismatch");
    repeat(8) begin @(negedge clk); if(!commit_valid||commit!==held||header_ready) $fatal(1,"Reduce commit was not held"); end
    commit_ready=1; @(posedge clk); @(negedge clk); commit_ready=0;
    // A duplicate tile 0 cannot be applied a second time when tile 1 is expected.
    send_header(); rejected_done(GC_BAD_HEADER,ROWS);

    // The two front-end words are real capacity, not an unbounded TB queue.
    start(6); send_header(); work_ready=0; send_data(0); send_data(1);
    @(negedge clk); data_valid=1; last=0;
    repeat(4) begin @(posedge clk); if(data_ready) $fatal(1,"Reduce input exceeded two-word capacity"); end
    @(negedge clk); clear=1; data_valid=0;
    @(negedge clk); clear=0;
    @(negedge clk);
    if(work_valid||done_valid||commit_valid||busy) $fatal(1,"Reduce clear left stale work");
    start(7); send_header(1); rejected_done(GC_BAD_HEADER,0);
    $display("tb_gcore_reduce_sink PASS rejected=%0d frontend_depth=2 final_write_barrier=1 commit_backpressure=1 duplicate_tile=1 cancel_recovery=1",rejected);
    $finish;
  end
  initial begin #200000; $fatal(1,"Reduce sink watchdog"); end
endmodule
