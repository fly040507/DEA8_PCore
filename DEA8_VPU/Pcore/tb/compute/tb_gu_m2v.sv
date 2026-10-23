`timescale 1ns/1ps
module tb_gu_m2v;
 import pcore_pkg::*;
 logic clk=0;always #2 clk=~clk;
 logic reset=1,clear=0,reserve_valid=0,reserve_ready,capture_valid=0,capture_ready,capture_branch=0;
 logic [4:0] capture_pair=0;
 logic [1:0] capture_row_valid=0;
 logic [15:0][31:0] capture_even,capture_odd,out_gate,out_up;
 logic out_valid,out_ready=0,out_last,complete,protocol_error;
 logic [5:0] out_row,out_n;logic [1:0] out_row_valid;logic [3:0] out_epoch;logic [2:0] out_head;
 int received=0,cycle=0;
 dea8_gu_pair_buffer dut(.clk,.reset,.clear,.ram_a(),.ram_b(),.ram_a_data('0),.ram_b_data('0),
   .reserve_valid,.reserve_ready,.reserve_epoch(4'd3),.reserve_head(3'd2),.reserve_n(6'd7),
   .capture_valid,.capture_ready,.capture_branch,.capture_pair,.capture_row_valid,.capture_even,.capture_odd,
   .capture_epoch(4'd3),.capture_head(3'd2),.capture_n(6'd7),.input_consumed(1'b0),
   .out_valid,.out_ready,.out_row,.out_gate,.out_up,.out_row_valid,.out_epoch,.out_head,.out_n,.out_last,.complete,.protocol_error);
 always @(posedge clk)begin
   cycle++;
   if(!reset)begin
     if(protocol_error)$fatal(1,"GU M2V protocol");
     if(out_valid&&out_ready)begin
       if(out_row!=received||out_epoch!=3||out_head!=2||out_n!=7||out_row_valid!=1||out_last!=(received==50))$fatal(1,"GU row metadata");
       for(int lane=0;lane<16;lane++)if(out_gate[lane]!==32'(100*received+lane)||out_up[lane]!==32'(100000+100*received+lane))
         $fatal(1,"GU row-major data mismatch row=%0d lane=%0d gate=%h up=%h",received,lane,out_gate[lane],out_up[lane]);
       received++;
     end
   end
 end
 always @(negedge clk)if(!reset)out_ready=cycle%7<4;
 initial begin
   capture_even=0;capture_odd=0;
   repeat(35)@(negedge clk);reset=0;reserve_valid=1;@(negedge clk);reserve_valid=0;
   for(int branch=0;branch<2;branch++)for(int pair=0;pair<26;pair++)begin
     capture_branch=1'(branch);capture_pair=5'(pair);capture_row_valid=row_mask(pair);capture_valid=1;
     for(int lane=0;lane<16;lane++)begin capture_even[lane]=32'(branch*100000+200*pair+lane);capture_odd[lane]=32'(branch*100000+200*pair+100+lane);end
     @(negedge clk);capture_valid=0;@(negedge clk);
   end
   wait(received==51);repeat(4)@(negedge clk);
   $display("tb_gu_m2v PASS rows=51 SDP_R16_W16=1 stalls=1 row50_tail=1");$finish;
 end
 initial begin #20000;$fatal(1,"GU M2V watchdog");end
endmodule
