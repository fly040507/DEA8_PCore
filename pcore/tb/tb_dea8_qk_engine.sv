`timescale 1ns/1ps
import dea8_pcore_pkg::*;
module tb_dea8_qk_engine;
  localparam int JOB_WORDS = SUFFIX_LEN*HEAD_TILES;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0, job_valid=0, resources_ready=0, job_ready, job_busy, job_done;
  logic [BLOCK_BITS-1:0] job_block_id=0, current_block_id;
  logic [HEAD_BITS-1:0] job_head=0;
  logic [EPOCH_BITS-1:0] job_epoch=0;
  logic job_facc_bank=0, hbm_valid=0, hbm_ready;
  logic [HBM_BITS-1:0] hbm_data=0;
  logic qoz_wr_en=0;
  logic [QOZ_ADDR_BITS-1:0] qoz_wr_addr=0;
  logic [DW_ACT-1:0] qoz_wr_data=0;
  logic [SCALE_BITS-1:0] qoz_wr_scale=0;
  logic facc_rd_en=0, facc_rd_bank=0, facc_rd_valid;
  logic [ROW_BITS-1:0] facc_rd_addr=0;
  logic [DW_VEC-1:0] facc_rd_data;
  logic commit_valid;
  pipe_tag_t commit_tag;
  deq_dest_t commit_dest;
  logic [DW_VEC-1:0] golden[0:2*JOB_WORDS-1];
  pipe_tag_t expected_tag[0:2*JOB_WORDS-1];
  deq_dest_t expected_dest[0:2*JOB_WORDS-1];
  int accept_cycle[0:2*JOB_WORDS-1];
  int cycle=0, issued=0, responses=0, committed=0, reads=0, loads=0, multiplies=0, dones=0;
  int first_load[0:1], previous_mul=-1, job_index, row_index, kt_index, boundary_stalls=0;
  bit hbm_done=0, stream_mode, starve_mode;
  dea8_qk_engine dut (.*);

  function automatic int q(int row,int kt,int k);
    return ((row*3+kt*13+k*17)%256)-128;
  endfunction
  function automatic int w(int tile,int k,int n);
    return ((tile*37+k*11+n*7)%256)-128;
  endfunction

  always @(posedge clk) begin
    cycle++;
    if(rst_n) begin
      if(job_valid && !resources_ready && job_ready) $fatal(1,"Job accepted without reservation");
      if(dut.load_valid && dut.load_weight_idx==0) begin
        if(loads%HEAD_TILES==0) first_load[loads/HEAD_TILES]=cycle;
        loads++;
      end
      if(dut.qoz_rd_en) begin
        if(dut.qoz_rd_addr !== QOZ_ADDR_BITS'((reads%SUFFIX_LEN)*QOZ_TILES+(reads%JOB_WORDS)/SUFFIX_LEN))
          $fatal(1,"QOZ address/tag schedule mismatch");
        reads++;
      end
      if(dut.req_valid) begin
        if(!dut.req_ready) $fatal(1,"QK input rejected");
        job_index=issued/JOB_WORDS;
        row_index=issued%SUFFIX_LEN;
        kt_index=(issued%JOB_WORDS)/SUFFIX_LEN;
        if(current_block_id != (job_index==0 ? 3 : 17)) $fatal(1,"Block context changed during job");
        if(dut.req_tag.row!=row_index || dut.req_tag.kt!=kt_index || dut.req_tag.nt!=0 ||
           dut.req_tag.head!=job_index+1 || dut.req_tag.epoch!=job_index+3 ||
           dut.req_tag.exp_fold!=QK_EXP_FOLD || dut.req_tag.lane_mask!={TILE{1'b1}} ||
           dut.req_tag.final_k!=(kt_index==HEAD_TILES-1) ||
           dut.req_tag.last!=((kt_index==HEAD_TILES-1)&&(row_index==SUFFIX_LEN-1)))
          $fatal(1,"QK request metadata mismatch");
        if(dut.req_dest.acc_sel!=(job_index==0 ? ACC_FACC_A : ACC_FACC_B) ||
           dut.req_dest.acc_addr!=row_index || dut.req_dest.acc_clear!=(kt_index==0))
          $fatal(1,"QK input destination mismatch");
        if(dut.e_stream!=110+(kt_index+row_index)%80) $fatal(1,"QOZ scale misaligned");
        for(int k=0;k<TILE;k++)
          if($signed(dut.activation[k*ACT_BITS+:ACT_BITS])!=q(row_index,kt_index,k))
            $fatal(1,"QOZ data misaligned");
        if(issued%JOB_WORDS==0 && !dut.load_tile_complete) $fatal(1,"First input not at load16");
        accept_cycle[issued]=cycle; expected_tag[issued]=dut.req_tag; expected_dest[issued]=dut.req_dest;
        issued++;
      end
      if(dut.mul_valid) begin
        if(multiplies%JOB_WORDS==0 && cycle-first_load[multiplies/JOB_WORDS]!=TILE)
          $fatal(1,"First QK multiply has a bubble");
        if(multiplies%SUFFIX_LEN!=0 && cycle-previous_mul!=1) $fatal(1,"Tile is not continuous");
        if(!starve_mode && multiplies%JOB_WORDS!=0 && cycle-previous_mul!=1) $fatal(1,"Block bubble");
        if(multiplies%JOB_WORDS!=0 && cycle-previous_mul>1) boundary_stalls++;
        if(!starve_mode && multiplies%JOB_WORDS==JOB_WORDS-1 &&
           cycle-first_load[multiplies/JOB_WORDS]+1!=MATRIX_BLOCK_CYCLES)
          $fatal(1,"QK block is not 832 cycles");
        previous_mul=cycle;
        multiplies++;
      end
      if(dut.mem_wr_en && dut.mem_wr_data!==golden[committed])
        $fatal(1,"QK job numeric mismatch %0d",committed);
    end
    #1;
    if(rst_n && dut.rsp_valid) begin
      if(dut.rsp_tag!==expected_tag[responses] || dut.rsp_dest!==expected_dest[responses])
        $fatal(1,"MXU response metadata mismatch");
      responses++;
    end
    if(rst_n && commit_valid) begin
      if(commit_tag!==expected_tag[committed] || commit_dest!==expected_dest[committed])
        $fatal(1,"QK commit metadata mismatch");
      if(cycle-accept_cycle[committed]!=MXU_STAGES+DEQACC_LAT-1) $fatal(1,"QK commit latency");
      if(current_block_id!=(committed/JOB_WORDS==0 ? 3 : 17)) $fatal(1,"Context lost before commit");
      if(!job_busy || job_ready) $fatal(1,"Context released before last commit");
      committed++;
    end
    if(rst_n && job_done) begin
      if(!commit_valid || !commit_tag.last || committed%JOB_WORDS!=0) $fatal(1,"Early job_done");
      dones++;
    end
  end

  initial begin
    stream_mode=$test$plusargs("STREAMING") || $test$plusargs("STARVE");
    starve_mode=$test$plusargs("STARVE");
    $readmemh("test_vectors/qk_job.txt",golden);
    repeat(3) @(negedge clk);
    rst_n=1;
    // Initialize both halves; QK must only read tile_idx 0..15.
    for(int row=0;row<SUFFIX_LEN;row++) for(int kt=0;kt<QOZ_TILES;kt++) begin
      @(negedge clk);
      qoz_wr_en=1; qoz_wr_addr=QOZ_ADDR_BITS'(row*QOZ_TILES+kt);
      qoz_wr_scale=SCALE_BITS'(110+(row+kt)%80);
      for(int k=0;k<TILE;k++) qoz_wr_data[k*ACT_BITS+:ACT_BITS]=ACT_BITS'(q(row,kt,k));
    end
    @(negedge clk); qoz_wr_en=0;
    if(!stream_mode) wait(hbm_done);
    for(int j=0;j<2;j++) begin
      @(negedge clk);
      job_valid=1; resources_ready=0;
      job_block_id=BLOCK_BITS'(j==0 ? 3 : 17);
      job_head=HEAD_BITS'(j+1); job_epoch=EPOCH_BITS'(j+3); job_facc_bank=1'(j);
      repeat(4) @(negedge clk);
      resources_ready=1;
      do @(posedge clk); while(!job_ready);
      @(negedge clk);
      // Incoming job fields may change, but accepted context must not.
      job_block_id=55; job_head=7; job_epoch=15; job_facc_bank=~job_facc_bank;
      repeat(5) @(negedge clk);
      job_valid=0;
      if (j == 1) begin
        // QK accumulates into B while VPU-style reads drain completed A.
        for(int row=0;row<SUFFIX_LEN;row++) begin
          @(negedge clk);
          facc_rd_en=1; facc_rd_bank=0; facc_rd_addr=ROW_BITS'(row);
          @(posedge clk); #2;
          if(!job_busy || !facc_rd_valid ||
             facc_rd_data!==golden[(HEAD_TILES-1)*SUFFIX_LEN+row])
            $fatal(1,"Concurrent FACC A read during QK B mismatch");
        end
        @(negedge clk); facc_rd_en=0;
      end
      wait(job_done);
      @(negedge clk);
      if(current_block_id!=(j==0 ? 3 : 17)) $fatal(1,"Done block id mismatch");
      wait(!job_busy);
      for(int row=0;row<SUFFIX_LEN;row++) begin
        @(negedge clk); facc_rd_en=1; facc_rd_bank=1'(j); facc_rd_addr=ROW_BITS'(row);
        @(posedge clk); #2;
        if(!facc_rd_valid || facc_rd_data!==golden[j*JOB_WORDS+(HEAD_TILES-1)*SUFFIX_LEN+row])
          $fatal(1,"Final FACC readback mismatch job=%0d row=%0d",j,row);
      end
      @(negedge clk); facc_rd_en=0;
    end
    repeat(5) @(negedge clk);
    if(issued!=2*JOB_WORDS || responses!=issued || committed!=issued || reads!=issued ||
       loads!=2*HEAD_TILES || dones!=2) $fatal(1,"QK job count mismatch");
    if(starve_mode && boundary_stalls==0) $fatal(1,"STARVE did not exercise a tile-boundary wait");
    $display("tb_dea8_qk_engine PASS: 2 jobs, 1632 transactions, QOZ pairs, tag58/dest13, QK fold=-4, final RAM commits");
    $finish;
  end

  initial begin
    wait(rst_n);
    if(stream_mode) wait(job_busy);
    for(int t=0;t<2*HEAD_TILES;t++) for(int b=0;b<HBM_BEATS_PER_TILE;b++) begin
      @(negedge clk);
      if(starve_mode && t==8 && b==0) begin hbm_valid=0; repeat(600) @(negedge clk); end
      if(stream_mode && t==0 && b==WEIGHT_HBM_BEATS_PER_TILE) begin
        hbm_valid=0; repeat(12) @(negedge clk);
      end
      hbm_data='1;
      if(b<WEIGHT_HBM_BEATS_PER_TILE) begin
        for(int half=0;half<2;half++) for(int n=0;n<TILE;n++)
          hbm_data[(half*TILE+n)*WEIGHT_BITS+:WEIGHT_BITS]=WEIGHT_BITS'(w(t,2*b+half,n));
      end else for(int n=0;n<TILE;n++) hbm_data[n*SCALE_BITS+:SCALE_BITS]=SCALE_BITS'(100+(t+n)%90);
      hbm_valid=1;
      do @(posedge clk); while(!hbm_ready);
    end
    @(negedge clk); hbm_valid=0; hbm_done=1;
  end
  initial begin #1000000; $fatal(1,"QK job watchdog"); end
  initial if($test$plusargs("RESET_JOB")) begin
    wait(issued>=10);
    @(negedge clk); rst_n=0;
    repeat(4) @(negedge clk);
    if(job_busy || job_done || commit_valid || dut.req_valid || dut.mem_wr_en)
      $fatal(1,"Reset did not cancel the in-flight QK job");
    rst_n=1;
    repeat(20) @(negedge clk);
    if(job_busy || job_done || commit_valid || dut.req_valid || dut.mem_wr_en)
      $fatal(1,"Stale QK work survived reset");
    $display("tb_dea8_qk_engine PASS: in-flight job reset suppresses stale commits and done");
    $finish;
  end
  initial if($test$plusargs("QOZ_CONFLICT")) begin
    wait(issued>=10);
    @(negedge clk); qoz_wr_en=1;
  end
endmodule
