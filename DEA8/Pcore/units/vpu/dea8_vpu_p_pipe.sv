module dea8_vpu_p_pipe(
  input logic clk,reset,clear,in_valid,
  input dea8_vpu_math_pkg::pair_fp_t x,
  input dea8_vpu_math_pkg::scalars_t product,
  input logic [1:0] product_error,input_error,
  output logic out_valid,output dea8_vpu_math_pkg::scalars_t lvalue,
  output logic [1:0] error,
  input logic rope_mode,rope_in_valid,
  input dea8_vpu_math_pkg::pair_fp_t rope_a,rope_b,
  output logic rope_out_valid,output dea8_vpu_math_pkg::pair_fp_t rope_y
);
  import dea8_vpu_math_pkg::*;
  import dea8_compute_config_pkg::*;
  localparam int A=FP_ADD_LATENCY, L=5*A, D=4*A-FP_MUL_LATENCY;
  logic [L-1:0] valid_q;
  logic [A-1:0] rope_q;
  scalars_t product_aligned;
  logic [1:0] input_error_q[L],product_error_q[D+A];
  always_ff @(posedge clk)begin
    if(reset||clear)begin valid_q<=0;rope_q<=0;end
    else begin valid_q<={valid_q[L-2:0],in_valid};rope_q<={rope_q[A-2:0],rope_in_valid};end
    product_error_q[0]<=product_error;input_error_q[0]<=input_error;
    for(int i=1;i<D+A;i++)product_error_q[i]<=product_error_q[i-1];
    for(int i=1;i<L;i++)input_error_q[i]<=input_error_q[i-1];
  end
  dea8_delay_ram #(.WIDTH(64),.DELAY(D)) product_delay(
    .clk,.advance(1'b1),.in_data(product),.out_data(product_aligned));
  for(genvar r=0;r<2;r++)begin: rows
    logic [31:0] node_y[16],node_a[16],node_b[16];
    for(genvar n=0;n<16;n++)begin: nodes
      if(n<8)begin assign node_a[n]=x[r][2*n];assign node_b[n]=x[r][2*n+1];end
      else if(n<12)begin assign node_a[n]=node_y[2*(n-8)];assign node_b[n]=node_y[2*(n-8)+1];end
      else if(n<14)begin assign node_a[n]=node_y[8+2*(n-12)];assign node_b[n]=node_y[9+2*(n-12)];end
      else if(n==14)begin assign node_a[n]=node_y[12];assign node_b[n]=node_y[13];end
      else begin assign node_a[n]=product_aligned[r];assign node_b[n]=node_y[14];end
      wire sum_valid=n<8?in_valid:n<12?valid_q[A-1]:n<14?valid_q[2*A-1]:n==14?valid_q[3*A-1]:valid_q[4*A-1];
      dea8_vpu_add_pipe add(.clk,.reset,.clear,.in_valid(rope_mode?rope_in_valid:sum_valid),
        .a(rope_mode?rope_a[r][n]:node_a[n]),.b(rope_mode?rope_b[r][n]:node_b[n]),
        .out_valid(),.y(node_y[n]));
      assign rope_y[r][n]=node_y[n];
    end
    assign lvalue[r]=node_y[15];
    assign error[r]=input_error_q[L-1][r]||product_error_q[D+A-1][r]||nonfinite(lvalue[r]);
  end
  assign out_valid=valid_q[L-1];
  assign rope_out_valid=rope_q[A-1];
endmodule
