import dea8_pcore_pkg::*;

// Preserve the original beat until BOTH sub-blocks have been accepted.
module dea8_xbc_adapter #(
  parameter int FIFO_DEPTH = 32,
  parameter int X_BLOCK_BITS = $clog2(D_MODEL/TILE)
) (
  input logic clk,rst_n,
  input logic xbc_valid,
  output logic xbc_ready,
  input logic [2*DW_ACT-1:0] xbc_q,
  input logic [2*SCALE_BITS-1:0] xbc_e,
  input logic [ROW_BITS-1:0] xbc_row,
  input logic [X_BLOCK_BITS-1:0] xbc_blk,
  input logic [2*TILE-1:0] xbc_lane_mask,
  input logic xbc_last,
  input logic [EPOCH_BITS-1:0] xbc_epoch,
  output logic a_valid,
  input logic a_ready,
  output logic [DW_ACT-1:0] a_data,
  output logic [SCALE_BITS-1:0] a_scale,
  output logic [ROW_BITS-1:0] a_row,
  output logic [X_BLOCK_BITS-1:0] a_block,
  output logic [TILE-1:0] a_lane_mask,
  output logic a_last,
  output logic [EPOCH_BITS-1:0] a_epoch
);
  typedef struct packed {
    logic [2*DW_ACT-1:0] q;
    logic [2*SCALE_BITS-1:0] e;
    logic [ROW_BITS-1:0] row;
    logic [X_BLOCK_BITS-1:0] block_id;
    logic [2*TILE-1:0] mask;
    logic last;
    logic [EPOCH_BITS-1:0] epoch;
  } beat_t;
  beat_t incoming,front;
  logic fifo_valid,slot_q;
  assign incoming={xbc_q,xbc_e,xbc_row,xbc_blk,xbc_lane_mask,xbc_last,xbc_epoch};
  dea8_stream_fifo #(.WIDTH($bits(beat_t)),.DEPTH(FIFO_DEPTH)) xfifo (
    .clk,.rst_n,.in_valid(xbc_valid),.in_ready(xbc_ready),.in_data(incoming),
    .out_valid(fifo_valid),.out_ready(a_valid && a_ready && slot_q),.out_data(front),.count()
  );
  assign a_valid=rst_n && fifo_valid;
  assign a_data=front.q[slot_q*DW_ACT+:DW_ACT];
  assign a_scale=front.e[slot_q*SCALE_BITS+:SCALE_BITS];
  assign a_row=front.row;
  assign a_block=front.block_id+X_BLOCK_BITS'(slot_q);
  assign a_lane_mask=front.mask[slot_q*TILE+:TILE];
  assign a_last=front.last && slot_q;
  assign a_epoch=front.epoch;
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) slot_q<=0;
    else if(a_valid && a_ready) slot_q<=!slot_q;
  end
  // synthesis translate_off
  always @(posedge clk) if(rst_n && xbc_valid && xbc_ready) begin
    if(xbc_row>=SUFFIX_LEN || int'(xbc_blk)+1>=D_MODEL/TILE)
      $fatal(1,"XBC row/block out of range");
  end
  // synthesis translate_on
endmodule
