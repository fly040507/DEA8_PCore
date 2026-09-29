package dea8_fp32_v3_pkg;
  localparam logic [31:0] FP_QNAN=32'h7fc00000;
  localparam logic [31:0] FP_INF=32'h7f800000;

  // Binary priority tree: zero returns 0, otherwise index of the leading one.
  function automatic logic [4:0] lead32(input logic [31:0] x);
    logic hi16,hi8,hi4,hi2;
    logic [15:0] s16;logic [7:0] s8;logic [3:0] s4;logic [1:0] s2;
    hi16=|x[31:16];s16=hi16?x[31:16]:x[15:0];
    hi8=|s16[15:8];s8=hi8?s16[15:8]:s16[7:0];
    hi4=|s8[7:4];s4=hi4?s8[7:4]:s8[3:0];
    hi2=|s4[3:2];s2=hi2?s4[3:2]:s4[1:0];
    return {hi16,hi8,hi4,hi2,s2[1]};
  endfunction

  function automatic logic [32:0] round_right32(input logic [31:0] value,input logic signed [11:0] shift);
    logic [32:0] kept,rounded;
    logic [31:0] mask;
    logic guard_bit,sticky_bit;
    logic [11:0] left_distance;
    left_distance=-shift;
    kept=(shift<=0)?((left_distance<33)?({1'b0,value}<<left_distance[5:0]):33'b0):
      ((shift<33)?({1'b0,value}>>shift[5:0]):33'b0);
    mask=(shift>32)?32'hffffffff:((shift>1)?(32'hffffffff>>(33-shift)):32'b0);
    guard_bit=(shift>0&&shift<=32)?value[$unsigned(5'(shift-1))]:1'b0;
    sticky_bit=|(value&mask);
    rounded=kept+33'(guard_bit&&(sticky_bit||kept[0]));
    return (shift<=0)?kept:rounded;
  endfunction

  function automatic logic [31:0] pack_scaled32(
    input logic sign_bit,input logic [31:0] normalized,input logic signed [10:0] unbiased,
    input logic is_zero,input logic bad_scale);
    logic [32:0] rounded,adjusted,subrounded;
    logic signed [11:0] exp_adjusted,subshift;
    logic [7:0] exp_field;
    rounded={9'b0,normalized[31:8]}+33'(normalized[7]&&((|normalized[6:0])||normalized[8]));
    adjusted=rounded[24]?(rounded>>1):rounded;
    exp_adjusted=$signed({unbiased[10],unbiased})+$signed({11'b0,rounded[24]});
    subshift=-$signed(unbiased)-12'sd118;
    subrounded=round_right32(normalized,subshift);
    exp_field=8'(exp_adjusted+12'sd127);
    if(bad_scale) return FP_QNAN;
    if(is_zero) return 32'b0;
    if(unbiased < -11'sd126) return {sign_bit,7'b0,subrounded[23:0]};
    if(exp_adjusted>127) return {sign_bit,FP_INF[30:0]};
    return {sign_bit,exp_field,adjusted[22:0]};
  endfunction

  function automatic logic [27:0] shift_right_jam28(input logic [27:0] value,input logic [7:0] distance);
    logic [27:0] s16,s8,s4,s2,s1;
    s16=distance[4]?{16'b0,value[27:17],|value[16:0]}:value;
    s8=distance[3]?{8'b0,s16[27:9],|s16[8:0]}:s16;
    s4=distance[2]?{4'b0,s8[27:5],|s8[4:0]}:s8;
    s2=distance[1]?{2'b0,s4[27:3],|s4[2:0]}:s4;
    s1=distance[0]?{1'b0,s2[27:2],|s2[1:0]}:s2;
    return (|distance[7:5])?{27'b0,|value}:s1;
  endfunction

  typedef struct packed {
    logic special;
    logic [31:0] special_value;
    logic sign_result,zero_sign,subtract;
    logic [8:0] exponent;
    logic [27:0] big_x,small_x;
  } fp_add_pre_t;

  function automatic fp_add_pre_t fp32_prepare(input logic [31:0] a,b);
    fp_add_pre_t p;
    logic [7:0] ea,eb,big_e,small_e,diff;
    logic [23:0] ma,mb,big_m,small_m;
    logic a_big,a_nan,b_nan,a_inf,b_inf;
    ea=(a[30:23]==0)?8'd1:a[30:23];eb=(b[30:23]==0)?8'd1:b[30:23];
    ma={(|a[30:23]),a[22:0]};mb={(|b[30:23]),b[22:0]};
    a_big=(ea>eb)||((ea==eb)&&(ma>=mb));
    big_e=a_big?ea:eb;small_e=a_big?eb:ea;diff=big_e-small_e;
    big_m=a_big?ma:mb;small_m=a_big?mb:ma;
    a_nan=(&a[30:23])&&(|a[22:0]);b_nan=(&b[30:23])&&(|b[22:0]);
    a_inf=a[30:0]==FP_INF[30:0];b_inf=b[30:0]==FP_INF[30:0];
    p.special=a_nan||b_nan||a_inf||b_inf;
    p.special_value=(a_nan||b_nan||(a_inf&&b_inf&&(a[31]!=b[31])))?FP_QNAN:(a_inf?a:b);
    p.sign_result=a_big?a[31]:b[31];p.zero_sign=a[31]&&b[31];p.subtract=a[31]^b[31];
    p.exponent={1'b0,big_e};p.big_x={1'b0,big_m,3'b0};
    p.small_x=shift_right_jam28({1'b0,small_m,3'b0},diff);
    return p;
  endfunction

  function automatic logic [31:0] fp32_normalize(input fp_add_pre_t p,input logic [27:0] sum_raw);
    logic [27:0] sum_norm;
    logic [4:0] norm_shift,wanted_shift;
    logic z16,z8,z4,z2;
    logic [31:0] l0,l16,l8,l4,l2,l1;
    logic [27:0] normal_left,subnormal_left;
    logic [8:0] exponent_norm,exponent_final;
    logic [24:0] round_raw,round_final;
    logic [7:0] exp_field;
    l0={sum_raw[26:0],5'b0};
    z16=!(|l0[31:16]);l16=z16?{l0[15:0],16'b0}:l0;
    z8=!(|l16[31:24]);l8=z8?{l16[23:0],8'b0}:l16;
    z4=!(|l8[31:28]);l4=z4?{l8[27:0],4'b0}:l8;
    z2=!(|l4[31:30]);l2=z2?{l4[29:0],2'b0}:l4;
    l1=l2[31]?l2:{l2[30:0],1'b0};
    wanted_shift={z16,z8,z4,z2,!l2[31]};
    norm_shift=({4'b0,wanted_shift}>(p.exponent-9'd1))?5'(p.exponent-9'd1):wanted_shift;
    normal_left={1'b0,l1[31:5]};
    subnormal_left=sum_raw<<5'(p.exponent-9'd1);
    sum_norm=sum_raw[27]?{1'b0,sum_raw[27:2],sum_raw[1]|sum_raw[0]}:
      (({4'b0,wanted_shift}>(p.exponent-9'd1))?subnormal_left:normal_left);
    exponent_norm=sum_raw[27]?(p.exponent+9'd1):(p.exponent-{4'b0,norm_shift});
    round_raw={1'b0,sum_norm[26:3]}+25'(sum_norm[2]&&(sum_norm[1]||sum_norm[0]||sum_norm[3]));
    round_final=round_raw[24]?(round_raw>>1):round_raw;
    exponent_final=exponent_norm+9'(round_raw[24]);
    exp_field=(exponent_final==1&&!round_final[23])?8'b0:exponent_final[7:0];
    if(p.special) return p.special_value;
    if(sum_raw==0) return {p.zero_sign,31'b0};
    if(exponent_final>=255) return {p.sign_result,FP_INF[30:0]};
    return {p.sign_result,exp_field,round_final[22:0]};
  endfunction

  function automatic logic [31:0] fp32_add(input logic [31:0] a,b);
    fp_add_pre_t p;
    p=fp32_prepare(a,b);
    return fp32_normalize(p,p.subtract?(p.big_x-p.small_x):(p.big_x+p.small_x));
  endfunction
  function automatic logic [31:0] fp32_finish(input fp_add_pre_t p);
    return fp32_normalize(p,p.subtract?(p.big_x-p.small_x):(p.big_x+p.small_x));
  endfunction
endpackage
