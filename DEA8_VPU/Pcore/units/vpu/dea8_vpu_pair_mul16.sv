// Two ordered half transactions share sixteen real FP32 multipliers.
// Caller accepts a new pair only on in_ready. Pipeline is never flushed
// between halves; one pair / two clocks, all sixteen lanes remain usable.
module dea8_vpu_pair_mul16 #(parameter bit SHARED_GELU=0)(
 input logic clk,reset,clear,in_valid,output logic in_ready,out_valid,
 input dea8_vpu_math_pkg::pair_fp_t a,b,
 output dea8_vpu_math_pkg::pair_fp_t y,output logic [1:0] error,
 input logic guest_mode,input logic [4:0] guest_valid,
 input logic [4:0][31:0] guest_a,guest_b,
 output logic [4:0] guest_out_valid,output logic [4:0][31:0] guest_y
);
 import dea8_compute_config_pkg::*;
 logic second;
 logic [15:0][31:0] a_hold,b_hold,even_q;
 logic [FP_MUL_LATENCY-1:0] valid_q,half_q;
 logic [15:0][31:0] result;
 wire active=!reset&&!clear;
 assign in_ready=active&&!second;
 wire take=in_valid&&in_ready;
 for(genvar lane=0;lane<16;lane++)begin: lanes
   logic [31:0] operand_a,operand_b;
   logic valid,out_v;
   always_comb begin
     operand_a=second?a_hold[lane]:a[0][lane];operand_b=second?b_hold[lane]:b[0][lane];
     valid=take||second;
     if(SHARED_GELU&&guest_mode)begin
       operand_a=0;operand_b=0;valid=0;
       if(lane<5)begin operand_a=guest_a[lane];operand_b=guest_b[lane];valid=guest_valid[lane];end
       if(lane>=8)begin
         operand_a=second?a_hold[lane-8]:a[0][lane-8];
         operand_b=second?b_hold[lane-8]:b[0][lane-8];valid=take||second;
       end
     end
   end
   dea8_fpmul_ip mul(.aclk(clk),.aclken(1'b1),.aresetn(active),
     .s_axis_a_tvalid(valid),.s_axis_a_tdata(operand_a),
     .s_axis_b_tvalid(valid),.s_axis_b_tdata(operand_b),
     .m_axis_result_tvalid(out_v),.m_axis_result_tdata(result[lane]));
   if(lane<5)begin assign guest_out_valid[lane]=guest_mode&&out_v;assign guest_y[lane]=result[lane];end
 end
 always_ff @(posedge clk)begin
   if(reset||clear)begin second<=0;valid_q<=0;half_q<=0;out_valid<=0;end
   else begin
     second<=take;
     valid_q<={valid_q[FP_MUL_LATENCY-2:0],take||second};
     half_q<={half_q[FP_MUL_LATENCY-2:0],second};
     out_valid<=valid_q[FP_MUL_LATENCY-1]&&half_q[FP_MUL_LATENCY-1];
     if(take)begin
       a_hold<=SHARED_GELU&&guest_mode?{256'b0,a[0][15:8]}:a[1];
       b_hold<=SHARED_GELU&&guest_mode?{256'b0,b[0][15:8]}:b[1];
     end
     if(valid_q[FP_MUL_LATENCY-1])begin
       if(!half_q[FP_MUL_LATENCY-1])even_q<=result;
       else if(SHARED_GELU&&guest_mode)begin y[0]<={result[15:8],even_q[15:8]};y[1]<=0;end
       else begin y[0]<=even_q;y[1]<=result;end
     end
   end
 end
 always_comb begin
   error=0;
   for(int r=0;r<2;r++)for(int lane=0;lane<16;lane++)error[r]|=&y[r][lane][30:23];
 end
endmodule
