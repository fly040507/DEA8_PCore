module dea8_vpu_dsp_addsub(input logic clk,reset,ce,subtract,
 input logic [27:0] a,b,output logic [27:0] y);
 wire [47:0] p;
 assign y=p[27:0];
 DSP48E2 #(.AREG(0),.ACASCREG(0),.BREG(0),.BCASCREG(0),.DREG(0),.ADREG(0),
  .MREG(0),.PREG(1),.CREG(0),.INMODEREG(0),.OPMODEREG(0),.ALUMODEREG(0),
  .CARRYINREG(0),.CARRYINSELREG(0),.USE_MULT("NONE"),.USE_SIMD("ONE48")) dsp(
  .CLK(clk),.A({20'b0,b[27:18]}),.B(b[17:0]),.C({20'b0,a}),.D(27'b0),
  .INMODE(5'b0),.OPMODE(9'b000110011),.ALUMODE({2'b00,{2{subtract}}}),
  .CARRYINSEL(3'b0),.CARRYIN(1'b0),.CARRYCASCIN(1'b0),.MULTSIGNIN(1'b0),
  .ACIN(30'b0),.BCIN(18'b0),.PCIN(48'b0),.P(p),
  .CEA1(1'b0),.CEA2(1'b0),.CEB1(1'b0),.CEB2(1'b0),.CEAD(1'b0),.CED(1'b0),
  .CEC(1'b0),.CECTRL(1'b0),.CEINMODE(1'b0),.CEALUMODE(1'b0),.CECARRYIN(1'b0),
  .CEM(1'b0),.CEP(ce),.RSTA(1'b0),.RSTB(1'b0),.RSTD(1'b0),.RSTC(1'b0),
  .RSTM(1'b0),.RSTP(reset),.RSTCTRL(1'b0),.RSTINMODE(1'b0),.RSTALUMODE(1'b0),.RSTALLCARRYIN(1'b0));
endmodule
