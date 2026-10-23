`timescale 1ns/1ps
module tb_gcore_stores;
  import gcore_pkg::*;
  import pcore_pkg::xbc4_t;
  import gcore_tb_pkg::*;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic cmd_valid=0,cmd_ready,in_valid=0,in_ready,done_valid,done_ready=0,import_busy;
  gcore_cmd_t cmd;
  residual_import_t in_data;
  gcore_done_t done;
  logic wr_valid,wr_ready,rd_valid=0,rd_ready,rsp_valid,rsp_ready=0,error;
  logic [VECTOR_ADDR_BITS-1:0] wr_addr,rd_addr=0,rsp_addr;
  logic [255:0] wr_data,rsp_data;
  logic aw_valid=0,aw_ready,ar_valid=0,ar_ready,ap_valid,ap_ready=0,aerror;
  logic [VECTOR_ADDR_BITS-1:0] aw_index=0;
  logic [135:0] aw_word=0;
  logic [5:0] ar_tile=0;
  logic [3:0] ar_group=0;
  xbc4_t ap;
  int writes=0,reads=0,act_reads=0;

  dea8_gcore_residual_import importer (
    .clk,.reset,.clear,.cmd_valid,.cmd_ready,.cmd,.in_valid,.in_ready,.in_data,
    .wr_valid,.wr_ready,.wr_addr,.wr_data,.done_valid,.done_ready,.done,.busy(import_busy)
  );
  dea8_gcore_residual_store resid (
    .clk,.reset,.clear,.wr_valid,.wr_ready,.wr_addr,.wr_data,
    .rd_valid,.rd_ready,.rd_addr,.rsp_valid,.rsp_ready,.rsp_data,.rsp_addr,.protocol_error(error)
  );
  dea8_gcore_activation_store activation (
    .clk,.reset,.clear,.wr_valid(aw_valid),.wr_ready(aw_ready),.wr_index(aw_index),.wr_word(aw_word),
    .rd_valid(ar_valid),.rd_ready(ar_ready),.rd_tile(ar_tile),.rd_group(ar_group),
    .rsp_valid(ap_valid),.rsp_ready(ap_ready),.rsp(ap),.protocol_error(aerror)
  );
  always @(posedge clk) if(!reset&&!clear&&wr_valid&&wr_ready) writes++;

  task automatic start_import(input int id);
    @(negedge clk); cmd='0; cmd.opcode=GC_IMPORT_RESID;
    cmd.command_id=16'(id); cmd.generation=7; cmd.context_id=2; cmd.core_mask='1;
    cmd_valid=1;
    do @(posedge clk); while(!cmd_ready);
    @(negedge clk); cmd_valid=0;
  endtask
  task automatic send_word(input int index,salt,input bit last,input logic [31:0] token);
    @(negedge clk);
    in_data.data=residual_word(index,salt); in_data.index=VECTOR_ADDR_BITS'(index);
    in_data.last=last; in_data.token=token; in_valid=1;
    do @(posedge clk); while(!in_ready);
    @(negedge clk); in_valid=0;
  endtask
  task automatic take_done(input gcore_status_e status,input int count);
    gcore_done_t held;
    wait(done_valid); @(negedge clk); held=done;
    repeat(4) begin
      if(!done_valid||done!==held) $fatal(1,"import completion changed under backpressure");
      @(negedge clk);
    end
    if(done.status!=status||done.completed_items!=count) $fatal(1,"import completion mismatch");
    done_ready=1; @(posedge clk); @(negedge clk); done_ready=0;
  endtask
  task automatic read_residual(input int index,salt);
    logic [255:0] held;
    @(negedge clk); rd_valid=1; rd_addr=VECTOR_ADDR_BITS'(index);
    do @(posedge clk); while(!rd_ready);
    @(negedge clk); rd_valid=0;
    wait(rsp_valid); held=rsp_data;
    repeat(index%4) begin
      @(negedge clk);
      if(!rsp_valid||rsp_data!==held) $fatal(1,"RAM response changed while stalled");
    end
    if(rsp_addr!=index||rsp_data!==residual_word(index,salt)) $fatal(1,"residual RAM mismatch index=%0d",index);
    @(negedge clk); rsp_ready=1; @(posedge clk); reads++;
    @(negedge clk); rsp_ready=0;
  endtask

  initial begin
    cmd='0; in_data='0;
    repeat(5) @(negedge clk); reset=0;
    if($bits(gcore_cmd_t)!=192||$bits(gcore_done_t)!=128||$bits(residual_import_t)!=301||
        $bits(prefix_import_t)!=184||$bits(rsqrt_packet_t)!=110) $fatal(1,"GCore type width mismatch");
    for(int pass=0;pass<2;pass++) begin
      start_import(pass+1);
      for(int i=0;i<VECTOR_WORDS;i++) send_word(i,pass,i==VECTOR_WORDS-1,command_token(cmd));
      take_done(GC_OK,VECTOR_WORDS);
      for(int i=0;i<VECTOR_WORDS;i++) read_residual(i,pass);
    end
    if(writes!=2*VECTOR_WORDS) $fatal(1,"RAM write count mismatch");
    start_import(3);
    send_word(1,0,0,command_token(cmd)); // Must be rejected BEFORE writing RAM.
    take_done(GC_SOURCE_PROTOCOL,0);
    start_import(4); send_word(0,0,1,command_token(cmd)); take_done(GC_SOURCE_PROTOCOL,0);
    start_import(5); send_word(0,0,0,32'hffffffff); take_done(GC_SOURCE_PROTOCOL,0);
    start_import(6);
    @(negedge clk); in_data='0; in_data.data[15:0]=16'h7f80;
    in_data.token=command_token(cmd); in_valid=1;
    do @(posedge clk); while(!in_ready);
    @(negedge clk); in_valid=0;
    take_done(GC_NUMERIC_FAULT,0);
    if(writes!=2*VECTOR_WORDS) $fatal(1,"invalid import wrote RAM");

    for(int i=0;i<VECTOR_WORDS;i++) begin
      @(negedge clk); aw_valid=1; aw_index=VECTOR_ADDR_BITS'(i);
      aw_word=activation_word(i/ROWS,i%ROWS);
      do @(posedge clk); while(!aw_ready);
    end
    @(negedge clk); aw_valid=0;
    for(int t=0;t<HIDDEN_TILES;t++) for(int g=0;g<ROW_GROUPS;g++) begin
      @(negedge clk); ar_valid=1; ar_tile=6'(t); ar_group=4'(g);
      do @(posedge clk); while(!ar_ready);
      @(negedge clk); ar_valid=0;
      wait(ap_valid);
      repeat((t+g)%3) @(negedge clk);
      if(ap.tile_idx!=t||ap.group_idx!=g||ap.reserved!=0||ap.slot!=0||
          ap.row_valid!=((g==ROW_GROUPS-1)?4'b0111:4'b1111)) $fatal(1,"activation tag mismatch");
      for(int r=0;r<4;r++) begin
        logic [135:0] gold;
        gold=(4*g+r<ROWS)?activation_word(t,4*g+r):136'b0;
        if(ap.row[r].data!==gold[127:0]||ap.row[r].scale!==gold[135:128])
          $fatal(1,"activation bank/data/scale mismatch tile=%0d group=%0d row=%0d",t,g,r);
      end
      @(negedge clk); ap_ready=1; @(posedge clk); act_reads++;
      @(negedge clk); ap_ready=0;
    end
    if(error||aerror) $fatal(1,"unexpected store error");
    // Clear cancels an outstanding synchronous response, but does not reset RAM.
    @(negedge clk); rd_valid=1; rd_addr=0;
    @(posedge clk); @(negedge clk); rd_valid=0; clear=1;
    @(negedge clk); clear=0;
    if(rsp_valid||ap_valid||done_valid||import_busy) $fatal(1,"clear did not cancel valid state");
    read_residual(0,1);
    // Revoke an active import before its next data word can mutate RAM.
    start_import(7); send_word(0,2,0,command_token(cmd));
    @(negedge clk); clear=1; in_valid=1; in_data.index=1;
    repeat(2) begin
      @(posedge clk);
      if(wr_valid||in_ready) $fatal(1,"clear allowed a cancelled import write");
    end
    @(negedge clk); in_valid=0; clear=0;
    @(negedge clk);
    if(import_busy||done_valid) $fatal(1,"cancelled import remained live");
    if(writes!=2*VECTOR_WORDS+1) $fatal(1,"cancelled import write count mismatch");

    @(negedge clk); rd_addr='1; rd_valid=1;
    do @(posedge clk); while(!rd_ready);
    @(negedge clk); rd_valid=0;
    if(!error||rsp_valid) $fatal(1,"out-of-range residual read was not rejected");
    clear=1; @(negedge clk); clear=0;
    @(negedge clk); aw_valid=1; aw_index='1;
    do @(posedge clk); while(!aw_ready);
    @(negedge clk); aw_valid=0;
    if(!aerror) $fatal(1,"out-of-range activation write was not rejected");
    clear=1; @(negedge clk); clear=0;
    $display("tb_gcore_stores PASS residual_writes=%0d residual_reads=%0d xhat_groups=%0d import_rejects=4 bounds_rejects=2 two_sessions=1 cancel_write=1",writes,reads,act_reads);
    $finish;
  end
  initial begin #1000000; $fatal(1,"stores watchdog"); end
endmodule
