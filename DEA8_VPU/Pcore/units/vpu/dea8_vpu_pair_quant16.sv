// One B16 quantizer; ordered even/odd transactions and held pair output.
module dea8_vpu_pair_quant16(
 input logic clk,reset,clear,in_valid,output logic in_ready,advance,
 input dea8_vpu_math_pkg::pair_fp_t x,input logic [1:0][15:0] lane_valid,
 output logic out_valid,input logic out_ready,
 output dea8_vpu_math_pkg::pair_int8_t q,output logic [1:0][7:0] scale,
 output logic [1:0] error
);
 logic second,half_out;
 logic [15:0][31:0] x_hold;
 logic [15:0] mask_hold;
 logic quant_ready,quant_valid,quant_out_ready,quant_error;
 logic [15:0][7:0] quant_q;
 logic [7:0] quant_scale;
 wire take=in_valid&&in_ready;
 assign in_ready=quant_ready&&!second;
 assign advance=quant_ready;
 assign quant_out_ready=!out_valid||out_ready;
 dea8_vpu_quant16_pipe quant(.clk,.reset,.clear,.in_valid(take||second),.in_ready(quant_ready),
   .x(second?x_hold:x[0]),.lane_valid(second?mask_hold:lane_valid[0]),
   .out_valid(quant_valid),.out_ready(quant_out_ready),.q(quant_q),.scale(quant_scale),.error(quant_error));
 always_ff @(posedge clk)begin
   if(reset||clear)begin second<=0;half_out<=0;out_valid<=0;end
   else begin
     if(out_valid&&out_ready)out_valid<=0;
     if(quant_ready)begin
       if(second)second<=0;
       else if(take)begin second<=1;x_hold<=x[1];mask_hold<=lane_valid[1];end
     end
     if(quant_valid&&quant_out_ready)begin
       half_out<=!half_out;
       if(!half_out)begin q[0]<=quant_q;scale[0]<=quant_scale;error[0]<=quant_error;end
       else begin q[1]<=quant_q;scale[1]<=quant_scale;error[1]<=quant_error;out_valid<=1;end
     end
   end
 end
endmodule
