// S02 §4.4 floor-type MXINT8-B16: E=amax exponent; q=RNE(x*2^(133-E)).
// Symmetric saturation [-127,127]. All-zero group E=0. Invalid lanes -> q=0.
// NaN/Inf on an enabled lane raises error; do NOT commit that group.
module dea8_vpu_quant16(
  input logic [15:0][31:0] x,
  input logic [15:0] lane_valid,
  output logic [15:0][7:0] q,
  output logic [7:0] scale,
  output logic error
);
  import dea8_vpu_math_pkg::*;
  // E=max(raw exponent). For enabled finite lanes, distance is always >=16.
  wire [7:0] tree[31];
  wire [15:0] bad;
  wire [7:0] group_exponent=tree[0];
  for(genvar j=0;j<16;j++)begin: leaves
    assign bad[j]=lane_valid[j]&&nonfinite(x[j]);
    assign tree[15+j]=(lane_valid[j]&&!nonfinite(x[j]))?x[j][30:23]:8'b0;
  end
  for(genvar n=0;n<15;n++)begin: reduction
    assign tree[n]=(tree[2*n+1]>tree[2*n+2])?tree[2*n+1]:tree[2*n+2];
  end
  assign error=|bad;
  assign scale=error?8'b0:group_exponent;
  for(genvar j=0;j<16;j++)begin: lanes
    wire [23:0] mant={(|x[j][30:23]),x[j][22:0]};
    wire [8:0] distance={1'b0,group_exponent}-{1'b0,x[j][30:23]}+
                           ((x[j][30:23]==0)?9'd16:9'd17);
    // Compute all observable RNE results before exponent-distance selection.
    // Valid finite lanes have distance>=16; distance>24 always rounds to zero.
    wire [7:0] choice[9];
    for(genvar k=0;k<9;k++)begin: rounding_choices
      localparam int D=16+k;
      wire [7:0] kept=8'(mant>>D);
      wire increment=mant[D-1]&&((|mant[D-2:0])||kept[0]);
      assign choice[k]=kept+8'(increment);
    end
    logic [7:0] rounded;
    always_comb begin
      case(distance)
        16:rounded=choice[0];17:rounded=choice[1];18:rounded=choice[2];
        19:rounded=choice[3];20:rounded=choice[4];21:rounded=choice[5];
        22:rounded=choice[6];23:rounded=choice[7];24:rounded=choice[8];
        default:rounded=0;
      endcase
    end
    wire [7:0] magnitude=rounded[7]?8'd127:rounded;
    assign q[j]=(!lane_valid[j]||error)?8'b0:(x[j][31]?(8'b0-magnitude):magnitude);
  end
endmodule
