`timescale 1ns/1ps
module tb_gcore_kv;
  import gcore_pkg::*;
  import dea8_tile_link_pkg::*;
  import gcore_tb_pkg::*;
  import pcore_pkg::OP_K_PROJ;
  import pcore_pkg::OP_V_PROJ;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0,cmd_valid=0,cmd_ready,done_valid,done_ready=0,busy;
  gcore_cmd_t cmd;
  gcore_context_t context_data;
  gcore_done_t done;
  logic [CORES-1:0] header_valid=0,header_ready,data_valid=0,data_ready,last=0;
  tile_header_t header[CORES];
  logic [CORES-1:0][135:0] data=0;
  logic [CORES-1:0] commit_valid,commit_ready=0,wr_valid,wr_ready=0;
  tile_commit_t commit[CORES];
  kv_write_t wr[CORES];
  int checks=0,writes=0,rejections=0;
  bit monitor_writes=0;
  dea8_gcore_kv_receive dut(.*);
  logic [CORES-1:0] mem_wr_valid=0,mem_wr_ready;
  kv_write_t mem_wr[CORES];
  logic mem_rd_valid=0,mem_rd_ready,mem_rsp_valid,mem_rsp_ready=0,mem_error;
  kv_read_t mem_rd;
  pcore_pkg::b2_t mem_rsp;
  logic source_cmd_valid=0,source_cmd_ready,source_rd_valid,source_rd_ready=0;
  logic source_rsp_valid=0,source_rsp_ready,source_done_valid,source_done_ready=0,source_busy,source_error;
  logic [CORES-1:0] source_out_valid;
  kv_read_t source_rd;
  pcore_pkg::b2_t source_rsp='0,source_out;
  gcore_cmd_t source_cmd='0;
  gcore_done_t source_done;
  dea8_gcore_kvb source (
    .clk,.reset,.clear,.cmd_valid(source_cmd_valid),.cmd_ready(source_cmd_ready),.cmd(source_cmd),.context_data,
    .rd_valid(source_rd_valid),.rd_ready(source_rd_ready),.rd(source_rd),
    .rsp_valid(source_rsp_valid),.rsp_ready(source_rsp_ready),.rsp(source_rsp),
    .kv_valid(source_out_valid),.kv_ready(8'hff),.kv(source_out),
    .done_valid(source_done_valid),.done_ready(source_done_ready),.done(source_done),.busy(source_busy),.protocol_error(source_error)
  );
  dea8_gcore_kv_store store (
    .clk,.reset,.clear,.wr_valid(mem_wr_valid),.wr_ready(mem_wr_ready),.wr(mem_wr),
    .rd_valid(mem_rd_valid),.rd_ready(mem_rd_ready),.rd(mem_rd),
    .rsp_valid(mem_rsp_valid),.rsp_ready(mem_rsp_ready),.rsp(mem_rsp),.protocol_error(mem_error)
  );
  always @(posedge clk) if(!reset&&!clear) begin
    if(monitor_writes&&wr_valid[0]&&wr_ready[0]) begin
      if(wr[0].value_kind||wr[0].feature_tile!=0||wr[0].parity!=1'(writes%2)||
          wr[0].address!=writes/2||wr[0].word_data!==kv_word(0,0,0,writes)) $fatal(1,"KV RX write address/data mismatch");
      writes++;
    end
    if(commit_valid[0]&&writes<51&&monitor_writes) $fatal(1,"KV RX commit before final write");
  end
  task automatic flush;
    @(negedge clk); clear=1; header_valid=0; data_valid=0; commit_ready=0; wr_ready=0;
    mem_wr_valid=0; mem_rd_valid=0;
    @(negedge clk); clear=0;
    if(done_valid||busy||mem_error) $fatal(1,"KV clear failed");
  endtask
  task automatic start(input bit is_value=0);
    @(negedge clk); cmd='0; cmd.opcode=GC_KV_RX; cmd.pcore_op=is_value?OP_V_PROJ:OP_K_PROJ;
    cmd.command_id=16'(rejections+1); cmd.context_id=9; cmd.generation=2; cmd.core_mask='1; cmd_valid=1;
    do @(posedge clk); while(!cmd_ready);
    @(negedge clk); cmd_valid=0;
  endtask
  task automatic put_header(input bit is_value=0,input int bad=0);
    tile_transfer_t t;
    t=is_value?context_data.v_transfer:context_data.k_transfer;
    @(negedge clk); header[0]='0;
    header[0].transfer_id=t.transfer_id; header[0].transfer_epoch=t.transfer_epoch;
    header[0].destination_id=t.destination_id; header[0].token_origin=t.token_origin;
    header[0].rows=51; header[0].columns=16; header[0].kind=is_value?TILE_V:TILE_K;
    header[0].layout=is_value?LAYOUT_V_GROUPS:LAYOUT_K_ROWS;
    case(bad)
      1:header[0].source_id=1;
      2:header[0].column_base=16;
      3:header[0].transfer_epoch++;
      4:header[0].layout=LAYOUT_FP_ROWS;
      default:;
    endcase
    header_valid[0]=1;
    do @(posedge clk); while(!header_ready[0]);
    @(negedge clk); header_valid[0]=0;
  endtask
  task automatic put_word(input int index,input bit is_value=0,input int bad=0);
    @(negedge clk); data_valid[0]=1; data[0]=kv_word(is_value,0,0,index); last[0]=index==(is_value?63:50);
    case(bad)
      1:last[0]=!last[0];
      2:data[0][135:128]=8'hff;
      3:data[0][31:24]=8'h01;
      default:;
    endcase
    do @(posedge clk); while(!data_ready[0]);
    @(negedge clk); data_valid[0]=0;
  endtask
  task automatic rejection(input gcore_status_e status);
    gcore_done_t saved;
    wait(done_valid); @(negedge clk); saved=done;
    if(done.status!=status||!same_completion(done,cmd)) $fatal(1,"KV rejection mismatch expected=%0d got=%0d",status,done.status);
    repeat(4) begin @(negedge clk); if(!done_valid||done!==saved) $fatal(1,"KV rejected completion not stable"); end
    done_ready=1; @(posedge clk); @(negedge clk); done_ready=0; rejections++;
    flush();
  endtask
  initial begin
    cmd='0; context_data='0; mem_rd='0;
    for(int c=0;c<CORES;c++) begin header[c]='0; mem_wr[c]='0; end
    context_data.k_transfer='{16'd1,16'd11,16'd21,16'd31};
    context_data.v_transfer='{16'd2,16'd12,16'd22,16'd32};
    repeat(5) @(negedge clk); reset=0;
    if((|header_ready)||(|data_ready)) $fatal(1,"idle KV accepted payload without command");
    for(int bad=1;bad<=4;bad++) begin
      start(bad==4); put_header(bad==4,bad); rejection(GC_BAD_HEADER);
    end
    start(); put_header(); put_word(0,0,1); rejection(GC_BAD_LENGTH);
    start(); put_header(); put_word(0,0,2); rejection(GC_NUMERIC_FAULT);
    start(1); put_header(1); wr_ready='1;
    for(int i=0;i<48;i++) put_word(i,1);
    put_word(48,1,3); rejection(GC_BAD_LENGTH);
    // Two-word capacity, no hidden third entry and no pre-write acknowledgement.
    start(); put_header(); monitor_writes=1; writes=0;
    put_word(0); put_word(1);
    @(negedge clk); data_valid[0]=1; data[0]=kv_word(0,0,0,2); last[0]=0;
    repeat(5) begin @(posedge clk); if(data_ready[0]||commit_valid[0]) $fatal(1,"KV FIFO exceeded two words"); checks++; end
    @(negedge clk); wr_ready='1;
    do @(posedge clk); while(!data_ready[0]);
    @(negedge clk); data_valid[0]=0;
    for(int i=3;i<51;i++) put_word(i);
    wait(commit_valid[0]); @(negedge clk);
    repeat(5) begin
      @(negedge clk);
      if(done_valid||!commit_valid[0]||writes!=51||commit[0].status!=0) $fatal(1,"KV commit barrier failed"); checks++;
    end
    commit_ready[0]=1; @(posedge clk); @(negedge clk); commit_ready[0]=0; monitor_writes=0;
    // The second header must be tile_seq=1; tile 0 replay cannot overwrite RAM.
    put_header(); rejection(GC_BAD_HEADER);
    // RAM rejects a paired-read address beyond the preloaded prefix window.
    @(negedge clk); mem_rd='0; mem_rd.prefix=1; mem_rd.address=PREFIX_BANK_DEPTH; mem_rd_valid=1;
    do @(posedge clk); while(!mem_rd_ready);
    @(negedge clk); mem_rd_valid=0;
    if(!mem_error||mem_rsp_valid) $fatal(1,"KV RAM accepted out-of-range read");
    checks++; flush();
    // Two physical writers must never drive one bank on the same edge.
    @(negedge clk); mem_wr_valid=3; mem_wr[0]='0; mem_wr[1]='0;
    mem_wr[0].word_data=kv_word(0,0,0,0); mem_wr[1].word_data=kv_word(0,0,0,1);
    @(posedge clk); @(negedge clk); mem_wr_valid=0;
    if(!mem_error) $fatal(1,"KV RAM ignored writer collision");
    checks++; flush();
    // A lone wrong owner must also fail, without relying on a collision.
    @(negedge clk);mem_wr_valid=2;mem_wr[1]='0;mem_wr[1].word_data=kv_word(0,0,0,0);
    @(posedge clk);@(negedge clk);mem_wr_valid=0;
    if(!mem_error)$fatal(1,"KV RAM accepted a wrong static owner");
    checks++;flush();
    // A paired response holds both MX words and tags until accepted.
    @(negedge clk); mem_wr_valid=1; mem_wr[0]='0;
    mem_wr[0].word_data=kv_word(0,0,0,0);
    @(posedge clk);@(negedge clk);
    mem_wr[0].word_data=kv_word(0,0,0,1);mem_wr[0].parity=1;
    @(posedge clk); @(negedge clk); mem_wr_valid=0;
    mem_rd='0; mem_rd.tile=6'd37; mem_rd.group_index=3'd5; mem_rd.epoch=4'd9; mem_rd_valid=1;
    do @(posedge clk); while(!mem_rd_ready);
    @(negedge clk); mem_rd_valid=0; wait(mem_rsp_valid);
    repeat(5) begin
      logic [135:0] even_word,odd_word;
      @(negedge clk); even_word=kv_word(0,0,0,0); odd_word=kv_word(0,0,0,1);
      if(!mem_rsp_valid||!mem_rd_ready||mem_rsp.tile_idx!=37||mem_rsp.group_idx!=5||mem_rsp.epoch!=9||
          {mem_rsp.col[0].scale,mem_rsp.col[0].data}!==even_word||
          {mem_rsp.col[1].scale,mem_rsp.col[1].data}!==odd_word) $fatal(1,"KV paired response changed while stalled");
      checks++;
    end
    mem_rsp_ready=1; @(posedge clk); @(negedge clk); mem_rsp_ready=0; flush();
    start(); put_header(); put_word(0); flush();
    if((|wr_valid)||(|commit_valid)) $fatal(1,"KV clear leaked an old word/commit");
    @(negedge clk); source_cmd='0; source_cmd.opcode=GC_KVB_RUN;
    source_cmd.pcore_op=pcore_pkg::OP_ATTENTION; source_cmd.core_mask='1; source_cmd_valid=1;
    do @(posedge clk); while(!source_cmd_ready);
    @(negedge clk); source_cmd_valid=0; source_rd_ready=1;
    repeat(STORE_RESPONSE_DEPTH) begin @(posedge clk); if(!source_rd_valid) $fatal(1,"KVB failed to reserve paired read"); end
    @(negedge clk); source_rd_ready=0;
    repeat(4) begin @(negedge clk); if(source_rd_valid) $fatal(1,"KVB exceeded read credits"); checks++; end
    // Wrong-generation responses retire every reserved read but may not
    // enter the broadcaster or turn this object into a successful completion.
    source_rsp='0; source_rsp.epoch=context_data.pcore_epoch+1'b1;
    source_rsp_valid=1;
    repeat(STORE_RESPONSE_DEPTH) begin @(posedge clk); if(!source_rsp_ready) $fatal(1,"KVB did not drain failed read"); end
    @(negedge clk); source_rsp_valid=0;
    wait(source_done_valid); @(negedge clk);
    if(source_done.status!=GC_SOURCE_PROTOCOL||!source_error||(|source_out_valid)) $fatal(1,"KVB bad tag leaked to consumers");
    flush();
    if(source_error||source_done_valid) $fatal(1,"KVB clear did not recover");
    $display("tb_gcore_kv PASS rejected_packets=%0d two_word_capacity=1 commit_after_write=1 duplicate_tile=1 memory_bounds=1 bank_collision=1 paired_response_stall=1 kvb_credit_limit=%0d kvb_bad_tag=1 cancel_recovery=1 checks=%0d",rejections,STORE_RESPONSE_DEPTH,checks);
    $finish;
  end
  initial begin #100000; $fatal(1,"KV unit watchdog"); end
endmodule
