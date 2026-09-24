// S1 is the DSP M register; S2 restores two signed products in fabric.
// No behavioral substitute in synthesis or simulation: both use DSP48E2.
module dea8_pe_2row (
  input logic clk,reset,clear,mul_en,
  input logic active_bank,load_we,load_bank,
  input logic signed [7:0] load_weight,a0,a1,
  output logic signed [15:0] product0,product1
);
  (* ram_style="registers" *) logic signed [7:0] weight_bank[0:1];
  logic signed [29:0] a_port;
  logic signed [26:0] d_port;
  logic signed [17:0] b_port;
  logic [47:0] packed_product;
  logic signed [17:0] high_product;
  logic unpack_valid;
  logic [29:0] dsp_acout_unused;
  logic [17:0] dsp_bcout_unused;
  logic dsp_carrycascout_unused;
  logic [3:0] dsp_carryout_unused;
  logic dsp_multsignout_unused;
  logic dsp_overflow_unused;
  logic [47:0] dsp_pcout_unused;
  logic dsp_patternbdetect_unused;
  logic dsp_patterndetect_unused;
  logic dsp_underflow_unused;
  logic [7:0] dsp_xorout_unused;
  assign a_port=$signed({{22{a0[7]}},a0}) <<< 18;
  assign d_port={{19{a1[7]}},a1};
  assign b_port={{10{weight_bank[active_bank][7]}},weight_bank[active_bank]};
  assign high_product=$signed(packed_product[35:18])+
                       (packed_product[17] ? 18'sd1 : 18'sd0);
  always_ff @(posedge clk) begin
    if(load_we && !reset && !clear) weight_bank[load_bank]<=load_weight;
    if(reset || clear) unpack_valid<=0;
    else unpack_valid<=mul_en;
    if(unpack_valid && !reset && !clear) begin
      product0<=high_product[15:0];
      product1<=packed_product[15:0];
    end
  end
  DSP48E2 #(
    .AMULTSEL("AD"),.BMULTSEL("B"),.PREADDINSEL("A"),
    .AREG(0),.ACASCREG(0),.BREG(0),.BCASCREG(0),.DREG(0),.ADREG(0),
    .MREG(1),.PREG(0),.CREG(0),.INMODEREG(0),.OPMODEREG(0),
    .ALUMODEREG(0),.CARRYINREG(0),.CARRYINSELREG(0),
    .USE_MULT("MULTIPLY"),.USE_SIMD("ONE48")
  ) dsp (
    .ACOUT(dsp_acout_unused),.BCOUT(dsp_bcout_unused),
    .CARRYCASCOUT(dsp_carrycascout_unused),.CARRYOUT(dsp_carryout_unused),
    .MULTSIGNOUT(dsp_multsignout_unused),.OVERFLOW(dsp_overflow_unused),
    .PATTERNBDETECT(dsp_patternbdetect_unused),
    .PATTERNDETECT(dsp_patterndetect_unused),.PCOUT(dsp_pcout_unused),
    .UNDERFLOW(dsp_underflow_unused),.XOROUT(dsp_xorout_unused),
    .CLK(clk),.A(a_port),.D(d_port),.B(b_port),.C(48'b0),
    .INMODE(5'b00100),.OPMODE(9'b000000101),.ALUMODE(4'b0),
    .CARRYINSEL(3'b0),.CARRYIN(1'b0),.CARRYCASCIN(1'b0),.MULTSIGNIN(1'b0),
    .ACIN(30'b0),.BCIN(18'b0),.PCIN(48'b0),.P(packed_product),
    .CEA1(1'b0),.CEA2(1'b0),.CEB1(1'b0),.CEB2(1'b0),.CEAD(1'b0),
    .CED(1'b0),.CEC(1'b0),.CECTRL(1'b0),.CEINMODE(1'b0),
    .CEALUMODE(1'b0),.CECARRYIN(1'b0),.CEM(mul_en),.CEP(1'b0),
    .RSTA(reset|clear),.RSTB(reset|clear),.RSTD(reset|clear),.RSTC(reset|clear),
    .RSTM(reset|clear),.RSTP(reset|clear),.RSTCTRL(reset|clear),
    .RSTINMODE(reset|clear),.RSTALUMODE(reset|clear),.RSTALLCARRYIN(reset|clear)
  );
endmodule
