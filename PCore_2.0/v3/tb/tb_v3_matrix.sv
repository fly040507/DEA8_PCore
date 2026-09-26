`timescale 1ns/1ps
import pcore3_pkg::*;
import dea8_fp32_v3_pkg::*;

module tb_v3_matrix;
  localparam int TEST_TILES=64;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic xbc_valid,xbc_ready; xbc4_t xbc_entry;
  logic hbm_valid,hbm_ready,kv_valid,kv_ready; b2_t hbm_entry,kv_entry;
  b_source_e b_source;
  logic job_start,job_ready,job_busy;
  logic [TILE_BITS-1:0] job_tile_idx;
  logic [TILE_BITS:0] job_tiles;
  logic [EPOCH_BITS-1:0] job_epoch;
  logic [2:0] job_head; logic job_final_k;
  logic signed [EXP_FOLD_BITS-1:0] job_exp_fold;
  acc_sel_e job_acc_sel; logic job_acc_clear;
  logic commit_valid,done; pair_meta_t commit_meta;
  logic dbg_valid,dbg_parity; acc_sel_e dbg_sel; logic [9:0] dbg_addr;
  logic [3:0] dbg_lane; logic [31:0] dbg_data;
  logic a_protocol_error,b_protocol_error;
  int commits;
  int last_tile_count;
  int cycle_count,issue_count,last_issue_cycle,max_issue_gap;

  dea8_matrix_v3 dut(
    .clk,.reset,.clear,.xbc_valid,.xbc_ready,.xbc_entry,
    .hbm_valid,.hbm_ready,.hbm_entry,.kv_valid,.kv_ready,.kv_entry,.b_source,
    .job_start,.job_tile_idx,.job_tiles,.job_epoch,.job_head,.job_final_k,
    .job_exp_fold,.job_acc_sel,.job_acc_clear,.job_ready,.job_busy,
    .commit_valid,.done,.commit_meta,.dbg_valid,.dbg_sel,.dbg_parity,
    .dbg_addr,.dbg_lane,.dbg_data,.a_protocol_error,.b_protocol_error);

  always @(posedge clk) begin
    cycle_count++;
    if(dut.req_valid) begin
      if(issue_count!=0 && cycle_count-last_issue_cycle>max_issue_gap)
        max_issue_gap=cycle_count-last_issue_cycle;
      last_issue_cycle=cycle_count;
      issue_count++;
    end
    #1;
    if(commit_valid) begin
      commits++;
      if(commit_meta.last) last_tile_count++;
    end
  end

  function automatic qvec16_t qv(input int value,input int scale);
    qvec16_t t;
    begin
      t='0; t.scale=scale[7:0];
      for(int k=0;k<TILE;k++) t.data[k*8+:8]=value[7:0];
      return t;
    end
  endfunction

  task automatic send_a4(input int tile,input int g);
    xbc_entry.tile_idx=tile[TILE_BITS-1:0];
    xbc_entry.group_idx=g[3:0];
    xbc_entry.slot=0; xbc_entry.reserved=0;
    xbc_entry.row_valid=(g==XBC_GROUPS-1)?4'b0111:4'b1111;
    for(int r=0;r<4;r++) begin
      if(r==0) xbc_entry.row[r]=qv(1,128);
      else if(r==1) xbc_entry.row[r]=qv(2,128);
      else xbc_entry.row[r]=qv(1,128);
    end
    do begin @(negedge clk); xbc_valid=1; end while(!xbc_ready);
    @(negedge clk); xbc_valid=0;
  endtask

  task automatic send_b2(input int tile,input int g,input logic use_kv);
    if(use_kv) begin
      kv_entry.tile_idx=tile[TILE_BITS-1:0]; kv_entry.reserved=0;
      kv_entry.group_idx=g[2:0]; kv_entry.epoch=1;
      kv_entry.col[0]=qv(1,128); kv_entry.col[1]=qv(1,128);
      do begin @(negedge clk); kv_valid=1; end while(!kv_ready);
      @(negedge clk); kv_valid=0;
    end else begin
      hbm_entry.tile_idx=tile[TILE_BITS-1:0]; hbm_entry.reserved=0;
      hbm_entry.group_idx=g[2:0]; hbm_entry.epoch=1;
      hbm_entry.col[0]=qv(1,128); hbm_entry.col[1]=qv(1,128);
      do begin @(negedge clk); hbm_valid=1; end while(!hbm_ready);
      @(negedge clk); hbm_valid=0;
    end
  endtask

  initial begin
    xbc_valid=0; hbm_valid=0; kv_valid=0; b_source=B_HBM;
    job_start=0; job_tile_idx=0; job_tiles=TEST_TILES;
    job_epoch=1; job_head=0; job_final_k=1; job_exp_fold=0;
    job_acc_sel=ACC_FACC_A; job_acc_clear=1;
    dbg_valid=0; dbg_sel=ACC_FACC_A; dbg_parity=0; dbg_addr=0; dbg_lane=0;
    commits=0; last_tile_count=0; cycle_count=0; issue_count=0;
    last_issue_cycle=0; max_issue_gap=0;

    repeat(20) @(negedge clk); reset=0;
    if(!job_ready) $fatal(1,"matrix job shell is not ready after reset");

    // Launch before the producers so finite FIFOs can back-pressure safely.
    @(negedge clk); job_start=1;
    @(negedge clk); job_start=0;
    // Live inputs are deliberately changed after acceptance.  All metadata
    // observed at the commit boundary must still come from the latched job.
    job_tile_idx=6'h3f; job_tiles=1; job_epoch=4'hf; job_head=3'h7;
    job_final_k=0; job_exp_fold=-7; job_acc_sel=ACC_FACC_B; job_acc_clear=0;

    fork
      begin
        for(int t=0;t<TEST_TILES;t++)
          for(int g=0;g<XBC_GROUPS;g++) send_a4(t,g);
      end
      begin
        // Tile 0 enters through the HBM-facing path; the remaining Tiles
        // enter through the K/V path.  The loader must release and reuse both
        // stationary banks while this single job is still active.
        b_source=B_HBM;
        for(int g=0;g<8;g++) send_b2(0,g,0);
        b_source=B_KVB;
        for(int t=1;t<TEST_TILES;t++)
          for(int g=0;g<8;g++) send_b2(t,g,1);
      end
    join

    wait(done);
    // Matrix observes DEQACC's registered done on the following clock and
    // releases job_busy there.  Sample the public job boundary after that
    // synchronous handoff, not in the same delta cycle as done.
    @(posedge clk); #1;
    if(a_protocol_error||b_protocol_error)
      $fatal(1,"matrix ingress protocol error in multi-tile job");
    if(commits!=TEST_TILES*PAIRS)
      $fatal(1,"multi-tile commit count=%0d expected=%0d",commits,TEST_TILES*PAIRS);
    if(issue_count!=TEST_TILES*PAIRS || max_issue_gap>1)
      $fatal(1,"MXU issue stream has a gap issues=%0d max_gap=%0d",
        issue_count,max_issue_gap);
    if(last_tile_count!=1)
      $fatal(1,"final commit marker count=%0d",last_tile_count);
    if(commit_meta.tile_idx!=TEST_TILES-1 || commit_meta.pair_idx!=PAIRS-1 ||
       !commit_meta.last || commit_meta.epoch!=1 || commit_meta.head!=0 ||
       commit_meta.final_k!=1 || commit_meta.acc_sel!=ACC_FACC_A)
      $fatal(1,"latched final metadata mismatch tile=%0d epoch=%0d head=%0d last=%0d",
        commit_meta.tile_idx,commit_meta.epoch,commit_meta.head,commit_meta.last);
    if(job_busy) $fatal(1,"job remains busy after final DEQACC commit");

    // Every tile contributes the same partial result.  This checks that all
    // 26 pairs of the first Tile use clear, while later Tiles use read/add.
    dbg_valid=1; dbg_sel=ACC_FACC_A; dbg_parity=0; dbg_addr=0; dbg_lane=0; #1;
    if(dbg_data!==pack_scaled32(0,32'h80000000,0,0,0))
      $fatal(1,"row0 accumulated FACC mismatch %h",dbg_data);
    dbg_parity=1; #1;
    if(dbg_data!==pack_scaled32(0,32'h80000000,1,0,0))
      $fatal(1,"row1 accumulated FACC mismatch %h",dbg_data);

    $display("tb_v3_matrix PASS A4=%0d B2=%0d tiles=%0d commits=%0d issues=%0d max_gap=%0d",
      TEST_TILES*XBC_GROUPS,TEST_TILES*8,TEST_TILES,commits,issue_count,max_issue_gap);
    $finish;
  end
  initial begin #1000000; $fatal(1,"v3 matrix watchdog"); end
endmodule
