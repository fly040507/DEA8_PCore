`timescale 1ns/1ps
module tb_deq_format_nocost;
  import pcore_pkg::*;
  localparam int COUNT=384;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,rsp_valid=0,commit_valid,done,commit_write_valid;
  mxu_rsp_t rsp;pair_meta_t commit_meta;acc_write_t commit_write;
  logic [1:0][15:0][31:0] expected[COUNT];
  pair_meta_t tags[COUNT];
  int cycle=0,issued=0,received=0,launch_cycle[COUNT];
  DEQACC_3_3ns dut(.clk,.reset,.clear,.rsp_valid,.rsp,.commit_valid,.commit_meta,.done,
    .commit_write_valid,.commit_write,.matrix_tile('0),.matrix_needs_scaled(1'b0),.matrix_tile_ready(),
    .raw_begin(1'b0),.raw_page(1'b0),.result_rd_owner(ACC_READ_RESULT),.result_rd_valid(1'b0),
    .result_rd_ready(),.result_rd_sel(ACC_FACC_A),.result_rd_addr('0),.result_rd_data_valid(),
    .result_even_data(),.result_odd_data(),.vpu_wr_valid(1'b0),.vpu_wr_ready(),.vpu_wr('0),
    .dbg_valid(1'b0),.dbg_sel(ACC_FACC_A),.dbg_parity(1'b0),.dbg_addr('0),.dbg_lane('0),.dbg_data());

  // Integer quotient/remainder RNE oracle, independent of the DUT's jam tree.
  function automatic logic [31:0] oracle(input logic signed [PSUM_BITS-1:0] x,
    input logic [7:0] a,b,input logic signed [EXP_FOLD_BITS-1:0] fold);
    longint unsigned mag,normalized,quotient,remainder,half;
    int lead,exponent,distance;
    logic [7:0] field;
    if(a==255||b==255)return 32'h7fc00000;
    if(x==0)return 0;
    mag=x<0?-longint'(x):longint'(x);lead=0;
    for(int bit_idx=0;bit_idx<PSUM_BITS;bit_idx++)if(mag[bit_idx])lead=bit_idx;
    exponent=int'(a)+int'(b)-266+int'(fold)+lead;
    if(exponent>127)return {x[PSUM_BITS-1],8'hff,23'b0};
    normalized=mag<<(23-lead);
    if(exponent>=-126)begin field=8'(exponent+127);return {x[PSUM_BITS-1],field,23'(normalized)};end
    distance=-126-exponent;
    quotient=0;
    if(distance<=24)begin
      quotient=normalized>>distance;remainder=normalized-(quotient<<distance);half=64'b1<<(distance-1);
      if(remainder>half||(remainder==half&&quotient[0]))quotient++;
    end
    return {x[PSUM_BITS-1],7'b0,24'(quotient)};
  endfunction
  always @(posedge clk)begin
    cycle++;
    if(!reset)begin
      if(rsp_valid)begin
        tags[issued]=rsp.meta;launch_cycle[issued]=cycle;
        for(int r=0;r<2;r++)for(int lane=0;lane<16;lane++)
          expected[issued][r][lane]=oracle(rsp.psum[r][lane],rsp.e_stream[r],rsp.e_stat[lane],rsp.meta.exp_fold);
        issued++;
      end
      if(commit_valid)begin
        if(!commit_write_valid||commit_meta!==tags[received]||commit_write.data!==expected[received])
          $fatal(1,"DEQ format transaction=%0d metadata=%b actual0=%h expected0=%h",received,
            commit_meta===tags[received],commit_write.data[0][0],expected[received][0][0]);
        if(cycle-launch_cycle[received]!=DEQACC_PIPE_STAGES)$fatal(1,"DEQ latency %0d",cycle-launch_cycle[received]);
        received++;
      end
    end
  end
  initial begin
    int seed=40123;
    seed=$urandom(seed);rsp='0;
    repeat(35)@(negedge clk);reset=0;repeat(8)@(negedge clk);
    for(int t=0;t<COUNT;t++)begin
      @(negedge clk);rsp='0;rsp.meta.acc_sel=t%2?ACC_FACC_A:ACC_FACC_B;
      rsp.meta.pair_idx=t%PAIRS;rsp.meta.epoch=t%16;rsp.meta.head=t%8;
      rsp.meta.exp_fold=EXP_FOLD_BITS'(t);rsp.meta.last=t==COUNT-1;rsp.row_valid=row_mask(rsp.meta.pair_idx);
      for(int r=0;r<2;r++)rsp.e_stream[r]=8'(t/2);
      for(int lane=0;lane<16;lane++)begin
        rsp.e_stat[lane]=t%16==0?255:8'(t%192+lane);
        for(int r=0;r<2;r++)case(t%9)
          0:rsp.psum[r][lane]=0;
          1:rsp.psum[r][lane]=PSUM_BITS'(1<<lane);
          2:rsp.psum[r][lane]=PSUM_BITS'(-(1<<lane));
          3:rsp.psum[r][lane]=20'h80000;
          4:rsp.psum[r][lane]=20'h7ffff;
          5:rsp.psum[r][lane]=20'hfffff;
          default:rsp.psum[r][lane]=PSUM_BITS'($urandom);
        endcase
      end
      rsp_valid=1;@(negedge clk);rsp_valid=0;repeat(t%4)@(negedge clk);
    end
    wait(received==COUNT);@(negedge clk);
    $display("tb_deq_format_nocost PASS pairs=%0d lane_checks=%0d exact_INT20=1 RNE=1 subnormal=1 overflow=1 bad_scale=1 latency=%0d gaps=1",received,received*32,DEQACC_PIPE_STAGES);$finish;
  end
  initial begin #100000;$fatal(1,"DEQ format timeout issued=%0d received=%0d",issued,received);end
endmodule
