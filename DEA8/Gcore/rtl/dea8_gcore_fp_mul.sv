module dea8_gcore_fp_mul (
  input logic clk,advance,
  input logic [31:0] a,b,
  output logic [31:0] result
);
  import gcore_fp_pkg::*;
  logic [23:0] ma,mb;
  logic [47:0] low_product,high_product,low_cascade;
  multiply_raw_t metadata_q,raw;
  multiply_norm_t normalized_q;
  assign ma={(|a[30:23]),a[22:0]};
  assign mb={(|b[30:23]),b[22:0]};
  assign raw={metadata_q.sign_bit,metadata_q.special,metadata_q.special_value,
    high_product[30:0],low_product[16:0],metadata_q.exponent_base};
  // low=A*B[16:0]; high=A*B[23:17]+(low>>17), using the DSP cascade.
  for(genvar half=0;half<2;half++) begin: product_parts
    wire [47:0] p,pcout;
    if(half==0)begin assign low_product=p;assign low_cascade=pcout;end
    else assign high_product=p;
    DSP48E2 #(
      .AREG(0),.ACASCREG(0),.BREG(0),.BCASCREG(0),.CREG(0),
      .DREG(0),.ADREG(0),.MREG(1),.PREG(0),.INMODEREG(0),
      .OPMODEREG(0),.ALUMODEREG(0),.CARRYINREG(0),.CARRYINSELREG(0),
      .USE_MULT("MULTIPLY"),.USE_SIMD("ONE48")
    ) dsp (
      .CLK(clk),.A({6'b0,ma}),
      .B(half==0?{1'b0,mb[16:0]}:{11'b0,mb[23:17]}),.C(48'b0),.D(27'b0),
      .INMODE(5'b0),.OPMODE(half==0?9'b000000101:9'b001010101),.ALUMODE(4'b0),
      .PCIN(half==0?48'b0:low_cascade),.P(p),.PCOUT(pcout),
      .ACIN(30'b0),.BCIN(18'b0),.CARRYIN(1'b0),.CARRYINSEL(3'b0),
      .CARRYCASCIN(1'b0),.MULTSIGNIN(1'b0),
      .CEA1(1'b0),.CEA2(1'b0),.CEB1(1'b0),.CEB2(1'b0),.CEC(1'b0),
      .CED(1'b0),.CEAD(1'b0),.CEM(advance),.CEP(1'b0),
      .CEINMODE(1'b0),.CECTRL(1'b0),.CEALUMODE(1'b0),.CECARRYIN(1'b0),
      .RSTA(1'b0),.RSTB(1'b0),.RSTC(1'b0),.RSTD(1'b0),.RSTM(1'b0),
      .RSTP(1'b0),.RSTINMODE(1'b0),.RSTCTRL(1'b0),
      .RSTALUMODE(1'b0),.RSTALLCARRYIN(1'b0)
    );
  end
  always_ff @(posedge clk) if(advance) begin
    metadata_q<=multiply_prepare(a,b);
    normalized_q<=multiply_normalize(raw);
    result<=multiply_pack(normalized_q);
  end
endmodule
