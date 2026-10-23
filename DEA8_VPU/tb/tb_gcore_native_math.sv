`timescale 1ns/1ps
module tb_gcore_native_math;
  import dea8_compute_config_pkg::*;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,advance=1,in_valid=0;
  logic [31:0] a,b,ay,my;
  logic [FP_ADD_LATENCY-1:0] av;
  logic [FP_MUL_LATENCY-1:0] mv;
  logic [127:0] vectors[256];
  int sent=0,adds=0,muls=0,cycle=0;
  dea8_gcore_fp_add add(.clk,.reset,.clear,.advance,.a,.b,.result(ay));
  dea8_gcore_fp_mul multiply(.clk,.reset,.clear,.advance,.a,.b,.result(my));
  always @(posedge clk)begin
    cycle++;
    if(reset||clear)begin av<=0;mv<=0;end
    else if(advance)begin
      av<={av[FP_ADD_LATENCY-2:0],in_valid};mv<={mv[FP_MUL_LATENCY-2:0],in_valid};
    end
  end
  always @(negedge clk)if(!reset&&!clear&&advance)begin
    if(av[FP_ADD_LATENCY-1])begin
      if(ay!==vectors[adds][63:32])$fatal(1,"GCore native ADD index=%0d",adds);
      adds++;
    end
    if(mv[FP_MUL_LATENCY-1])begin
      if(my!==vectors[muls][31:0])$fatal(1,"GCore native MUL index=%0d",muls);
      muls++;
    end
  end
  initial begin
    $readmemh("Pcore/tb/data/compute/binary.mem",vectors);a=0;b=0;
    repeat(35)@(negedge clk);reset=0;
    while(sent<256)begin
      @(negedge clk);advance=cycle%9>2;in_valid=1;
      a=vectors[sent][127:96];b=vectors[sent][95:64];
      @(posedge clk);if(advance)sent++;
    end
    @(negedge clk);in_valid=0;advance=1;
    wait(adds==256&&muls==256);repeat(2)@(negedge clk);
    $display("tb_gcore_native_math PASS native_add=256 native_multiply=256 CE_backpressure=1");$finish;
  end
  initial begin #100000;$fatal(1,"GCore arithmetic timeout adds=%0d muls=%0d",adds,muls);end
endmodule
