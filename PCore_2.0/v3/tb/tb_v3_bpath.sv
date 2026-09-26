`timescale 1ns/1ps
import pcore3_pkg::*;

module tb_v3_bpath;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic b_valid,b_ready,b_out_valid,b_out_ready,b_protocol;
  b2_t b_in,b_head;
  logic b_tile_available;
  logic [6:0] b_count; logic [3:0] b_complete;
  logic serializer_start,serializer_allow,ser_in_ready,ser_out_valid,ser_out_ready,ser_busy;
  b1_t ser_out;
  logic [1:0] bank_ready; logic [TILE_BITS-1:0] bank_tile[0:1];
  logic load_valid,load_bank; logic [3:0] load_column; qvec16_t load_col;
  logic [1:0] occupied_seen; int load_count;

  dea8_bfifo_v3 bfifo(.clk,.reset,.clear,.in_valid(b_valid),.in_ready(b_ready),.in_entry(b_in),
    .out_valid(b_out_valid),.out_ready(b_out_ready),.out_entry(b_head),.tile_available(b_tile_available),
    .protocol_error(b_protocol),.count(b_count),.complete_tiles(b_complete));
  dea8_b_serializer_v3 serializer(.clk,.reset,.clear,.start_tile(serializer_allow),
    .in_valid(b_out_valid),.in_ready(ser_in_ready),.in_entry(b_head),.out_valid(ser_out_valid),
    .out_ready(ser_out_ready),.out_entry(ser_out),.busy(ser_busy));
  dea8_b_loader_v3 loader(.clk,.reset,.clear,.enable(1'b1),.tile_available(b_tile_available),
    .bfifo_head(b_head),.serializer_busy(ser_busy),.serializer_start(serializer_start),
    .serializer_allow(serializer_allow),.b1_valid(ser_out_valid),.b1_ready(ser_out_ready),
    .b1_entry(ser_out),.release_valid(1'b0),.release_bank(1'b0),.bank_ready,.bank_tile,
    .load_valid,.load_bank,.load_column,.load_col);
  assign b_out_ready=ser_in_ready;
  always @(posedge clk) if(load_valid) load_count++;

  task automatic make_b(input int g);
    b_in.tile_idx=0;b_in.group_idx=g;b_in.epoch=3;b_in.reserved=0;
    for(int c=0;c<2;c++) begin
      b_in.col[c].scale=8'd128;
      for(int k=0;k<16;k++) b_in.col[c].data[k*8+:8]=8'(g*2+c+k);
    end
  endtask
  initial begin
    b_valid=0;load_count=0;
    repeat(20) @(negedge clk);reset=0;
    for(int g=0;g<8;g++) begin
      @(negedge clk);make_b(g);b_valid=1;
      do @(posedge clk); while(!b_ready);
      @(negedge clk);b_valid=0;
    end
    @(posedge clk);#1;
    if(b_complete!=1||b_protocol||b_count<7) $fatal(1,"BFIFO fill failed count=%0d complete=%0d",b_count,b_complete);
    wait(bank_ready[0]);#1;
    if(load_count!=16||bank_tile[0]!=0) $fatal(1,"B2 to B1 load failed count=%0d",load_count);
    if(b_complete!=0||b_count!=0) $fatal(1,"BFIFO did not drain one Tile");
    $display("tb_v3_bpath PASS B2_entries=8 B1_loads=%0d",load_count);
    $finish;
  end
  initial begin #100000;$fatal(1,"v3 B path watchdog"); end
endmodule
