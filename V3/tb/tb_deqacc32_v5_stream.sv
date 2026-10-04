`timescale 1ns/1ps
import pcore3_pkg::*;
module tb_deqacc32_v5_stream;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,rsp_valid=0,commit_valid,done;
  mxu_rsp_t rsp;
  pair_meta_t commit_meta;
  logic [31:0] model[0:2][0:415][0:1][0:15];
  logic [1:0][15:0][31:0] queue_data[0:10];
  pair_meta_t queue_meta[0:10];
  logic [1:0] queue_rows[0:10];
  logic [10:0] valids=0;
  logic [31:0] rng=32'h37fa5901;
  int checked=0;
  DEQACC_3_3ns dut(.clk,.reset,.clear,.rsp_valid,.rsp,.commit_valid,.done,.commit_meta,
    .result_rd_owner(ACC_READ_RESULT),.result_rd_valid(1'b0),.result_rd_ready(),
    .result_rd_sel(ACC_OACC),.result_rd_addr('0),.result_rd_data_valid(),.result_even_data(),.result_odd_data(),
    .vpu_wr_valid(1'b0),.vpu_wr_ready(),.vpu_wr('0),
    .dbg_valid(1'b0),.dbg_sel(ACC_OACC),.dbg_parity(1'b0),.dbg_addr('0),.dbg_lane('0),.dbg_data());
  function automatic logic [31:0] rand_next(input logic [31:0] x);
    logic [31:0] a,b;a=x^(x<<13);b=a^(a>>17);return b^(b<<5);
  endfunction
  function automatic logic [31:0] partial(input logic signed [31:0] x,input int a,b,fold);
    logic [31:0] mag;int lead;
    mag=x[31]?(~x+1):x;lead=0;
    for(int i=0;i<32;i++)if(mag[i])lead=i;
    return fp32_legacy_ref_pkg::pack_scaled32(x[31],mag<<(31-lead),a+b-266+fold+lead,mag==0,a==255||b==255);
  endfunction
  always @(posedge clk) begin
    int addr;logic [31:0] p;
    if(reset||clear) valids=0;
    else begin
      // Values presented to the actual RAM write port must match this token.
      if(dut.context_q[9].valid) begin
        for(int r=0;r<2;r++)for(int n=0;n<16;n++)if(queue_rows[9][r])
          if(dut.lane_value[r][n]!==queue_data[9][r][n])
            $fatal(1,"stream numeric mismatch transaction=%0d r=%0d lane=%0d got=%h want=%h nt=%0d pair=%0d bank=%0d",checked,r,n,dut.lane_value[r][n],queue_data[9][r][n],queue_meta[9].nt,queue_meta[9].pair_idx,queue_meta[9].acc_sel);
      end
      for(int i=10;i>0;i--)begin
        valids[i]=valids[i-1];queue_data[i]=queue_data[i-1];queue_meta[i]=queue_meta[i-1];queue_rows[i]=queue_rows[i-1];
      end
      valids[0]=rsp_valid;queue_meta[0]=rsp.meta;queue_rows[0]=rsp.row_valid;
      if(rsp_valid)begin
        addr=rsp.meta.acc_sel==ACC_OACC?oacc_addr(rsp.meta.pair_idx,rsp.meta.nt):int'(rsp.meta.pair_idx);
        for(int r=0;r<2;r++)for(int n=0;n<16;n++)begin
          p=partial(rsp.psum[r][n],int'(rsp.e_stream[r]),int'(rsp.e_stat[n]),int'($signed(rsp.meta.exp_fold)));
          queue_data[0][r][n]=rsp.meta.add_old?fp32_legacy_ref_pkg::fp32_add(model[rsp.meta.acc_sel][addr][r][n],p):p;
          if(rsp.row_valid[r])model[rsp.meta.acc_sel][addr][r][n]=queue_data[0][r][n];
        end
      end
    end
    #1;
    if($test$plusargs("trace")&&$time<60) $display("t=%0t s0=%h exp=%0d s1=%h s2=%h lane=%h",$time,dut.s0[0][1].norm,$signed(dut.s0[0][1].exponent),dut.s1[0][1],dut.s2[0][1],dut.lane_value[0][1]);
    if(commit_valid!==valids[10])$fatal(1,"stream fixed latency mismatch");
    if(commit_valid)begin
      if(commit_meta!==queue_meta[10]||done!==queue_meta[10].last)$fatal(1,"stream metadata mismatch");
      checked++;
    end
  end
  initial begin
    rsp='0;
    for(int b=0;b<3;b++)for(int a=0;a<416;a++)for(int r=0;r<2;r++)for(int n=0;n<16;n++)model[b][a][r][n]=0;
    repeat(5)@(negedge clk);reset=0;
    for(int i=0;i<5000;i++)begin
      rsp='0;rsp_valid=1;rsp.meta.acc_sel=acc_sel_e'(i%3);
      rsp.meta.pair_idx=PAIR_BITS'((i/3)%PAIRS);rsp.meta.nt=TILE_BITS'((i/(3*PAIRS))%16);
      rng=rand_next(rng);rsp.meta.add_old=rng[0];rsp.meta.exp_fold=EXP_FOLD_BITS'(rng[6:1]);
      rsp.meta.epoch=EPOCH_BITS'(i);rsp.meta.head=3'(i/17);rsp.meta.tile_idx=TILE_BITS'(i/7);rsp.meta.last=i==4999;
      rsp.row_valid=(rng[8:7]|2'b01)&row_mask(rsp.meta.pair_idx);
      rsp.e_stream[0]=rng[23:16];rsp.e_stream[1]=rng[31:24];
      for(int n=0;n<16;n++)begin
        rng=rand_next(rng);rsp.e_stat[n]=rng[7:0];rsp.psum[0][n]=$signed(rng);
        rng=rand_next(rng);rsp.psum[1][n]=$signed(rng);
      end
      @(negedge clk);
    end
    rsp_valid=0;repeat(12)@(negedge clk);
    if(checked!=5000)$fatal(1,"stream count %0d",checked);
    $display("tb_deqacc32_v5_stream PASS transactions=%0d lanes=32 latency=11 II=1",checked);$finish;
  end
endmodule
