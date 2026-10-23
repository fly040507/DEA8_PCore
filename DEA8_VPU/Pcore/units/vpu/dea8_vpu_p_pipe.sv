// One sixteen-adder bank: 15-node row sum + l update, or 16 RoPE adds.
// Even/odd rows are adjacent beats, not duplicated arithmetic pipelines.
module dea8_vpu_p_pipe #(parameter bit SHARE_ADD=0)(
 input logic clk,reset,clear,in_valid,
 input dea8_vpu_math_pkg::pair_fp_t x,
 input dea8_vpu_math_pkg::scalars_t product,
 input logic [1:0] product_error,input_error,
 output logic out_valid,output dea8_vpu_math_pkg::scalars_t lvalue,
 output logic [1:0] error,
 input logic rope_mode,rope_in_valid,
 input dea8_vpu_math_pkg::pair_fp_t rope_a,rope_b,
 output logic rope_out_valid,output dea8_vpu_math_pkg::pair_fp_t rope_y,
 input logic [3:0] guest_valid,input logic [3:0][31:0] guest_a,guest_b,
 output logic guest_ready,output logic [3:0] guest_out_valid,output logic [3:0][31:0] guest_y
);
 import dea8_compute_config_pkg::*;
 localparam int A=FP_ADD_LATENCY,L=5*A,D=4*A-(FP_MUL_LATENCY+2);
 logic second;
 logic [15:0][31:0] x_hold,ra_hold,rb_hold,row_x,node_a,node_b,node_y;
 logic [L-1:0] v,h;
 logic [31:0] even_sum;
 logic [15:0][31:0] even_rope;
 logic [L+1:0][1:0] input_errors;
 logic [D+A+1:0][1:0] product_errors;
 logic [63:0] aligned_product;
 wire launch=rope_mode?rope_in_valid:in_valid;
 wire row_valid=launch||second;
 assign guest_ready=!row_valid;
 assign row_x=second?x_hold:x[0];
 dea8_delay_ram #(.WIDTH(64),.DELAY(D)) product_delay(
   .clk,.advance(1'b1),.in_data(product),.out_data(aligned_product));
 always_comb begin
   for(int n=0;n<16;n++)begin
     if(n<8)begin node_a[n]=row_x[2*n];node_b[n]=row_x[2*n+1];end
     else if(n<12)begin node_a[n]=node_y[2*(n-8)];node_b[n]=node_y[2*(n-8)+1];end
     else if(n<14)begin node_a[n]=node_y[8+2*(n-12)];node_b[n]=node_y[9+2*(n-12)];end
     else if(n==14)begin node_a[n]=node_y[12];node_b[n]=node_y[13];end
     else begin node_a[n]=h[4*A-1]?aligned_product[63:32]:aligned_product[31:0];node_b[n]=node_y[14];end
     if(rope_mode)begin node_a[n]=second?ra_hold[n]:rope_a[0][n];node_b[n]=second?rb_hold[n]:rope_b[0][n];end
   end
 end
 for(genvar n=0;n<16;n++)begin: nodes
   wire sum_valid=n<8?row_valid:n<12?v[A-1]:n<14?v[2*A-1]:n==14?v[3*A-1]:v[4*A-1];
   wire external_use=SHARE_ADD&&(n<4)&&!row_valid&&guest_valid[n%4];
   logic add_valid;
   dea8_vpu_add_pipe add(.clk,.reset,.clear,
     .in_valid(external_use?1'b1:(rope_mode?row_valid:sum_valid)),
     .a(external_use?guest_a[n%4]:node_a[n]),.b(external_use?guest_b[n%4]:node_b[n]),
     .out_valid(add_valid),.y(node_y[n]));
   if(n<4)begin
     logic [A-1:0] guest_tag;
     always_ff @(posedge clk)begin
       if(reset||clear)guest_tag<=0;else guest_tag<={guest_tag[A-2:0],external_use};
     end
     assign guest_out_valid[n]=add_valid&&guest_tag[A-1];assign guest_y[n]=node_y[n];
   end
 end
 always_ff @(posedge clk)begin
   if(reset||clear)begin second<=0;v<=0;h<=0;out_valid<=0;rope_out_valid<=0;end
   else begin
     second<=launch;
     v<={v[L-2:0],row_valid};h<={h[L-2:0],second};
     out_valid<=!rope_mode&&v[L-1]&&h[L-1];
     rope_out_valid<=rope_mode&&v[A-1]&&h[A-1];
     if(launch)begin x_hold<=x[1];ra_hold<=rope_a[1];rb_hold<=rope_b[1];end
     if(!rope_mode&&v[L-1])begin
       if(!h[L-1])even_sum<=node_y[15];
       else begin lvalue[0]<=even_sum;lvalue[1]<=node_y[15];
         error<=input_errors[L]|product_errors[D+A]|
           {(&node_y[15][30:23]),(&even_sum[30:23])};
       end
     end
     if(rope_mode&&v[A-1])begin
       if(!h[A-1])even_rope<=node_y;
       else begin rope_y[0]<=even_rope;rope_y[1]<=node_y;end
     end
   end
   input_errors[0]<=input_error;product_errors[0]<=product_error;
   for(int i=1;i<L+2;i++)input_errors[i]<=input_errors[i-1];
   for(int i=1;i<D+A+2;i++)product_errors[i]<=product_errors[i-1];
 end
 // synthesis translate_off
 always @(posedge clk)if(!reset&&!clear&&launch&&second)$fatal(1,"ADD16 pair input overrun");
 // synthesis translate_on
endmodule
