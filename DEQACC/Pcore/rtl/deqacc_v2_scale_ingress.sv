import pcore_pkg::*;

// One ingress per physical cluster. Ea/fold feed two row-bias cones; each
// bias feeds only four local columns. No additional clock boundary is added.
module deqacc_v2_scale_ingress(
  input logic [1:0][SCALE_BITS-1:0] ea,
  input logic [3:0][SCALE_BITS-1:0] eb,
  input logic signed [EXP_FOLD_BITS-1:0] fold,
  output logic signed [1:0][11:0] row_bias,
  output logic signed [1:0][3:0][11:0] base,
  output logic [1:0][3:0] bad_scale
);
  for(genvar r=0;r<2;r++)begin: rows
    assign row_bias[r]=$signed({4'b0,ea[r]})+12'($signed(fold))-12'(DOT_EXP_OFFSET);
    for(genvar n=0;n<4;n++)begin: columns
      assign base[r][n]=$signed(row_bias[r])+$signed({4'b0,eb[n]});
      assign bad_scale[r][n]=(&ea[r])||(&eb[n]);
    end
  end
endmodule
