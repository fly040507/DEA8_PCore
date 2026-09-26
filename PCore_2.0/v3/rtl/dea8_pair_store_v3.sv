import pcore3_pkg::*;

// Parameterized QOZ/PBUF storage. Data and scale are one qvec16_t, while the
// even and odd physical rows remain separate so a complete A2 is one read.
module dea8_pair_store_v3 #(parameter int MEM_TILES=32,parameter int BANKS=1) (
  input logic clk,reset,clear,
  input logic [1:0] wr_mask,input logic wr_bank,
  input logic [TILE_BITS-1:0] wr_tile,input logic [PAIR_BITS-1:0] wr_pair,
  input qvec16_t wr_row[0:1],
  input logic begin_valid,input logic begin_bank,
  input logic [EPOCH_BITS-1:0] begin_epoch,
  input logic [TILE_BITS-1:0] begin_base,
  input logic [TILE_BITS:0] begin_tiles,
  input logic commit_valid,input logic commit_bank,
  input logic [EPOCH_BITS-1:0] commit_epoch,
  input logic [TILE_BITS-1:0] commit_base,
  input logic [TILE_BITS:0] commit_tiles,
  output logic protocol_error,
  output logic [BANKS-1:0] complete,
  output logic [EPOCH_BITS-1:0] complete_epoch[0:BANKS-1],
  output logic [TILE_BITS-1:0] complete_base[0:BANKS-1],
  output logic [TILE_BITS:0] complete_tiles[0:BANKS-1],
  input logic rd_valid,output logic rd_ready,input logic rd_bank,
  input logic [TILE_BITS-1:0] rd_tile,input logic [PAIR_BITS-1:0] rd_pair,
  input logic rd_slot,input logic [EPOCH_BITS-1:0] rd_epoch,
  output logic out_valid,input logic out_ready,output a2_t out_entry
);
  localparam int DEPTH=MEM_TILES*PAIRS;
  qvec16_t mem[0:1][0:BANKS-1][0:DEPTH-1];
  logic [BANKS-1:0] open_bank;
  logic [EPOCH_BITS-1:0] open_epoch[0:BANKS-1];
  logic [TILE_BITS-1:0] open_base[0:BANKS-1];
  logic [TILE_BITS:0] open_tiles[0:BANKS-1];
  logic [DEPTH-1:0] init[0:1][0:BANKS-1];
  logic [$clog2(PAIRS*MEM_TILES+1)-1:0] writes[0:BANKS-1][0:1];
  logic wr_in_range,rd_in_range,wr_ok,wr_in_region,rd_in_region,commit_bad;
  logic wr_bank_open,begin_bank_open,begin_bad;
  logic rd_data_ready;
  logic [BANKS-1:0] bank_idx;
  logic [PAIR_BITS+$clog2(MEM_TILES)-1:0] addr;
  assign bank_idx=wr_bank;
  assign addr=wr_tile*PAIRS+wr_pair;
  assign wr_in_range=wr_bank<BANKS&&wr_tile<MEM_TILES&&wr_pair<PAIRS;
  assign rd_in_range=rd_bank<BANKS&&rd_tile<MEM_TILES&&rd_pair<PAIRS;
  always_comb begin
    rd_in_region=0;wr_in_region=0;commit_bad=0;wr_bank_open=0;begin_bank_open=0;begin_bad=0;
    if(wr_in_range) begin
      wr_bank_open=open_bank[wr_bank];
      wr_in_region=wr_tile>=open_base[wr_bank]&&
        wr_tile<open_base[wr_bank]+open_tiles[wr_bank];
    end
    if(rd_in_range) rd_in_region=rd_tile>=complete_base[rd_bank]&&
      rd_tile<complete_base[rd_bank]+complete_tiles[rd_bank]&&
      complete[rd_bank]&&complete_epoch[rd_bank]==rd_epoch;
    if(commit_valid) begin
      if(commit_bank>=BANKS) commit_bad=1;
      else commit_bad=!open_bank[commit_bank]||open_epoch[commit_bank]!=commit_epoch||
        open_base[commit_bank]!=commit_base||open_tiles[commit_bank]!=commit_tiles||
      writes[commit_bank][0] < PAIRS*commit_tiles ||
      writes[commit_bank][1] < ((ROWS%2)?PAIRS*commit_tiles-1:PAIRS*commit_tiles);
    end
    if(begin_valid) begin
      if(begin_bank>=BANKS) begin_bad=1;
      else begin
        begin_bank_open=open_bank[begin_bank];
        begin_bad=begin_tiles==0||begin_base+begin_tiles>MEM_TILES||begin_bank_open;
      end
    end
  end
  always_comb begin
    rd_data_ready=0;
    if(rd_in_range) rd_data_ready=init[0][rd_bank][rd_tile*PAIRS+rd_pair]&&
      (!((row_mask(rd_pair)&2'b10)!=0)||init[1][rd_bank][rd_tile*PAIRS+rd_pair]);
  end
  assign wr_ok=(|wr_mask)&&wr_in_range&&wr_in_region&&wr_bank_open&&!protocol_error&&
    (wr_mask&~row_mask(wr_pair))==0;
  assign rd_ready=!reset&&!clear&&!protocol_error&&rd_valid&&rd_in_region&&
    (!out_valid||out_ready)&&rd_data_ready;
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      protocol_error<=0;open_bank<='0;complete<='0;out_valid<=0;
      for(int b=0;b<BANKS;b++) begin
        complete_epoch[b]<=0;complete_base[b]<=0;complete_tiles[b]<=0;
        open_epoch[b]<=0;open_base[b]<=0;open_tiles[b]<=0;
        for(int r=0;r<2;r++) writes[b][r]<='0;
      end
      for(int r=0;r<2;r++) for(int b=0;b<BANKS;b++) init[r][b]<='0;
    end else begin
      if(commit_bad||begin_bad) protocol_error<=1;
      if(begin_valid&&!protocol_error&&(begin_bank<BANKS)&&begin_tiles!=0&&
         begin_base+begin_tiles<=MEM_TILES&&!open_bank[begin_bank]) begin
        open_bank[begin_bank]<=1;open_epoch[begin_bank]<=begin_epoch;
        open_base[begin_bank]<=begin_base;open_tiles[begin_bank]<=begin_tiles;
        complete[begin_bank]<=0;writes[begin_bank][0]<='0;writes[begin_bank][1]<='0;
        for(int r=0;r<2;r++) for(int i=0;i<DEPTH;i++) init[r][begin_bank][i]<=0;
      end
      if(wr_ok) begin
        for(int r=0;r<2;r++) if(wr_mask[r]) begin mem[r][wr_bank][addr]<=wr_row[r];init[r][wr_bank][addr]<=1;end
        for(int r=0;r<2;r++) if(wr_mask[r]&&!init[r][wr_bank][addr]) writes[wr_bank][r]<=writes[wr_bank][r]+1'b1;
      end
      if(commit_valid&&!commit_bad&&!protocol_error) begin
        open_bank[commit_bank]<=0;complete[commit_bank]<=1;
        complete_epoch[commit_bank]<=commit_epoch;complete_base[commit_bank]<=commit_base;
        complete_tiles[commit_bank]<=commit_tiles;
      end
      if(rd_valid&&rd_ready) begin
        out_entry.row[0]<=mem[0][rd_bank][rd_tile*PAIRS+rd_pair];
        out_entry.row[1]<=mem[1][rd_bank][rd_tile*PAIRS+rd_pair];out_entry.row_valid<=row_mask(rd_pair);
        out_entry.pair_idx<=rd_pair;out_entry.tile_idx<=rd_tile;out_entry.slot<=rd_slot;out_valid<=1;
      end else if(out_valid&&out_ready) out_valid<=0;
    end
  end
  initial if(MEM_TILES<1||BANKS<1) $fatal(1,"pair store geometry");
endmodule
