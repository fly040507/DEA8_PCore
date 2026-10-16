module dea8_gcore_kv_store (
  input logic clk,reset,clear,
  input logic [gcore_pkg::CORES-1:0] wr_valid,
  output logic [gcore_pkg::CORES-1:0] wr_ready,
  input gcore_pkg::kv_write_t wr [gcore_pkg::CORES],
  input logic rd_valid,
  output logic rd_ready,
  input gcore_pkg::kv_read_t rd,
  output logic rsp_valid,
  input logic rsp_ready,
  output pcore_pkg::b2_t rsp,
  output logic protocol_error
);
  import gcore_pkg::*;
  logic write_bad,read_bad,wr_fire_any,rd_fire;
  logic [CORES-1:0] wr_fire;
  logic [1:0][135:0] read_words;
  logic [1:0] zero_q;
  logic [5:0] tile_q;
  logic [2:0] group_q;
  logic [3:0] epoch_q;

  assign wr_ready={CORES{!reset&&!clear&&!protocol_error}};
  assign wr_fire=wr_valid&wr_ready;
  assign wr_fire_any=|wr_fire;
  assign rd_ready=!reset&&!clear&&!protocol_error&&(!rsp_valid||rsp_ready);
  assign rd_fire=rd_valid&&rd_ready;
  always_comb begin
    write_bad=0;
    for(int c=0;c<CORES;c++) if(wr_fire[c]) begin
      if(wr[c].word_data[135:128]==8'hff) write_bad=1;
      if(wr[c].value_kind ? wr[c].feature_tile/2!=c : wr[c].feature_tile%CORES!=c)write_bad=1;
      for(int d=0;d<c;d++) if(wr_fire[d] && wr[c].value_kind==wr[d].value_kind &&
          wr[c].feature_tile==wr[d].feature_tile && wr[c].parity==wr[d].parity) write_bad=1;
    end
    read_bad=rd.address>=(rd.prefix?PREFIX_BANK_DEPTH:SUFFIX_BANK_DEPTH);
    // Object ownership normally excludes this case; enforce it at the RAM too.
    if(!rd.prefix)
      for(int c=0;c<CORES;c++) if(wr_fire[c] && wr[c].value_kind==rd.value_kind &&
          wr[c].feature_tile==rd.feature_tile && wr[c].address==rd.address) read_bad=1;
  end

  for(genvar k=0;k<2;k++) begin: kinds
    for(genvar f=0;f<KV_FEATURE_TILES;f++) begin: features
      for(genvar p=0;p<2;p++) begin: parity
        // Preloaded by the system before registration. No prefix receiver/DMA.
        localparam int OWNER=k==0?f%CORES:f/2;
        (* ram_style="block" *) logic [135:0] memory [PREFIX_BANK_DEPTH+SUFFIX_BANK_DEPTH];
        always_ff @(posedge clk) begin
          if(wr_fire[OWNER]&&!write_bad&&wr[OWNER].value_kind==k&&
              wr[OWNER].feature_tile==f&&wr[OWNER].parity==p)
            memory[PREFIX_BANK_DEPTH+wr[OWNER].address]<=wr[OWNER].word_data;
        end
      end
    end
  end

  // Static bank read enables retain one synchronous read port per physical bank.
  logic [1:0][135:0] bank_read [2][KV_FEATURE_TILES];
  logic kind_q;
  logic [3:0] feature_q;
  for(genvar k=0;k<2;k++) begin: read_kinds
    for(genvar f=0;f<KV_FEATURE_TILES;f++) begin: read_features
      for(genvar p=0;p<2;p++) begin: read_parity
        always_ff @(posedge clk)
          if(rd_fire&&!read_bad && rd.value_kind==k && rd.feature_tile==f)
            bank_read[k][f][p]<=kinds[k].features[f].parity[p].memory[
              rd.prefix?int'(rd.address):PREFIX_BANK_DEPTH+int'(rd.address[4:0])];
      end
    end
  end
  assign read_words=bank_read[kind_q][feature_q];
  always_comb begin
    rsp='0; rsp.tile_idx=tile_q; rsp.group_idx=group_q; rsp.epoch=epoch_q;
    for(int p=0;p<2;p++) if(!zero_q[p]) begin
      rsp.col[p].data=read_words[p][127:0];
      rsp.col[p].scale=read_words[p][135:128];
    end
  end
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      rsp_valid<=0; protocol_error<=0; zero_q<=0; tile_q<=0; group_q<=0;
      epoch_q<=0; kind_q<=0; feature_q<=0;
    end else begin
      if(rsp_valid&&rsp_ready) rsp_valid<=0;
      if(wr_fire_any&&write_bad) protocol_error<=1;
      if(rd_fire) begin
        if(read_bad) protocol_error<=1;
        else begin
          rsp_valid<=1; zero_q<=rd.zero_mask; tile_q<=rd.tile;
          group_q<=rd.group_index; epoch_q<=rd.epoch;
          kind_q<=rd.value_kind; feature_q<=rd.feature_tile;
        end
      end
    end
  end
endmodule
