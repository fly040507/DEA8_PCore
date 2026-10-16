`timescale 1ns/1ps
module tb_gcore_xbc;
  import gcore_pkg::*;
  import pcore_pkg::xbc4_t;
  import pcore_pkg::pcore_op_e;
  import pcore_pkg::OP_K_PROJ;
  import pcore_pkg::OP_V_PROJ;
  import pcore_pkg::OP_Q_PROJ;
  import pcore_pkg::OP_GU;
  import gcore_tb_pkg::*;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0,cmd_valid=0,cmd_ready;
  gcore_cmd_t cmd;
  logic wr_valid=0,wr_ready,rd_valid,rd_ready,rsp_valid,rsp_ready;
  logic [VECTOR_ADDR_BITS-1:0] wr_index=0;
  logic [135:0] wr_word=0;
  logic [5:0] rd_tile;
  logic [3:0] rd_group;
  xbc4_t rsp,xbc;
  logic [CORES-1:0] xbc_valid,xbc_ready=0,gu_valid=0,gu_ready;
  logic [CORES-1:0][5:0] gu_n=0;
  logic done_valid,done_ready=0,busy,protocol_error,store_error;
  gcore_done_t done;
  int cycle=0,counts[CORES],grant_count[CORES],total=0,expected=0;
  int session=0,request_count=0,response_count=0,logical_retired=0;
  int last_retire_cycle=0,continuous_checks=0;
  bit enable_checker=0,automatic_ready=1,automatic_grants=1;
  bit check_ii=0;
  bit stalled[CORES];
  xbc4_t previous[CORES];

  dea8_gcore_activation_store activation (
    .clk,.reset,.clear,.wr_valid,.wr_ready,.wr_index,.wr_word,.rd_valid,.rd_ready,.rd_tile,.rd_group,
    .rsp_valid,.rsp_ready,.rsp,.protocol_error(store_error)
  );
  dea8_gcore_xbc source (
    .clk,.reset,.clear,.cmd_valid,.cmd_ready,.cmd,.rd_valid,.rd_ready,.rd_tile,.rd_group,
    .rsp_valid,.rsp_ready,.rsp,.xbc_valid,.xbc_ready,.xbc,
    .gu_prefetch_valid(gu_valid),.gu_prefetch_ready(gu_ready),.gu_prefetch_n(gu_n),
    .done_valid,.done_ready,.done,.busy,.protocol_error
  );
  always @(negedge clk) if(!reset&&!clear) begin
    for(int c=0;c<CORES;c++) begin
      if(automatic_ready) xbc_ready[c]=((cycle+3*c)%19)>c%7;
      if(automatic_grants) begin
        if(!gu_valid[c]||gu_ready[c]) begin
          gu_valid[c]=busy&&cmd.pcore_op==OP_GU&&grant_count[c]<32&&((cycle+c)%9<5);
          gu_n[c]=6'(grant_count[c]);
        end
      end
    end
  end
  always @(posedge clk) begin
    cycle++;
    if(reset||clear) begin
      for(int c=0;c<CORES;c++) stalled[c]=0;
    end else begin
      if(enable_checker&&rd_valid&&rd_ready) request_count++;
      if(enable_checker&&rsp_valid&&rsp_ready) response_count++;
      if(enable_checker&&source.retire) begin
        if(check_ii&&logical_retired!=0) begin
          if(cycle!=last_retire_cycle+1) $fatal(1,"unnecessary XBC bubble with all cores ready");
          continuous_checks++;
        end
        logical_retired++; last_retire_cycle=cycle;
      end
      for(int c=0;c<CORES;c++) begin
        if(gu_valid[c]&&gu_ready[c]) grant_count[c]++;
        if(stalled[c] && (!xbc_valid[c] || xbc!==previous[c])) $fatal(1,"broadcast changed under backpressure core=%0d",c);
        stalled[c]=xbc_valid[c]&&!xbc_ready[c]; previous[c]=xbc;
        if(enable_checker&&xbc_valid[c]&&xbc_ready[c]) begin
          int t,g;
          t=(counts[c]/ROW_GROUPS)%HIDDEN_TILES; g=counts[c]%ROW_GROUPS;
          if(counts[c]>=expected) $fatal(1,"duplicate broadcast core=%0d",c);
          if(xbc.tile_idx!=t||xbc.group_idx!=g||xbc.slot||xbc.reserved ||
              xbc.row_valid!=((g==ROW_GROUPS-1)?4'b0111:4'b1111)) $fatal(1,"XBC metadata core=%0d count=%0d",c,counts[c]);
          for(int r=0;r<4;r++) begin
            logic [135:0] gold;
            gold=(4*g+r<ROWS)?activation_word(t,4*g+r):136'b0;
            if(xbc.row[r].data!==gold[127:0]||xbc.row[r].scale!==gold[135:128])
              $fatal(1,"XBC payload core=%0d count=%0d row=%0d",c,counts[c],r);
          end
          counts[c]++; total++;
        end
      end
    end
  end
  task automatic start_session(input pcore_op_e op);
    @(negedge clk);
    for(int c=0;c<CORES;c++) begin counts[c]=0; grant_count[c]=1; end
    request_count=0; response_count=0; logical_retired=0;
    cmd='0; cmd.opcode=GC_XBC_RUN; cmd.pcore_op=op; cmd.core_mask='1;
    cmd.command_id=16'(session+1); cmd.generation=1; cmd.context_id=1;
    expected=xbc_tiles(op)*HIDDEN_TILES*ROW_GROUPS; session++; enable_checker=1; cmd_valid=1;
    do @(posedge clk); while(!cmd_ready);
    @(negedge clk); cmd_valid=0;
  endtask
  task automatic finish_session;
    gcore_done_t held;
    wait(done_valid); @(negedge clk); held=done;
    if(done.status!=GC_OK||done.completed_items!=expected||protocol_error||store_error)
      $fatal(1,"XBC completion status=%0d received=%0d expected=%0d",done.status,done.completed_items,expected);
    for(int c=0;c<CORES;c++) if(counts[c]!=expected) $fatal(1,"missing broadcast core=%0d got=%0d",c,counts[c]);
    if(request_count!=expected||response_count!=expected||logical_retired!=expected)
      $fatal(1,"read credit/retire mismatch");
    repeat(7) begin
      @(negedge clk);
      if(!done_valid||done!==held||cmd_ready) $fatal(1,"XBC completion is not held");
    end
    done_ready=1; @(posedge clk); @(negedge clk); done_ready=0; enable_checker=0;
    $display("XBC_METRICS op=%0d beats=%0d per_core=%0d reads=%0d",cmd.pcore_op,expected,counts[7],request_count);
  endtask
  initial begin
    cmd='0;
    for(int c=0;c<CORES;c++) begin counts[c]=0; grant_count[c]=1; stalled[c]=0; end
    repeat(5) @(negedge clk); reset=0;
    for(int i=0;i<VECTOR_WORDS;i++) begin
      @(negedge clk); wr_valid=1; wr_index=VECTOR_ADDR_BITS'(i);
      wr_word=activation_word(i/ROWS,i%ROWS);
      do @(posedge clk); while(!wr_ready);
    end
    @(negedge clk); wr_valid=0;
    start_session(OP_K_PROJ); finish_session();
    start_session(OP_V_PROJ); finish_session();
    start_session(OP_Q_PROJ); finish_session();
    start_session(OP_GU); finish_session();
    for(int c=0;c<CORES;c++) if(grant_count[c]!=32) $fatal(1,"missing G-U permits core=%0d",c);

    automatic_ready=0; xbc_ready='1; check_ii=1;
    start_session(OP_V_PROJ); finish_session(); check_ii=0;

    // Cancellation with one slow core and both RAM/broadcast state occupied.
    automatic_ready=0; automatic_grants=0; gu_valid=0; xbc_ready=8'h7f;
    start_session(OP_Q_PROJ);
    wait(counts[0]==1); repeat(5) @(negedge clk);
    if(counts[7]!=0||!rsp_valid) $fatal(1,"cancel did not exercise a pending read");
    @(negedge clk); clear=1; enable_checker=0;
    @(negedge clk); clear=0;
    if(xbc_valid||rsp_valid||busy||done_valid) $fatal(1,"cancel left stale state");
    automatic_ready=1; automatic_grants=1;
    start_session(OP_K_PROJ); finish_session();

    // Wrong G-U n is a protocol error, not permission to read the next slice.
    automatic_grants=0;
    start_session(OP_GU);
    @(negedge clk); gu_valid=8'h01; gu_n[0]=7;
    do @(posedge clk); while(!gu_ready[0]);
    @(negedge clk); gu_valid=0;
    wait(done_valid); @(negedge clk);
    if(done.status!=GC_SOURCE_PROTOCOL||!protocol_error) $fatal(1,"bad G-U permit was not rejected");
    enable_checker=0;
    $display("tb_gcore_xbc PASS full_sessions=6 cores=8 payload_checks=%0d gu_grants=248 ii1_checks=%0d cancel_recovery=1 bad_permit=1",total,continuous_checks);
    $finish;
  end
  initial begin #5000000; $fatal(1,"XBC watchdog"); end
endmodule
