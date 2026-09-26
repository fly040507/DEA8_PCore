`timescale 1ns/1ps
import pcore3_pkg::*;

module tb_v3_ingress;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic x_valid,x_ready;
  xbc4_t x_entry;
  logic [1:0] a_valid,a_ready;
  a2_t a_entry[0:1];
  logic reserve,tile_available,running,out_valid,protocol_error;
  a2_t out_entry;
  logic [6:0] count;
  logic [1:0] complete_tiles;

  dea8_xbc4_adapter_v3 adapter(.clk,.reset,.clear,.in_valid(x_valid),.in_ready(x_ready),
    .in_entry(x_entry),.out_valid(a_valid),.out_ready(a_ready),.out_entry(a_entry));
  dea8_afifo_v3 fifo(.clk,.reset,.clear,.in_valid(a_valid),.in_ready(a_ready),.in_entry(a_entry),
    .reserve_tile(reserve),.tile_available,.running,.out_valid,.out_entry,.protocol_error,
    .count,.complete_tiles);

  task automatic make_x(input int g);
    x_entry.group_idx=g;x_entry.tile_idx=0;x_entry.slot=1;x_entry.reserved=0;
    for(int r=0;r<4;r++) begin
      x_entry.row_valid[r]=(g==12&&r==3)?0:1;
      x_entry.row[r].scale=8'd7;
      for(int k=0;k<16;k++) x_entry.row[r].data[k*8+:8]=8'(g*4+r+k);
    end
  endtask
  initial begin
    x_valid=0;reserve=0;
    repeat(20) @(negedge clk);reset=0;
    if($bits(a2_t)!=288||$bits(b2_t)!=288) $fatal(1,"v3 ingress width contract failed");
    for(int g=0;g<XBC_GROUPS;g++) begin
      @(negedge clk);make_x(g);x_valid=1;
      do @(posedge clk); while(!x_ready);
      @(negedge clk);x_valid=0;
    end
    @(posedge clk);#1;
    if(count!=PAIRS||complete_tiles!=1||protocol_error) $fatal(1,"A4 to AFIFO fill failed");
    @(negedge clk);reserve=1;#1;
    if(!tile_available) $fatal(1,"AFIFO Tile reservation not available");
    @(posedge clk);#1;reserve=0;
    for(int p=0;p<PAIRS;p++) begin
      if(!out_valid) $fatal(1,"AFIFO missing pair %0d",p);
      if(out_entry.pair_idx!=p||out_entry.tile_idx!=0||out_entry.slot!=1||out_entry.row_valid!=row_mask(p))
        $fatal(1,"AFIFO order mismatch at pair %0d",p);
      @(posedge clk);#1;
    end
    if(running||out_valid||count!=0||complete_tiles!=0||protocol_error)
      $fatal(1,"AFIFO drain state mismatch");
    $display("tb_v3_ingress PASS A4_beats=%0d A2_entries=%0d",XBC_GROUPS,PAIRS);
    $finish;
  end
  initial begin #100000;$fatal(1,"v3 ingress watchdog"); end
endmodule
