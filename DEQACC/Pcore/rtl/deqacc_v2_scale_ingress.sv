import pcore_pkg::*;

// Shared row-bias roots -> four local branches per row -> four base adders
// per branch. These are spatial buffers, not extra pipeline boundaries.
module deqacc_v2_scale_ingress(
  input logic [1:0][SCALE_BITS-1:0] ea,
  input logic [TILE-1:0][SCALE_BITS-1:0] eb,
  input logic signed [EXP_FOLD_BITS-1:0] fold,
  output logic signed [1:0][11:0] row_bias,
  output logic signed [1:0][TILE-1:0][11:0] base,
  output logic [1:0][TILE-1:0] bad_scale
);
  localparam int BASE_BITS=12;
  localparam int ROW_BRANCHES=4;
  localparam int BRANCH_COLUMNS=TILE/ROW_BRANCHES;
  logic signed [1:0][ROW_BRANCHES-1:0][BASE_BITS-1:0] row_bias_branch;
  logic [1:0][ROW_BRANCHES-1:0] bad_ea_branch;
  logic [TILE-1:0] bad_eb;

  for(genvar n=0;n<TILE;n++)begin: stat_flags
    assign bad_eb[n]=&eb[n];
  end
  for(genvar r=0;r<2;r++)begin: rows
    (* keep="true" *) logic signed [BASE_BITS-1:0] bias_root;
    logic bad_ea;
    assign bias_root=BASE_BITS'($signed({1'b0,ea[r]}))+
      BASE_BITS'($signed(fold))-BASE_BITS'(DOT_EXP_OFFSET);
    assign row_bias[r]=bias_root;
    assign bad_ea=&ea[r];

    for(genvar g=0;g<ROW_BRANCHES;g++)begin: branches
      // Protect only the branch endpoints, not the arithmetic or control.
      // A wire alias alone cannot enforce four independent local drivers.
      for(genvar b=0;b<BASE_BITS;b++)begin: bias_bits
        (* DONT_TOUCH="true" *) LUT1 #(.INIT(2'b10)) branch_buffer(
          .I0(bias_root[b]),.O(row_bias_branch[r][g][b]));
      end
      (* DONT_TOUCH="true" *) LUT1 #(.INIT(2'b10)) bad_buffer(
        .I0(bad_ea),.O(bad_ea_branch[r][g]));
      for(genvar c=0;c<BRANCH_COLUMNS;c++)begin: columns
        localparam int COLUMN=g*BRANCH_COLUMNS+c;
        (* keep_hierarchy="soft" *) deqacc_v2_base_add base_adder(
          .row_bias(row_bias_branch[r][g]),.eb(eb[COLUMN]),
          .bad_ea(bad_ea_branch[r][g]),.bad_eb(bad_eb[COLUMN]),
          .base(base[r][COLUMN]),.bad_scale(bad_scale[r][COLUMN]));
      end
    end
  end
  // synthesis translate_off
  initial if(TILE!=16||BRANCH_COLUMNS!=4)$fatal(1,"V2 scale ingress requires per-row 1-to-4-to-16");
  // synthesis translate_on
endmodule

// A named local combinational cone for placement beside its Qlane.
(* keep_hierarchy="soft" *)
module deqacc_v2_base_add(
  input logic signed [11:0] row_bias,
  input logic [SCALE_BITS-1:0] eb,
  input logic bad_ea,bad_eb,
  output logic signed [11:0] base,
  output logic bad_scale
);
  assign base=$signed(row_bias)+12'($signed({1'b0,eb}));
  assign bad_scale=bad_ea||bad_eb;
endmodule
