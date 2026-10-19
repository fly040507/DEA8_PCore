// Internal arithmetic types only; command and completion use upstream packages.
package dea8_vpu_math_pkg;
  typedef logic [1:0][15:0][31:0] pair_fp_t;
  typedef logic [1:0][31:0] scalars_t;
  typedef logic [1:0][15:0][7:0] pair_int8_t;
  function automatic logic nonfinite(input logic [31:0] x);
    return (&x[30:23]);
  endfunction
  // Exact integer round-to-nearest-even; fixed loop bounds are synthesizable.
  function automatic logic [63:0] rshift_rne(input logic [63:0] x,input integer shift);
    logic [63:0] q;logic guard_bit,sticky;
    q=0;guard_bit=0;sticky=0;
    if(shift<=0) return (-shift<64)?(x<<(-shift)):64'b0;
    if(shift>64)return 0;
    q=(shift==64)?64'b0:x>>shift;
    guard_bit=x[shift-1];
    sticky=|(x & ((shift<=1)?64'b0:(64'hffffffffffffffff>>(65-shift))));
    return q+64'(guard_bit&&(sticky||q[0]));
  endfunction

  // FP32 multiply, including gradual underflow and RNE. Prototype combinational
  // implementation; no exception CSR/status flags and no Fmax/area signoff.
  function automatic logic [31:0] mul_fp(input logic [31:0] a,b);
    logic sign_bit,a_nan,b_nan,a_inf,b_inf,a_zero,b_zero;
    logic [23:0] ma,mb;logic [47:0] prod;
    logic [63:0] rounded;integer ea,eb,base,lead,ex;
    sign_bit=a[31]^b[31];
    a_nan=nonfinite(a)&&(|a[22:0]);b_nan=nonfinite(b)&&(|b[22:0]);
    a_inf=a[30:0]==31'h7f800000;b_inf=b[30:0]==31'h7f800000;
    a_zero=a[30:0]==0;b_zero=b[30:0]==0;
    if(a_nan||b_nan||(a_inf&&b_zero)||(b_inf&&a_zero))return 32'h7fc00000;
    if(a_inf||b_inf)return {sign_bit,8'hff,23'b0};
    if(a_zero||b_zero)return {sign_bit,31'b0};
    ma={(|a[30:23]),a[22:0]};mb={(|b[30:23]),b[22:0]};
    ea=a[30:23]==0?-126:int'(a[30:23])-127;
    eb=b[30:23]==0?-126:int'(b[30:23])-127;
    prod=ma*mb;base=ea+eb-46;lead=0;
    for(int i=0;i<48;i++)if(prod[i])lead=i;
    ex=base+lead;
    if(ex < -126)begin
      rounded=rshift_rne({16'b0,prod},-(base+149));
      if(rounded>=64'h800000)return {sign_bit,8'h01,23'b0};
      return {sign_bit,8'b0,rounded[22:0]};
    end
    rounded=rshift_rne({16'b0,prod},lead-23);
    if(rounded[24])begin rounded=rounded>>1;ex=ex+1;end
    if(ex>127)return {sign_bit,8'hff,23'b0};
    return {sign_bit,8'(ex+127),rounded[22:0]};
  endfunction

  function automatic logic [31:0] sum16(input logic [15:0][31:0] x);
    logic [31:0] t[0:30];
    for(int j=0;j<16;j++)t[15+j]=x[j];
    for(int n=14;n>=0;n--)t[n]=dea8_fp32_v3_pkg::fp32_add(t[2*n+1],t[2*n+2]);
    return t[0];
  endfunction
endpackage
