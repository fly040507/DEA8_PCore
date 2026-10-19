`timescale 1ns/1ps
module tb_compute_math;
  import dea8_vpu_math_pkg::*;
  import dea8_compute_config_pkg::*;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,iv=0,av,mv;
  logic [31:0] a,b,ay;
  pair_fp_t ma,mb,my;logic [1:0] error;
  logic [127:0] vectors[256];
  int launched=0,adds=0,muls=0;
  dea8_vpu_add_pipe add(.clk,.reset,.clear,.in_valid(iv),.a,.b,.out_valid(av),.y(ay));
  dea8_vpu_mul32_shared mul(.clk,.reset,.clear,.in_valid(iv),.a(ma),.b(mb),.out_valid(mv),.y(my),.error);
  always_comb begin ma='0;mb='0;ma[0][0]=a;mb[0][0]=b;end
  always @(negedge clk)if(!reset)begin
    if(av)begin
      if(ay!==vectors[adds][63:32])$fatal(1,"native add mismatch %0d got=%h want=%h",adds,ay,vectors[adds][63:32]);
      adds++;
    end
    if(mv)begin
      if(my[0][0]!==vectors[muls][31:0])$fatal(1,"native multiply mismatch %0d got=%h want=%h",muls,my[0][0],vectors[muls][31:0]);
      muls++;
    end
  end
  initial begin
    $readmemh("tb/data/compute/binary.mem",vectors);
    repeat(32)@(negedge clk);reset=0;repeat(8)@(negedge clk);
    for(int i=0;i<256;i++)begin
      iv=1;a=vectors[i][127:96];b=vectors[i][95:64];@(negedge clk);
    end
    iv=0;wait(adds==256&&muls==256);repeat(3)@(negedge clk);
    $display("tb_compute_math PASS adds=%0d multiplies=%0d ADD_LAT=%0d MUL_LAT=%0d",adds,muls,FP_ADD_LATENCY,FP_MUL_LATENCY);$finish;
  end
  initial begin #200000;$fatal(1,"compute math watchdog");end
endmodule
