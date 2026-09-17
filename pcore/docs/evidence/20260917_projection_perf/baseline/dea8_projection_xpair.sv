import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// One XBC pair of K tiles (2 x 51 rows). Fill and compute do not overlap.
// GCore replays XHAT for each output-column tile; no full XHAT cache is implied.
module dea8_projection_xpair (
  input logic clk,rst_n,clear,enable,release_pair,
  input logic [PROJ_K_BITS-1:0] expected_pair,
  input logic [EPOCH_BITS-1:0] expected_epoch,
  input logic xbc_valid,
  output logic xbc_ready,
  input logic [2*DW_ACT-1:0] xbc_q,
  input logic [2*SCALE_BITS-1:0] xbc_e,
  input logic [ROW_BITS-1:0] xbc_row,
  input logic [PROJ_K_BITS-1:0] xbc_blk,
  input logic [2*TILE-1:0] xbc_lane_mask,
  input logic xbc_last,
  input logic [EPOCH_BITS-1:0] xbc_epoch,
  output logic full,protocol_error,
  input logic rd_en,rd_half,
  input logic [ROW_BITS-1:0] rd_row,
  output logic [DW_ACT-1:0] rd_data,
  output logic [SCALE_BITS-1:0] rd_scale
);
  logic [DW_ACT-1:0] data_mem[0:1][0:SUFFIX_LEN-1];
  logic [SCALE_BITS-1:0] scale_mem[0:1][0:SUFFIX_LEN-1];
  logic [ROW_BITS:0] received_q;
  logic bad,rx_fire;
  assign full=received_q==SUFFIX_LEN;
  assign bad=rst_n && !clear && enable && !full && xbc_valid &&
    (xbc_row!=received_q || xbc_blk!=expected_pair || xbc_epoch!=expected_epoch ||
     xbc_lane_mask!={2*TILE{1'b1}} ||
     xbc_last!=(expected_pair==PROJ_K_TILES-2 && received_q==SUFFIX_LEN-1));
  assign xbc_ready=rst_n && !clear && enable && !full && !protocol_error && !bad;
  assign rx_fire=xbc_valid && xbc_ready;
  always_ff @(posedge clk) begin
    if(rx_fire) for(int half=0;half<2;half++) begin
      data_mem[half][xbc_row]<=xbc_q[half*DW_ACT+:DW_ACT];
      scale_mem[half][xbc_row]<=xbc_e[half*SCALE_BITS+:SCALE_BITS];
    end
    if(rd_en && !clear) begin
      rd_data<=data_mem[rd_half][rd_row];
      rd_scale<=scale_mem[rd_half][rd_row];
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin received_q<='0;protocol_error<=0;end
    else if(clear) begin received_q<='0;protocol_error<=0;end
    else begin
      if(bad) protocol_error<=1;
      if(release_pair) received_q<='0;
      else if(rx_fire) received_q<=received_q+1'b1;
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(rst_n && !clear) begin
    if(bad) $fatal(1,"Projection XBC context/order mismatch");
    if(rd_en && (!full || rd_row>=SUFFIX_LEN)) $fatal(1,"Projection read of incomplete A pair");
    if(release_pair && rx_fire) $fatal(1,"Projection pair overwrite");
  end
  // synthesis translate_on
endmodule
