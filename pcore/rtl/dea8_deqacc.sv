import dea8_pcore_pkg::*;

// Fixed-rate input: the sequencer reserves memory ownership before MXU issue.
module dea8_deqacc (
  input logic clk, rst_n, req_valid,
  input mxu_rsp_t req,
  input deq_dest_t req_dest,
  output logic mem_rd_en,
  output acc_sel_e mem_rd_sel,
  output logic [ACC_ADDR_BITS-1:0] mem_rd_addr,
  input logic [DW_VEC-1:0] mem_rd_data,
  output logic mem_wr_en,
  output acc_sel_e mem_wr_sel,
  output logic [ACC_ADDR_BITS-1:0] mem_wr_addr,
  output logic [TILE-1:0] mem_wr_lane_en,
  output logic [DW_VEC-1:0] mem_wr_data,
  output logic commit_valid,
  output pipe_tag_t commit_tag,
  output deq_dest_t commit_dest
);
  localparam int ARITH_STAGES = DEQACC_LAT - 1;
  logic [ARITH_STAGES-1:0] valid_q;
  pipe_tag_t tag_q [0:ARITH_STAGES-1];
  deq_dest_t dest_q [0:ARITH_STAGES-1];
  logic [TILE-1:0] lane_valid;
  for (genvar n = 0; n < TILE; n++) begin : g_lane
    dea8_deqacc_lane lane (
      .clk, .rst_n, .valid_in(req_valid), .psum_in(req.psum[n]),
      .e_stream_in(req.e_stream), .e_stat_in(req.e_stat[n]),
      .exp_fold_in(req.tag.exp_fold), .first_acc(req_dest.acc_clear),
      .old_acc_fp(mem_rd_data[n*FP_BITS+:FP_BITS]),
      .valid_out(lane_valid[n]), .acc_fp(mem_wr_data[n*FP_BITS+:FP_BITS]),
      .partial_fp(), .scale_exp(), .abs_psum(), .psum_sign()
    );
  end
  assign mem_rd_en = rst_n && valid_q[0] && !dest_q[0].acc_clear;
  assign mem_rd_sel = dest_q[0].acc_sel;
  assign mem_rd_addr = dest_q[0].acc_addr;
  assign mem_wr_en = rst_n && valid_q[ARITH_STAGES-1];
  assign mem_wr_sel = dest_q[ARITH_STAGES-1].acc_sel;
  assign mem_wr_addr = dest_q[ARITH_STAGES-1].acc_addr;
  assign mem_wr_lane_en = tag_q[ARITH_STAGES-1].lane_mask;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= '0; commit_valid <= 0; commit_tag <= '0; commit_dest <= '0;
      for (int i = 0; i < ARITH_STAGES; i++) begin tag_q[i] <= '0; dest_q[i] <= '0; end
    end else begin
      valid_q <= {valid_q[ARITH_STAGES-2:0], req_valid};
      if (req_valid) begin tag_q[0] <= req.tag; dest_q[0] <= req_dest; end
      for (int i = 1; i < ARITH_STAGES; i++)
        if (valid_q[i-1]) begin tag_q[i] <= tag_q[i-1]; dest_q[i] <= dest_q[i-1]; end
      // L4: external synchronous RAM samples the write at this same edge.
      commit_valid <= mem_wr_en;
      if (mem_wr_en) begin
        commit_tag <= tag_q[ARITH_STAGES-1]; commit_dest <= dest_q[ARITH_STAGES-1];
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk) if (rst_n) begin
    if (req_valid) begin
      if (req_dest.acc_sel == ACC_SBUF) $fatal(1, "Invalid DEQACC SBUF target");
      if ((req_dest.acc_sel == ACC_OACC && req_dest.acc_addr >= OACC_WORDS) ||
          (req_dest.acc_sel != ACC_OACC && req_dest.acc_addr >= FACC_WORDS))
        $fatal(1, "DEQACC address out of range");
      for (int i = 0; i < ARITH_STAGES-1; i++)
        if (valid_q[i] && dest_q[i].acc_sel == req_dest.acc_sel &&
            dest_q[i].acc_addr == req_dest.acc_addr)
          $fatal(1, "DEQACC accumulator RAW hazard");
    end
    if (lane_valid != {TILE{valid_q[ARITH_STAGES-1]}}) $fatal(1, "DEQACC lane valid mismatch");
  end
  initial if (DEQACC_LAT != 5) $fatal(1, "DEQACC stage contract is L0-L4");
  // synthesis translate_on
endmodule
