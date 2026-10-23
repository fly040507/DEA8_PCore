`timescale 1ns/1ps
module tb_fp32_acc_lane_v5;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,in_valid=0,add_old=0,out_valid;
  logic [31:0] old_value=0,partial_value=0,result_value;
  logic [31:0] expected[0:5];
  logic [5:0] valids=0;
  logic [31:0] rng=32'h12345678;
  int checked=0;
  DEQACC_3_3ns_lane dut(.*);
  function automatic logic [31:0] next_rng(input logic [31:0] x);
    logic [31:0] a,b;
    a=x^(x<<13);b=a^(a>>17);return b^(b<<5);
  endfunction
  always @(posedge clk) begin
    if(reset||clear) valids=0;
    else begin
      for(int i=5;i>0;i--) begin expected[i]=expected[i-1];valids[i]=valids[i-1];end
      valids[0]=in_valid;
      expected[0]=add_old?fp32_legacy_ref_pkg::fp32_add(old_value,partial_value):partial_value;
    end
    #1;
    if(out_valid!==valids[5]) $fatal(1,"lane valid latency mismatch");
    if(out_valid) begin
      if(result_value!==expected[5]) $fatal(1,"lane mismatch got=%h expected=%h index=%0d",result_value,expected[5],checked);
      checked++;
    end
  end
  initial begin
    repeat(4) @(negedge clk);reset=0;
    for(int i=0;i<1000000;i++) begin
      in_valid=1;add_old=i[0];rng=next_rng(rng);old_value=rng;
      rng=next_rng(rng);partial_value=rng;
      case(i%16)
        0,1: partial_value={~old_value[31],old_value[30:0]};
        2,3: begin old_value[30:23]=0;partial_value[30:23]=0;end
        4,5: old_value=32'h7f800000;
        6,7: partial_value=32'h7fc00001;
        8,9: begin old_value=32'h3f800001;partial_value=32'h33800000;end
        10,11: begin old_value=32'h80000000;partial_value=0;end
        default: ;
      endcase
      @(negedge clk);
    end
    in_valid=0;repeat(8) @(negedge clk);
    if(checked!=1000000) $fatal(1,"lane throughput count %0d",checked);
    // Cancel a nonempty pipeline; payload is deliberately not reset.
    in_valid=1;repeat(3)@(negedge clk);clear=1;
    @(negedge clk);clear=0;in_valid=0;
    repeat(8)@(negedge clk);
    if(checked!=1000000) $fatal(1,"clear leaked cancelled transactions");
    for(int i=0;i<16;i++)begin in_valid=1;partial_value=32'h3f800000;old_value=32'h3f800000;add_old=i[0];@(negedge clk);end
    in_valid=0;repeat(8)@(negedge clk);
    if(checked!=1000016) $fatal(1,"post-clear restart count");
    $display("tb_fp32_acc_lane_v5 PASS transactions=%0d latency=6 II=1",checked);$finish;
  end
endmodule
