`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;
module tb_dea8_kvb_stream;
  localparam int ENTRIES=MATRIX_JOB_COUNT*HEAD_TILES*TILE;
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,start=0,kvb_valid=0,kvb_ready,b_valid,b_ready=0;
  logic [HEAD_BITS-1:0] head=1;
  logic [EPOCH_BITS-1:0] epoch=2,kvb_epoch,mask_epoch;
  logic [DW_ACT-1:0] kvb_q,b_data;
  logic [SCALE_BITS-1:0] kvb_e,b_scale;
  logic kvb_kind,kvb_last,mask_valid,protocol_error;
  logic [BLOCK_BITS-1:0] kvb_blk_id,mask_block=0;
  logic [TILE_IDX_BITS-1:0] kvb_key_lane,kvb_feat_blk;
  logic [TILE-1:0] kvb_valid_mask,mask_data;
  logic [31:0] random_q=32'h119763fa;
  int accepted=0,consumed=0,run_id=0,expected_run=0,exchanges=0;
  bit consume_enable=0;
  assign mask_epoch=epoch;
  dea8_kvb_stream dut (.*);
  function automatic logic [DW_ACT-1:0] payload(input int run_number,index);
    logic [DW_ACT-1:0] value;
    for(int k=0;k<TILE;k++) value[k*ACT_BITS+:ACT_BITS]=ACT_BITS'(run_number*41+index*13+k*17);
    return value;
  endfunction
  task automatic set_entry(input int index);
    matrix_block_job_t descriptor;
    descriptor=attention_block_job(index/(HEAD_TILES*TILE),head,epoch);
    kvb_valid=1;kvb_q=payload(run_id,index);kvb_e=SCALE_BITS'(index*7+run_id);
    kvb_kind=descriptor.op==MATRIX_PV;kvb_blk_id=descriptor.ctx.block_id;kvb_epoch=epoch;
    kvb_feat_blk=TILE_IDX_BITS'((index/TILE)%HEAD_TILES);kvb_key_lane=TILE_IDX_BITS'(index%TILE);
    kvb_last=index%(HEAD_TILES*TILE)==HEAD_TILES*TILE-1;
    for(int n=0;n<TILE;n++) kvb_valid_mask[n]=int'(kvb_blk_id)*TILE+n<LOGICAL_SEQ;
  endtask
  task automatic restart(input int new_run);
    @(negedge clk);start=1;kvb_valid=0;consume_enable=0;
    run_id=new_run;expected_run=new_run;epoch=EPOCH_BITS'(new_run+2);
    @(negedge clk);start=0;
    if(b_valid || dut.received_q!=0 || dut.kvfifo.count!=0 || mask_valid)
      $fatal(1,"KVB synchronous restart left stale state");
  endtask
  always @(negedge clk) begin
    random_q={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
    b_ready=consume_enable && random_q[0];
  end
  always @(posedge clk) if(rst_n) begin
    if(start) begin accepted=0;consumed=0;end
    else begin
      if(kvb_valid && kvb_ready) accepted++;
      if(b_valid && b_ready) begin
        if(b_data!==payload(expected_run,consumed) || b_scale!==SCALE_BITS'(consumed*7+expected_run))
          $fatal(1,"KVB payload-only FIFO lost order across jobs/epochs");
        consumed++;
      end
      if(dut.kvfifo.count==KVFIFO_DEPTH && dut.kvfifo.push && dut.kvfifo.pop) exchanges++;
    end
  end
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    restart(0);
    for(int i=0;i<KVFIFO_DEPTH;i++) begin
      @(negedge clk);set_entry(i);do @(posedge clk);while(!kvb_ready);
    end
    @(negedge clk);kvb_valid=0;
    if(!mask_valid || mask_data!=='1 || consumed!=0 || dut.kvfifo.count!=KVFIFO_DEPTH)
      $fatal(1,"Mask was not committed on RX before FIFO consumption");
    // Clear a full FIFO, then finish two complete Top Jobs without hard reset.
    for(int run_number=1;run_number<=2;run_number++) begin
      restart(run_number);consume_enable=1;
      for(int i=0;i<ENTRIES;i++) begin
        @(negedge clk);set_entry(i);do @(posedge clk);while(!kvb_ready);
      end
      @(negedge clk);kvb_valid=0;
      wait(consumed==ENTRIES);@(negedge clk);
      if(accepted!=ENTRIES || protocol_error || b_valid || kvb_ready) $fatal(1,"KVB final count/ready");
    end
    if(exchanges==0) $fatal(1,"KVB full exchange not exercised");
    $display("tb_dea8_kvb_stream PASS: RX metadata strip, mask timing, full clear, two Top Jobs, epochs, mixed jobs, exact count");
    $finish;
  end
  initial begin #3000000;$fatal(1,"KVB stream timeout");end
endmodule
