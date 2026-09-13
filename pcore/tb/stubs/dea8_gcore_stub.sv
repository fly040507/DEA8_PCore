import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// Simulation fixture for the documented outer buses, NOT GCore arithmetic.
// CNET tag encoding is intentionally opaque and must be supplied by its owner.
// V_COLUMN_PROFILE is an explicit experimental opt-in, NOT a frozen KVB rule.
module dea8_gcore_stub #(
  parameter int CNET_TAG_BITS=1,
  parameter bit V_COLUMN_PROFILE=0
) (
  input logic clk,rst_n,pipe_en,
  input logic xbc_enable,
  output logic xbc_valid,
  input logic [N_CORE-1:0] xbc_ready,
  output logic [DW_XBC-1:0] xbc_q,
  output logic [2*SCALE_BITS-1:0] xbc_e,
  output logic [ROW_BITS-1:0] xbc_row,
  output logic [ROW_BITS-1:0] xbc_blk,
  output logic [DW_XBC/ACT_BITS-1:0] xbc_lane_mask,
  output logic xbc_last,
  output logic [EPOCH_BITS-1:0] xbc_epoch,
  input logic kv_request_valid,
  output logic kv_request_ready,
  input matrix_job_t kv_request,
  output logic kvb_valid,
  input logic [N_CORE-1:0] kvb_ready,
  output logic [DW_ACT-1:0] kvb_q,
  output logic [SCALE_BITS-1:0] kvb_e,
  output logic kvb_kind,
  output logic [BLOCK_BITS-1:0] kvb_blk_id,
  output logic [TILE_IDX_BITS-1:0] kvb_key_lane,kvb_feat_blk,
  output logic [TILE-1:0] kvb_valid_mask,
  output logic kvb_last,
  output logic [EPOCH_BITS-1:0] kvb_epoch,
  input logic cnet_valid,
  output logic cnet_ready,
  input logic [DW_CNET-1:0] cnet_data,
  input logic [CNET_TAG_BITS-1:0] cnet_tag,
  input logic [1:0] cnet_mode,
  output integer cnet_received
);
  localparam int XBC_WORDS=SUFFIX_LEN*D_MODEL/(DW_XBC/ACT_BITS);
  int unsigned xbc_count,kv_count;
  logic kv_active;
  matrix_job_t ctx_q;
  assign xbc_valid=rst_n && xbc_enable && xbc_count<XBC_WORDS;
  assign xbc_q={DW_XBC/ACT_BITS{8'd1}};
  assign xbc_e={2{8'd133}};
  assign xbc_row=ROW_BITS'(xbc_count/(D_MODEL/(DW_XBC/ACT_BITS)));
  assign xbc_blk=ROW_BITS'((xbc_count%(D_MODEL/(DW_XBC/ACT_BITS)))*2);
  assign xbc_lane_mask='1;
  assign xbc_last=xbc_count==XBC_WORDS-1;
  assign xbc_epoch='0;
  assign kv_request_ready=rst_n && !kv_active;
  assign kvb_valid=rst_n && kv_active;
  assign kvb_q={TILE{8'd1}};
  assign kvb_e=8'd133;
  assign kvb_kind=ctx_q.op==MATRIX_PV;
  assign kvb_blk_id=ctx_q.ctx.block_id;
  assign kvb_epoch=ctx_q.ctx.epoch;
  assign kvb_feat_blk=TILE_IDX_BITS'(kv_count/TILE);
  assign kvb_key_lane=TILE_IDX_BITS'(kv_count%TILE);
  assign kvb_valid_mask='1;
  assign kvb_last=kv_count==HEAD_TILES*TILE-1;
  assign cnet_ready=rst_n;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin xbc_count<=0;kv_count<=0;kv_active<=0;ctx_q<='0;cnet_received<=0;end
    else begin
      if(!xbc_enable) xbc_count<=0;
      else if(xbc_valid && (&xbc_ready) && pipe_en) xbc_count<=xbc_count+1;
      if(kv_request_valid && kv_request_ready) begin ctx_q<=kv_request;kv_count<=0;kv_active<=1;end
      if(kvb_valid && (&kvb_ready) && pipe_en) begin
        if(kvb_last) kv_active<=0;
        else kv_count<=kv_count+1;
      end
      if(cnet_valid && cnet_ready && pipe_en) cnet_received<=cnet_received+1;
    end
  end
  always @(posedge clk) if(rst_n) begin
    if(kv_request_valid && kv_request_ready && kv_request.op==MATRIX_PV && !V_COLUMN_PROFILE)
      $fatal(1,"KVB V packing is not confirmed; experimental column profile disabled");
    if(cnet_valid && cnet_mode>1) $fatal(1,"Reserved CNET mode");
  end
endmodule
