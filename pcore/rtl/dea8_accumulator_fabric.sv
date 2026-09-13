import dea8_pcore_pkg::*;

// Bank reservation is a JOB lifetime contract, not a per-cycle priority.
// DEQACC cannot be stalled. The controller reserves before issuing any tile
// and releases only after the final L4 commit. VPU responses are non-stallable
// one-cycle synchronous responses; reserve sink capacity before requesting.
module dea8_accumulator_fabric (
  input logic clk, rst_n,
  input logic [2:0] deq_reserved,
  input logic deq_rd_en,
  input acc_sel_e deq_rd_sel,
  input logic [ACC_ADDR_BITS-1:0] deq_rd_addr,
  output logic [DW_VEC-1:0] deq_rd_data,
  input logic deq_wr_en,
  input acc_sel_e deq_wr_sel,
  input logic [ACC_ADDR_BITS-1:0] deq_wr_addr,
  input logic [TILE-1:0] deq_wr_lane_en,
  input logic [DW_VEC-1:0] deq_wr_data,
  input logic vpu_rd_valid,
  output logic vpu_rd_ready,
  input acc_sel_e vpu_rd_sel,
  input logic [ACC_ADDR_BITS-1:0] vpu_rd_addr,
  output logic vpu_rsp_valid,
  output logic [DW_VEC-1:0] vpu_rsp_data,
  input logic vpu_wr_valid,
  output logic vpu_wr_ready,
  input acc_sel_e vpu_wr_sel,
  input logic [ACC_ADDR_BITS-1:0] vpu_wr_addr,
  input logic [TILE-1:0] vpu_wr_lane_en,
  input logic [DW_VEC-1:0] vpu_wr_data
);
  logic [2:0] rd_en, wr_en;
  logic [2:0][ACC_ADDR_BITS-1:0] rd_addr, wr_addr;
  logic [2:0][DW_VEC-1:0] rd_data, wr_data;
  logic [2:0][TILE-1:0] wr_lane_en;
  acc_sel_e deq_sel_q, vpu_sel_q;
  logic vpu_rd_fire, vpu_wr_fire;

  assign vpu_rd_ready = rst_n && vpu_rd_sel != ACC_SBUF &&
                        !deq_reserved[vpu_rd_sel];
  assign vpu_wr_ready = rst_n && vpu_wr_sel != ACC_SBUF &&
                        !deq_reserved[vpu_wr_sel];
  assign vpu_rd_fire = vpu_rd_valid && vpu_rd_ready;
  assign vpu_wr_fire = vpu_wr_valid && vpu_wr_ready;
  assign deq_rd_data = rd_data[deq_sel_q];
  assign vpu_rsp_data = rd_data[vpu_sel_q];

  for (genvar b=0; b<3; b++) begin : g_bank
    assign rd_en[b] = rst_n && ((deq_rd_en && deq_rd_sel == b) ||
                               (vpu_rd_fire && vpu_rd_sel == b));
    assign wr_en[b] = rst_n && ((deq_wr_en && deq_wr_sel == b) ||
                               (vpu_wr_fire && vpu_wr_sel == b));
    assign rd_addr[b] = deq_reserved[b] ? deq_rd_addr : vpu_rd_addr;
    assign wr_addr[b] = deq_reserved[b] ? deq_wr_addr : vpu_wr_addr;
    assign wr_data[b] = deq_reserved[b] ? deq_wr_data : vpu_wr_data;
    assign wr_lane_en[b] = deq_reserved[b] ? deq_wr_lane_en : vpu_wr_lane_en;
    dea8_acc_bank #(.WORDS(b == 2 ? OACC_WORDS : FACC_WORDS)) bank (
      .clk, .rd_en(rd_en[b]), .rd_addr(rd_addr[b]), .rd_data(rd_data[b]),
      .wr_en(wr_en[b]), .wr_addr(wr_addr[b]),
      .wr_lane_en(wr_lane_en[b]), .wr_data(wr_data[b])
    );
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      deq_sel_q <= ACC_FACC_A;
      vpu_sel_q <= ACC_FACC_A;
      vpu_rsp_valid <= 0;
    end else begin
      if (deq_rd_en) deq_sel_q <= deq_rd_sel;
      if (vpu_rd_fire) vpu_sel_q <= vpu_rd_sel;
      vpu_rsp_valid <= vpu_rd_fire;
    end
  end
  // synthesis translate_off
  always @(posedge clk) if (rst_n) begin
    if (deq_rd_en && (deq_rd_sel == ACC_SBUF || !deq_reserved[deq_rd_sel]))
      $fatal(1, "DEQACC read without bank reservation");
    if (deq_wr_en && (deq_wr_sel == ACC_SBUF || !deq_reserved[deq_wr_sel]))
      $fatal(1, "DEQACC write without bank reservation");
    if ((vpu_rd_valid && vpu_rd_sel == ACC_SBUF) ||
        (vpu_wr_valid && vpu_wr_sel == ACC_SBUF))
      $fatal(1, "SBUF must use its separate client port");
  end
  // synthesis translate_on
endmodule
