import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// Two independently owned A-pair banks. RX follows the complete nt/pair stream;
// compute selects by context and releases only after the last MXU input issue.
// GCore still replays XHAT per nt. No full XHAT cache or external nt field.
module dea8_projection_xpair (
  input logic clk,rst_n,clear,enable,release_pair,
  input logic [PROJ_K_BITS-1:0] expected_pair,
  input logic [TILE_IDX_BITS-1:0] expected_nt,
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
  typedef enum logic [1:0] {EMPTY,FILL,READY,ACTIVE} pair_state_e;
  pair_state_e bank_state[0:1];
  logic [DW_ACT-1:0] data_mem[0:1][0:1][0:SUFFIX_LEN-1];
  logic [SCALE_BITS-1:0] scale_mem[0:1][0:1][0:SUFFIX_LEN-1];
  logic [PROJ_K_BITS-1:0] bank_pair[0:1],rx_pair_q;
  logic [TILE_IDX_BITS-1:0] bank_nt[0:1],rx_nt_q;
  logic [EPOCH_BITS-1:0] bank_epoch[0:1];
  logic [ROW_BITS-1:0] rx_row_q;
  logic rx_bank_q,rx_done_q,read_bank,rx_space;
  logic bad,rx_fire;
  assign rx_space=bank_state[rx_bank_q]==EMPTY || bank_state[rx_bank_q]==FILL;
  always_comb begin
    full=0;read_bank=0;
    for(int b=0;b<2;b++)
      if((bank_state[b]==READY || bank_state[b]==ACTIVE) &&
         bank_pair[b]==expected_pair && bank_nt[b]==expected_nt && bank_epoch[b]==expected_epoch) begin
        full=1;read_bank=1'(b);
      end
  end
  assign bad=rst_n && !clear && enable && !rx_done_q && xbc_valid &&
    (xbc_row!=rx_row_q || xbc_blk!=rx_pair_q || xbc_epoch!=expected_epoch ||
     xbc_lane_mask!={2*TILE{1'b1}} ||
     xbc_last!=(rx_pair_q==PROJ_K_TILES-2 && rx_row_q==SUFFIX_LEN-1));
  assign xbc_ready=rst_n && !clear && enable && !rx_done_q && rx_space && !protocol_error && !bad;
  assign rx_fire=xbc_valid && xbc_ready;
  always_ff @(posedge clk) begin
    if(rx_fire) for(int half=0;half<2;half++) begin
      data_mem[rx_bank_q][half][xbc_row]<=xbc_q[half*DW_ACT+:DW_ACT];
      scale_mem[rx_bank_q][half][xbc_row]<=xbc_e[half*SCALE_BITS+:SCALE_BITS];
    end
    if(rd_en && !clear) begin
      rd_data<=data_mem[read_bank][rd_half][rd_row];
      rd_scale<=scale_mem[read_bank][rd_half][rd_row];
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      rx_bank_q<=0;rx_row_q<='0;rx_pair_q<='0;rx_nt_q<='0;rx_done_q<=0;protocol_error<=0;
      for(int b=0;b<2;b++) begin bank_state[b]<=EMPTY;bank_pair[b]<='0;bank_nt[b]<='0;bank_epoch[b]<='0;end
    end else if(clear) begin
      rx_bank_q<=0;rx_row_q<='0;rx_pair_q<='0;rx_nt_q<='0;rx_done_q<=0;protocol_error<=0;
      for(int b=0;b<2;b++) bank_state[b]<=EMPTY;
    end
    else begin
      if(bad) protocol_error<=1;
      if(rx_fire) begin
        if(rx_row_q==0) begin
          bank_state[rx_bank_q]<=FILL;
          bank_pair[rx_bank_q]<=rx_pair_q;bank_nt[rx_bank_q]<=rx_nt_q;bank_epoch[rx_bank_q]<=expected_epoch;
        end
        if(rx_row_q==SUFFIX_LEN-1) begin
          bank_state[rx_bank_q]<=READY;rx_row_q<='0;rx_bank_q<=!rx_bank_q;
          if(rx_pair_q==PROJ_K_TILES-2) begin
            rx_pair_q<='0;
            if(rx_nt_q==PROJ_N_TILES-1) rx_done_q<=1;
            else rx_nt_q<=rx_nt_q+1'b1;
          end else rx_pair_q<=rx_pair_q+PROJ_K_BITS'(2);
        end else rx_row_q<=rx_row_q+1'b1;
      end
      if(rd_en) bank_state[read_bank]<=ACTIVE;
      if(release_pair) bank_state[read_bank]<=EMPTY;
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(rst_n && !clear) begin
    if(bad) $fatal(1,"Projection XBC context/order mismatch");
    if(rd_en && (!full || rd_row>=SUFFIX_LEN)) $fatal(1,"Projection read of incomplete A pair");
    if(rx_fire && (bank_state[rx_bank_q]==READY || bank_state[rx_bank_q]==ACTIVE))
      $fatal(1,"Projection RX overwrote owned A bank");
    if(rx_fire && (rd_en || release_pair) && rx_bank_q==read_bank)
      $fatal(1,"Projection A bank read/write collision");
    if(release_pair && (!full || bank_state[read_bank]!=ACTIVE || rd_en))
      $fatal(1,"Projection release without completed ACTIVE pair");
    if(bank_state[0]==ACTIVE && bank_state[1]==ACTIVE) $fatal(1,"Projection multiple ACTIVE pairs");
  end
  // synthesis translate_on
endmodule
