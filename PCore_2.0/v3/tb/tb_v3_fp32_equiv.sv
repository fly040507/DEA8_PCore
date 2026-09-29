`timescale 1ns/1ps
module tb_v3_fp32_equiv;
  logic [31:0] rng=32'h6f79a532;
  logic [31:0] corners[0:15]='{32'h0,32'h80000000,32'h1,32'h80000001,
    32'h007fffff,32'h00800000,32'h3f800000,32'hbf800000,32'h3f800001,32'h33800000,
    32'h7f7fffff,32'hff7fffff,32'h7f800000,32'hff800000,32'h7fc12345,32'h7f800001};
  int checks=0,packs=0;
  function automatic logic [31:0] random_word(input logic [31:0] x);
    logic [31:0] s1,s2;
    s1=x^(x<<13);s2=s1^(s1>>17);return s2^(s2<<5);
  endfunction
  task automatic compare(input logic [31:0] a,b);
    logic [31:0] expected,actual;
    expected=fp32_legacy_ref_pkg::fp32_add(a,b);actual=dea8_fp32_v3_pkg::fp32_add(a,b);
    if(actual!==expected) $fatal(1,"FP add mismatch a=%h b=%h got=%h want=%h",a,b,actual,expected);
    checks++;
  endtask
  initial begin
    for(int a=0;a<16;a++)for(int b=0;b<16;b++)compare(corners[a],corners[b]);
    for(int i=0;i<100000;i++) begin
      logic [31:0] a,b;
      rng=random_word(rng);a=rng;rng=random_word(rng);b=rng;
      compare(a,b);compare(a,{~a[31],a[30:0]});compare(a,{b[31],a[30:23],b[22:0]});
      compare({a[31],8'b0,a[22:0]},{b[31],8'b0,b[22:0]});
    end
    for(int e=-300;e<=300;e++) for(int i=0;i<128;i++) begin
      logic [31:0] n,actual,expected;
      rng=random_word(rng);n=rng|32'h80000000;
      actual=dea8_fp32_v3_pkg::pack_scaled32(i[0],n,11'(e),i==0,i==1);
      expected=fp32_legacy_ref_pkg::pack_scaled32(i[0],n,e,i==0,i==1);
      if(actual!==expected) $fatal(1,"FP pack mismatch e=%0d n=%h got=%h want=%h",e,n,actual,expected);
      packs++;
    end
    $display("tb_v3_fp32_equiv PASS adds=%0d packs=%0d frozen_reference=1",checks,packs);$finish;
  end
endmodule
