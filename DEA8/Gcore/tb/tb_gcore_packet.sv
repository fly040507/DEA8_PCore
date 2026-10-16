`timescale 1ns/1ps
module tb_gcore_packet;
  import dea8_tile_link_pkg::*;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,busy,protocol_error;
  logic [7:0] in_valid=0,in_ready,in_last=0;
  logic [7:0][255:0] in_data=0;
  logic [7:0] kv_header_valid,kv_header_ready='1,kv_valid,kv_ready=0,kv_last,kv_retire=0;
  logic [7:0] fp_header_valid,fp_header_ready='1,fp_valid,fp_ready=0;
  logic [7:0][135:0] kv_data;
  logic [7:0][255:0] fp_data;
  tile_header_t kv_header[8],fp_header[8];
  logic fp_retire=0;
  dea8_gcore_packet_rx dut(.*);
  function automatic logic [255:0] header(input tile_kind_e kind,input int source=0);
    tile_header_t h;h='0;h.kind=kind;h.source_id=4'(source);h.rows=51;h.columns=16;
    h.layout=kind==TILE_K?LAYOUT_K_ROWS:(kind==TILE_V?LAYOUT_V_GROUPS:LAYOUT_FP_ROWS);
    return encode_packet_header(h);
  endfunction
  task automatic word(input logic [255:0] value,input bit last_word=0);
    @(negedge clk);in_valid[0]=1;in_data[0]=value;in_last[0]=last_word;
    do @(posedge clk);while(!in_ready[0]);@(negedge clk);in_valid[0]=0;
  endtask
  task automatic flush;
    @(negedge clk);clear=1;in_valid=0;kv_ready=0;fp_ready=0;fp_retire=0;kv_retire=0;
    @(negedge clk);clear=0;
    if(protocol_error||busy||kv_valid||fp_valid)$fatal(1,"packet flush failed");
  endtask
  task automatic expect_error;
    if(!protocol_error)$fatal(1,"packet accepted malformed beat");
    repeat(4)begin @(negedge clk);if(in_ready!=0||kv_valid!=0||fp_valid!=0)$fatal(1,"packet did not halt on error");end
    flush();
  endtask
  initial begin
    logic [255:0] v;
    repeat(4)@(negedge clk);reset=0;
    word(header(TILE_O));
    for(int b=0;b<4;b++)word(256'(b+100));
    if(in_ready[0]||!fp_valid[0]||fp_data[0]!=100)$fatal(1,"packet FIFO capacity/head");
    // Holding the low/high read phase outside RX must not pop or change its head.
    repeat(7)begin @(negedge clk);if(fp_data[0]!=100)$fatal(1,"packet head moved without pop");end
    for(int b=0;b<4;b++)begin
      if(fp_data[0]!=b+100)$fatal(1,"packet FIFO order");
      fp_ready[0]=1;@(negedge clk);fp_ready[0]=0;@(negedge clk);
    end
    if(fp_valid[0])$fatal(1,"packet FIFO did not drain");flush();
    v=header(TILE_K);v[255]=1;word(v);expect_error();
    word(header(TILE_K,1));expect_error();
    word(header(TILE_K));word(0,1);expect_error();
    word(header(TILE_K));v=0;v[135:128]=8'hff;word(v);expect_error();
    word(header(TILE_K));v=0;v[136]=1;word(v);expect_error();
    word(header(TILE_O));v=0;v[31:0]=32'h7fc00000;word(v);expect_error();
    word(header(TILE_V));kv_ready[0]=1;
    for(int b=0;b<48;b++)word(0);
    v=0;v[24]=1;word(v);expect_error();
    word(header(TILE_K));kv_ready[0]=1;
    for(int b=0;b<51;b++)word(0,b==50);
    repeat(4)@(negedge clk);
    if(in_ready[0]||!busy)$fatal(1,"packet descriptor retired before KV commit");
    kv_retire[0]=1;@(negedge clk);kv_retire=0;
    if(!in_ready[0]||busy)$fatal(1,"packet commit retirement");
    $display("tb_gcore_packet PASS depth=4 stable_head=1 malformed_cases=7 kv_commit_barrier=1 flush=1");$finish;
  end
  initial begin #20000;$fatal(1,"packet watchdog");end
endmodule
