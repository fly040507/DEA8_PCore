`timescale 1ns/1ps
import dea8_pcore_pkg::*;
module tb_dea8_mxu;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0, hbm_valid=0, hbm_ready;
  logic [HBM_BITS-1:0] hbm_data='0;
  logic run=0, bank_load_enable;
  logic tile_last_mul_fire, active_bank, active_valid, load_bank, load_valid;
  logic [TILE_IDX_BITS-1:0] load_weight_idx;
  logic signed [TILE-1:0][WEIGHT_BITS-1:0] load_weight_beat;
  logic scale_load_valid, load_tile_complete, bank_activate, new_active_bank;
  logic [SCALE_WORD_BITS-1:0] load_scale_word;
  bank_state_e bank_state_a, bank_state_b;
  logic req_valid, req_ready, mul_valid, rsp_valid, rsp_ready=1;
  logic signed [TILE-1:0][ACT_BITS-1:0] activation;
  logic [SCALE_BITS-1:0] e_stream, rsp_e_stream;
  pipe_tag_t req_tag, rsp_tag;
  logic signed [TILE-1:0][PSUM_BITS-1:0] psum;
  logic [TILE-1:0][SCALE_BITS-1:0] e_stat;
  localparam int TOTAL_TILES=2*HEAD_TILES;
  int sent=0, retired=0, mul_count=0, loads_started=0, completed_tiles=0;
  int cycle=0, previous_mul=-1, first_load=-1, load_cycles=0;
  int accept_cycle [0:TOTAL_TILES*SUFFIX_LEN-1];
  pipe_tag_t expected_tag [0:TOTAL_TILES*SUFFIX_LEN-1];
  int dot_expected;
  bit streaming, inject_bubble;

  function automatic int w(int t,int k,int n);
    if(t==0) return -128;
    if(t==1) return 127;
    return ((t*37+k*11+n*7)%256)-128;
  endfunction
  function automatic int a(int t,int r,int k);
    if(t==0) return -128;
    return ((t*13+r*3+k*17)%256)-128;
  endfunction
  function automatic int es(int t,int n);
    return 100+(t+n)%90;
  endfunction
  function automatic int ea(int t,int r);
    return 110+(t+r)%80;
  endfunction

  dea8_w_loader loader (.*);
  dea8_mxu dut (.*);

  always_comb begin
    // Two separate blocks: no Bank Load for block 1 until block 0 retires.
    bank_load_enable=run && (loads_started<TOTAL_TILES) &&
                     ((loads_started<HEAD_TILES) || (completed_tiles>=HEAD_TILES));
    req_valid=run && (sent<TOTAL_TILES*SUFFIX_LEN);
    if (inject_bubble && sent==10) req_valid=0;
    req_tag='0;
    req_tag.row=sent%SUFFIX_LEN;
    req_tag.kt=(sent/SUFFIX_LEN)%HEAD_TILES;
    req_tag.blk=(sent/SUFFIX_LEN)/HEAD_TILES;
    req_tag.nt=(sent/SUFFIX_LEN)%HEAD_TILES;
    req_tag.last=(sent%SUFFIX_LEN==SUFFIX_LEN-1);
    req_tag.final_k=(req_tag.kt==HEAD_TILES-1);
    req_tag.epoch=3;
    req_tag.lane_mask='1;
    e_stream=ea(sent/SUFFIX_LEN,sent%SUFFIX_LEN);
    for(int k=0;k<TILE;k++) activation[k]=a(sent/SUFFIX_LEN,sent%SUFFIX_LEN,k);
  end

  always @(posedge clk) begin
    cycle=cycle+1;
    if(rst_n) begin
      if(load_valid) begin
        if(load_weight_idx==0) begin
          if(!scale_load_valid) $fatal(1,"Scale not paired with first row");
          if(loads_started%HEAD_TILES==0) first_load=cycle;
          loads_started=loads_started+1;
          load_cycles=0;
        end else if(scale_load_valid) $fatal(1,"Repeated scale write");
        if(load_weight_idx!=load_cycles) $fatal(1,"Noncontinuous Bank Load");
        load_cycles=load_cycles+1;
        if(load_tile_complete && load_cycles!=TILE) $fatal(1,"Load not 16 cycles");
      end
      if(req_valid && req_ready) begin
        accept_cycle[sent]=cycle;
        expected_tag[sent]=req_tag;
        // Every block's first activation is captured on its final load edge.
        if(sent%(HEAD_TILES*SUFFIX_LEN)==0 && !load_tile_complete)
          $fatal(1,"First activation did not coincide with load16");
        sent<=sent+1;
      end
      if(mul_valid) begin
        if(mul_count%(HEAD_TILES*SUFFIX_LEN)==0) begin
          if(cycle-first_load!=TILE) $fatal(1,"First multiply has switch bubble");
          if(mul_count!=0 && cycle-previous_mul!=TILE+1)
            $fatal(1,"Block gap is not 16 load cycles");
        end else if(cycle-previous_mul!=1) $fatal(1,"Bubble inside matrix block");
        previous_mul=cycle;
        mul_count=mul_count+1;
      end
      if(tile_last_mul_fire) completed_tiles<=completed_tiles+1;
    end
    #1;
    if(rst_n && rsp_valid) begin
      if(retired>=sent) $fatal(1,"Unexpected output");
      if(cycle-accept_cycle[retired]!=MXU_STAGES-1) $fatal(1,"Stage latency mismatch");
      if(rsp_tag!==expected_tag[retired]) $fatal(1,"Tag mismatch at %0d",retired);
      if(rsp_e_stream!=ea(retired/SUFFIX_LEN,retired%SUFFIX_LEN))
        $fatal(1,"E_stream mismatch");
      for(int n=0;n<TILE;n++) begin
        dot_expected=0;
        for(int k=0;k<TILE;k++)
          dot_expected+=a(retired/SUFFIX_LEN,retired%SUFFIX_LEN,k)*w(retired/SUFFIX_LEN,k,n);
        if($signed(psum[n])!==dot_expected)
          $fatal(1,"Psum row=%0d lane=%0d expected=%0d got=%0d",retired,n,dot_expected,$signed(psum[n]));
        if(e_stat[n]!=es(retired/SUFFIX_LEN,n))
          $fatal(1,"Wrong E_stat generation at row %0d lane %0d",retired,n);
      end
      retired=retired+1;
      if(retired==TOTAL_TILES*SUFFIX_LEN) begin
        $display("tb_dea8_mxu PASS: 2 blocks, 32 tiles, 1632 rows, exact scales/tags, 832-cycle windows");
        $finish;
      end
    end
  end
  initial begin
    streaming=$test$plusargs("STREAMING");
    inject_bubble=$test$plusargs("INJECT_BUBBLE");
    repeat(3) @(negedge clk);
    rst_n=1;
    if(streaming) run=1;
    // Prefill all tiles, including nonzero ignored high scale bytes.
    for(int t=0;t<TOTAL_TILES;t++) begin
      for(int b=0;b<HBM_BEATS_PER_TILE;b++) begin
        @(negedge clk);
        if(streaming && t==0 && b==WEIGHT_HBM_BEATS_PER_TILE) begin
          hbm_valid=0;
          repeat(12) begin
            @(negedge clk);
            if(load_valid) $fatal(1,"Started before scale reservation");
          end
        end
        hbm_data='1;
        if(b<WEIGHT_HBM_BEATS_PER_TILE) begin
          for(int half=0;half<2;half++)
            for(int n=0;n<TILE;n++)
              hbm_data[(half*TILE+n)*8+:8]=w(t,2*b+half,n);
        end else begin
          for(int n=0;n<TILE;n++) hbm_data[n*8+:8]=es(t,n);
        end
        hbm_valid=1;
        do @(posedge clk); while(!hbm_ready);
      end
    end
    @(negedge clk); hbm_valid=0;
    repeat(3) @(negedge clk);
    if(!streaming && loads_started!=0) $fatal(1,"Loaded before enable");
    run=1;
  end
  initial begin #100000; $fatal(1,"Timeout"); end
endmodule
