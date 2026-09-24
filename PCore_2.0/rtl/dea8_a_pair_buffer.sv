import pcore2_pkg::*;
// QOZ: MEM_TILES=32, BANKS=1. PBUF: MEM_TILES=1, BANKS=2.
// Each parity has physically separate data and exponent RAMs.
(* use_dsp="no" *) module dea8_a_pair_buffer #(
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
  output logic [BANKS-1:0] bank_complete,
  output logic [EPOCH_BITS-1:0] committed_epoch[0:BANKS-1],
  output logic [TILE_BITS-1:0] committed_base[0:BANKS-1],
  output logic [TILE_BITS:0] committed_tiles[0:BANKS-1],
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
  logic [TILE_BITS-1:0] region_base[0:BANKS-1];
  logic [TILE_BITS:0] region_tiles[0:BANKS-1];
  logic read_in_range,read_in_region,write_in_range,write_in_region;
  logic conflict,duplicate_write,commit_complete,bad_ctrl,write_ok;
  logic [COUNT_BITS-1:0] region_tile_count,expected_even,expected_odd;
  logic out_bank;
  logic [1:0] read_mask;
  assign bank_complete=complete_bank;
  assign read_mask=row_mask(rd_pair);
  assign wa=ADDR_BITS'((wr_bank*PAIRS+wr_pair)*MEM_TILES+wr_tile);
  assign ra=ADDR_BITS'((rd_bank*PAIRS+rd_pair)*MEM_TILES+rd_tile);
  assign read_in_range=rd_bank<BANKS && rd_tile<MEM_TILES && rd_pair<PAIRS;
  assign write_in_range=wr_bank<BANKS && wr_tile<MEM_TILES && wr_pair<PAIRS;
  assign read_in_region=read_in_range &&
    rd_tile>=region_base[rd_bank] &&
    rd_tile<region_base[rd_bank]+region_tiles[rd_bank];
  assign write_in_region=write_in_range && open_bank[wr_bank] &&
    wr_tile>=region_base[wr_bank] &&
    wr_tile<region_base[wr_bank]+region_tiles[wr_bank];
  assign conflict=(|wr_mask) && write_in_range && wa==ra;
  assign duplicate_write=(|wr_mask) && write_in_region &&
    ((wr_mask[0] && initialized[0][wa]) ||
     (wr_mask[1] && initialized[1][wa]));
  assign region_tile_count=COUNT_BITS'(region_tiles[commit_bank.bank]);
  assign expected_even=(region_tile_count<<4)+(region_tile_count<<3)+(region_tile_count<<1);
  assign expected_odd=(region_tile_count<<4)+(region_tile_count<<3)+region_tile_count;
  assign commit_complete=commit_bank.valid && commit_bank.bank<BANKS &&
    commit_bank.tile_base==region_base[commit_bank.bank] &&
    commit_bank.tile_count==region_tiles[commit_bank.bank] &&
    written[commit_bank.bank][0]==expected_even &&
    written[commit_bank.bank][1]==expected_odd;
  assign bad_ctrl=(begin_bank.valid &&
      (begin_bank.bank>=BANKS || begin_bank.tile_count==0 ||
       begin_bank.tile_base+begin_bank.tile_count>MEM_TILES ||
       open_bank[begin_bank.bank] ||
       (rd_valid && rd_bank==begin_bank.bank) ||
       (out_valid && out_bank==begin_bank.bank))) ||
    (commit_bank.valid && (commit_bank.bank>=BANKS || !open_bank[commit_bank.bank] ||
      bank_epoch[commit_bank.bank]!=commit_bank.epoch || !commit_complete)) ||
    ((|wr_mask) && (!write_in_region || duplicate_write ||
      (wr_mask & ~row_mask(wr_pair))!=0 ||
      (begin_bank.valid && begin_bank.bank==wr_bank))) ||
    (begin_bank.valid && commit_bank.valid && begin_bank.bank==commit_bank.bank);
  assign write_ok=(|wr_mask) && !reset && !clear && !protocol_error && !bad_ctrl &&
    write_in_region && !duplicate_write;
  assign rd_ready=!reset && !clear && !protocol_error && (!out_valid || out_ready) &&
    read_in_region && complete_bank[rd_bank] && bank_epoch[rd_bank]==rd_epoch &&
    initialized[0][ra] &&
    (!read_mask[1] || initialized[1][ra]) && !conflict;

  for(genvar r=0;r<ROW_LANES;r++) begin : g_parity
    (* ram_style="block" *) logic [DATA_BITS-1:0] data_mem[0:DEPTH-1];
    (* ram_style="block" *) logic [SCALE_BITS-1:0] scale_mem[0:DEPTH-1];
    always_ff @(posedge clk) begin
      if(write_ok && wr_mask[r]) begin
        data_mem[wa]<=wr_data[r];scale_mem[wa]<=wr_scale[r];
      end
      if(rd_valid && rd_ready) begin
        out_entry.data[r]<=data_mem[ra];
        out_entry.scale[r]<=scale_mem[ra];
      end
      if(reset || clear) initialized[r]<='0;
      else begin
        if(begin_bank.valid && !bad_ctrl && !protocol_error)
          for(int i=0;i<PAIRS*MEM_TILES;i++)
            initialized[r][begin_bank.bank*PAIRS*MEM_TILES+i]<=0;
        if(write_ok && wr_mask[r])
          initialized[r][wa]<=1;
      end
    end
  end
  always_ff @(posedge clk) begin
    if(reset || clear) begin
      out_valid<=0;protocol_error<=0;open_bank<='0;complete_bank<='0;
      for(int b=0;b<BANKS;b++) begin
        bank_epoch[b]<=0;
        region_base[b]<=0;region_tiles[b]<=0;
        committed_epoch[b]<=0;committed_base[b]<=0;committed_tiles[b]<=0;
        for(int r=0;r<ROW_LANES;r++) written[b][r]<=0;
      end
    end else begin
      if(bad_ctrl) protocol_error<=1;
      if(begin_bank.valid && !bad_ctrl && !protocol_error) begin
        open_bank[begin_bank.bank]<=1;complete_bank[begin_bank.bank]<=0;
        bank_epoch[begin_bank.bank]<=begin_bank.epoch;
        region_base[begin_bank.bank]<=begin_bank.tile_base;
        region_tiles[begin_bank.bank]<=begin_bank.tile_count;
        for(int r=0;r<ROW_LANES;r++) written[begin_bank.bank][r]<=0;
      end
      if(commit_bank.valid && !bad_ctrl && !protocol_error) begin
        open_bank[commit_bank.bank]<=0;complete_bank[commit_bank.bank]<=1;
        committed_epoch[commit_bank.bank]<=commit_bank.epoch;
        committed_base[commit_bank.bank]<=commit_bank.tile_base;
        committed_tiles[commit_bank.bank]<=commit_bank.tile_count;
      end
      for(int r=0;r<ROW_LANES;r++)
        if(write_ok && wr_mask[r] && !initialized[r][wa])
          written[wr_bank][r]<=written[wr_bank][r]+1'b1;
    end
    if(reset || clear) out_valid<=0;
    else if(!out_valid || out_ready) begin
      out_valid<=rd_valid && rd_ready;
      if(rd_valid && rd_ready) begin
        out_entry.reserved<=0;out_entry.row_valid<=row_mask(rd_pair);
        out_entry.pair_idx<=rd_pair;out_entry.tile_idx<=rd_emit_tile;
        out_entry.slot<=rd_slot;out_epoch<=rd_epoch;out_bank<=rd_bank;
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
