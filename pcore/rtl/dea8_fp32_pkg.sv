package dea8_fp32_pkg;
  // Binary32 RNE, gradual underflow, canonical NaN. Combinational datapaths.
  localparam logic [31:0] FP_QNAN = 32'h7fc00000;
  localparam logic [31:0] FP_INF  = 32'h7f800000;

  function automatic logic [32:0] round_right32(input logic [31:0] value, input integer shift);
    logic [32:0] kept;
    logic guard_bit, sticky_bit;
    kept = '0; guard_bit = 0; sticky_bit = 0;
    if (shift <= 0) kept = {1'b0, value} << (-shift);
    else begin
      if (shift < 33) kept = {1'b0, value} >> shift;
      for (int i = 0; i < 32; i++) begin
        if (i == shift - 1) guard_bit = value[i];
        if (i < shift - 1) sticky_bit |= value[i];
      end
      kept = kept + (guard_bit && (sticky_bit || kept[0]));
    end
    return kept;
  endfunction

  function automatic logic [31:0] pack_scaled32(
    input logic sign_bit, input logic [31:0] normalized,
    input integer unbiased, input logic is_zero, bad_scale
  );
    logic [32:0] rounded;
    logic [7:0] exponent_field;
    integer exponent_value;
    if (bad_scale) return FP_QNAN;
    if (is_zero) return 32'b0;
    exponent_value = unbiased;
    if (exponent_value < -126) begin
      rounded = round_right32(normalized, -exponent_value - 118);
      return {sign_bit, 7'b0, rounded[23:0]};
    end
    rounded = round_right32(normalized, 8);
    if (rounded[24]) begin rounded = rounded >> 1; exponent_value++; end
    if (exponent_value > 127) return {sign_bit, FP_INF[30:0]};
    exponent_field = 8'(exponent_value + 127);
    return {sign_bit, exponent_field, rounded[22:0]};
  endfunction

  function automatic logic [27:0] shift_right_jam28(input logic [27:0] value, input integer distance);
    logic [27:0] shifted;
    logic sticky_bit;
    shifted = distance >= 28 ? 28'b0 : value >> distance;
    sticky_bit = 0;
    for (int i = 0; i < 28; i++) if (i < distance) sticky_bit |= value[i];
    shifted[0] |= sticky_bit;
    return shifted;
  endfunction

  function automatic logic [31:0] fp32_add(input logic [31:0] a, b);
    logic [23:0] ma, mb, big_m, small_m;
    logic [27:0] big_x, small_x, sum_x;
    logic [24:0] rounded;
    logic sign_result, a_nan, b_nan, a_inf, b_inf;
    logic [7:0] exponent_field;
    integer ea, eb, big_e, small_e, result_e, top_bit, normalize_shift;
    a_nan = (&a[30:23]) && (|a[22:0]);
    b_nan = (&b[30:23]) && (|b[22:0]);
    a_inf = a[30:0] == FP_INF[30:0];
    b_inf = b[30:0] == FP_INF[30:0];
    if (a_nan || b_nan) return FP_QNAN;
    if (a_inf && b_inf && (a[31] != b[31])) return FP_QNAN;
    if (a_inf) return a;
    if (b_inf) return b;
    ea = a[30:23] == 0 ? 1 : int'(a[30:23]);
    eb = b[30:23] == 0 ? 1 : int'(b[30:23]);
    ma = {(|a[30:23]), a[22:0]}; mb = {(|b[30:23]), b[22:0]};
    if ((ea > eb) || ((ea == eb) && (ma >= mb))) begin
      big_e = ea; small_e = eb; big_m = ma; small_m = mb; sign_result = a[31];
    end else begin
      big_e = eb; small_e = ea; big_m = mb; small_m = ma; sign_result = b[31];
    end
    big_x = {1'b0, big_m, 3'b0};
    small_x = shift_right_jam28({1'b0, small_m, 3'b0}, big_e - small_e);
    result_e = big_e;
    sum_x = a[31] == b[31] ? big_x + small_x : big_x - small_x;
    if (sum_x == 0) return {(a[31] && b[31]), 31'b0};
    if (sum_x[27]) begin sum_x = shift_right_jam28(sum_x, 1); result_e++; end
    else begin
      // One leading-bit encoder and one barrel shift, not 26 chained shifters.
      top_bit = 0;
      for (int i = 0; i < 27; i++) if (sum_x[i]) top_bit = i;
      normalize_shift = 26 - top_bit;
      if (normalize_shift > result_e - 1) normalize_shift = result_e - 1;
      sum_x = sum_x << normalize_shift;
      result_e -= normalize_shift;
    end
    rounded = {1'b0, sum_x[26:3]} + (sum_x[2] && (sum_x[1] || sum_x[0] || sum_x[3]));
    if (rounded[24]) begin rounded = rounded >> 1; result_e++; end
    if (result_e >= 255) return {sign_result, FP_INF[30:0]};
    exponent_field = ((result_e == 1) && !rounded[23]) ? 8'b0 : 8'(result_e);
    return {sign_result, exponent_field, rounded[22:0]};
  endfunction
endpackage
