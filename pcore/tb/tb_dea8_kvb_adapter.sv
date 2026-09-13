`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;
module tb_dea8_kvb_adapter;
  localparam int ENTRIES=HEAD_TILES*TILE;
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0,kvb_valid=0,kvb_ready,kvb_kind,kvb_last;
  logic [DW_ACT-1:0] kvb_q;
  logic [SCALE_BITS-1:0] kvb_e;
  logic [BLOCK_BITS-1:0] kvb_blk_id,mask_block;
  logic [TILE_IDX_BITS-1:0] kvb_key_lane,kvb_feat_blk;
  logic [TILE-1:0] kvb_valid_mask,mask_data;
  logic [EPOCH_BITS-1:0] kvb_epoch,mask_epoch;
  logic expect_valid=0,expect_ready,b_valid,b_ready=0,mask_valid,protocol_error;
  logic [DW_ACT-1:0] b_data;
  logic [SCALE_BITS-1:0] b_scale;
  matrix_job_t expect_job;
  int received=0,cycle=0;
  logic draining=0;
  dea8_kvb_adapter #(.FIFO_DEPTH(3*ENTRIES),.V_KEY_LANE_IS_COLUMN(1)) dut (.*);
  always @(negedge clk) begin
    cycle++;
    b_ready=draining && cycle%5!=0;
  end
  always @(posedge clk) if(rst_n && b_valid && b_ready) begin
    if(b_data!==DW_ACT'(received) || b_scale!==SCALE_BITS'(received))
      $fatal(1,"KVB payload lost or reordered");
    received++;
  end
  task automatic send(input int jobno,input int idx);
    kvb_valid=1;
    kvb_q=DW_ACT'(jobno*ENTRIES+idx); kvb_e=SCALE_BITS'(jobno*ENTRIES+idx);
    kvb_kind=jobno==1; kvb_blk_id=BLOCK_BITS'(N_KV_BLOCK-1-(jobno==2));
    kvb_key_lane=TILE_IDX_BITS'(idx%TILE); kvb_feat_blk=TILE_IDX_BITS'(idx/TILE);
    kvb_valid_mask=jobno==2 ? '1 : TILE'((1<<(LOGICAL_SEQ%TILE))-1);
    kvb_last=idx==ENTRIES-1; kvb_epoch=1;
    if(idx==0 && jobno==0) begin
      if($test$plusargs("BAD_KIND")) kvb_kind=1;
      if($test$plusargs("BAD_BLOCK")) kvb_blk_id=0;
      if($test$plusargs("BAD_EPOCH")) kvb_epoch=2;
      if($test$plusargs("BAD_COLUMN")) kvb_key_lane=1;
      if($test$plusargs("BAD_TILE")) kvb_feat_blk=1;
      if($test$plusargs("EARLY_LAST")) kvb_last=1;
      if($test$plusargs("PADDING")) kvb_valid_mask='1;
    end
    if($test$plusargs("LATE_LAST") && idx==ENTRIES-1) kvb_last=0;
    if($test$plusargs("MASK_CHANGE") && jobno==1) kvb_valid_mask=1;
    if($test$plusargs("V_COLUMN") && jobno==1 && idx==0) kvb_key_lane=1;
    do @(posedge clk); while(!kvb_ready);
    @(negedge clk); kvb_valid=0;
  endtask
  initial begin
    repeat(3) @(negedge clk); rst_n=1;
    // K/V of one block and K of another arrive before any consumer context.
    for(int j=0;j<3;j++) for(int i=0;i<ENTRIES;i++) send(j,i);
    repeat(4) @(negedge clk);
    if(b_valid || received || kvb_ready) $fatal(1,"Prefetch escaped/full FIFO not exercised");
    draining=1;
    for(int j=0;j<3;j++) begin
      expect_job='0; expect_job.op=j==1 ? MATRIX_PV : MATRIX_QK;
      expect_job.ctx.block_id=BLOCK_BITS'(N_KV_BLOCK-1-(j==2)); expect_job.ctx.epoch=1;
      expect_valid=1;
      do @(posedge clk); while(!expect_ready);
      @(negedge clk); expect_valid=0;
      wait(received==(j+1)*ENTRIES);
      @(negedge clk); mask_block=expect_job.ctx.block_id; mask_epoch=1;
      @(negedge clk);
      if(!mask_valid || mask_data!=(j==2 ? {TILE{1'b1}} : TILE'((1<<(LOGICAL_SEQ%TILE))-1)))
        $fatal(1,"Mask lookup failed");
      repeat(4) @(negedge clk);
      if(b_valid) $fatal(1,"Next job escaped without expected context");
    end
    rst_n=0; @(negedge clk);
    if(mask_valid || b_valid || protocol_error) $fatal(1,"Reset failed");
    $display("tb_dea8_kvb_adapter PASS: prefetch, full FIFO, backpressure, K/V mask, reset");
    $finish;
  end
  initial begin #100000; $fatal(1,"KVB timeout"); end
endmodule
