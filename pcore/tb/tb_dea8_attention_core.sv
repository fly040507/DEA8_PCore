`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;
module tb_dea8_attention_core #(
  parameter bit SOFTMAX_MODEL = 0
);
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0,start_valid=0,resources_ready=1,start_ready,busy,done_valid,done_ready=0,matrix_busy;
  logic [HEAD_BITS-1:0] start_head=1;
  logic [EPOCH_BITS-1:0] start_epoch=2;
  matrix_job_t current_job;
  logic b_valid=1,b_ready;
  logic [DW_ACT-1:0] b_data={TILE{8'd1}};
  logic [SCALE_BITS-1:0] b_scale=133;
  logic kvb_valid=0,kvb_ready,kvb_kind,kvb_last;
  logic [DW_ACT-1:0] kvb_q={TILE{8'd1}};
  logic [SCALE_BITS-1:0] kvb_e=133;
  logic [BLOCK_BITS-1:0] kvb_blk_id;
  logic [TILE_IDX_BITS-1:0] kvb_key_lane,kvb_feat_blk;
  logic [TILE-1:0] kvb_valid_mask,vpu_key_mask;
  logic [EPOCH_BITS-1:0] kvb_epoch;
  logic vpu_key_mask_valid,kvb_protocol_error;
  logic qoz_wr_en=0;
  logic [QOZ_ADDR_BITS-1:0] qoz_wr_addr=0;
  logic [DW_ACT-1:0] qoz_wr_data={TILE{8'd1}};
  logic [SCALE_BITS-1:0] qoz_wr_scale=133;
  logic vpu_valid,vpu_ready,vpu_done_valid,vpu_done_ready;
  vpu_job_t vpu_cmd,vpu_done;
  logic sfu_valid,sfu_ready,sfu_done_valid,sfu_done_ready;
  sfu_job_t sfu_cmd,sfu_done;
  logic vpu_rd_valid,vpu_rd_ready,vpu_rsp_valid,vpu_wr_valid,vpu_wr_ready;
  acc_sel_e vpu_rd_sel,vpu_wr_sel;
  logic [ACC_ADDR_BITS-1:0] vpu_rd_addr,vpu_wr_addr;
  logic [DW_VEC-1:0] vpu_rsp_data,vpu_wr_data;
  logic [TILE-1:0] vpu_wr_lane_en;
  logic sbuf_wr_en,sbuf_wr_bank,sbuf_rd_en,sbuf_rd_bank,sbuf_rsp_valid;
  logic [ROW_BITS-1:0] sbuf_wr_row,sbuf_rd_row;
  logic [DW_VEC-1:0] sbuf_wr_data,sbuf_rd_data;
  logic pbuf_wr_en,pbuf_wr_bank;
  logic [ROW_BITS-1:0] pbuf_wr_row;
  logic [DW_ACT-1:0] pbuf_wr_data;
  logic [SCALE_BITS-1:0] pbuf_wr_scale;
  logic vpu_m_rd_en,vpu_m_rsp_valid,vpu_m_aa_wr_en,vpu_l_rd_en,vpu_l_rsp_valid,vpu_l_wr_en;
  logic [ROW_BITS-1:0] vpu_m_rd_row,vpu_m_aa_wr_row,vpu_l_rd_row,vpu_l_wr_row;
  fp_t vpu_m_rsp_data,vpu_m_wr_data,vpu_aa_wr_data,vpu_l_rsp_data,vpu_l_wr_data;
  logic sfu_m_rd_en,sfu_m_rsp_valid,sfu_aa_rd_en,sfu_l_rd_en,sfu_aa_rsp_valid,sfu_l_rsp_valid;
  logic [ROW_BITS-1:0] sfu_m_rd_row,sfu_aa_rd_base,sfu_l_rd_base;
  logic [SFU_LANES-1:0] sfu_aa_rd_mask,sfu_l_rd_mask;
  fp_t sfu_m_rsp_data;
  logic [SFU_LANES*FP_BITS-1:0] sfu_aa_rsp_data,sfu_l_rsp_data;
  logic alpha_wr_en,vpu_alpha_rd_en,vpu_alpha_rd_bank,vpu_alpha_rsp_valid;
  logic [ROW_BITS-1:0] alpha_wr_base,vpu_alpha_rd_row;
  logic [SFU_LANES-1:0] alpha_wr_mask;
  logic [SFU_LANES*FP_BITS-1:0] alpha_wr_data;
  fp_t vpu_alpha_rsp_data;
  logic recip_wr_en,vpu_recip_rd_en,vpu_recip_rsp_valid;
  logic [ROW_BITS-1:0] recip_wr_base,vpu_recip_rd_row;
  logic [SFU_LANES-1:0] recip_wr_mask;
  logic [SFU_LANES*FP_BITS-1:0] recip_wr_data;
  fp_t vpu_recip_rsp_data;
  logic sfu_p_valid,sfu_p_ready,vpu_p_valid,vpu_p_ready;
  p_result_t sfu_p_data,vpu_p_data;
  logic commit_valid;
  pipe_tag_t commit_tag;
  deq_dest_t commit_dest;
  int qk_commits=0,pv_commits=0,vpu_jobs,sfu_jobs;
  localparam int MATRIX_WORDS=SUFFIX_LEN*HEAD_TILES;
  logic [DW_VEC-1:0] expected_pv[0:N_KV_BLOCK*MATRIX_WORDS-1];
  logic [DW_VEC-1:0] expected_final[0:MATRIX_WORDS-1];
  logic [4*FP_BITS-1:0] expected_scalar[0:N_KV_BLOCK*SUFFIX_LEN-1];
  int cycles=0,top_cycle=0,matrix_jobs=0,matrix_finishes=0,scale_jobs=0;
  int pv53_done=-1,pv54_start=-1,pv54_done=-1,tail_scale_start=-1,tail_scale_done=-1;
  int tail_first_write=-1,tail_last_write=-1,tail_writes=0,logfd;
  int first_matrix_done=-1,last_matrix_done=-1;
  logic tail_scaled=0;
  function automatic bit close_fp(input logic [31:0] actual,expected);
    real delta,tolerance;
    if($isunknown(actual)) return 0;
    if(actual==expected) return 1;
    if(actual[30:23]==255 || expected[30:23]==255) return 0;
    delta=dea8_behavioral_fp_pkg::fp_real(actual)-dea8_behavioral_fp_pkg::fp_real(expected);
    if(delta<0.0) delta=-delta;
    tolerance=dea8_behavioral_fp_pkg::fp_real(expected);
    if(tolerance<0.0) tolerance=-tolerance;
    return delta<=2.0e-6+2.0e-6*tolerance;
  endfunction
  dea8_attention_core #(.USE_KVB(1),.V_KEY_LANE_IS_COLUMN(1)) dut (.*);
  // GCore receives one Top Job, then emits the entire fixed K/V sequence.
  initial begin : kv_producer
    matrix_block_job_t transport_job;
    wait(rst_n && start_valid && start_ready);
    @(posedge clk);
    for(int job_index=0;job_index<MATRIX_JOB_COUNT;job_index++) begin
      @(negedge clk);
      transport_job=attention_block_job(job_index,start_head,start_epoch);
      kvb_kind=transport_job.op==MATRIX_PV;
      kvb_blk_id=transport_job.ctx.block_id; kvb_epoch=transport_job.ctx.epoch;
      kvb_valid_mask='0;
      for(int k=0;k<TILE;k++)
        kvb_valid_mask[k]=int'(kvb_blk_id)*TILE+k<LOGICAL_SEQ;
      for(int t=0;t<HEAD_TILES;t++) for(int n=0;n<TILE;n++) begin
        if(SOFTMAX_MODEL) begin
          kvb_e=transport_job.op==MATRIX_QK ? 129 : 133;
          for(int k=0;k<TILE;k++) kvb_q[k*ACT_BITS+:ACT_BITS]=ACT_BITS'(
            transport_job.op==MATRIX_QK ? int'(transport_job.ctx.block_id)+1+n%3 :
            (int'(transport_job.ctx.block_id)*3+k*2+(t*TILE+n)*5)%15-7);
        end
        kvb_valid=1; kvb_feat_blk=TILE_IDX_BITS'(t); kvb_key_lane=TILE_IDX_BITS'(n);
        kvb_last=t==HEAD_TILES-1 && n==TILE-1;
        do @(posedge clk); while(!kvb_ready);
        @(negedge clk);
      end
      kvb_valid=0;
    end
  end
  always @(posedge clk) if(rst_n && vpu_valid && vpu_ready && vpu_cmd.op==VPU_QK_POST) begin
    if(!vpu_key_mask_valid || kvb_protocol_error) $fatal(1,"Mask context missing");
    for(int k=0;k<TILE;k++)
      if(vpu_key_mask[k] !== (int'(vpu_cmd.ctx.block_id)*TILE+k<LOGICAL_SEQ))
        $fatal(1,"VPU QK_POST mask mismatch");
  end
  // Default preserves the historical identity fixture. SOFTMAX_MODEL uses
  // nonuniform Q/K/V, padding mask, nonidentity alpha, and independent Python
  // expected PV/AFIN values. MXU/DEQACC and all memories remain real RTL.
  dea8_vpu_stub #(.SOFTMAX_MODEL(SOFTMAX_MODEL)) vpu_model (.jobs(vpu_jobs),.*);
  dea8_sfu_stub #(.SOFTMAX_MODEL(SOFTMAX_MODEL)) sfu_model (.jobs(sfu_jobs),.*);
  always @(posedge clk) if(rst_n && dut.mem_wr_en) begin
    if(current_job.op==MATRIX_QK) begin
      // The fixture's 16 K-tiles contribute equal integer dot products.
      if(SOFTMAX_MODEL) for(int n=0;n<TILE;n++)
        if(dut.mem_wr_data[n*FP_BITS+:FP_BITS] !== dea8_behavioral_fp_pkg::real_fp(
           real'(1+(qk_commits%SUFFIX_LEN)%3)*
           (int'(current_job.ctx.block_id)+1+n%3)*
           (1+(qk_commits%MATRIX_WORDS)/SUFFIX_LEN)/HEAD_TILES))
          $fatal(1,"Softmax QK oracle mismatch");
      qk_commits++;
    end
    else begin
      if(SOFTMAX_MODEL) for(int n=0;n<TILE;n++)
        if(!close_fp(dut.mem_wr_data[n*FP_BITS+:FP_BITS],expected_pv[pv_commits][n*FP_BITS+:FP_BITS]))
          $fatal(1,"Softmax PV oracle mismatch block=%0d word=%0d lane=%0d got=%h expected=%h",
            current_job.ctx.block_id,pv_commits%MATRIX_WORDS,n,
            dut.mem_wr_data[n*FP_BITS+:FP_BITS],expected_pv[pv_commits][n*FP_BITS+:FP_BITS]);
      pv_commits++;
    end
  end
  always @(posedge clk) begin : timing_monitor
    matrix_block_job_t expected_job;
    cycles++;
    if(rst_n) begin
      if(start_valid && start_ready) top_cycle=cycles;
      if(dut.matrix_valid && dut.matrix_ready) begin
        expected_job=attention_block_job(matrix_jobs,start_head,start_epoch);
        if(dut.matrix_cmd!==expand_matrix_job(expected_job)) $fatal(1,"Full attention job order");
        $fdisplay(logfd,"matrix_start,%0d,%0d,%0d",dut.matrix_cmd.op,dut.matrix_cmd.ctx.block_id,cycles-top_cycle);
        if(dut.matrix_cmd.op==MATRIX_PV && dut.matrix_cmd.ctx.block_id==N_KV_BLOCK-1) begin
          pv54_start=cycles;
          if(!tail_scaled || tail_writes!=MATRIX_WORDS || tail_scale_done>=cycles ||
             pv54_start-pv53_done<MATRIX_STEADY_BUDGET)
            $fatal(1,"PV54 started before tail slot/scaling committed");
        end
        matrix_jobs++;
      end
      if(dut.matrix_done_valid && dut.matrix_done_ready) begin
        if(SOFTMAX_MODEL && last_matrix_done>=0 &&
           !(current_job.op==MATRIX_PV && current_job.ctx.block_id==N_KV_BLOCK-1) &&
           cycles-last_matrix_done!=MATRIX_STEADY_BUDGET)
          $fatal(1,"Full attention ordinary block interval is not 828");
        $fdisplay(logfd,"matrix_done,%0d,%0d,%0d",current_job.op,current_job.ctx.block_id,cycles-top_cycle);
        if(first_matrix_done<0) first_matrix_done=cycles;
        last_matrix_done=cycles;matrix_finishes++;
        if(current_job.op==MATRIX_PV && current_job.ctx.block_id==N_KV_BLOCK-2) begin
          pv53_done=cycles;
          if(dut.matrix.engine.sequencer.bank_state_a!=BANK_READY &&
             dut.matrix.engine.sequencer.bank_state_b!=BANK_READY)
            $fatal(1,"PV54 tile0 not prefetched before tail slot");
        end
        if(current_job.op==MATRIX_PV && current_job.ctx.block_id==N_KV_BLOCK-1) pv54_done=cycles;
      end
      if(vpu_valid && vpu_ready) begin
        $fdisplay(logfd,"vpu_start,%0d,%0d,%0d",vpu_cmd.op,vpu_cmd.ctx.block_id,cycles-top_cycle);
        if(vpu_cmd.op==VPU_OACC_SCALE) begin
          scale_jobs++;
          if(vpu_cmd.ctx.block_id==N_KV_BLOCK-1) tail_scale_start=cycles;
        end
      end
      if(vpu_wr_valid && vpu_wr_ready && vpu_done.op==VPU_OACC_SCALE && vpu_done.ctx.block_id==N_KV_BLOCK-1) begin
        if(tail_first_write<0) tail_first_write=cycles;
        tail_last_write=cycles;tail_writes++;
        if(matrix_busy) $fatal(1,"Matrix ran during tail OACC scaling");
      end
      if(vpu_done_valid && vpu_done_ready) begin
        $fdisplay(logfd,"vpu_done,%0d,%0d,%0d",vpu_done.op,vpu_done.ctx.block_id,cycles-top_cycle);
        if(vpu_done.op==VPU_OACC_SCALE && vpu_done.ctx.block_id==N_KV_BLOCK-1) begin
          tail_scale_done=cycles;tail_scaled=1;
          if(tail_writes!=MATRIX_WORDS) $fatal(1,"Tail SCALE incomplete writes");
        end
      end
      if(sfu_valid && sfu_ready)
        $fdisplay(logfd,"sfu_start,%0d,%0d,%0d",sfu_cmd.op,sfu_cmd.ctx.block_id,cycles-top_cycle);
      if(sfu_done_valid && sfu_done_ready)
        $fdisplay(logfd,"sfu_done,%0d,%0d,%0d",sfu_done.op,sfu_done.ctx.block_id,cycles-top_cycle);
      if(SOFTMAX_MODEL && vpu_l_wr_en &&
         !close_fp(vpu_l_wr_data,expected_scalar[int'(vpu_done.ctx.block_id)*SUFFIX_LEN+vpu_l_wr_row][3*FP_BITS+:FP_BITS]))
        $fatal(1,"Softmax l oracle mismatch");
      if(SOFTMAX_MODEL && alpha_wr_en) for(int n=0;n<SFU_LANES;n++) if(alpha_wr_mask[n] &&
         !close_fp(alpha_wr_data[n*FP_BITS+:FP_BITS],
           expected_scalar[int'(sfu_done.ctx.block_id)*SUFFIX_LEN+alpha_wr_base+n][2*FP_BITS+:FP_BITS]))
        $fatal(1,"Softmax alpha oracle mismatch");
      if(pv53_done>=0 && pv54_start<0 && (dut.matrix.engine.mul_valid || dut.matrix.engine.load_valid))
        $fatal(1,"MXU issued or loaded a phantom job during tail scale slot");
    end
  end
  initial begin
    logfd=$fopen(SOFTMAX_MODEL ? ($test$plusargs("TAIL_SLOW") ? "attention_full_slow_cycles.csv" :
      $test$plusargs("SKIP_TAIL_SCALE") ? "attention_full_negative_cycles.csv" : "attention_full_cycles.csv") :
      "attention_fixture_cycles.csv","w");
    $fdisplay(logfd,"event,op,block,cycle_from_top");
    if(SOFTMAX_MODEL) begin
      $readmemh("../test_vectors/attention_pv.hex",expected_pv);
      $readmemh("../test_vectors/attention_scalar.hex",expected_scalar);
      $readmemh("../test_vectors/attention_final.hex",expected_final);
    end
    repeat(3) @(negedge clk); rst_n=1;
    for(int r=0;r<SUFFIX_LEN;r++) for(int t=0;t<HEAD_TILES;t++) begin
      qoz_wr_en=1; qoz_wr_addr=QOZ_ADDR_BITS'(r*QOZ_TILES+t);
      if(SOFTMAX_MODEL) qoz_wr_data={TILE{ACT_BITS'(1+r%3)}};
      @(negedge clk);
    end
    qoz_wr_en=0; start_valid=1;
    do @(posedge clk); while(!start_ready);
    @(negedge clk); start_valid=0;
    wait(done_valid);
    @(negedge clk);
    if(qk_commits!=N_KV_BLOCK*SUFFIX_LEN*HEAD_TILES || pv_commits!=qk_commits ||
       vpu_jobs!=N_KV_BLOCK*3 || sfu_jobs!=N_KV_BLOCK*2+1) $fatal(1,"Integrated job counts");
    if(matrix_jobs!=MATRIX_JOB_COUNT || matrix_finishes!=MATRIX_JOB_COUNT || scale_jobs!=N_KV_BLOCK-1)
      $fatal(1,"Full attention matrix/scale counts");
    if(SOFTMAX_MODEL) begin
      if(!$test$plusargs("TAIL_SLOW") &&
         (pv54_start-pv53_done!=MATRIX_STEADY_BUDGET ||
          pv54_done-pv53_done!=2*MATRIX_STEADY_BUDGET ||
          pv54_done-top_cycle!=first_matrix_done-top_cycle+MATRIX_JOB_COUNT*MATRIX_STEADY_BUDGET))
        $fatal(1,"Full attention did not add exactly one 828-cycle tail slot");
      if($test$plusargs("TAIL_SLOW") && pv54_start-pv53_done<=MATRIX_STEADY_BUDGET)
        $fatal(1,"Slow VPU tail completion did not extend the slot");
      if(vpu_model.afin_count!=MATRIX_WORDS) $fatal(1,"AFIN vector count");
      for(int a=0;a<MATRIX_WORDS;a++) for(int n=0;n<TILE;n++)
        if(!close_fp(vpu_model.final_result[a][n*FP_BITS+:FP_BITS],expected_final[a][n*FP_BITS+:FP_BITS]))
          $fatal(1,"AFIN oracle mismatch addr=%0d lane=%0d",a,n);
      if(tail_last_write-tail_first_write!=MATRIX_WORDS-1) $fatal(1,"SCALE not one vector per cycle");
    end
    $display("ATTENTION_TIMING functional=%0d matrix_done=%0d full_done=%0d cold=%0d",
      SOFTMAX_MODEL,pv54_done-top_cycle,cycles-top_cycle,first_matrix_done-top_cycle);
    $display("TAIL_TIMING pv53_done=%0d scale_start=%0d first_write=%0d last_write=%0d scale_done=%0d pv54_start=%0d pv54_done=%0d gap=%0d",
      pv53_done-top_cycle,tail_scale_start-top_cycle,tail_first_write-top_cycle,tail_last_write-top_cycle,
      tail_scale_done-top_cycle,pv54_start-top_cycle,pv54_done-top_cycle,pv54_done-pv53_done);
    $fdisplay(logfd,"attention_done,0,0,%0d",cycles-top_cycle);$fclose(logfd);
    $display("tb_dea8_attention_core PASS: 55 QK/PV real jobs, 54 OACC scales, tail slot, AFIN; behavioral_softmax=%0d",SOFTMAX_MODEL);
    $finish;
  end
  initial begin #5000000; $fatal(1,"Attention core timeout"); end
endmodule

module tb_dea8_attention_core_softmax;
  tb_dea8_attention_core #(.SOFTMAX_MODEL(1)) test();
endmodule
