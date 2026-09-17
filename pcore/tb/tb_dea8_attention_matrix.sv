`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

module tb_dea8_attention_matrix #(
  parameter bit PREFETCH = 1
);
  localparam int WORDS=SUFFIX_LEN*HEAD_TILES;
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0,start=0,resources_ready=1,launch_ready,job_busy,job_done_valid,job_done_ready=1;
  logic [HEAD_BITS-1:0] head=3;
  logic [EPOCH_BITS-1:0] epoch=5;
  matrix_job_t current_job,a_read_job;
  logic matrix_done;
  logic kvb_valid=0,kvb_ready,kvb_kind=0,kvb_last=0;
  logic [DW_ACT-1:0] kvb_q='0;
  logic [SCALE_BITS-1:0] kvb_e=133;
  logic [BLOCK_BITS-1:0] kvb_blk_id=0;
  logic [TILE_IDX_BITS-1:0] kvb_key_lane=0,kvb_feat_blk=0;
  logic [TILE-1:0] kvb_valid_mask='1;
  logic [EPOCH_BITS-1:0] kvb_epoch=5;
  logic b_valid,b_ready;
  logic [DW_ACT-1:0] b_data,a_data;
  logic [SCALE_BITS-1:0] b_scale,a_scale;
  logic a_rd_en;
  logic [QOZ_ADDR_BITS-1:0] a_rd_addr;
  logic mem_rd_en,mem_wr_en,commit_valid;
  acc_sel_e mem_rd_sel,mem_wr_sel;
  logic [ACC_ADDR_BITS-1:0] mem_rd_addr,mem_wr_addr;
  logic [DW_VEC-1:0] mem_rd_data,mem_wr_data;
  logic [TILE-1:0] mem_wr_lane_en;
  pipe_tag_t commit_tag;
  deq_dest_t commit_dest;
  logic mask_valid,protocol_error;
  logic [TILE-1:0] mask_data;
  logic [2:0] deq_reserved;
  int cycles=0,top_cycle=0,done_count=0,writes=0,loads=0,muls=0;
  int first_mul=-1,last_mul=-1,last_done=0,first_done=0,full_pop_push=0;
  int facc_ref[0:1][0:SUFFIX_LEN-1][0:TILE-1];
  int oacc_ref[0:OACC_WORDS-1][0:TILE-1];
  int logfd;
  bit starve;
  dea8_kvb_stream frontend (
    .mask_block(current_job.ctx.block_id),.mask_epoch(epoch),.*
  );
  dea8_attention_matrix #(.AUTO_LAUNCH(1),.ENABLE_LOOKAHEAD(PREFETCH)) dut (
    .launch_valid(1'b0),.launch_job('0),.*
  );
  assign deq_reserved=job_busy ? (current_job.op==MATRIX_PV ? 3'b100 :
                            (current_job.facc_bank ? 3'b010 : 3'b001)) : 3'b000;
  dea8_accumulator_fabric fabric (
    .clk,.rst_n,.deq_reserved,
    .deq_rd_en(mem_rd_en),.deq_rd_sel(mem_rd_sel),.deq_rd_addr(mem_rd_addr),.deq_rd_data(mem_rd_data),
    .deq_wr_en(mem_wr_en),.deq_wr_sel(mem_wr_sel),.deq_wr_addr(mem_wr_addr),
    .deq_wr_lane_en(mem_wr_lane_en),.deq_wr_data(mem_wr_data),
    .vpu_rd_valid(1'b0),.vpu_rd_ready(),.vpu_rd_sel(ACC_FACC_A),.vpu_rd_addr('0),
    .vpu_rsp_valid(),.vpu_rsp_data(),.vpu_wr_valid(1'b0),.vpu_wr_ready(),.vpu_wr_sel(ACC_OACC),
    .vpu_wr_addr('0),.vpu_wr_lane_en('0),.vpu_wr_data('0)
  );
  function automatic int av(input int j,r,t,k);
    return (j*3+r*5+t*7+k*2)%13-6;
  endfunction
  function automatic int bv(input int j,t,k,n);
    return (j*7+t*3+k*5+n*11)%17-8;
  endfunction
  // Independent exact conversion: all reference values fit in 24 mantissa bits.
  function automatic logic [31:0] exact_fp(input int value, input int exponent_adjust);
    logic sign_bit;
    logic [31:0] magnitude,mantissa;
    int top_bit;
    if(value==0) return 0;
    sign_bit=value<0; magnitude=sign_bit ? -value : value;
    top_bit=0;
    for(int b=0;b<31;b++) if(magnitude>>b) top_bit=b;
    if(top_bit>23) $fatal(1,"Integer oracle exceeds exact FP32 range");
    mantissa=magnitude<<(23-top_bit);
    return {sign_bit,8'(127+top_bit+exponent_adjust),mantissa[22:0]};
  endfunction

  always @(posedge clk) begin : monitor
    int row,tile,psum,result,bank,job_index;
    logic [31:0] expected;
    matrix_block_job_t expected_job;
    cycles++;
    if(rst_n) begin
      if(start) top_cycle=cycles;
      if(a_rd_en) begin
        row=a_read_job.op==MATRIX_QK ? a_rd_addr/QOZ_TILES : a_rd_addr;
        tile=a_read_job.op==MATRIX_QK ? a_rd_addr%QOZ_TILES : 0;
        for(int k=0;k<TILE;k++) a_data[k*ACT_BITS+:ACT_BITS]<=
          ACT_BITS'(av(done_count+(job_done_valid && job_done_ready ? 1:0),row,tile,k));
        a_scale<=SCALE_BITS'(133+(row%2));
      end
      if(frontend.kvfifo.count==KVFIFO_DEPTH && frontend.kvfifo.push && frontend.kvfifo.pop)
        full_pop_push++;
      if(dut.engine.load_valid) loads++;
      if(dut.engine.mul_valid) begin
        if(muls%WORDS==0) begin
          first_mul=cycles;
          $fdisplay(logfd,"first_mul,%0d,%0d",done_count,cycles-top_cycle);
        end else if(!starve && cycles!=last_mul+1) $fatal(1,"Unexpected compute bubble");
        last_mul=cycles; muls++;
      end
      if(mem_wr_en) begin
        job_index=writes/WORDS; tile=(writes%WORDS)/SUFFIX_LEN; row=(writes%WORDS)%SUFFIX_LEN;
        expected_job=attention_block_job(job_index,head,epoch);
        if(current_job!==expand_matrix_job(expected_job)) $fatal(1,"Executing context changed before commit");
        bank=current_job.facc_bank;
        for(int n=0;n<TILE;n++) begin
          psum=0;
          for(int k=0;k<TILE;k++) begin
            psum+=av(job_index,row,(current_job.op==MATRIX_QK ? tile:0),k)*bv(job_index,tile,k,n);
          end
          psum=psum<<((row%2)+((job_index+tile+n)%2));
          if(current_job.op==MATRIX_QK) begin
            result=psum+(tile==0 ? 0 : facc_ref[bank][row][n]);
            facc_ref[bank][row][n]=result;
            expected=exact_fp(result,-4);
          end else begin
            result=psum+(current_job.init_oacc ? 0 : oacc_ref[row*HEAD_TILES+tile][n]);
            oacc_ref[row*HEAD_TILES+tile][n]=result;
            expected=exact_fp(result,0);
          end
          if(mem_wr_data[n*FP_BITS+:FP_BITS]!==expected)
            $fatal(1,"Continuous numeric mismatch job=%0d tile=%0d row=%0d lane=%0d got=%h expected=%h",
                job_index,tile,row,n,mem_wr_data[n*FP_BITS+:FP_BITS],expected);
        end
        writes++;
        if(writes%WORDS==0)
          $fdisplay(logfd,"final_ram_write,%0d,%0d",done_count,cycles-top_cycle);
      end
      if(commit_valid && commit_tag.last)
        $fdisplay(logfd,"final_commit,%0d,%0d",done_count,cycles-top_cycle);
      if(job_done_valid && job_done_ready) begin
        if(writes!=(done_count+1)*WORDS) $fatal(1,"Done before all RAM writes");
        if(!starve && !$test$plusargs("DEPENDENCY_WAIT") && !$test$plusargs("DONE_BACKPRESSURE")) begin
          if(done_count==0 && cycles-top_cycle>MATRIX_COLD_BUDGET)
            $fatal(1,"Cold Top Job budget exceeded");
          if(done_count!=0 &&
             ((PREFETCH && cycles-last_done!=MATRIX_STEADY_BUDGET) ||
              (!PREFETCH && cycles-last_done>MATRIX_STEADY_BUDGET+TILE)))
            $fatal(1,"Steady/fallback interval mismatch: %0d",cycles-last_done);
        end
        if(!starve && !$test$plusargs("DONE_BACKPRESSURE") && first_mul>0 &&
           cycles-first_mul>MATRIX_WATCHDOG_CYCLES)
          $fatal(1,"Block exceeded no-starvation budget");
        if(done_count==0) first_done=cycles-top_cycle;
        if(done_count<3 || done_count>=MATRIX_JOB_COUNT-2)
          $display("TIMING job=%0d op=%0d block=%0d done=%0d interval=%0d first_mul=%0d last_mul=%0d",
             done_count,current_job.op,current_job.ctx.block_id,cycles-top_cycle,cycles-last_done,first_mul-top_cycle,last_mul-top_cycle);
        $fdisplay(logfd,"block_done,%0d,%0d",done_count,cycles-top_cycle);
        last_done=cycles; done_count++;
      end
    end
  end
  initial begin : producer
    matrix_block_job_t transport_job;
    wait(start); @(posedge clk); @(negedge clk);
    for(int j=0;j<MATRIX_JOB_COUNT;j++) begin
      transport_job=attention_block_job(j,head,epoch);
      for(int t=0;t<HEAD_TILES;t++) for(int n=0;n<TILE;n++) begin
        if(starve && ((j==0 && t==0 && n==15) || (j==1 && t==0 && n==8) ||
                      (j==4 && t==8 && n==15))) begin
          kvb_valid=0; repeat(900) @(negedge clk);
        end
        kvb_valid=1; kvb_kind=transport_job.op==MATRIX_PV;
        kvb_blk_id=transport_job.ctx.block_id; kvb_epoch=epoch;
        kvb_feat_blk=TILE_IDX_BITS'(t); kvb_key_lane=TILE_IDX_BITS'(n);
        kvb_last=t==HEAD_TILES-1 && n==TILE-1;
        for(int k=0;k<TILE;k++) begin
          kvb_q[k*ACT_BITS+:ACT_BITS]=ACT_BITS'(bv(j,t,k,n));
          kvb_valid_mask[k]=int'(kvb_blk_id)*TILE+k<LOGICAL_SEQ;
        end
        kvb_e=SCALE_BITS'(133+(j+t+n)%2);
        if($test$plusargs("BAD_COLUMN") && j==1 && t==0 && n==3) kvb_key_lane=4;
        if($test$plusargs("BAD_EPOCH") && j==1 && t==0 && n==3) kvb_epoch=epoch+1'b1;
        if($test$plusargs("BAD_ORDER") && j==1) kvb_kind=1;
        if($test$plusargs("BAD_TILE") && j==1 && t==0 && n==3) kvb_feat_blk=1;
        if($test$plusargs("EARLY_LAST") && j==1 && t==0 && n==3) kvb_last=1;
        if($test$plusargs("LATE_LAST") && j==1 && t==HEAD_TILES-1 && n==TILE-1) kvb_last=0;
        if($test$plusargs("MASK_CHANGE") && j==1 && t==0 && n==3) kvb_valid_mask[0]=0;
        if($test$plusargs("PADDING") && int'(kvb_blk_id)==N_KV_BLOCK-1) kvb_valid_mask='1;
        do @(posedge clk); while(!kvb_ready);
        @(negedge clk);
      end
    end
    kvb_valid=0;
  end
  initial begin
    matrix_block_job_t decode;
    matrix_job_t expanded;
    for(int j=0;j<MATRIX_JOB_COUNT;j++) begin
      decode=attention_block_job(j,head,epoch);
      expanded=expand_matrix_job(decode);
      if(expanded.op!==decode.op || expanded.ctx!==decode.ctx) $fatal(1,"Expanded descriptor mismatch");
      if(decode.op !== ((j==MATRIX_JOB_COUNT-1 || (j>0 && j%2==0)) ? MATRIX_PV : MATRIX_QK))
        $fatal(1,"Job decoder op mismatch");
      if(decode.ctx.block_id !== BLOCK_BITS'(j==0 ? 0 : j==MATRIX_JOB_COUNT-1 ? N_KV_BLOCK-1 : (j%2==1 ? (j+1)/2 : j/2-1)))
        $fatal(1,"Job decoder block mismatch");
    end
    starve=$test$plusargs("STARVE");
    logfd=$fopen(starve ? "attention_matrix_starve_cycles.csv" :
      $test$plusargs("DEPENDENCY_WAIT") ? "attention_matrix_dependency_cycles.csv" :
      $test$plusargs("DONE_BACKPRESSURE") ? "attention_matrix_backpressure_cycles.csv" :
      $test$plusargs("RESET_JOB") ? "attention_matrix_reset_cycles.csv" :
      ($test$plusargs("BAD_COLUMN") || $test$plusargs("BAD_EPOCH") || $test$plusargs("BAD_ORDER") ||
       $test$plusargs("BAD_TILE") || $test$plusargs("EARLY_LAST") || $test$plusargs("LATE_LAST") ||
       $test$plusargs("MASK_CHANGE") || $test$plusargs("PADDING")) ?
      "attention_matrix_error_cycles.csv" : PREFETCH ? "attention_matrix_cycles.csv" :
      "attention_matrix_noprefetch_cycles.csv","w");
    $fdisplay(logfd,"event,job,cycle_from_top");
    repeat(3) @(negedge clk); rst_n=1; start=1;
    @(negedge clk); start=0;
    wait(matrix_done); @(negedge clk);
    if(done_count!=MATRIX_JOB_COUNT || writes!=MATRIX_JOB_COUNT*WORDS ||
       loads!=MATRIX_JOB_COUNT*HEAD_TILES*TILE || muls!=writes || !full_pop_push || protocol_error)
      $fatal(1,"Continuous job/column/output/FIFO count mismatch");
    $display("TIMING total=%0d cold=%0d prefetch=%0d full_push_pop=%0d",last_done-top_cycle,first_done,PREFETCH,full_pop_push);
    $display("tb_dea8_attention_matrix PASS: 110 jobs, 89760 exact vectors, continuous K/V columns");
    $fclose(logfd); $finish;
  end
  initial if($test$plusargs("RESET_JOB")) begin
    // Stop the cancelled external producer before releasing reset.
    wait(loads>HEAD_TILES*TILE);
    disable producer;
    @(negedge clk); rst_n=0;
    repeat(3) @(negedge clk);
    if(job_busy || job_done_valid || b_ready || kvb_ready || mem_wr_en || commit_valid)
      $fatal(1,"Reset did not cancel prefetched work");
    kvb_valid=0; rst_n=1;
    repeat(8) begin
      @(negedge clk);
      if(job_busy || job_done_valid || b_ready || kvb_ready || mem_wr_en || commit_valid)
        $fatal(1,"Stale work reappeared after reset release");
    end
    $display("tb_dea8_attention_matrix PASS: reset cancels current and prefetched bank");
    $finish;
  end
  initial begin #3000000; $fatal(1,"Continuous matrix timeout"); end
  initial if($test$plusargs("DEPENDENCY_WAIT")) begin
    wait(loads>(HEAD_TILES+1)*TILE-1);
    @(negedge clk); resources_ready=0;
    wait(done_count==1);
    repeat(37) begin
      @(negedge clk);
      if(job_busy || dut.engine.mul_valid || a_rd_en || mem_wr_en || loads!=(HEAD_TILES+1)*TILE)
        $fatal(1,"Prefetched job ran without dependency reservation");
    end
    resources_ready=1;
  end
  initial if($test$plusargs("DONE_BACKPRESSURE")) begin
    matrix_job_t held_job;
    wait(loads>(HEAD_TILES+1)*TILE-1);
    @(negedge clk); job_done_ready=0;
    wait(job_done_valid); held_job=current_job;
    repeat(37) begin
      @(negedge clk);
      if(!job_done_valid || !job_busy || current_job!==held_job ||
         dut.engine.mul_valid || mem_wr_en || a_rd_en || done_count!=0)
        $fatal(1,"Completion backpressure changed job or issued work");
    end
    job_done_ready=1;
  end
endmodule

module tb_dea8_attention_matrix_no_prefetch;
  tb_dea8_attention_matrix #(.PREFETCH(0)) test();
endmodule
