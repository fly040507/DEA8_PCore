// Five-stage elastic MXINT8-B16 quantizer, II=1. Same floor/RNE semantics
// as dea8_vpu_quant16. All stages stall together when the output is held.
module dea8_vpu_quant16_pipe(
 input logic clk,reset,clear,in_valid,output logic in_ready,
 input logic [15:0][31:0] x,input logic [15:0] lane_valid,
 output logic out_valid,input logic out_ready,
 output logic [15:0][7:0] q,output logic [7:0] scale,output logic error);
 import dea8_vpu_math_pkg::*;
 logic [4:0] v;
 wire advance=!v[4]||out_ready;
 assign in_ready=advance&&!reset&&!clear;
 assign out_valid=v[4]&&!reset&&!clear;
 // Preserve only the information used after exponent reduction: sign,
 // exponent, top significand bits and sticky. No rounding occurs here.
 logic [15:0][18:0] x0,x1,x2;
 logic [15:0] mask0,mask1,mask2,mask3,sign3;
 logic [3:0][7:0] groups_d,groups1;
 logic [7:0] exponent_d,exponent2,exponent3;
 logic bad_d,bad1,bad2,bad3;
 // One 8-bit magnitude plus guard and sticky per lane, not nine rounded alternatives.
 logic [15:0][9:0] significand3;
 function automatic logic [9:0] quant_shift_jam(input logic [9:0] value,input logic [3:0] distance);
  logic [9:0] s8,s4,s2,s1;
  s8=distance[3]?{8'b0,value[9],|value[8:0]}:value;
  s4=distance[2]?{4'b0,s8[9:5],|s8[4:0]}:s8;
  s2=distance[1]?{2'b0,s4[9:3],|s4[2:0]}:s4;
  s1=distance[0]?{1'b0,s2[9:2],|s2[1:0]}:s2;
  return s1;
 endfunction
 function automatic logic [7:0] max8(input logic [7:0] a,b);return a>b?a:b;endfunction
 always_comb begin
  groups_d='0;bad_d=0;
  for(int g=0;g<4;g++)begin
   logic [3:0][7:0] leaf;
   for(int k=0;k<4;k++)begin
    leaf[k]=(mask0[4*g+k]&&!(&x0[4*g+k][17:10]))?x0[4*g+k][17:10]:8'b0;
    bad_d|=mask0[4*g+k]&&(&x0[4*g+k][17:10]);
   end
   groups_d[g]=max8(max8(leaf[0],leaf[1]),max8(leaf[2],leaf[3]));
  end
  exponent_d=max8(max8(groups1[0],groups1[1]),max8(groups1[2],groups1[3]));
 end
 logic [15:0][7:0] rounded_q;
 always_comb begin
  rounded_q='0;
  for(int j=0;j<16;j++)begin
   logic [7:0] rounded,magnitude;
   rounded=significand3[j][9:2]+8'(significand3[j][1]&&(significand3[j][0]||significand3[j][2]));
   magnitude=rounded[7]?8'd127:rounded;
   rounded_q[j]=(!mask3[j]||bad3)?0:(sign3[j]?(8'b0-magnitude):magnitude);
  end
 end
 always_ff @(posedge clk)begin
  if(reset||clear)v<=0;
  else if(advance)v<={v[3:0],in_valid};
  if(advance)begin
   if(in_valid)begin
    for(int j=0;j<16;j++)x0[j]<={x[j][31],x[j][30:23],(|x[j][30:23]),x[j][22:15],(|x[j][14:0])};
    mask0<=lane_valid;
   end
   if(v[0])begin x1<=x0;mask1<=mask0;groups1<=groups_d;bad1<=bad_d;end
   if(v[1])begin x2<=x1;mask2<=mask1;exponent2<=exponent_d;bad2<=bad1;end
   if(v[2])begin
    mask3<=mask2;exponent3<=exponent2;bad3<=bad2;
    for(int j=0;j<16;j++)begin
     logic [8:0] distance;
     sign3[j]<=x2[j][18];
     distance={1'b0,exponent2}-{1'b0,x2[j][17:10]}+((x2[j][17:10]==0)?9'd16:9'd17);
     // Values outside the original 16..24 choice range retain an exact zero result.
     significand3[j]<=(distance>=16&&distance<=24)?
      quant_shift_jam(x2[j][9:0],4'(distance-16)):10'b0;
    end
   end
   if(v[3])begin q<=rounded_q;scale<=bad3?0:exponent3;error<=bad3;end
  end
 end
 // synthesis translate_off
 ap_hold:assert property(@(posedge clk) disable iff(reset||clear)
  out_valid&&!out_ready |=> out_valid&&$stable({q,scale,error}));
 // synthesis translate_on
endmodule
