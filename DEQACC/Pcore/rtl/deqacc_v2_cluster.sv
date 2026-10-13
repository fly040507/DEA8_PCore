import pcore_pkg::*;

// Physical locality only: no key pipeline, RAW comparator, bank owner or ACC.
// Two rows x four columns share one local scale ingress and feedback bundle.
(* keep_hierarchy="soft" *)
module deqacc_v2_cluster(
  input logic clk,reset,clear,q0_valid,a0_valid,a3_stage_valid,add_old,
  input logic signed [1:0][3:0][31:0] psum,
  input logic [1:0][7:0] ea,
  input logic [3:0][7:0] eb,
  input logic signed [EXP_FOLD_BITS-1:0] fold,
  input logic [1:0] use_a3,use_c,
  input logic [1:0][3:0][31:0] acc_old_data,
  output logic [1:0][3:0][31:0] commit_data,
  output logic [1:0][3:0][31:0] a3_values
);
  logic signed [1:0][11:0] row_bias;
  logic signed [1:0][3:0][11:0] base;
  logic [1:0][3:0] bad_scale,partial_valid,a3_valid;
  logic [1:0][3:0][31:0] old_issue,partial_values;

  deqacc_v2_scale_ingress scale_ingress(.ea,.eb,.fold,.row_bias,.base,.bad_scale);
  for(genvar r=0;r<2;r++)begin: rows
    for(genvar n=0;n<4;n++)begin: lanes
      assign old_issue[r][n]=!add_old?32'b0:
        use_a3[r]?a3_values[r][n]:use_c[r]?commit_data[r][n]:acc_old_data[r][n];
      dequant_lane_v1 quant(.clk,.reset,.clear,.in_valid(q0_valid),.psum(psum[r][n]),
        .base(base[r][n]),.bad_scale(bad_scale[r][n]),
        .out_valid(partial_valid[r][n]),.partial_value(partial_values[r][n]));
      fp32_add_lane_v1 add(.clk,.reset,.clear,.in_valid(a0_valid),.add_old,
        .old_value(old_issue[r][n]),.partial_value(partial_values[r][n]),
        .out_valid(a3_valid[r][n]),.result_value(a3_values[r][n]));
    end
  end
  always_ff @(posedge clk) commit_data<=a3_values;

  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)begin
    if(partial_valid!=={8{a0_valid}})$fatal(1,"V2 partial/key mismatch");
    if(a3_valid!=={8{a3_stage_valid}})$fatal(1,"V2 A3/key mismatch");
  end
  // synthesis translate_on
endmodule
