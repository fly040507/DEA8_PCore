package gcore_fp_pkg;
  function automatic logic finite32(input logic [31:0] x);
    return x[30:23]!=8'hff;
  endfunction
  function automatic logic [15:0] round_bf16(input logic [31:0] x);
    logic [31:0] rounded;
    if(x[30:23]==8'hff && x[22:0]!=0) return x[31:16]|16'h0040;
    rounded=x+32'h00007fff+32'(x[16]);
    return rounded[31:16];
  endfunction

  typedef struct packed {
    logic sign_bit,special;
    logic [31:0] special_value;
    logic [47:0] product;
    logic signed [10:0] exponent_base;
  } multiply_raw_t;
  typedef struct packed {
    logic sign_bit,special;
    logic [31:0] special_value,normalized;
    logic signed [10:0] exponent;
  } multiply_norm_t;

  function automatic logic [$bits(multiply_raw_t)-1:0] multiply_prepare(input logic [31:0] a,b);
    multiply_raw_t r;
    logic [23:0] ma,mb;
    logic a_zero,b_zero,a_inf,b_inf,a_nan,b_nan;
    r='0;
    r.sign_bit=a[31]^b[31];
    ma={(|a[30:23]),a[22:0]}; mb={(|b[30:23]),b[22:0]};
    a_zero=a[30:0]==0; b_zero=b[30:0]==0;
    a_inf=a[30:0]==31'h7f800000; b_inf=b[30:0]==31'h7f800000;
    a_nan=!finite32(a)&&!a_inf; b_nan=!finite32(b)&&!b_inf;
    r.exponent_base=11'((a[30:23]==0?1:int'(a[30:23]))+
      (b[30:23]==0?1:int'(b[30:23]))-300);
    r.special=a_zero||b_zero||a_inf||b_inf||a_nan||b_nan;
    if(a_nan||b_nan||(a_zero&&b_inf)||(b_zero&&a_inf)) r.special_value=32'h7fc00000;
    else if(a_inf||b_inf) r.special_value={r.sign_bit,8'hff,23'b0};
    else r.special_value={r.sign_bit,31'b0};
    return r;
  endfunction
  function automatic logic [$bits(multiply_raw_t)-1:0] multiply_raw(input logic [31:0] a,b);
    multiply_raw_t r;
    logic [23:0] ma,mb;
    r=multiply_prepare(a,b);
    ma={(|a[30:23]),a[22:0]};mb={(|b[30:23]),b[22:0]};
    r.product=ma*mb;
    return r;
  endfunction
  function automatic logic [$bits(multiply_norm_t)-1:0] multiply_normalize(input multiply_raw_t r);
    multiply_norm_t n;
    logic [47:0] mask;
    int lead,distance;
    n='0; n.sign_bit=r.sign_bit; n.special=r.special; n.special_value=r.special_value;
    lead=(|r.product[47:32])?32+int'(dea8_fp32_pkg::lead32({16'b0,r.product[47:32]})):
      int'(dea8_fp32_pkg::lead32(r.product[31:0]));
    distance=lead-31;
    if(distance>0) begin
      n.normalized=32'(r.product>>distance);
      mask=48'hffffffffffff>>(48-distance);
      n.normalized[0]=n.normalized[0]||(|(r.product&mask));
    end else n.normalized=32'(r.product<<(-distance));
    n.exponent=r.exponent_base+11'(lead);
    return n;
  endfunction
  function automatic logic [31:0] multiply_pack(input multiply_norm_t n);
    if(n.special) return n.special_value;
    return dea8_fp32_pkg::pack_scaled32(n.sign_bit,n.normalized,n.exponent,0,0);
  endfunction
  function automatic logic [31:0] scale_power_two(input logic [31:0] x,input int power);
    logic [23:0] significand;
    logic [31:0] normalized;
    int lead,exponent;
    if(!finite32(x)||x[30:0]==0) return x;
    significand={(|x[30:23]),x[22:0]};
    lead=int'(dea8_fp32_pkg::lead32({8'b0,significand}));
    normalized={8'b0,significand}<<(31-lead);
    exponent=(x[30:23]==0?1:int'(x[30:23]))-150+lead+power;
    return dea8_fp32_pkg::pack_scaled32(x[31],normalized,11'(exponent),0,0);
  endfunction

  function automatic logic [7:0] quant_lane(input logic [31:0] x,input logic [7:0] scale);
    logic [23:0] significand;
    logic [31:0] kept,mask;
    logic guard_bit,sticky_bit;
    int distance,magnitude,signed_value;
    significand={(|x[30:23]),x[22:0]};
    distance=int'(scale)+17-(x[30:23]==0?1:int'(x[30:23]));
    kept=0; guard_bit=0; sticky_bit=0; mask=0;
    if(distance<=0) kept={8'b0,significand}<<(-distance);
    else if(distance<=24) begin
      kept={8'b0,significand}>>distance;
      guard_bit=significand[distance-1];
      mask=32'hffffffff>>(33-distance);
      sticky_bit=|({8'b0,significand}&mask);
    end
    magnitude=int'(kept)+int'(guard_bit&&(sticky_bit||kept[0]));
    signed_value=x[31]?-magnitude:magnitude;
    if(signed_value>127) signed_value=127;
    if(signed_value< -128) signed_value=-128;
    return 8'(signed_value);
  endfunction
  function automatic logic [30:0] max4(input logic [3:0][30:0] values);
    logic [30:0] left,right;
    left=values[0]>values[1]?values[0]:values[1];
    right=values[2]>values[3]?values[2]:values[3];
    return left>right?left:right;
  endfunction
  function automatic logic [7:0] quant_scale(input logic [30:0] maximum);
    logic [7:0] scale;
    if(maximum[30:23]==0) return (maximum[22:0]>23'h7f0000)?8'd1:8'd0;
    scale=maximum[30:23];
    if(maximum[22:0]>23'h7e0000 && scale<254) scale=scale+1'b1;
    return scale;
  endfunction
  // The high bit reports NaN/Inf. Low 136 bits use RAM order {E,data}.
  function automatic logic [136:0] quantize16(input logic [15:0][31:0] values);
    logic [30:0] maximum;
    logic [7:0] scale;
    logic [127:0] data;
    logic bad;
    maximum=0; bad=0;
    for(int i=0;i<16;i++) begin
      if(!finite32(values[i])) bad=1;
      if(values[i][30:0]>maximum) maximum=values[i][30:0];
    end
    scale=quant_scale(maximum);
    if(bad) begin scale=0; data=0; end
    else for(int i=0;i<16;i++) data[8*i+:8]=quant_lane(values[i],scale);
    return {bad,scale,data};
  endfunction
endpackage
