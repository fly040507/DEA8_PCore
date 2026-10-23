`timescale 1ns/1ps
module tb_shared16;
 import dea8_vpu_math_pkg::*;
 logic clk=0;always #2 clk=~clk;
 logic reset=1,clear=0,in_valid=0,in_ready,mul_valid,sum_valid,rope_valid;
 pair_fp_t a,b,product,x,ra,rb,ry;
 scalars_t scalar_product,sums;
 logic [1:0] mul_error,sum_error;
 logic rope_mode=0;
 logic [31:0] expect_sum[256][2];
 pair_fp_t expected_mul[256],expected_rope[256];
 int issued=0,muls=0,adds=0,rotations=0;
 dea8_vpu_pair_mul16 mul(.clk,.reset,.clear,.in_valid,.in_ready,.out_valid(mul_valid),.a,.b,.y(product),.error(mul_error));
 assign scalar_product={product[1][0],product[0][0]};
 dea8_vpu_p_pipe add(.clk,.reset,.clear,.in_valid(in_valid&&!rope_mode),.x,
   .product(scalar_product),.product_error(mul_error),.input_error(2'b0),
   .out_valid(sum_valid),.lvalue(sums),.error(sum_error),.rope_mode,
   .rope_in_valid(in_valid&&rope_mode),.rope_a(ra),.rope_b(rb),.rope_out_valid(rope_valid),.rope_y(ry));
 function automatic logic [31:0] sum_ref(input logic [15:0][31:0] values,input logic [31:0] p);
   logic [31:0] t[31];
   for(int i=0;i<16;i++)t[15+i]=values[i];
   for(int i=14;i>=0;i--)t[i]=dea8_fp32_v3_pkg::fp32_add(t[2*i+1],t[2*i+2]);
   return dea8_fp32_v3_pkg::fp32_add(p,t[0]);
 endfunction
 always @(negedge clk)if(!reset&&!clear)begin
   if(mul_valid)begin
     if(product!==expected_mul[muls])$fatal(1,"MUL16 order/value mismatch item=%0d",muls);
     muls++;
   end
   if(sum_valid)begin
     if(sums[0]!==expect_sum[adds][0]||sums[1]!==expect_sum[adds][1]||sum_error)
       $fatal(1,"ADD16 sum mismatch item=%0d got=%h/%h expected=%h/%h",adds,sums[0],sums[1],expect_sum[adds][0],expect_sum[adds][1]);
     adds++;
   end
   if(rope_valid)begin
     if(ry!==expected_rope[rotations])$fatal(1,"ADD16 RoPE value/order item=%0d",rotations);
     rotations++;
   end
 end
 task automatic send(input int n,input bit mode);
   @(negedge clk);while(!in_ready)@(negedge clk);
   for(int r=0;r<2;r++)for(int l=0;l<16;l++)begin
     a[r][l]=32'h3f800000|32'((n*31+r*17+l)*128);
     b[r][l]=32'h40000000;
     x[r][l]=32'h3f000000|32'((n*19+r*71+l)*256);
     ra[r][l]=a[r][l];rb[r][l]=x[r][l];
     expected_mul[issued][r][l]=mul_fp(a[r][l],b[r][l]);
     expected_rope[n][r][l]=dea8_fp32_v3_pkg::fp32_add(ra[r][l],rb[r][l]);
   end
   for(int r=0;r<2;r++)expect_sum[issued][r]=sum_ref(x[r],expected_mul[issued][r][0]);
   rope_mode=mode;in_valid=1;issued++;
   @(negedge clk);in_valid=0;
   repeat(n%4+1)@(negedge clk);
 endtask
 initial begin
   a=0;b=0;x=0;ra=0;rb=0;
   repeat(35)@(negedge clk);reset=0;
   for(int i=0;i<128;i++)send(i,0);
   wait(adds==128&&muls==128);repeat(4)@(negedge clk);
   for(int i=0;i<128;i++)send(i,1);
   wait(rotations==128&&muls==256);repeat(4)@(negedge clk);
   $display("tb_shared16 PASS pairs_mul=%0d pairs_sum=%0d pairs_rope=%0d physical_mul=16 physical_add=16 gaps=1",muls,adds,rotations);$finish;
 end
 initial begin #100000;$fatal(1,"Shared16 timeout issued=%0d muls=%0d adds=%0d rotations=%0d",issued,muls,adds,rotations);end
endmodule
