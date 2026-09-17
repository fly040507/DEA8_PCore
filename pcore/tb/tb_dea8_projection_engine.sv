`timescale 1ns/1ps
import dea8_pcore_pkg::*;
import dea8_job_pkg::*;
module tb_dea8_projection_engine;
  localparam int TOTAL_TILES=PROJ_N_TILES*PROJ_K_TILES;
  localparam int WORDS=TOTAL_TILES*SUFFIX_LEN;
  localparam int Q_WORDS=PROJ_N_TILES*SUFFIX_LEN;
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,clear=0,job_valid=0,job_ready,job_busy,job_done_valid,job_done_ready=0;
  logic [HEAD_BITS-1:0] job_head=3;
  logic [EPOCH_BITS-1:0] job_epoch=2;
  logic hbm_valid=0,hbm_ready;
  logic [HBM_BITS-1:0] hbm_data='0;
  logic xbc_valid=0,xbc_ready,xbc_last=0;
  logic [2*DW_ACT-1:0] xbc_q='0;
  logic [2*SCALE_BITS-1:0] xbc_e='0;
  logic [ROW_BITS-1:0] xbc_row='0;
  logic [PROJ_K_BITS-1:0] xbc_blk='0;
  logic [2*TILE-1:0] xbc_lane_mask='1;
  logic [EPOCH_BITS-1:0] xbc_epoch=0;
  logic post_cmd_valid,post_cmd_ready,post_rd_valid,post_rd_ready,post_rsp_valid;
  projection_post_job_t post_cmd,post_done;
  logic [ROW_BITS-1:0] post_rd_row;
  logic [DW_VEC-1:0] post_rsp_data;
  logic post_result_valid,post_result_ready,post_done_valid,post_done_ready;
  projection_q_result_t post_result;
  logic qoz_valid,protocol_error,qoz_rd_en=0,qoz_rd_ready,qoz_rsp_valid;
  logic [QOZ_ADDR_BITS-1:0] qoz_rd_addr=0;
  logic [DW_ACT-1:0] qoz_rd_data;
  logic [SCALE_BITS-1:0] qoz_rd_scale;
  logic commit_valid;
  pipe_tag_t commit_tag;
  deq_dest_t commit_dest;
  logic [DW_VEC-1:0] golden[0:WORDS-1],final_fp[0:Q_WORDS-1];
  logic [DW_PSUM-1:0] golden_psum[0:WORDS-1];
  logic [B_ENTRY_BITS-1:0] final_q[0:Q_WORDS-1];
  int cycle=0,issued=0,responses=0,writes=0,commits=0,qwrites=0,post_jobs=0;
  int hbm_beats=0,xbc_beats=0,start_cycle=0,completed_runs=0;
  int previous_mul=0,mul_count=0,boundary_waits=0,readbacks=0;
  int request_cycle[0:WORDS-1];
  int fd;
  bit stress=0,cancel_sources=0;
  dea8_projection_engine dut (.*);
  dea8_projection_vpu_stub vpu (.*);

  function automatic int a(input int row,kt,k);
    return row==0 ? 0 : (row*29+kt*11+k*7)%256-128;
  endfunction
  function automatic int w(input int nt,kt,k,n);
    return (nt*31+kt*17+k*13+n*19)%256-128;
  endfunction
  function automatic int ea(input int row,kt);return 125+(row+kt*3)%9;endfunction
  function automatic int ew(input int nt,kt,n);return 125+(nt*3+kt+n*5)%9;endfunction

  task automatic send_hbm;
    for(int nt=0;nt<PROJ_N_TILES;nt++) for(int kt=0;kt<PROJ_K_TILES;kt++)
      for(int beat=0;beat<HBM_BEATS_PER_TILE;beat++) begin
        @(negedge clk);if(cancel_sources) return;
        if(stress && (kt+beat)%13==0) begin
          hbm_valid=0;repeat(9) @(negedge clk);if(cancel_sources) return;
        end
        hbm_data='1;
        if(beat<WEIGHT_HBM_BEATS_PER_TILE)
          for(int half=0;half<WEIGHT_WORDS_PER_HBM;half++) for(int n=0;n<TILE;n++)
            hbm_data[(half*TILE+n)*WEIGHT_BITS+:WEIGHT_BITS]=
              WEIGHT_BITS'(w(nt,kt,beat*WEIGHT_WORDS_PER_HBM+half,n));
        else for(int n=0;n<TILE;n++) hbm_data[n*SCALE_BITS+:SCALE_BITS]=SCALE_BITS'(ew(nt,kt,n));
        hbm_valid=1;
        do begin @(posedge clk);if(cancel_sources) return;end while(!hbm_ready);
      end
    @(negedge clk);hbm_valid=0;
  endtask
  task automatic send_xbc;
    for(int nt=0;nt<PROJ_N_TILES;nt++) for(int pair=0;pair<PROJ_K_TILES;pair+=2)
      for(int row=0;row<SUFFIX_LEN;row++) begin
        @(negedge clk);if(cancel_sources) return;
        if(stress && row%11==0) begin
          xbc_valid=0;repeat(7) @(negedge clk);if(cancel_sources) return;
        end
        xbc_row=ROW_BITS'(row);xbc_blk=PROJ_K_BITS'(pair);xbc_epoch=job_epoch;
        if($test$plusargs("BAD_XBC")) xbc_epoch=job_epoch+1'b1;
        xbc_last=pair==PROJ_K_TILES-2 && row==SUFFIX_LEN-1;
        for(int half=0;half<2;half++) begin
          xbc_e[half*SCALE_BITS+:SCALE_BITS]=SCALE_BITS'(ea(row,pair+half));
          for(int k=0;k<TILE;k++) xbc_q[half*DW_ACT+k*ACT_BITS+:ACT_BITS]=ACT_BITS'(a(row,pair+half,k));
        end
        xbc_valid=1;
        do begin @(posedge clk);if(cancel_sources) return;end while(!xbc_ready);
      end
    @(negedge clk);xbc_valid=0;
  endtask

  always @(posedge clk) begin : check_path
    int row,kt,nt,index;
    cycle++;
    if(!rst_n || clear) begin
      issued=0;responses=0;writes=0;commits=0;qwrites=0;post_jobs=0;
      hbm_beats=0;xbc_beats=0;mul_count=0;boundary_waits=0;
    end else begin
      if(job_valid && job_ready) begin
        issued=0;responses=0;writes=0;commits=0;qwrites=0;post_jobs=0;
        hbm_beats=0;xbc_beats=0;mul_count=0;boundary_waits=0;start_cycle=cycle;
      end
      if(hbm_valid && hbm_ready) hbm_beats++;
      if(xbc_valid && xbc_ready) xbc_beats++;
      if(dut.req_valid) begin
        row=issued%SUFFIX_LEN;kt=(issued/SUFFIX_LEN)%PROJ_K_TILES;nt=issued/(SUFFIX_LEN*PROJ_K_TILES);
        if(!dut.req_ready || dut.req_tag.row!=row || dut.req_tag.kt!=kt || dut.req_tag.nt!=nt)
          $fatal(1,"Projection A schedule mismatch");
        for(int k=0;k<TILE;k++) if($signed(dut.activation[k*ACT_BITS+:ACT_BITS])!=a(row,kt,k))
          $fatal(1,"Projection XBC payload mismatch");
        if(dut.e_stream!=ea(row,kt)) $fatal(1,"Projection A scale mismatch");
        request_cycle[issued]=cycle;issued++;
      end
      if(dut.mul_valid) begin
        if(mul_count%SUFFIX_LEN!=0 && cycle-previous_mul!=1) $fatal(1,"Projection stalled inside tile");
        if(mul_count!=0 && cycle-previous_mul>1) boundary_waits++;
        previous_mul=cycle;mul_count++;
      end
      if(dut.accum.deq_wr_en) begin
        if(dut.mem_wr_data!==golden[writes]) $fatal(1,"Projection FP32 oracle mismatch vector=%0d",writes);
        writes++;
      end
      if(commit_valid) commits++;
      if(post_cmd_valid && post_cmd_ready) begin
        if(post_cmd.nt!=post_jobs || writes!=(post_jobs+1)*PROJ_K_TILES*SUFFIX_LEN)
          $fatal(1,"Projection post command before reduction complete");
        $fdisplay(fd,"post_cmd,%0d,%0d",post_jobs,cycle-start_cycle);post_jobs++;
      end
      if(post_result_valid && post_result_ready) begin
        index=int'(post_result.job.nt)*SUFFIX_LEN+int'(post_result.row);
        if({post_result.data,post_result.scale}!==final_q[index])
          $fatal(1,"Projection QOZ quantization oracle mismatch vector=%0d",index);
        if(dut.qoz.wr_addr!=post_result.row*QOZ_TILES+post_result.job.nt)
          $fatal(1,"Projection QOZ address mismatch");
        qwrites++;
      end
      if(protocol_error) $fatal(1,"Projection unexpected protocol error");
    end
    #1;
    if(rst_n && !clear && dut.state_q!=dut.ABORTING) begin
      if(dut.rsp_valid) begin
        row=responses%SUFFIX_LEN;kt=(responses/SUFFIX_LEN)%PROJ_K_TILES;
        nt=responses/(SUFFIX_LEN*PROJ_K_TILES);
        if(cycle-request_cycle[responses]!=MXU_STAGES-1) $fatal(1,"Projection MXU latency mismatch");
        for(int n=0;n<TILE;n++) begin
          if(dut.psum[n]!==golden_psum[responses][n*PSUM_BITS+:PSUM_BITS])
            $fatal(1,"Projection INT32 dot mismatch rsp=%0d row=%0d nt=%0d kt=%0d lane=%0d got=%0d expected=%0d",responses,row,nt,kt,n,$signed(dut.psum[n]),$signed(golden_psum[responses][n*PSUM_BITS+:PSUM_BITS]));
          if(dut.e_stat[n]!=ew(nt,kt,n)) $fatal(1,"Projection stationary scale mismatch");
        end
        responses++;
      end
      if(post_rsp_valid) begin
        index=int'(post_cmd.nt)*SUFFIX_LEN+int'(post_rd_row);
        if(post_rsp_data!==final_fp[index]) $fatal(1,"Projection final FACC readback mismatch");
      end
    end
  end

  task automatic run_job(input bit abort_job);
    @(negedge clk);cancel_sources=0;job_valid=1;job_done_ready=0;
    do @(posedge clk);while(!job_ready);
    @(negedge clk);job_valid=0;
    fork
      send_hbm();
      send_xbc();
      begin
        if(abort_job) begin
          if($test$plusargs("CLEAR_POST")) wait(qwrites>=10);
          else wait(writes>=15);
          @(negedge clk);cancel_sources=1;clear=1;hbm_valid=0;xbc_valid=0;
          @(negedge clk);clear=0;
          while(!job_ready) begin
            @(negedge clk);
            if(commit_valid || dut.accum.deq_wr_en || dut.qoz_write || job_done_valid || qoz_valid)
              $fatal(1,"Projection stale side effect during clear drain");
          end
        end else begin
          wait(job_done_valid);@(negedge clk);
          if(issued!=WORDS || responses!=WORDS || writes!=WORDS || commits!=WORDS ||
             qwrites!=Q_WORDS || post_jobs!=PROJ_N_TILES || !qoz_valid ||
             hbm_beats!=TOTAL_TILES*HBM_BEATS_PER_TILE || xbc_beats!=WORDS/2)
            $fatal(1,"Projection completion counts mismatch i=%0d rsp=%0d w=%0d c=%0d q=%0d",issued,responses,writes,commits,qwrites);
          $display("PROJECTION_TIMING cycles=%0d tiles=%0d partial_vectors=%0d qoz_vectors=%0d boundary_waits=%0d",cycle-start_cycle,TOTAL_TILES,writes,qwrites,boundary_waits);
          $fdisplay(fd,"job_done,%0d,%0d",completed_runs,cycle-start_cycle);
          repeat(5) begin @(negedge clk);if(!job_done_valid || !qoz_valid) $fatal(1,"Projection done not held");end
          job_done_ready=1;@(negedge clk);job_done_ready=0;
          completed_runs++;
        end
      end
    join
    hbm_valid=0;xbc_valid=0;
    if(!abort_job) begin
      for(int nt=0;nt<PROJ_N_TILES;nt++) for(int row=0;row<SUFFIX_LEN;row++) begin
        @(negedge clk);qoz_rd_en=1;qoz_rd_addr=QOZ_ADDR_BITS'(row*QOZ_TILES+nt);
        @(posedge clk);#2;
        if(!qoz_rsp_valid || {qoz_rd_data,qoz_rd_scale}!==final_q[nt*SUFFIX_LEN+row])
          $fatal(1,"Projection final QOZ RAM readback mismatch nt=%0d row=%0d",nt,row);
        readbacks++;
      end
      @(negedge clk);qoz_rd_en=0;
    end
  endtask
  initial begin
    stress=$test$plusargs("STALL");
    fd=$fopen(stress ? "projection_stall_cycles.csv" :
      ($test$plusargs("CLEAR_RESTART") ? "projection_restart_cycles.csv" :
      ($test$plusargs("CLEAR_POST") ? "projection_clear_post_cycles.csv" :
      ($test$plusargs("REPEAT") ? "projection_repeat_cycles.csv" :
      (($test$plusargs("BAD_XBC") || $test$plusargs("EARLY_DONE") ||
        $test$plusargs("BAD_RESULT") || $test$plusargs("BAD_QUANT")) ?
        "projection_negative_cycles.csv" : "projection_cycles.csv")))),"w");
    $fdisplay(fd,"event,nt_or_run,cycle_from_job");
    $readmemh("test_vectors/projection_acc.txt",golden);
    $readmemh("test_vectors/projection_psum.txt",golden_psum);
    $readmemh("test_vectors/projection_final.txt",final_fp);
    $readmemh("test_vectors/projection_qoz.txt",final_q);
    repeat(3) @(negedge clk);rst_n=1;
    if($test$plusargs("CLEAR_RESTART") || $test$plusargs("CLEAR_POST")) begin run_job(1);job_epoch=5;end
    run_job(0);
    if($test$plusargs("REPEAT")) begin job_epoch=7;run_job(0);end
    if(readbacks!=completed_runs*Q_WORDS) $fatal(1,"Projection readback coverage missing");
    $display("tb_dea8_projection_engine PASS: full 51x1024x256, every INT32/FP32 partial, actual VPU quant, QOZ data+scale readback; runs=%0d",completed_runs);
    $fclose(fd);$finish;
  end
  initial begin #6000000;$fatal(1,"Projection watchdog");end
endmodule
