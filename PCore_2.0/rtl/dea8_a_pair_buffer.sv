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
  input a_bank_ctrl_t begin_bank,commit_bank,
  output logic protocol_error,
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
  localparam int COUNT_BITS=$clog2(PAIRS*MEM_TILES+1);
  logic [ADDR_BITS-1:0] wa,ra;
  logic [DEPTH-1:0] initialized[0:1];
  logic [COUNT_BITS-1:0] written[0:BANKS-1][0:1];
  logic [BANKS-1:0] open_bank,complete_bank;
  logic [EPOCH_BITS-1:0] bank_epoch[0:BANKS-1];
  logic read_in_range,write_in_range,conflict,commit_complete,bad_ctrl;
  logic [1:0] read_mask;
  assign read_mask=row_mask(rd_pair);
  assign wa=ADDR_BITS'((wr_bank*PAIRS+wr_pair)*MEM_TILES+wr_tile);
  assign ra=ADDR_BITS'((rd_bank*PAIRS+rd_pair)*MEM_TILES+rd_tile);
  assign read_in_range=rd_bank<BANKS && rd_tile<MEM_TILES && rd_pair<PAIRS;
  assign write_in_range=wr_bank<BANKS && wr_tile<MEM_TILES && wr_pair<PAIRS;
  assign conflict=(|wr_mask) && write_in_range && wa==ra;
  assign commit_complete=commit_bank.valid && commit_bank.bank<BANKS &&
    written[commit_bank.bank][0]==PAIRS*MEM_TILES &&
    written[commit_bank.bank][1]==(PAIRS-(ROWS%2))*MEM_TILES;
  assign bad_ctrl=(begin_bank.valid && begin_bank.bank>=BANKS) ||
    (commit_bank.valid && (commit_bank.bank>=BANKS || !open_bank[commit_bank.bank] ||
      bank_epoch[commit_bank.bank]!=commit_bank.epoch || !commit_complete)) ||
    ((|wr_mask) && (!write_in_range || !open_bank[wr_bank] ||
      (begin_bank.valid && begin_bank.bank==wr_bank))) ||
    (begin_bank.valid && commit_bank.valid && begin_bank.bank==commit_bank.bank);
  assign rd_ready=!reset && !clear && (!out_valid || out_ready) &&
    read_in_range && complete_bank[rd_bank] && bank_epoch[rd_bank]==rd_epoch &&
    initialized[0][ra] &&
    (!read_mask[1] || initialized[1][ra]) && !conflict;

  for(genvar r=0;r<ROW_LANES;r++) begin : g_parity
    (* ram_style="block" *) logic [DATA_BITS-1:0] data_mem[0:DEPTH-1];
    (* ram_style="block" *) logic [SCALE_BITS-1:0] scale_mem[0:DEPTH-1];
    always_ff @(posedge clk) begin
      if(!reset && !clear && wr_mask[r] && write_in_range && open_bank[wr_bank] &&
         !(begin_bank.valid && begin_bank.bank==wr_bank)) begin
        data_mem[wa]<=wr_data[r];scale_mem[wa]<=wr_scale[r];
      end
      if(rd_valid && rd_ready) begin
        out_entry.data[r]<=data_mem[ra];
        out_entry.scale[r]<=scale_mem[ra];
      end
      if(reset || clear) initialized[r]<='0;
      else begin
        if(begin_bank.valid && begin_bank.bank<BANKS)
          for(int i=0;i<PAIRS*MEM_TILES;i++)
            initialized[r][begin_bank.bank*PAIRS*MEM_TILES+i]<=0;
        if(wr_mask[r] && write_in_range && open_bank[wr_bank] &&
           !(begin_bank.valid && begin_bank.bank==wr_bank))
          initialized[r][wa]<=1;
      end
    end
  end
  always_ff @(posedge clk) begin
    if(reset || clear) begin
      out_valid<=0;protocol_error<=0;open_bank<='0;complete_bank<='0;
      for(int b=0;b<BANKS;b++) begin
        bank_epoch[b]<=0;
        for(int r=0;r<ROW_LANES;r++) written[b][r]<=0;
      end
    end else begin
      if(bad_ctrl) protocol_error<=1;
      if(begin_bank.valid && begin_bank.bank<BANKS) begin
        open_bank[begin_bank.bank]<=1;complete_bank[begin_bank.bank]<=0;
        bank_epoch[begin_bank.bank]<=begin_bank.epoch;
        for(int r=0;r<ROW_LANES;r++) written[begin_bank.bank][r]<=0;
      end
      if(commit_bank.valid && !bad_ctrl) begin
        open_bank[commit_bank.bank]<=0;complete_bank[commit_bank.bank]<=1;
      end
      for(int r=0;r<ROW_LANES;r++)
        if(wr_mask[r] && write_in_range && open_bank[wr_bank] &&
           !initialized[r][wa] && !(begin_bank.valid && begin_bank.bank==wr_bank))
          written[wr_bank][r]<=written[wr_bank][r]+1'b1;
    end
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
    if(!write_in_range || (wr_mask & ~row_mask(wr_pair))!=0 || bad_ctrl)
      $fatal(1,"Pair buffer invalid write address/mask");
  end
  always @(posedge clk) if(!reset && !clear && begin_bank.valid &&
    rd_valid && rd_bank==begin_bank.bank)
    $fatal(1,"A bank replaced while reader active");
  // synthesis translate_on
endmodule
