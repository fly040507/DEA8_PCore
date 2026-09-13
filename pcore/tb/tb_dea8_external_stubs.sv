`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;
module tb_dea8_external_stubs;
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,pipe_en=1,xbc_enable=0,xbc_valid,xbc_last;
  logic [N_CORE-1:0] xbc_ready='0,kvb_ready='0;
  logic [DW_XBC-1:0] xbc_q;
  logic [2*SCALE_BITS-1:0] xbc_e;
  logic [ROW_BITS-1:0] xbc_row,xbc_blk;
  logic [DW_XBC/ACT_BITS-1:0] xbc_lane_mask;
  logic [EPOCH_BITS-1:0] xbc_epoch,kvb_epoch;
  logic kv_request_valid=0,kv_request_ready,kvb_valid,kvb_kind,kvb_last;
  matrix_job_t kv_request;
  logic [DW_ACT-1:0] kvb_q;
  logic [SCALE_BITS-1:0] kvb_e;
  logic [BLOCK_BITS-1:0] kvb_blk_id;
  logic [TILE_IDX_BITS-1:0] kvb_key_lane,kvb_feat_blk;
  logic [TILE-1:0] kvb_valid_mask;
  logic cnet_valid=0,cnet_ready;
  logic [DW_CNET-1:0] cnet_data='0;
  logic [7:0] cnet_tag=0;
  logic [1:0] cnet_mode=0;
  integer cnet_received;
  logic start=0,busy,done,hbm_valid,hbm_ready=0;
  logic [HBM_BITS-1:0] hbm_data;
  int cycle=0,nx=0,nk=0,nh=0,nc=0;
  dea8_gcore_stub #(.CNET_TAG_BITS(8)) gcore (.*);
  dea8_hbm_stub #(.TILE_COUNT(2)) hbm (.*);
  always @(posedge clk) if(rst_n) begin
    if(xbc_valid && (&xbc_ready) && pipe_en) begin
      if(xbc_row!=nx/32 || xbc_blk!=(nx%32)*2 || xbc_last!=(nx==SUFFIX_LEN*32-1) ||
         xbc_q!={32{8'd1}} || xbc_e!={2{8'd133}}) $fatal(1,"XBC stub sequence");
      nx++;
    end
    if(kvb_valid && (&kvb_ready) && pipe_en) begin
      if(kvb_kind || kvb_blk_id!=3 || kvb_epoch!=5 || kvb_key_lane!=nk%TILE ||
         kvb_feat_blk!=nk/TILE || kvb_last!=(nk==HEAD_TILES*TILE-1)) $fatal(1,"KVB K stub sequence");
      nk++;
    end
    if(hbm_valid && hbm_ready) begin
      if(nh%HBM_BEATS_PER_TILE<WEIGHT_HBM_BEATS_PER_TILE) begin
        if(hbm_data!={HBM_BITS/WEIGHT_BITS{8'd1}}) $fatal(1,"HBM payload beat");
      end else if(hbm_data[SCALE_WORD_BITS-1:0]!={TILE{8'd133}} || hbm_data[HBM_BITS-1:SCALE_WORD_BITS]!='0)
        $fatal(1,"HBM scale beat");
      nh++;
    end
    if(cnet_valid && cnet_ready && pipe_en) nc++;
  end
  initial begin
    kv_request='0;kv_request.ctx.block_id=3;kv_request.ctx.epoch=5;
    if($test$plusargs("V_UNCONFIRMED")) kv_request.op=MATRIX_PV;
    repeat(3) @(negedge clk);rst_n=1;start=1;kv_request_valid=1;xbc_enable=1;
    @(negedge clk);start=0;kv_request_valid=0;
    while(nx<SUFFIX_LEN*32 || nk<HEAD_TILES*TILE || nh<2*HBM_BEATS_PER_TILE) begin
      cycle++;
      pipe_en=cycle%7!=0;
      xbc_ready='1;kvb_ready='1;
      xbc_ready[0]=cycle%5!=0;kvb_ready[0]=cycle%3!=0;
      hbm_ready=cycle%4!=0;cnet_valid=cycle<30;
      @(negedge clk);
    end
    cnet_valid=0;
    if(cnet_received!=nc) $fatal(1,"CNET sink did not honor pipe_en");
    $display("tb_dea8_external_stubs PASS: XBC, KVB K, HBM 8+1 beats, CNET handshake");
    $finish;
  end
  initial begin #100000;$fatal(1,"External stub timeout");end
endmodule
