import pcore_pkg::*;
import dea8_fp32_pkg::*;

// V2 Q path.
// Q0 captures magnitude, leading position and the local scale base. Q1 uses
// fixed-width barrel/jam stages and a fixed RNE rule. There is no integer or
// data-dependent loop in the datapath.
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
  logic [32:0] rounded_shift;
  logic [32:0] rounded_normal;
  logic signed [11:0] exponent;
  logic signed [11:0] shift_distance;
  logic signed [11:0] exponent_work;
  logic [31:0] magnitude;
  logic [31:0] next_value;

  function automatic logic [31:0] abs32(input logic signed [31:0] value);
    return value[31]?(~value+32'd1):value;
  endfunction

  function automatic logic [32:0] left_fixed(input logic [32:0] value,input logic [5:0] amount);
    logic [32:0] x0,x1,x2,x3,x4,x5;
    begin
      x0=value;
      x1=amount[0]?(x0<<1):x0;
      x2=amount[1]?(x1<<2):x1;
      x3=amount[2]?(x2<<4):x2;
      x4=amount[3]?(x3<<8):x3;
      x5=amount[4]?(x4<<16):x4;
      if(amount[5]) left_fixed=(amount==6'd32)?(value<<32):33'b0;
      else left_fixed=x5;
    end
  endfunction

  function automatic logic [32:0] right_fixed(input logic [32:0] value,input logic [5:0] amount);
    logic [32:0] x0,x1,x2,x3,x4,x5;
    begin
      x0=value;
      x1=amount[0]?(x0>>1):x0;
      x2=amount[1]?(x1>>2):x1;
      x3=amount[2]?(x2>>4):x2;
      x4=amount[3]?(x3>>8):x3;
      x5=amount[4]?(x4>>16):x4;
      if(amount[5]) right_fixed=33'b0;
      else right_fixed=x5;
    end
  endfunction

  function automatic logic sticky_below(input logic [31:0] value,input logic [5:0] distance);
    begin
      case(distance)
        6'd0,6'd1: sticky_below=1'b0;
        6'd2: sticky_below=|value[0:0];
        6'd3: sticky_below=|value[1:0];
        6'd4: sticky_below=|value[2:0];
        6'd5: sticky_below=|value[3:0];
        6'd6: sticky_below=|value[4:0];
        6'd7: sticky_below=|value[5:0];
        6'd8: sticky_below=|value[6:0];
        6'd9: sticky_below=|value[7:0];
        6'd10: sticky_below=|value[8:0];
        6'd11: sticky_below=|value[9:0];
        6'd12: sticky_below=|value[10:0];
        6'd13: sticky_below=|value[11:0];
        6'd14: sticky_below=|value[12:0];
        6'd15: sticky_below=|value[13:0];
        6'd16: sticky_below=|value[14:0];
        6'd17: sticky_below=|value[15:0];
        6'd18: sticky_below=|value[16:0];
        6'd19: sticky_below=|value[17:0];
        6'd20: sticky_below=|value[18:0];
        6'd21: sticky_below=|value[19:0];
        6'd22: sticky_below=|value[20:0];
        6'd23: sticky_below=|value[21:0];
        6'd24: sticky_below=|value[22:0];
        6'd25: sticky_below=|value[23:0];
        6'd26: sticky_below=|value[24:0];
        6'd27: sticky_below=|value[25:0];
        6'd28: sticky_below=|value[26:0];
        6'd29: sticky_below=|value[27:0];
        6'd30: sticky_below=|value[28:0];
        6'd31: sticky_below=|value[29:0];
        6'd32: sticky_below=|value[30:0];
        default: sticky_below=|value;
      endcase
    end
  endfunction

  function automatic logic guard_at(input logic [31:0] value,input logic [5:0] distance);
    begin
      case(distance)
        6'd1: guard_at=value[0];
        6'd2: guard_at=value[1];
        6'd3: guard_at=value[2];
        6'd4: guard_at=value[3];
        6'd5: guard_at=value[4];
        6'd6: guard_at=value[5];
        6'd7: guard_at=value[6];
        6'd8: guard_at=value[7];
        6'd9: guard_at=value[8];
        6'd10: guard_at=value[9];
        6'd11: guard_at=value[10];
        6'd12: guard_at=value[11];
        6'd13: guard_at=value[12];
        6'd14: guard_at=value[13];
        6'd15: guard_at=value[14];
        6'd16: guard_at=value[15];
        6'd17: guard_at=value[16];
        6'd18: guard_at=value[17];
        6'd19: guard_at=value[18];
        6'd20: guard_at=value[19];
        6'd21: guard_at=value[20];
        6'd22: guard_at=value[21];
        6'd23: guard_at=value[22];
        6'd24: guard_at=value[23];
        6'd25: guard_at=value[24];
        6'd26: guard_at=value[25];
        6'd27: guard_at=value[26];
        6'd28: guard_at=value[27];
        6'd29: guard_at=value[28];
        6'd30: guard_at=value[29];
        6'd31: guard_at=value[30];
        6'd32: guard_at=value[31];
        default: guard_at=1'b0;
      endcase
    end
  endfunction

  function automatic logic [32:0] rne_fixed(input logic [31:0] value,input logic signed [11:0] distance);
    logic [5:0] shift;
    logic [32:0] kept;
    logic guard_bit,sticky;
    begin
      if(distance<=0) begin
        shift=6'(-distance);
        rne_fixed=left_fixed({1'b0,value},shift);
      end else if(distance>=33) begin
        rne_fixed=33'b0;
      end else begin
        shift=6'(distance);
        kept=right_fixed({1'b0,value},shift);
        guard_bit=guard_at(value,shift);
        sticky=sticky_below(value,shift);
        rne_fixed=kept+33'(guard_bit&&(sticky||kept[0]));
      end
    end
  endfunction

  always_comb begin
    magnitude=abs32(psum);
    exponent=$signed(base_q)+$signed({7'b0,lead_q});
    shift_distance=(exponent<-126)?-($signed(base_q)+12'sd149):
      $signed({7'b0,lead_q})-12'sd23;
    rounded_shift=rne_fixed(mag_q,shift_distance);
    exponent_work=exponent;
    rounded_normal=rounded_shift;
    if(exponent>=-126 && rounded_shift[24]) begin
      rounded_normal=right_fixed(rounded_shift,6'd1);
      exponent_work=exponent+12'sd1;
    end
    next_value=0;
    if(bad_q) next_value=FP_QNAN;
    else if(zero_q) next_value=0;
    else if(exponent<-126) next_value={sign_q,7'b0,rounded_shift[23:0]};
    else begin
      next_value=exponent_work>127?{sign_q,FP_INF[30:0]}:
        {sign_q,8'(exponent_work+127),rounded_normal[22:0]};
    end
  end

  always_ff @(posedge clk) begin
    mag_q<=magnitude;
    lead_q<=lead32(magnitude);
    sign_q<=psum[31];
    zero_q<=magnitude==0;
    bad_q<=(&ea)||(&eb);
    base_q<=$signed({4'b0,ea})+$signed({4'b0,eb})+$signed(fold)-12'sd266;
    partial_value<=next_value;
    if(reset||clear) begin
      valid_q<=0;
      out_valid<=0;
    end else begin
      valid_q<=in_valid;
      out_valid<=valid_q;
    end
  end
endmodule
