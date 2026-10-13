`timescale 1ns/1ps
module tb_dynamic_pe;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,mul_en=0,active_bank=0,load_we=0,load_bank=0;
  logic signed [7:0] load_weight=0,a0=0,a1=0;
  logic signed [15:0] product0,product1;
  int weights[0:1],expected0,expected1,checks=0;
  bit pending=0;
  dea8_pe_2row dut(.*);
  always @(posedge clk)begin
    bit check_now;int old0,old1;
    check_now=pending;old0=expected0;old1=expected1;
    if(reset||clear)begin pending=0;check_now=0;end
    else begin
      pending=mul_en;
      if(mul_en)begin
        expected0=int'($signed(a0))*weights[active_bank];
        expected1=int'($signed(a1))*weights[active_bank];
      end
      if(load_we)weights[load_bank]=int'($signed(load_weight));
    end
    #1;
    if(check_now)begin
      if($signed(product0)!==16'(old0)||$signed(product1)!==16'(old1))
        $fatal(1,"PE mismatch p0=%0d/%0d p1=%0d/%0d",product0,old0,product1,old1);
      checks++;
    end
  end
  initial begin
    // glbl's GSR lasts 100 ns even after the local reset is released.
    repeat(32)@(negedge clk);reset=0;
    for(int w=-128;w<=127;w++)begin
      @(negedge clk);load_we=1;load_bank=w[0];load_weight=8'(w);
      @(negedge clk);load_we=0;active_bank=w[0];
      for(int v=-128;v<=127;v++)begin
        a0=8'(v);a1=8'(v*37+w*13);mul_en=1;
        @(negedge clk);
      end
      mul_en=0;repeat(2)@(negedge clk);
    end
    if(checks!=65536)$fatal(1,"PE coverage count mismatch");
    // Reset/clear must discard an in-flight unpack, not produce a stale value.
    mul_en=1;@(negedge clk);mul_en=0;clear=1;
    @(negedge clk);clear=0;repeat(3)@(negedge clk);
    if(checks!=65536)$fatal(1,"PE clear did not cancel multiply");
    $display("tb_dynamic_pe PASS shared_B_products=%0d bank0_bank1=1 signed_extrema=1",checks*2);
    $finish;
  end
  initial begin #1000000;$fatal(1,"PE watchdog");end
endmodule
