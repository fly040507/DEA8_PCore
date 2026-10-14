`timescale 1ns/1ps
import pcore_pkg::*;
import dea8_tile_link_pkg::*;
module tb_dynamic_kv_output;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,start_valid=0,quant_valid=0,quant_ready;
  pcore_job_t context_job='0;job_token_t context_token=32'h12340099;
  kv_quant_t quant='0;
  logic kv_hdr_valid,kv_hdr_ready=0,kv_out_valid,kv_out_ready=0,kv_out_last;
  logic kv_commit_valid=0,kv_commit_ready,done,protocol_error;
  tile_header_t kv_hdr;tile_commit_t kv_commit='0;
  logic [ROW_BITS-1:0] kv_out;
  dea8_pcore_output dut(.*);
  int checked_words=0,negative_checks=0;
  bit allow_error=0;
  function automatic logic [$bits(kv_quant_t)-1:0] fixture(input int nt,index);
    kv_quant_t q;
    q='0;q.token=context_token;q.tile=TILE_BITS'(nt);q.index=6'(index);
    q.mask=context_job.op==OP_K_PROJ?row_mask_for_rows(ROWS,index):2'b11;
    q.last=index==(context_job.op==OP_K_PROJ?PAIRS-1:V_PACKETS_PER_TILE-1);
    for(int t=0;t<TILE;t++)q.token_mask[t]=context_job.op==OP_K_PROJ||index/(TILE/ROW_LANES)*TILE+t<ROWS;
    for(int h=0;h<ROW_LANES;h++)begin
      q.entry[h].scale=8'(130+nt+h);
      for(int i=0;i<TILE;i++)q.entry[h].data[i*INT_BITS+:INT_BITS]=8'(nt*53+index*7+h*19+i);
    end
    return q;
  endfunction
  task automatic flush;
    @(negedge clk);clear=1;quant_valid=0;kv_commit_valid=0;kv_hdr_ready=0;kv_out_ready=0;
    @(negedge clk);clear=0;allow_error=0;
    if(protocol_error||done||dut.sender.busy)$fatal(1,"KV output clear failed");
  endtask
  task automatic start(input pcore_op_e op);
    @(negedge clk);context_job='0;context_job.op=op;context_job.kv_column_base0=48;
    context_job.kv_column_base1=op==OP_K_PROJ?176:64;
    context_job.transfer_context=9;context_job.data_context=17;start_valid=1;
    context_job.transfer_epoch=16'h9876;
    @(negedge clk);start_valid=0;
  endtask
  task automatic produce(input int nt);
    for(int j=0;j<(context_job.op==OP_K_PROJ?PAIRS:V_PACKETS_PER_TILE);j++)begin
      @(negedge clk);quant=fixture(nt,j);quant_valid=1;
      do @(posedge clk);while(!quant_ready);@(negedge clk);quant_valid=0;
    end
  endtask
  task automatic consume(input int nt,input bit bad_commit=0);
    tile_header_t h;kv_quant_t q;logic [ROW_BITS-1:0] expected,held;
    int words,index,lane;
    while(!kv_hdr_valid)@(negedge clk);h=kv_hdr;
    repeat(5)begin @(negedge clk);if(!kv_hdr_valid||kv_hdr!==h)$fatal(1,"KV output header changed");end
    if(h.tile_seq!=nt||h.transfer_epoch!=context_job.transfer_epoch||
      h.column_base!=(nt==0?48:(context_job.op==OP_K_PROJ?176:64)))$fatal(1,"KV output Tile coordinates/global epoch");
    kv_hdr_ready=1;@(posedge clk);@(negedge clk);kv_hdr_ready=0;
    words=context_job.op==OP_K_PROJ?ROWS:V_GROUPS*TILE;
    for(int w=0;w<words;w++)begin
      while(!kv_out_valid)@(negedge clk);held=kv_out;index=w/ROW_LANES;lane=w%ROW_LANES;
      q=fixture(nt,index);expected={q.entry[lane].scale,q.entry[lane].data};
      for(int i=0;i<TILE;i++)if(!q.token_mask[i])expected[i*INT_BITS+:INT_BITS]=0;
      repeat(w%3)begin @(negedge clk);if(!kv_out_valid||kv_out!==held||kv_out_last!=(w==words-1))$fatal(1,"KV output held data/last");end
      if(kv_out!==expected||kv_out_last!=(w==words-1))$fatal(1,"KV output word/padding w=%0d",w);
      kv_out_ready=1;@(posedge clk);checked_words++;@(negedge clk);kv_out_ready=0;
    end
    repeat(7)begin @(negedge clk);if(done||!dut.sender.busy)$fatal(1,"KV output release before commit");end
    kv_commit='0;kv_commit.transfer_id=h.transfer_id;kv_commit.transfer_epoch=h.transfer_epoch;
    kv_commit.tile_seq=h.tile_seq;kv_commit.source_id=h.source_id;
    if(bad_commit)begin kv_commit.transfer_epoch++;allow_error=1;end
    kv_commit_valid=1;@(posedge clk);if(!kv_commit_ready)$fatal(1,"KV output commit not accepted");
    @(negedge clk);kv_commit_valid=0;
    if(bad_commit)begin
      if(!protocol_error||!dut.sender.busy||done)$fatal(1,"KV bad commit released ownership");
      negative_checks++;
    end
  endtask
  always @(posedge clk)begin #1;if(protocol_error&&!allow_error)$fatal(1,"Unexpected KV output fault");end
  initial begin
    repeat(32)@(negedge clk);reset=0;
    for(int op=1;op<=2;op++)begin
      start(pcore_op_e'(op));
      fork begin produce(0);produce(1);end begin consume(0);consume(1);end join
      while(!done)@(negedge clk);
    end
    for(int kind=0;kind<6;kind++)begin
      flush();start(OP_K_PROJ);quant=fixture(0,0);
      case(kind)
        0:quant.token++;
        1:quant.index=1;
        2:quant.mask=1;
        3:quant.token_mask=7;
        4:quant.last=1;
        5:quant.tile=1;
      endcase
      allow_error=1;quant_valid=1;@(posedge clk);@(negedge clk);quant_valid=0;
      if(!protocol_error||dut.sender.busy||done)$fatal(1,"Malformed quant entered sender kind=%0d",kind);
      negative_checks++;
    end
    flush();start(OP_K_PROJ);fork produce(0);consume(0,1);join
    flush();start(OP_K_PROJ);allow_error=1;kv_commit_valid=1;
    @(posedge clk);@(negedge clk);kv_commit_valid=0;
    if(!protocol_error||done)$fatal(1,"Early KV commit accepted");negative_checks++;
    flush();start(OP_K_PROJ);quant=fixture(0,0);quant_valid=1;
    @(posedge clk);@(negedge clk);quant_valid=0;repeat(6)@(negedge clk);
    if(!dut.sender.busy)$fatal(1,"Cancel fixture not live");flush();
    start(OP_V_PROJ);fork begin produce(0);produce(1);end begin consume(0);consume(1);end join
    while(!done)@(negedge clk);
    $display("tb_dynamic_kv_output PASS words=%0d malformed_quant=6 bad_commit=1 early_commit=1 negative_checks=%0d header_data_hold=1 V_padding_zero=1 partial_tile_cancel=1 next_job_without_clear=1",checked_words,negative_checks);
    $finish;
  end
  initial begin #500000;$fatal(1,"KV output watchdog");end
endmodule
