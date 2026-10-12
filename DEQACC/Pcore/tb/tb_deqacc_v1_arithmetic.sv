`timescale 1ns/1ps
import pcore_pkg::*;
module tb_deqacc_v1_arithmetic;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,qvalid=0,avalid=0,add_old=1,qout,aout;
  logic signed [31:0] psum;
  logic [7:0] ea,eb;
  logic signed [EXP_FOLD_BITS-1:0] fold;
  logic [31:0] a,b,qresult,aresult;
  logic [1:0] qv=0;logic [3:0] av=0;
  logic [31:0] qexpect[0:1],aexpect[0:3];
  logic [31:0] rng=32'hbe719403;
  int qcount=0,acount=0,close_count=0,far_sub_count=0,bypass_count=0;
  dequant_lane_v1 q(.clk,.reset,.clear,.in_valid(qvalid),.psum,.ea,.eb,.fold,
    .out_valid(qout),.partial_value(qresult));
  fp32_add_lane_v1 adder(.clk,.reset,.clear,.in_valid(avalid),.add_old,
    .old_value(a),.partial_value(b),.out_valid(aout),.result_value(aresult));
  function automatic logic [31:0] random_bits;
    rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);return rng;
  endfunction
  function automatic logic [31:0] qref(input logic signed [31:0] x,input int va,vb,vfold);
    logic [31:0] mag;int lead;
    mag=x[31]?(~x+32'd1):x;lead=0;
    for(int i=0;i<32;i++)if(mag[i])lead=i;
    return fp32_legacy_ref_pkg::pack_scaled32(x[31],mag<<(31-lead),va+vb+vfold-266+lead,
      mag==0,va==255||vb==255);
  endfunction
  always @(posedge clk)begin
    int de;
    if(reset||clear)begin qv=0;av=0;end
    else begin
      qv={qv[0],qvalid};av={av[2:0],avalid};
      qexpect[1]=qexpect[0];qexpect[0]=qref(psum,int'(ea),int'(eb),int'($signed(fold)));
      for(int i=3;i>0;i--)aexpect[i]=aexpect[i-1];
      aexpect[0]=add_old?fp32_legacy_ref_pkg::fp32_add(a,b):b;
      if(avalid)begin
        de=(a[30:23]==0?1:int'(a[30:23]))-(b[30:23]==0?1:int'(b[30:23]));
        if(!add_old)bypass_count++;
        else if(a[31]!=b[31])begin
          if(de>=-1&&de<=1)close_count++;else far_sub_count++;
        end
      end
    end
    #1;
    if(qout!==qv[1]||aout!==av[3])$fatal(1,"V1 lane fixed latency mismatch");
    if(qout)begin
      if(qresult!==qexpect[1])$fatal(1,"V1 dequant mismatch got=%h expect=%h count=%0d",qresult,qexpect[1],qcount);
      qcount++;
    end
    if(aout)begin
      if(aresult!==aexpect[3])$fatal(1,"V1 FPADD mismatch got=%h expect=%h count=%0d",aresult,aexpect[3],acount);
      acount++;
    end
  end
  task automatic input_pair(input logic signed [31:0] x,input int va,vb,vfold,
    input logic [31:0] aa,bb,input bit use_old);
    @(negedge clk);psum=x;ea=8'(va);eb=8'(vb);fold=EXP_FOLD_BITS'(vfold);
    a=aa;b=bb;add_old=use_old;qvalid=1;avalid=1;
  endtask
  initial begin
    psum=0;ea=0;eb=0;fold=0;a=0;b=0;
    repeat(4)@(negedge clk);reset=0;
    input_pair(0,255,0,0,32'h7f800000,32'hff800000,1);
    input_pair(32'h80000000,133,133,0,32'h80000000,32'h80000000,1);
    input_pair(1,70,69,0,32'h3f800000,32'hbeffffff,1);
    input_pair(-1,58,58,0,32'h00000001,32'h80000001,1);
    input_pair(16777215,58,58,0,32'h007fffff,32'h00000001,1);
    input_pair(16777217,133,133,0,32'h4b800000,32'h3f800000,1);
    input_pair(0,0,0,0,32'h7fc12345,32'h80000000,0);
    input_pair(1,254,254,31,32'h7f7fffff,32'h7f7fffff,1);
    for(int i=0;i<65536;i++)begin
      logic [31:0] x,aa,bb;
      x=random_bits();aa=random_bits();bb=random_bits();
      case(i%8)
        0:begin bb={~aa[31],aa[30:0]};end
        1:begin bb[30:23]=aa[30:23];bb[31]=~aa[31];end
        2:begin bb[30:23]=aa[30:23]>1?aa[30:23]-1:8'd1;bb[31]=~aa[31];end
        3:begin bb[30:23]=aa[30:23]>2?aa[30:23]-2:8'd1;bb[31]=~aa[31];end
        4:begin aa[30:23]=0;bb[30:23]=0;end
        5:begin aa[30:23]=255;end
        default:begin end
      endcase
      input_pair(x,i/256,i%256,(i%64)-32,aa,bb,(i%11)!=0);
    end
    for(int lead=0;lead<32;lead++)for(int tail=0;tail<8;tail++)begin
      logic [31:0] x;
      x=(32'd1<<lead)|32'(tail);
      for(int base=-153;base<=129;base++)
        input_pair(tail[0]?-x:x,(base+266)/2,(base+266)-(base+266)/2,0,random_bits(),random_bits(),1);
    end
    @(negedge clk);qvalid=0;avalid=0;repeat(5)@(negedge clk);
    // Flush busy lanes and ensure old valids never emerge after clear.
    input_pair(1,133,133,0,32'h3f800000,32'h3f800000,1);
    @(negedge clk);clear=1;qvalid=0;avalid=0;
    @(negedge clk);clear=0;repeat(5)@(negedge clk);
    if(qcount!=8+65536+32*8*283||acount!=qcount||close_count==0||far_sub_count==0||bypass_count==0)
      $fatal(1,"V1 arithmetic coverage/count mismatch q=%0d a=%0d",qcount,acount);
    $display("tb_deqacc_v1_arithmetic PASS dequant=%0d fpadd=%0d q_latency=2 add_latency=4 II=1 close=%0d far_sub=%0d bypass=%0d",
      qcount,acount,close_count,far_sub_count,bypass_count);$finish;
  end
  initial begin #5000000;$fatal(1,"V1 arithmetic watchdog");end
endmodule
