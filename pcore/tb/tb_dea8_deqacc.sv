`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_fp32_pkg::*;

module tb_dea8_deqacc;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, req_valid = 0;
  mxu_rsp_t req;
  deq_dest_t req_dest;
  logic mem_rd_en, mem_wr_en, commit_valid;
  acc_sel_e mem_rd_sel, mem_wr_sel;
  logic [ACC_ADDR_BITS-1:0] mem_rd_addr, mem_wr_addr;
  logic [DW_VEC-1:0] mem_rd_data, mem_wr_data;
  logic [TILE-1:0] mem_wr_lane_en;
  pipe_tag_t commit_tag;
  deq_dest_t commit_dest;
  logic [DW_VEC-1:0] expected_in, expected_q [0:3];
  logic [3:0] valid_q = '0;
  pipe_tag_t tag_q [0:3];
  deq_dest_t dest_q [0:3];
  int accepted = 0, committed = 0, add_cases = 0, deq_cases = 0;
  int f, rc, raw_sel, raw_addr, raw_clear, raw_mask, raw_stream, raw_fold;
  logic [31:0] a, b, expected, actual, mag, normalized;
  int p, unbiased;
  logic [DW_PSUM-1:0] raw_psum;
  logic [DW_SCALE-1:0] raw_stat;

  dea8_deqacc dut (.*);
  dea8_accumulator_storage storage (
    .clk, .rd_en(mem_rd_en), .rd_sel(mem_rd_sel), .rd_addr(mem_rd_addr), .rd_data(mem_rd_data),
    .wr_en(mem_wr_en), .wr_sel(mem_wr_sel), .wr_addr(mem_wr_addr),
    .wr_lane_en(mem_wr_lane_en), .wr_data(mem_wr_data)
  );

  always @(posedge clk) begin
    if (!rst_n) valid_q = '0;
    else begin
      if (mem_wr_en !== valid_q[3]) $fatal(1, "L4 latency mismatch");
      if (mem_wr_en) begin
        if (mem_wr_data !== expected_q[3])
          $fatal(1, "DEQACC data mismatch transaction %0d got=%h expected=%h", committed, mem_wr_data, expected_q[3]);
        if (mem_wr_sel !== dest_q[3].acc_sel || mem_wr_addr !== dest_q[3].acc_addr ||
            mem_wr_lane_en !== tag_q[3].lane_mask) $fatal(1, "Write metadata mismatch");
        committed++;
      end
      // Check post-edge commit before advancing the test scoreboard.
      #1;
      if (commit_valid !== valid_q[3]) $fatal(1, "Commit valid mismatch");
      if (commit_valid && (commit_tag !== tag_q[3] || commit_dest !== dest_q[3]))
        $fatal(1, "Commit metadata mismatch");
      for (int i = 3; i > 0; i--) begin
        expected_q[i] = expected_q[i-1]; tag_q[i] = tag_q[i-1]; dest_q[i] = dest_q[i-1];
      end
      valid_q = {valid_q[2:0], req_valid};
      expected_q[0] = expected_in; tag_q[0] = req.tag; dest_q[0] = req_dest;
      if (req_valid) accepted++;
    end
  end

  initial begin
    req = '0; req_dest = '0; expected_in = '0;
    f = $fopen("test_vectors/fp_add.txt", "r");
    if (!f) $fatal(1, "Generate DEQACC vectors first");
    while (!$feof(f)) begin
      rc = $fscanf(f, "%h %h %h\n", a, b, expected);
      if (rc != 3) $fatal(1, "Malformed FP add vector");
      actual = fp32_add(a, b);
      if (actual !== expected) $fatal(1, "FP add %h + %h got %h expected %h", a, b, actual, expected);
      add_cases++;
    end
    $fclose(f);
    f = $fopen("test_vectors/dequant.txt", "r");
    if (!f) $fatal(1, "Missing dequant vectors");
    while (!$feof(f)) begin
      rc = $fscanf(f, "%h %h %h %h %h\n", a, raw_stream, raw_sel, raw_fold, expected);
      if (rc != 5) $fatal(1, "Malformed dequant vector");
      mag = a[31] ? ~a + 1'b1 : a;
      p = 0;
      for (int i = 0; i < 32; i++) if (mag[i]) p = i;
      normalized = mag << (31-p);
      unbiased = p + raw_stream + raw_sel - DOT_EXP_OFFSET + int'($signed(6'(raw_fold)));
      actual = pack_scaled32(a[31], normalized, unbiased, mag == 0, raw_stream == 255 || raw_sel == 255);
      if (actual !== expected) $fatal(1, "Dequant %h got %h expected %h", a, actual, expected);
      deq_cases++;
    end
    $fclose(f);
    repeat (3) @(negedge clk);
    rst_n = 1;
    f = $fopen("test_vectors/pipeline.txt", "r");
    if (!f) $fatal(1, "Missing pipeline vectors");
    while (!$feof(f)) begin
      @(negedge clk);
      rc = $fscanf(f, "%h %h %h %h %h %h %h %h %h\n", raw_sel, raw_addr, raw_clear,
                   raw_mask, raw_stream, raw_fold, raw_psum, raw_stat, expected_in);
      if (rc != 9) $fatal(1, "Malformed pipeline vector");
      req_valid = 1;
      req.psum = raw_psum; req.e_stat = raw_stat; req.e_stream = SCALE_BITS'(raw_stream);
      req.tag = '0;
      req.tag.row = ROW_BITS'(raw_addr % SUFFIX_LEN);
      req.tag.kt = TOKEN_BITS'(accepted / SUFFIX_LEN);
      req.tag.nt = TOKEN_BITS'(raw_addr / SUFFIX_LEN);
      req.tag.epoch = EPOCH_BITS'(accepted);
      req.tag.exp_fold = EXP_FOLD_BITS'(raw_fold);
      req.tag.lane_mask = TILE'(raw_mask);
      req.tag.final_k = accepted % 13 == 0; req.tag.last = accepted % 19 == 0;
      req_dest = '{acc_sel:acc_sel_e'(raw_sel), acc_addr:ACC_ADDR_BITS'(raw_addr), acc_clear:1'(raw_clear)};
      if ($test$plusargs("RAW_HAZARD") && accepted == 1) req_dest.acc_addr = 0;
      if ($test$plusargs("RAW_GAP3") && accepted == 3) req_dest.acc_addr = 0;
      if ($test$plusargs("BAD_DEST") && accepted == 1) req_dest.acc_sel = ACC_SBUF;
      if ($test$plusargs("BAD_ADDR") && accepted == 1) req_dest.acc_addr = FACC_WORDS;
      if ($test$plusargs("BUBBLES") && accepted % 11 == 0) begin
        @(negedge clk); req_valid = 0;
      end
    end
    $fclose(f);
    @(negedge clk); req_valid = 0;
    repeat (6) @(negedge clk);
    if (accepted != committed || accepted != 3433) $fatal(1, "Transaction count mismatch %0d %0d", accepted, committed);
    // Reset with a valid transaction in flight must suppress pending writes.
    req_valid = 1; req_dest.acc_clear = 1;
    @(negedge clk); rst_n = 0; req_valid = 0;
    repeat (6) @(negedge clk);
    if (mem_wr_en || commit_valid) $fatal(1, "Reset did not flush writes");
    rst_n = 1;
    repeat (6) @(negedge clk);
    if (mem_wr_en || commit_valid) $fatal(1, "Stale write after reset");
    $display("tb_dea8_deqacc PASS: add=%0d deq=%0d vectors=%0d lanes=%0d", add_cases, deq_cases, committed, committed*TILE);
    $finish;
  end
  initial begin #1000000; $fatal(1, "DEQACC watchdog"); end
endmodule
