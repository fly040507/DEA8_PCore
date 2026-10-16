`timescale 1ns/1ps
module tb_gcore_arithmetic;
  import gcore_fp_pkg::*;
  logic clk=0; always #2 clk=~clk;
  logic advance=1;
  logic [31:0] a=0,b=0,product;
  logic [15:0][31:0] quant_input=0;
  logic [136:0] quant_output,quant_expected[3];
  logic [95:0] multiply_vectors[4096];
  logic [95:0] add_vectors[4096];
  logic [31:0] add_a=0,add_b=0,add_result,add_expected[4];
  bit add_valid[4];
  logic [47:0] bf_vectors[2048];
  logic [648:0] quant_vectors[256];
  logic [31:0] expected[3];
  bit valid[3];
  int checked=0;
  dea8_gcore_fp_mul dut(.clk,.advance,.a,.b,.result(product));
  dea8_gcore_fp_add add_dut(.clk,.advance,.a(add_a),.b(add_b),.result(add_result));
  dea8_gcore_quant quant_dut(.clk,.advance,.values(quant_input),.result(quant_output));
  initial begin
    $readmemh("tb/data/multiply.mem",multiply_vectors);
    $readmemh("tb/data/add.mem",add_vectors);
    $readmemh("tb/data/bf16.mem",bf_vectors);
    $readmemh("tb/data/quantize.mem",quant_vectors);
    for(int i=0;i<3;i++) begin valid[i]=0; expected[i]=0; end
    for(int i=0;i<4;i++) begin add_valid[i]=0;add_expected[i]=0;end
    #120; // Official DSP model startup/GSR, not an arithmetic latency.
    for(int i=0;i<2048;i++)
      if(round_bf16(bf_vectors[i][47:16])!==bf_vectors[i][15:0]) $fatal(1,"BF16 RNE mismatch vector=%0d",i);
    for(int i=0;i<256;i++)
      if(quantize16(quant_vectors[i][648:137])!==quant_vectors[i][136:0])
        $fatal(1,"MXINT8 quantization mismatch vector=%0d got=%h expected=%h",i,quantize16(quant_vectors[i][648:137]),quant_vectors[i][136:0]);
    for(int i=0;i<4099;i++) begin
      @(negedge clk);
      if(valid[2]) begin
        if(product!==expected[2]) $fatal(1,"FP32 multiply mismatch index=%0d got=%h expected=%h",checked,product,expected[2]);
        checked++;
      end
      for(int j=2;j>0;j--) begin expected[j]=expected[j-1]; valid[j]=valid[j-1]; end
      valid[0]=i<4096;
      if(i<4096) begin a=multiply_vectors[i][95:64]; b=multiply_vectors[i][63:32]; expected[0]=multiply_vectors[i][31:0]; end
      if(i%17==3) begin
        logic [31:0] held;
        held=product; advance=0; repeat(3) @(negedge clk);
        if(product!==held) $fatal(1,"multiply did not honor pipeline stall");
        advance=1;
      end
    end
    if(checked!=4096) $fatal(1,"multiply coverage missing");
    checked=0;
    for(int i=0;i<4100;i++) begin
      @(negedge clk);
      if(add_valid[3]) begin
        if(add_result!==add_expected[3])
          $fatal(1,"FP32 DSP add mismatch index=%0d got=%h expected=%h",checked,add_result,add_expected[3]);
        checked++;
      end
      for(int j=3;j>0;j--) begin add_expected[j]=add_expected[j-1];add_valid[j]=add_valid[j-1];end
      add_valid[0]=i<4096;
      if(i<4096) begin add_a=add_vectors[i][95:64];add_b=add_vectors[i][63:32];add_expected[0]=add_vectors[i][31:0];end
      if(i%19==4) begin
        logic [31:0] held;
        held=add_result;advance=0;repeat(3) @(negedge clk);
        if(add_result!==held)$fatal(1,"DSP add ignored pipeline stall");
        advance=1;
      end
    end
    if(checked!=4096)$fatal(1,"DSP add coverage missing");
    for(int i=0;i<3;i++) valid[i]=0;
    checked=0;
    for(int i=0;i<259;i++) begin
      @(negedge clk);
      if(valid[2]) begin
        if(quant_output!==quant_expected[2]) $fatal(1,"pipelined MXINT8 mismatch index=%0d",checked);
        checked++;
      end
      for(int j=2;j>0;j--) begin quant_expected[j]=quant_expected[j-1]; valid[j]=valid[j-1]; end
      valid[0]=i<256;
      if(i<256) begin quant_input=quant_vectors[i][648:137]; quant_expected[0]=quant_vectors[i][136:0]; end
      if(i%13==2) begin
        logic [136:0] held;
        held=quant_output; advance=0; repeat(2) @(negedge clk);
        if(quant_output!==held) $fatal(1,"quantizer ignored pipeline stall");
        advance=1;
      end
    end
    if(checked!=256) $fatal(1,"pipelined quantizer coverage missing");
    $display("tb_gcore_arithmetic PASS fp32_mul=4096 fp32_add=4096 bf16=2048 quant=256 quant_pipeline=256 stalled_pipeline=1");
    $finish;
  end
  initial begin #200000; $fatal(1,"arithmetic watchdog"); end
endmodule
