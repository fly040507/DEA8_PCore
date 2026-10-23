module dea8_vpu_add_pipe(
  input logic clk,reset,clear,in_valid,
  input logic [31:0] a,b,output logic out_valid,output logic [31:0] y
);
  dea8_vpu_add_stall impl(.clk,.reset,.clear,.in_valid,.advance(1'b1),.a,.b,.out_valid,.y);
endmodule

module dea8_vpu_add_stall(
  input logic clk,reset,clear,in_valid,advance,
  input logic [31:0] a,b,output logic out_valid,output logic [31:0] y
);
  logic [1:0] reset_q;
  always_ff @(posedge clk)
    if(reset||clear) reset_q<=2'b11; else reset_q<={reset_q[0],1'b0};
  wire active=!(reset||clear||(|reset_q));
  logic native_valid;
  dea8_fpadd_ip native_add(
    .aclk(clk),.aclken(advance),.aresetn(active),
    .s_axis_a_tvalid(in_valid&&active),.s_axis_a_tdata(a),
    .s_axis_b_tvalid(in_valid&&active),.s_axis_b_tdata(b),
    .m_axis_result_tvalid(native_valid),.m_axis_result_tdata(y)
  );
  assign out_valid=active&&native_valid;
endmodule
