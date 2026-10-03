`timescale 1ns/1ps
import pcore3_pkg::*;

module tb_v3_bfifo_stream;
  localparam int TEST_TILES=16;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic in_valid,in_ready,out_valid,out_ready,tile_available,protocol_error;
  b2_t in_entry,out_entry;
  logic [6:0] count; logic [3:0] complete_tiles;
  int popped=0,simul_group7=0;

  dea8_bfifo_v3 dut(
    .clk,.reset,.clear,.in_valid,.in_ready,.in_entry,
    .out_valid,.out_ready,.out_entry,.tile_available,.protocol_error,
    .count,.complete_tiles);

  assign out_ready=1'b1;

  // Sample the transaction presented for the current clock edge, before the
  // FIFO advances its head in the NBA region.
  always @(posedge clk) begin
    if(out_valid&&out_ready) begin
      if(out_entry.tile_idx!=(popped/8) || out_entry.group_idx!=(popped%8))
        $fatal(1,"BFIFO order mismatch pop=%0d tile=%0d group=%0d",
          popped,out_entry.tile_idx,out_entry.group_idx);
      popped++;
    end
    if(in_valid&&in_ready&&out_valid&&out_ready&&in_entry.group_idx==7)
      simul_group7++;
  end

  task automatic make_b(input int tile,input int group);
    in_entry.tile_idx=tile[TILE_BITS-1:0]; in_entry.group_idx=group[2:0];
    in_entry.epoch=3; in_entry.reserved=0;
    for(int c=0;c<2;c++) begin
      in_entry.col[c].scale=8'd128;
      for(int k=0;k<16;k++) in_entry.col[c].data[k*8+:8]=8'(tile+group+c+k);
    end
  endtask

  initial begin
    in_valid=0;
    repeat(20) @(negedge clk); reset=0;
    for(int t=0;t<TEST_TILES;t++) for(int g=0;g<8;g++) begin
      @(negedge clk); make_b(t,g); in_valid=1;
      do @(posedge clk); while(!in_ready);
    end
    @(negedge clk); in_valid=0;
    wait(popped==TEST_TILES*8);
    @(posedge clk); #1;
    if(protocol_error) $fatal(1,"BFIFO protocol error during stream");
    if(count!=0 || complete_tiles!=0)
      $fatal(1,"BFIFO did not drain count=%0d complete=%0d",count,complete_tiles);
    if(simul_group7==0) $fatal(1,"test did not exercise group7 push/pop overlap");
    $display("tb_v3_bfifo_stream PASS tiles=%0d pops=%0d group7_overlap=%0d",
      TEST_TILES,popped,simul_group7);
    $finish;
  end
  initial begin #100000; $fatal(1,"v3 BFIFO stream watchdog"); end
endmodule
