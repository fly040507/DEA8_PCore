// Simulation-only arithmetic for unfinished VPU/SFU clients. Not in RTL .f.
package dea8_behavioral_fp_pkg;
  function automatic real fp_real(input logic [31:0] bits);
    real value;
    if(bits[30:23]==255) begin
      if(bits[22:0]!=0) $fatal(1,"NaN in behavioral client");
      return bits[31] ? -1.0e300 : 1.0e300;
    end
    value=real'(bits[22:0]) / 8388608.0;
    if(bits[30:23]!=0) value+=1.0;
    value*=2.0**(bits[30:23]==0 ? -126 : int'(bits[30:23])-127);
    return bits[31] ? -value : value;
  endfunction
  function automatic int round_even(input real x);
    int base_value;
    real fraction;
    base_value=int'($floor(x)); fraction=x-base_value;
    return base_value+((fraction>0.5 || (fraction==0.5 && (base_value%2)!=0)) ? 1:0);
  endfunction
  function automatic logic [31:0] real_fp(input real x);
    bit sign_bit;
    real magnitude,scaled;
    int exponent_value,mantissa;
    if(x==0.0) return 0;
    sign_bit=x<0; magnitude=sign_bit ? -x:x;
    if(magnitude>3.4028235678e38) return {sign_bit,8'hff,23'b0};
    if(magnitude<2.0**(-126)) begin
      mantissa=round_even(magnitude/(2.0**(-149)));
      return {sign_bit,31'(mantissa)};
    end
    exponent_value=0; scaled=magnitude;
    while(scaled>=2.0) begin scaled/=2.0; exponent_value++; end
    while(scaled<1.0) begin scaled*=2.0; exponent_value--; end
    mantissa=round_even(scaled*8388608.0);
    if(mantissa==16777216) begin mantissa=8388608; exponent_value++; end
    return {sign_bit,8'(exponent_value+127),23'(mantissa-8388608)};
  endfunction
  function automatic logic [31:0] sim_add(input logic [31:0] a,b);
    return real_fp(fp_real(a)+fp_real(b));
  endfunction
  function automatic logic [31:0] sim_mul(input logic [31:0] a,b);
    return real_fp(fp_real(a)*fp_real(b));
  endfunction
  function automatic logic [31:0] sim_exp(input logic [31:0] a);
    if(a==32'hff800000) return 0;
    return real_fp($exp(fp_real(a)));
  endfunction
endpackage
