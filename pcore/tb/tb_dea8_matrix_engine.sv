`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;
module tb_dea8_matrix_engine;
  localparam int WORDS=SUFFIX_LEN*HEAD_TILES;
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0,job_valid=0,resources_ready=1,job_ready,job_busy,job_done_valid,job_done_ready=0;
  matrix_job_t job,current_job,a_read_job;
  logic b_valid=0,b_ready,a_rd_en;
  logic [DW_ACT-1:0] b_data=0,a_data;
  logic [SCALE_BITS-1:0] b_scale=0,a_scale;
  logic [QOZ_ADDR_BITS-1:0] a_rd_addr;
  logic mem_rd_en,mem_wr_en,commit_valid;
  acc_sel_e mem_rd_sel,mem_wr_sel;
  logic [ACC_ADDR_BITS-1:0] mem_rd_addr,mem_wr_addr;
  logic [DW_VEC-1:0] mem_rd_data,mem_wr_data;
  logic [TILE-1:0] mem_wr_lane_en;
  pipe_tag_t commit_tag;
  deq_dest_t commit_dest;
  logic vpu_wr_valid=0,vpu_wr_ready;
  logic [ACC_ADDR_BITS-1:0] vpu_wr_addr=0;
  logic [DW_VEC-1:0] vpu_wr_data=0;
  logic [2:0] deq_reserved;
  logic [DW_VEC-1:0] golden[0:4*WORDS-1],scaled[0:WORDS-1];
  int j=0,accepted=0,writes=0,cycles=0,first_load=0,last_mul=-1,muls=0,load_count=0,boundary_waits=0;
  bit starve;
  logic kv_mode,engine_b_valid,engine_b_ready,adapter_ready,expect_ready,protocol_error;
  logic [DW_ACT-1:0] engine_b_data;
  logic [SCALE_BITS-1:0] engine_b_scale;
  logic [TILE_IDX_BITS-1:0] kv_tile,kv_column;
  logic kv_last,mask_valid;
  logic [TILE-1:0] mask_data;
  assign kv_mode=$test$plusargs("KVB");
  assign b_ready=kv_mode ? adapter_ready : engine_b_ready;
  dea8_kvb_adapter #(.V_KEY_LANE_IS_COLUMN(1)) frontend (
    .clk,.rst_n,.kvb_valid(b_valid && kv_mode),.kvb_ready(adapter_ready),
    .kvb_q(b_data),.kvb_e(b_scale),.kvb_kind(job.op==MATRIX_PV),
    .kvb_blk_id(job.ctx.block_id),.kvb_key_lane(kv_column),.kvb_feat_blk(kv_tile),
    .kvb_valid_mask({TILE{1'b1}}),.kvb_last(kv_last),.kvb_epoch(job.ctx.epoch),
    .expect_valid(job_valid && job_ready && kv_mode),.expect_ready,.expect_job(job),
    .b_valid(engine_b_valid),.b_ready(engine_b_ready && kv_mode),
    .b_data(engine_b_data),.b_scale(engine_b_scale),
    .mask_block(job.ctx.block_id),.mask_epoch(job.ctx.epoch),.mask_valid,.mask_data,.protocol_error
  );
  dea8_matrix_engine dut (
    .next_job_valid(1'b0),.next_job('0),
    .b_valid(kv_mode ? engine_b_valid : b_valid),.b_ready(engine_b_ready),
    .b_data(kv_mode ? engine_b_data : b_data),.b_scale(kv_mode ? engine_b_scale : b_scale),.*
  );
  assign deq_reserved=job_busy ? (current_job.op==MATRIX_PV ? 3'b100 :
                                    (current_job.facc_bank ? 3'b010 : 3'b001)) : 3'b000;
  dea8_accumulator_fabric fabric (
    .clk,.rst_n,.deq_reserved,
    .deq_rd_en(mem_rd_en),.deq_rd_sel(mem_rd_sel),.deq_rd_addr(mem_rd_addr),.deq_rd_data(mem_rd_data),
    .deq_wr_en(mem_wr_en),.deq_wr_sel(mem_wr_sel),.deq_wr_addr(mem_wr_addr),
    .deq_wr_lane_en(mem_wr_lane_en),.deq_wr_data(mem_wr_data),
    .vpu_rd_valid(1'b0),.vpu_rd_ready(),.vpu_rd_sel(ACC_FACC_A),.vpu_rd_addr('0),
    .vpu_rsp_valid(),.vpu_rsp_data(),.vpu_wr_valid,.vpu_wr_ready,.vpu_wr_sel(ACC_OACC),
    .vpu_wr_addr,.vpu_wr_lane_en({TILE{1'b1}}),.vpu_wr_data
  );
  function automatic int av(int jobno,int row,int tile,int k);
    return (jobno*19+row*3+(jobno%2==0 ? tile:0)*11+k*7)%255-127;
  endfunction
  function automatic int wv(int jobno,int tile,int k,int n);
    return (jobno*17+tile*31+k*13+n*5)%255-127;
  endfunction
  always @(posedge clk) begin
    cycles++;
    if(rst_n) begin
      if(a_rd_en) begin
        for(int k=0;k<TILE;k++) a_data[k*ACT_BITS+:ACT_BITS] <= ACT_BITS'(av(j,
          a_read_job.op==MATRIX_QK ? a_rd_addr/QOZ_TILES : a_rd_addr,
          a_read_job.op==MATRIX_QK ? a_rd_addr%QOZ_TILES : 0,k));
        a_scale <= SCALE_BITS'(128+((a_read_job.op==MATRIX_QK ?
                       a_rd_addr/QOZ_TILES+a_rd_addr%QOZ_TILES : a_rd_addr)+j)%5);
      end
      if(b_valid && b_ready) accepted++;
      if(dut.load_valid && dut.load_weight_idx==0) begin
        if(load_count%HEAD_TILES==0) first_load=cycles;
        load_count++;
      end
      if(dut.mul_valid) begin
        if(muls%WORDS==0 && cycles-first_load!=TILE) $fatal(1,"First tile activation timing");
        if(muls%SUFFIX_LEN!=0 && cycles-last_mul!=1) $fatal(1,"Local tile bubble");
        if(muls%WORDS!=0 && cycles-last_mul>1) boundary_waits++;
        if(!starve && muls%WORDS==WORDS-1 && cycles-first_load+1!=MATRIX_BLOCK_CYCLES)
          $fatal(1,"Matrix block is not 832 cycles");
        last_mul=cycles; muls++;
      end
      if(mem_wr_en) begin
        if(mem_wr_data!==golden[writes]) $fatal(1,"Matrix numeric mismatch job %0d vector %0d",j,writes);
        writes++;
      end
    end
  end
  initial begin
    starve=$test$plusargs("STARVE");
    $readmemh("test_vectors/matrix_jobs.txt",golden);
    $readmemh("test_vectors/matrix_scaled.txt",scaled);
    repeat(3) @(negedge clk); rst_n=1;
    for(j=0;j<4;j++) begin
      if(j==3) begin
        // Explicit VPU model: scale PV0 by 0.5 before the second PV job.
        for(int a=0;a<WORDS;a++) begin
          vpu_wr_valid=1; vpu_wr_addr=ACC_ADDR_BITS'(a); vpu_wr_data=scaled[a];
          @(posedge clk); if(!vpu_wr_ready) $fatal(1,"OACC not released to VPU");
          @(negedge clk);
        end
        vpu_wr_valid=0;
      end
      job='0; job.op=j%2==0 ? MATRIX_QK : MATRIX_PV;
      job.ctx.block_id=BLOCK_BITS'(j/2); job.ctx.head=2; job.ctx.epoch=6;
      job.facc_bank=j>=2; job.pbuf_bank=j>=2; job.init_oacc=j==1;
      job_valid=1;
      do @(posedge clk); while(!job_ready);
      @(negedge clk); job_valid=0;
      for(int t=0;t<HEAD_TILES;t++) for(int n=0;n<TILE;n++) begin
        kv_tile=TILE_IDX_BITS'(t); kv_column=TILE_IDX_BITS'(n);
        kv_last=t==HEAD_TILES-1 && n==TILE-1;
        if(starve && t==8 && n==0) begin b_valid=0; repeat(600) @(negedge clk); end
        for(int k=0;k<TILE;k++) b_data[k*ACT_BITS+:ACT_BITS]=ACT_BITS'(wv(j,t,k,n));
        b_scale=SCALE_BITS'(128+(j+t+n)%7); b_valid=1;
        do @(posedge clk); while(!b_ready);
        @(negedge clk);
      end
      b_valid=0;
      wait(job_done_valid);
      if(kv_mode && (!mask_valid || mask_data!={TILE{1'b1}} || protocol_error))
        $fatal(1,"KVB mask/context integration failed");
      if(writes!=(j+1)*WORDS || load_count!=(j+1)*HEAD_TILES) $fatal(1,"Early completion");
      repeat(3) @(negedge clk);
      if(!job_busy || !job_done_valid || engine_b_ready) $fatal(1,"Job context/transport not held at done");
      job_done_ready=1; @(negedge clk); job_done_ready=0;
    end
    if(accepted!=4*HEAD_TILES*TILE || writes!=4*WORDS) $fatal(1,"Matrix count mismatch");
    if(starve && boundary_waits==0) $fatal(1,"STARVE did not reach a tile boundary");
    $display("tb_dea8_matrix_engine PASS: QK/PV/QK/PV, 3264 bit-exact vectors, scaled old OACC");
    $finish;
  end
  initial begin #1000000; $fatal(1,"Matrix timeout"); end
  initial if($test$plusargs("RESET_JOB")) begin
    wait(muls>=10);
    @(negedge clk); rst_n=0;
    repeat(4) @(negedge clk);
    if(job_busy || job_done_valid || commit_valid || mem_wr_en || b_ready)
      $fatal(1,"Matrix reset did not cancel in-flight work");
    rst_n=1;
    repeat(20) @(negedge clk);
    if(job_busy || job_done_valid || commit_valid || mem_wr_en)
      $fatal(1,"Stale matrix work survived reset");
    $display("tb_dea8_matrix_engine PASS: reset cancels staging, issue and commits");
    $finish;
  end
endmodule
