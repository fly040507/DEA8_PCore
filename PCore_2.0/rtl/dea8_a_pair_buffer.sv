import pcore2_pkg::*;
// QOZ: MEM_TILES=32, BANKS=1. PBUF: MEM_TILES=1, BANKS=2.
// Each parity has physically separate data and exponent RAMs.
module dea8_a_pair_buffer #(
  parameter int MEM_TILES=32,BANKS=1,
  parameter int ADDR_BITS=$clog2(MEM_TILES*BANKS*PAIRS)
) (
  input logic clk,reset,clear,
  input logic [1:0] wr_mask,
  input logic wr_bank,
  input logic [TILE_BITS-1:0] wr_tile,
  input logic [PAIR_BITS-1:0] wr_pair,
  input logic [1:0][DATA_BITS-1:0] wr_data,
  input logic [1:0][SCALE_BITS-1:0] wr_scale,
  input logic rd_valid,
  output logic rd_ready,
  input logic rd_bank,
  input logic [TILE_BITS-1:0] rd_tile,rd_emit_tile,
  input logic [PAIR_BITS-1:0] rd_pair,
  input logic rd_slot,
  input logic [EPOCH_BITS-1:0] rd_epoch,
  output logic out_valid,
  input logic out_ready,
  output a2_t out_entry,
  output logic [EPOCH_BITS-1:0] out_epoch
);
  localparam int DEPTH=MEM_TILES*BANKS*PAIRS;
  logic [ADDR_BITS-1:0] wa,ra;
  logic [DEPTH-1:0] initialized[0:1];
  logic read_in_range,write_in_range,conflict;
  logic [1:0] read_mask;
  assign read_mask=row_mask(rd_pair);
  assign wa=ADDR_BITS'((wr_bank*PAIRS+wr_pair)*MEM_TILES+wr_tile);
  assign ra=ADDR_BITS'((rd_bank*PAIRS+rd_pair)*MEM_TILES+rd_tile);
  assign read_in_range=rd_bank<BANKS && rd_tile<MEM_TILES && rd_pair<PAIRS;
  assign write_in_range=wr_bank<BANKS && wr_tile<MEM_TILES && wr_pair<PAIRS;
  assign conflict=(|wr_mask) && write_in_range && wa==ra;
  assign rd_ready=!reset && !clear && (!out_valid || out_ready) &&
    read_in_range && initialized[0][ra] &&
    (!read_mask[1] || initialized[1][ra]) && !conflict;

  for(genvar r=0;r<ROW_LANES;r++) begin : g_parity
    (* ram_style="block" *) logic [DATA_BITS-1:0] data_mem[0:DEPTH-1];
    (* ram_style="block" *) logic [SCALE_BITS-1:0] scale_mem[0:DEPTH-1];
    always_ff @(posedge clk) begin
      if(!reset && !clear && wr_mask[r] && write_in_range) begin
        data_mem[wa]<=wr_data[r];scale_mem[wa]<=wr_scale[r];
      end
      if(rd_valid && rd_ready) begin
        out_entry.data[r]<=data_mem[ra];
        out_entry.scale[r]<=scale_mem[ra];
      end
      if(reset || clear) initialized[r]<='0;
      else if(wr_mask[r] && write_in_range) initialized[r][wa]<=1;
    end
  end
  always_ff @(posedge clk) begin
    if(reset || clear) out_valid<=0;
    else if(!out_valid || out_ready) begin
      out_valid<=rd_valid && rd_ready;
      if(rd_valid && rd_ready) begin
        out_entry.reserved<=0;out_entry.row_valid<=row_mask(rd_pair);
        out_entry.pair_idx<=rd_pair;out_entry.tile_idx<=rd_emit_tile;
        out_entry.slot<=rd_slot;out_epoch<=rd_epoch;
      end
    end
  end
  // Invalid odd tail RAM is intentionally not initialized; row_valid masks it.
  // A writer for an odd row uses mask 10 and lane 1, not mask 01.
  // synthesis translate_off
  always @(posedge clk) if(!reset && !clear && |wr_mask) begin
    if(!write_in_range || (wr_mask & ~row_mask(wr_pair))!=0)
      $fatal(1,"Pair buffer invalid write address/mask");
  end
  // synthesis translate_on
endmodule
