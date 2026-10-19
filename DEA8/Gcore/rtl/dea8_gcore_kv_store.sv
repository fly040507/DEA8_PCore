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
  import pcore_pkg::b2_t;
  logic enabled,write_bad,read_bad,rd_fire,read_issue,rsp_fire,fifo_ready;
  logic [CORES-1:0] wr_fire;
  logic [2:0] read_owner;
  logic [8:0] read_offset;
  logic [STORE_WORD_BITS-1:0] bank_even[CORES],bank_odd[CORES];
  logic [STORE_READ_LATENCY-1:0] read_valid;
  kv_read_t read_meta[STORE_READ_LATENCY];
  logic [STORE_CREDIT_BITS-1:0] reserved_q;
  b2_t response_word;

  assign enabled=!reset&&!clear&&!protocol_error;
  assign rsp_fire=rsp_valid&&rsp_ready;
  assign rd_ready=enabled&&(reserved_q<STORE_RESPONSE_DEPTH||rsp_fire);
  assign rd_fire=rd_valid&&rd_ready;
  assign read_bad=rd.address>=(rd.prefix?PREFIX_BANK_DEPTH:SUFFIX_BANK_DEPTH);
  assign read_issue=rd_fire&&!read_bad;
  assign read_owner=kv_ram_owner(rd.value_kind,rd.feature_tile);
  assign read_offset=rd.prefix?rd.address:9'(PREFIX_BANK_DEPTH+int'(rd.address));

  // Double reads take priority only at their owner; all other writers proceed.
  always_comb begin
    wr_ready={CORES{enabled}};
    if(read_issue)wr_ready[read_owner]=0;
    wr_fire=wr_valid&wr_ready;
    write_bad=0;
    for(int c=0;c<CORES;c++)if(wr_fire[c])begin
      if(wr[c].word_data[135:128]==8'hff ||
          kv_ram_owner(wr[c].value_kind,wr[c].feature_tile)!=c)write_bad=1;
    end
  end

  for(genvar c=0;c<CORES;c++)begin:banks
    wire re=read_issue&&read_owner==c;
    wire we=wr_fire[c]&&!write_bad;
    wire [KV_RAM_ADDR_BITS-1:0] write_address=kv_ram_address(
      wr[c].value_kind,wr[c].feature_tile,wr[c].parity,
      9'(PREFIX_BANK_DEPTH+int'(wr[c].address)));
    dea8_gcore_uram_tdp #(.AW(KV_RAM_ADDR_BITS)) ram (
      .clk,.enable_a(re||we),.enable_b(re),.write_a(we),.write_b(1'b0),
      .address_a(re?kv_ram_address(rd.value_kind,rd.feature_tile,1'b0,read_offset):write_address),
      .address_b(kv_ram_address(rd.value_kind,rd.feature_tile,1'b1,read_offset)),
      .data_a({8'b0,wr[c].word_data}),.data_b('0),
      .result_a(bank_even[c]),.result_b(bank_odd[c])
    );
  end

  always_comb begin
    response_word='0;
    response_word.tile_idx=read_meta[STORE_READ_LATENCY-1].tile;
    response_word.group_idx=read_meta[STORE_READ_LATENCY-1].group_index;
    response_word.epoch=read_meta[STORE_READ_LATENCY-1].epoch;
    if(!read_meta[STORE_READ_LATENCY-1].zero_mask[0])begin
      response_word.col[0].data=bank_even[kv_ram_owner(
        read_meta[STORE_READ_LATENCY-1].value_kind,read_meta[STORE_READ_LATENCY-1].feature_tile)][127:0];
      response_word.col[0].scale=bank_even[kv_ram_owner(
        read_meta[STORE_READ_LATENCY-1].value_kind,read_meta[STORE_READ_LATENCY-1].feature_tile)][135:128];
    end
    if(!read_meta[STORE_READ_LATENCY-1].zero_mask[1])begin
      response_word.col[1].data=bank_odd[kv_ram_owner(
        read_meta[STORE_READ_LATENCY-1].value_kind,read_meta[STORE_READ_LATENCY-1].feature_tile)][127:0];
      response_word.col[1].scale=bank_odd[kv_ram_owner(
        read_meta[STORE_READ_LATENCY-1].value_kind,read_meta[STORE_READ_LATENCY-1].feature_tile)][135:128];
    end
  end
  dea8_gcore_fifo #(.WIDTH($bits(b2_t)),.DEPTH(STORE_RESPONSE_DEPTH)) responses (
    .clk,.reset,.clear,.in_valid(read_valid[STORE_READ_LATENCY-1]),.in_ready(fifo_ready),
    .in_data(response_word),.out_valid(rsp_valid),.out_ready(rsp_ready),.out_data(rsp),.occupancy()
  );
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      read_valid<='0;reserved_q<=0;protocol_error<=0;
    end else begin
      read_valid[0]<=read_issue;
      for(int i=1;i<STORE_READ_LATENCY;i++)read_valid[i]<=read_valid[i-1];
      case({read_issue,rsp_fire})
        2'b10:reserved_q<=reserved_q+1'b1;
        2'b01:reserved_q<=reserved_q-1'b1;
        default:;
      endcase
      if(write_bad||(rd_fire&&read_bad)||
          (read_valid[STORE_READ_LATENCY-1]&&!fifo_ready))protocol_error<=1;
    end
    read_meta[0]<=rd;
    for(int i=1;i<STORE_READ_LATENCY;i++)read_meta[i]<=read_meta[i-1];
  end

  // One logical preload API keeps test fixtures independent of banking/XPM.
  // synthesis translate_off
  task automatic preload_prefix(input bit kind,input int feature,parity,address,
      input logic [135:0] word_data);
    logic [KV_RAM_ADDR_BITS-1:0] physical_address;
    if(feature<0||feature>=KV_FEATURE_TILES||parity<0||parity>1||
        address<0||address>=PREFIX_BANK_DEPTH)$fatal(1,"KV preload bounds");
    physical_address=kv_ram_address(kind,4'(feature),1'(parity),9'(address));
    case(kv_ram_owner(kind,4'(feature)))
      0:banks[0].ram.preload(physical_address,{8'b0,word_data});
      1:banks[1].ram.preload(physical_address,{8'b0,word_data});
      2:banks[2].ram.preload(physical_address,{8'b0,word_data});
      3:banks[3].ram.preload(physical_address,{8'b0,word_data});
      4:banks[4].ram.preload(physical_address,{8'b0,word_data});
      5:banks[5].ram.preload(physical_address,{8'b0,word_data});
      6:banks[6].ram.preload(physical_address,{8'b0,word_data});
      7:banks[7].ram.preload(physical_address,{8'b0,word_data});
    endcase
  endtask
  // synthesis translate_on
endmodule
