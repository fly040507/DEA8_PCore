`timescale 1ns/1ps
module tb_dea8_pe_2row;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0,mul_en=0,active_bank=0,load_we=0,load_bank=0;
  logic signed [7:0] load_weight=0,a0=0,a1=0;
  logic signed [15:0] product0,product1;
  int signed weight_model[0:1];
  int signed expected0[0:1],expected1[0:1];
  bit check_valid=0;
  int checked=0;
  int signed next0,next1;
  dea8_pe_2row dut(.*);
  always @(posedge clk) begin
    if(reset || clear) check_valid=0;
    else begin
      next0=$signed(a0)*weight_model[active_bank];
      next1=$signed(a1)*weight_model[active_bank];
      if(load_we) weight_model[load_bank]=$signed(load_weight);
      #1;
      if(check_valid) begin
        if($signed(product0)!==expected0[0] || $signed(product1)!==expected1[0])
          $fatal(1,"PE packed mismatch got=(%0d,%0d) expect=(%0d,%0d)",
            $signed(product0),$signed(product1),expected0[0],expected1[0]);
        checked++;
      end
      expected0[0]=next0;expected1[0]=next1;check_valid=mul_en;
    end
  end
  function automatic int edge_value(input int sweep);
    case(sweep)
      0:return -128; 1:return -127; 2:return -1; 3:return 0;
      4:return 1; 5:return 126; default:return 127;
    endcase
  endfunction
  task automatic load(input bit bank,input integer value);
    @(negedge clk); load_bank=bank;load_weight=value;load_we=1;
    @(negedge clk);load_we=0;
  endtask
  task automatic multiply(input integer x0,input integer x1);
    @(negedge clk);a0=x0;a1=x1;mul_en=1;
    @(negedge clk);mul_en=0;
  endtask
  initial begin
    repeat(2) @(negedge clk); reset=0; repeat(30) @(negedge clk);
    load(0,127); load(1,-128);
    active_bank=0; multiply(-128,-127);
    repeat(2) @(negedge clk);
    if($signed(product0)!==-16256 || $signed(product1)!==-16129)
      $fatal(1,"PE2 bank0 mismatch p0=%0d p1=%0d",$signed(product0),$signed(product1));
    active_bank=1; multiply(127,-128);
    repeat(2) @(negedge clk);
    if($signed(product0)!==-16256 || $signed(product1)!==16384)
      $fatal(1,"PE2 bank1 mismatch p0=%0d p1=%0d",$signed(product0),$signed(product1));
    // All 256x256 (a1,b) pairs for seven a0 boundaries, plus an a0 sweep.
    for(int sweep=0;sweep<8;sweep++) for(int b=-128;b<128;b++) begin
      active_bank=(b+128)%2;
      load(active_bank,b);
      for(int a=-128;a<128;a++) begin
        @(negedge clk);a0=sweep==7 ? 8'(a*73+b*19) : 8'(edge_value(sweep));
        a1=a;mul_en=1;
        if((a+128)%31==30) begin
          @(negedge clk);mul_en=0;
        end
      end
      @(negedge clk);mul_en=0;
    end
    repeat(3) @(negedge clk);
    if(checked!=524290) $fatal(1,"PE coverage count %0d",checked);
    // Cancel a product between multiply and unpack; no stale output retirement.
    @(negedge clk);mul_en=1;
    @(negedge clk);mul_en=0;clear=1;
    @(negedge clk);clear=0;
    repeat(3) @(negedge clk);
    if(checked!=524290) $fatal(1,"PE clear retained an old transaction");
    $display("tb_dea8_pe_2row PASS vectors=%0d products=%0d",checked,2*checked); $finish;
  end
  initial begin #4000000;$fatal(1,"PE watchdog");end
endmodule
