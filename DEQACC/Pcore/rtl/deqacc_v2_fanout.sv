// Spatial two-level control distribution. No registers or clock boundary.
// Protect only buffer endpoints so equal-valued branches cannot merge.
(* keep_hierarchy="soft" *)
module deqacc_v2_fanout #(
  parameter int WIDTH=1,
  parameter int BRANCHES=4,
  parameter int LEAVES_PER_BRANCH=4
)(
  input logic [WIDTH-1:0] root,
  output logic [BRANCHES*LEAVES_PER_BRANCH-1:0][WIDTH-1:0] leaf
);
  logic [BRANCHES-1:0][WIDTH-1:0] branch;
  for(genvar g=0;g<BRANCHES;g++)begin: branches
    for(genvar b=0;b<WIDTH;b++)begin: bits
      (* DONT_TOUCH="true" *) LUT1 #(.INIT(2'b10)) branch_buffer(
        .I0(root[b]),.O(branch[g][b]));
    end
    for(genvar n=0;n<LEAVES_PER_BRANCH;n++)begin: leaves
      for(genvar b=0;b<WIDTH;b++)begin: bits
        (* DONT_TOUCH="true" *) LUT1 #(.INIT(2'b10)) leaf_buffer(
          .I0(branch[g][b]),.O(leaf[g*LEAVES_PER_BRANCH+n][b]));
      end
    end
  end
  // synthesis translate_off
  initial if(WIDTH<1||BRANCHES<1||LEAVES_PER_BRANCH<1)
    $fatal(1,"V2 fanout dimensions must be positive");
  // synthesis translate_on
endmodule
