module dea8_gcore_activation_store (
  input logic clk,reset,clear,
  input logic wr_valid,
  output logic wr_ready,
  input logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] wr_index,
  input logic [135:0] wr_word,
  input logic rd_valid,
  output logic rd_ready,
  input logic [5:0] rd_tile,
  input logic [3:0] rd_group,
  output logic rsp_valid,
  input logic rsp_ready,
  output pcore_pkg::xbc4_t rsp,
  output logic protocol_error
);
  import gcore_pkg::*;
  import pcore_pkg::xbc4_t;
  logic enabled,wr_fire,rd_fire,read_issue,read_bad,rsp_fire,fifo_ready;
  logic wr_bank,wr_half;
  logic [5:0] wr_tile;
  logic [3:0] wr_group;
  logic [ACT_RAM_ADDR_BITS-1:0] write_address;
  logic [STORE_WORD_BITS-1:0] bank_first[2],bank_second[2];
  logic [STORE_READ_LATENCY-1:0] read_valid;
  logic [5:0] tile_q[STORE_READ_LATENCY];
  logic [3:0] group_q[STORE_READ_LATENCY];
  logic [STORE_CREDIT_BITS-1:0] reserved_q;
  xbc4_t response_word;

  assign enabled=!reset&&!clear&&!protocol_error;
  assign rsp_fire=rsp_valid&&rsp_ready;
  assign rd_ready=enabled&&(reserved_q<STORE_RESPONSE_DEPTH||rsp_fire);
  assign rd_fire=rd_valid&&rd_ready;
  assign read_bad=rd_group>=ROW_GROUPS;
  assign read_issue=rd_fire&&!read_bad;
  assign wr_ready=enabled&&!read_issue;
  assign wr_fire=wr_valid&&wr_ready;
  assign wr_bank=1'(wr_index%ROWS);
  assign wr_tile=6'(wr_index/ROWS);
  assign wr_group=4'((wr_index%ROWS)/4);
  assign wr_half=1'((wr_index%ROWS)/2);
  assign write_address={wr_tile,wr_group,wr_half};

  // Each parity bank reads two rows on A/B. A write waits for a free cycle.
  for(genvar b=0;b<2;b++)begin:banks
    wire we=wr_fire&&wr_index<VECTOR_WORDS&&wr_bank==b;
    dea8_gcore_uram_tdp #(.AW(ACT_RAM_ADDR_BITS)) ram (
      .clk,.enable_a(read_issue||we),.enable_b(read_issue),.write_a(we),.write_b(1'b0),
      .address_a(read_issue?{rd_tile,rd_group,1'b0}:write_address),
      .address_b({rd_tile,rd_group,1'b1}),
      .data_a({8'b0,wr_word}),.data_b('0),
      .result_a(bank_first[b]),.result_b(bank_second[b])
    );
  end
  always_comb begin
    response_word='0;
    response_word.tile_idx=tile_q[STORE_READ_LATENCY-1];
    response_word.group_idx=group_q[STORE_READ_LATENCY-1];
    response_word.row_valid=(group_q[STORE_READ_LATENCY-1]==ROW_GROUPS-1)?4'b0111:4'b1111;
    for(int r=0;r<4;r++)if(response_word.row_valid[r])begin
      if(r<2)begin
        response_word.row[r].data=bank_first[r%2][127:0];
        response_word.row[r].scale=bank_first[r%2][135:128];
      end else begin
        response_word.row[r].data=bank_second[r%2][127:0];
        response_word.row[r].scale=bank_second[r%2][135:128];
      end
    end
  end
  dea8_gcore_fifo #(.WIDTH($bits(xbc4_t)),.DEPTH(STORE_RESPONSE_DEPTH)) responses (
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
      if((wr_fire&&wr_index>=VECTOR_WORDS)||(rd_fire&&read_bad)||
          (read_valid[STORE_READ_LATENCY-1]&&!fifo_ready))protocol_error<=1;
    end
    tile_q[0]<=rd_tile;group_q[0]<=rd_group;
    for(int i=1;i<STORE_READ_LATENCY;i++)begin
      tile_q[i]<=tile_q[i-1];group_q[i]<=group_q[i-1];
    end
  end
endmodule
