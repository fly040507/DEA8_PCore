`timescale 1ns/1ps
// SFU P_EXP and VPU P_POST overlap on the same four leaf adders.
module tb_p_stream_shared;
 import pcore_pkg::*;import pcore_control_pkg::*;import dea8_vpu_math_pkg::*;
 logic clk=0;always #2 clk=~clk;
 logic reset=1,clear=0;
 logic [3:0] av,ao;logic [3:0][31:0] aa,ab,ay;
 logic [4:0] mv,mo;logic [4:0][31:0] ma,mb,my;
 logic ready;
 logic iv=0,ov;logic [3:0][31:0] a,b,y;
 logic p_valid=0,p_ready,mul_out,p_out;
 pair_fp_t x,prod;scalars_t psum;
 logic [1:0] me,pe;
 logic [31:0] expected[128];
 logic [15:0][31:0] accum;
 int issued=0,received=0,groups=0,completed=0;
 dea8_sfu_arithmetic #(.EXTERNAL_ARITHMETIC(1)) sfu(.clk,.active(!reset),.mode(2'd1),.in_valid(iv),.a,.b,
   .gelu_lane(1'b0),.out_valid(ov),.y,.add_valid(av),.add_a(aa),.add_b(ab),.add_out_valid(ao),.add_y(ay),
   .mul_valid(mv),.mul_a(ma),.mul_b(mb),.mul_out_valid(5'b0),.mul_y('0));
 dea8_vpu_p_pipe #(.SHARE_ADD(1)) add(.clk,.reset,.clear,.in_valid(p_valid),.x,
   .product({prod[1][0],prod[0][0]}),.product_error(me),.input_error(2'b0),.out_valid(p_out),.lvalue(psum),.error(pe),
   .rope_mode(1'b0),.rope_in_valid(1'b0),.rope_a('0),.rope_b('0),.rope_out_valid(),.rope_y(),
   .guest_valid(av),.guest_a(aa),.guest_b(ab),.guest_ready(ready),.guest_out_valid(ao),.guest_y(ay));
 dea8_vpu_pair_mul16 mul(.clk,.reset,.clear,.in_valid(p_valid),.in_ready(p_ready),.out_valid(mul_out),
   .a('0),.b('0),.y(prod),.error(me));
 always @(negedge clk)if(!reset)begin
   if(ov)begin
     for(int lane=0;lane<4;lane++)if(y[lane]!==32'h3f800000)$fatal(1,"Shared SUB/EXP corruption group=%0d lane=%0d value=%h",received,lane,y[lane]);
     received++;
   end
   if(p_out)begin
     if(psum[0]!==32'h41800000||psum[1]!==32'h41800000||pe)$fatal(1,"Shared P sum corruption pair=%0d sum=%h/%h",completed,psum[0],psum[1]);
     completed++;
   end
 end
 initial begin
   a=0;b=0;x={32{32'h3f800000}};
   repeat(35)@(negedge clk);reset=0;
   for(int cycle=0;cycle<300;cycle++)begin
     @(negedge clk);p_valid=cycle%8==0;iv=ready&&cycle%7!=3;
     #0.1;iv=iv&&ready;
     if(iv)issued++;if(p_valid)groups++;
   end
   @(negedge clk);iv=0;p_valid=0;
   repeat(180)@(negedge clk);
   if(issued!=received||groups!=completed)$fatal(1,"Shared stream lost transaction exp=%0d/%0d P=%0d/%0d",issued,received,groups,completed);
   $display("tb_p_stream_shared PASS EXP_groups=%0d P_pairs=%0d shared_adds=16",received,completed);$finish;
 end
 initial begin #100000;$fatal(1,"Shared stream watchdog");end
endmodule
