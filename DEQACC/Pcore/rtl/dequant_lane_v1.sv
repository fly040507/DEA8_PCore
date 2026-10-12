import pcore_pkg::*;
import dea8_fp32_pkg::*;

// Q0: magnitude/lead/base. Q1: one direct RNE conversion, including denormals.
module dequant_lane_v1(
  input logic clk,reset,clear,in_valid,
  input logic signed [31:0] psum,
  input logic [7:0] ea,eb,
  input logic signed [EXP_FOLD_BITS-1:0] fold,
  output logic out_valid,
  output logic [31:0] partial_value
);
  logic valid_q,sign_q,zero_q,bad_q;
  logic [31:0] mag_q;
  logic [4:0] lead_q;
  logic signed [11:0] base_q;
  logic [31:0] magnitude,next_value;
  logic [32:0] rounded;
  integer exponent,shift_distance;
  function automatic logic [32:0] rne(input logic [31:0] value,input integer distance);
    logic [32:0] kept;
    logic guard_bit,sticky;
    kept=0;guard_bit=0;sticky=0;
    if(distance<=0)kept={1'b0,value}<<(-distance);
    else begin
      if(distance<=32)kept={1'b0,value}>>distance;
      for(int i=0;i<32;i++)begin
        if(i==distance-1)guard_bit=value[i];
        if(i<distance-1)sticky|=value[i];
      end
      kept=kept+33'(guard_bit&&(sticky||kept[0]));
    end
    return kept;
  endfunction
  always_comb begin
    magnitude=psum[31]?(~psum+32'd1):psum;
    exponent=int'($signed(base_q))+int'(lead_q);
    shift_distance=exponent<-126?-(int'($signed(base_q))+149):int'(lead_q)-23;
    rounded=rne(mag_q,shift_distance);
    next_value=0;
    if(bad_q)next_value=FP_QNAN;
    else if(zero_q)next_value=0;
    else if(exponent<-126)next_value={sign_q,7'b0,rounded[23:0]};
    else begin
      if(rounded[24])begin rounded=rounded>>1;exponent++;end
      next_value=exponent>127?{sign_q,FP_INF[30:0]}:
        {sign_q,8'(exponent+127),rounded[22:0]};
    end
  end
  always_ff @(posedge clk)begin
    mag_q<=magnitude;lead_q<=lead32(magnitude);
    sign_q<=psum[31];zero_q<=magnitude==0;bad_q<=(&ea)||(&eb);
    base_q<=$signed({4'b0,ea})+$signed({4'b0,eb})+$signed(fold)-12'sd266;
    partial_value<=next_value;
    if(reset||clear)begin valid_q<=0;out_valid<=0;end
    else begin valid_q<=in_valid;out_valid<=valid_q;end
  end
endmodule
