`timescale 1ns/1ps
import dea8_pcore_pkg::*;
module tb_dea8_b_fifo;
  localparam int DEPTH=B_FIFO_DEPTH;
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,clear=0,in_valid=0,in_ready,out_valid,out_ready=0;
  logic [B_ENTRY_BITS-1:0] in_entry='0,out_entry;
  logic [$clog2(DEPTH+1)-1:0] count;
  logic [B_ENTRY_BITS-1:0] reference[0:50000];
  int rd=0,wr=0,occupancy=0,sequence_id=0,full_exchange=0,bypass_exchange=0;
  int clear_count=0,pop_count=0;
  logic [31:0] random_q=32'h17654983;
  logic [B_ENTRY_BITS-1:0] stalled_data;
  bit stalled=0;
  dea8_b_fifo dut (.*);
  task automatic drive(input bit push_enable,pop_enable,clear_enable);
    @(negedge clk);
    in_valid=push_enable;out_ready=pop_enable;clear=clear_enable;
    sequence_id++;
    in_entry={128'(sequence_id*1777),8'(sequence_id)};
  endtask
  always @(posedge clk) begin : scoreboard
    bit do_push,do_pop;
    do_push=in_valid && in_ready;do_pop=out_valid && out_ready;
    if(!rst_n || clear) begin
      if(in_ready || out_valid) $fatal(1,"FIFO handshook during reset/clear");
      rd=0;wr=0;occupancy=0;stalled=0;
      if(clear) clear_count++;
    end else begin
      if(count!=occupancy || out_valid!=(occupancy!=0)) $fatal(1,"FIFO count/valid mismatch");
      if(stalled && out_entry!==stalled_data) $fatal(1,"FIFO changed stalled head");
      if(do_pop) begin
        if(out_entry!==reference[rd]) $fatal(1,"FIFO payload order/pair mismatch");
        rd++;pop_count++;
      end
      if(do_push) begin reference[wr]=in_entry;wr++;end
      if(occupancy==DEPTH && do_pop && do_push) full_exchange++;
      if(occupancy==1 && do_pop && do_push) bypass_exchange++;
      occupancy+=int'(do_push)-int'(do_pop);
      stalled=out_valid && !out_ready;stalled_data=out_entry;
    end
    #1;if(count!=occupancy) $fatal(1,"FIFO post-edge count mismatch");
  end
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    repeat(DEPTH) drive(1,0,0);
    repeat(8) drive(1,0,0);
    repeat(4*DEPTH) drive(1,1,0);
    repeat(DEPTH-1) drive(0,1,0);
    repeat(100) drive(1,1,0);
    drive(1,1,1);drive(1,1,0);
    for(int i=0;i<6000;i++) begin
      random_q={random_q[30:0],random_q[31]^random_q[21]^random_q[1]^random_q[0]};
      drive(random_q[0] || random_q[3],random_q[2],i%499==0);
    end
    repeat(DEPTH+2) drive(0,1,0);
    drive(0,0,0);
    if(count || full_exchange<DEPTH || bypass_exchange<100 || clear_count<10 || pop_count<2000)
      $fatal(1,"FIFO directed coverage missing");
    $display("tb_dea8_b_fifo PASS: sync RAM, capacity64, full exchange, wrap, head bypass, clear, stalls; pops=%0d",pop_count);
    $finish;
  end
  initial begin #100000; $fatal(1,"B FIFO timeout");end
endmodule
