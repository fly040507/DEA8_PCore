module dea8_vpu_mul32_shared(
  input logic clk,reset,clear,in_valid,output logic out_valid,
  input dea8_vpu_math_pkg::pair_fp_t a,b,
  output dea8_vpu_math_pkg::pair_fp_t y,output logic [1:0] error
);
  logic [1:0] reset_q;
  logic [1:0][15:0] native_valid;
  always_ff @(posedge clk)
    if(reset||clear) reset_q<=2'b11; else reset_q<={reset_q[0],1'b0};
  wire active=!(reset||clear||(|reset_q));
  for(genvar r=0;r<2;r++)begin: rows
    logic [15:0] bad;
    for(genvar j=0;j<16;j++)begin: lanes
      dea8_fpmul_ip native_mul(
        .aclk(clk),.aclken(1'b1),.aresetn(active),
        .s_axis_a_tvalid(in_valid&&active),.s_axis_a_tdata(a[r][j]),
        .s_axis_b_tvalid(in_valid&&active),.s_axis_b_tdata(b[r][j]),
        .m_axis_result_tvalid(native_valid[r][j]),.m_axis_result_tdata(y[r][j])
      );
      assign bad[j]=(&y[r][j][30:23]);
    end
    assign error[r]=|bad;
  end
  assign out_valid=active&&native_valid[0][0];
endmodule
