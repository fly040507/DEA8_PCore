`timescale 1ns/1ps
import pcore3_pkg::*;

// Independent protocol model for the CURRENT scheduler; no Matrix RTL needed.
// Two accepted Matrix descriptors, independent VPU/SFU latencies and backpressure.
module tb_v3_attention_scheduler;
  localparam int BLOCKS=55,JOBS=110,GUARD=31;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,start_valid=0,start_ready,busy,done_valid,done_ready=0;
  logic [2:0] start_head=2;logic [EPOCH_BITS-1:0] start_epoch=3;
  logic matrix_valid,matrix_ready=0,matrix_done_valid=0,matrix_done_ready,tail_launch_ready;
  matrix_cmd_t matrix_cmd,matrix_done,mqueue[0:JOBS-1];
  logic vpu_valid,vpu_ready=0,vpu_done_valid=0,vpu_done_ready;
  vpu_cmd_t vpu_cmd,vpu_done;
  logic sfu_valid,sfu_ready=0,sfu_done_valid=0,sfu_done_ready;
  sfu_cmd_t sfu_cmd,sfu_done;
  int accepted=0,completed=0,executed=0,vc=0,sc=0;
  int mt=-1,vt=-1,st=-1,cycle=0,phase=0,tail_commit=-1;
  int matrix_stalls=0,vpu_stalls=0,sfu_stalls=0,simultaneous=0;
  bit qk_done[BLOCKS],qpost[BLOCKS],alpha[BLOCKS],pexp[BLOCKS],pready[BLOCKS],scaled[BLOCKS],pv_done[BLOCKS];
  bit reciprocal=0,afin=0,ms=0,vs=0,ss=0,ds=0;
  matrix_cmd_t held_m;vpu_cmd_t held_v;sfu_cmd_t held_s;
  logic [31:0] rng=32'hdeca5511;
  string corrupt;
  dea8_attention_scheduler_v4 #(.BLOCKS(BLOCKS),.TAIL_SCALE_SLOT_CYCLES(GUARD)) dut(.*);
  function automatic matrix_cmd_t expected(input int index);
    matrix_cmd_t c;int b;
    c='0;c.mode=MAT_ATTENTION;c.m_rows=ROWS;c.result_last=1;c.job_last=index==JOBS-1;
    c.epoch=start_epoch;c.head=start_head;
    if(index==0)begin b=0;c.op=MATRIX_QK;end
    else if(index==JOBS-1)begin b=BLOCKS-1;c.op=MATRIX_PV;end
    else if(index%2)begin b=(index+1)/2;c.op=MATRIX_QK;end
    else begin b=index/2-1;c.op=MATRIX_PV;end
    c.block_id=6'(b);c.a_id=c.op==MATRIX_PV?LOGICAL_ID_BITS'(b):0;
    c.b_id=LOGICAL_ID_BITS'(b*ATTN_K_TILES);c.out_tile=c.op==MATRIX_PV?4'(b):0;
    c.acc_sel=c.op==MATRIX_PV?ACC_OACC:(b%2?ACC_FACC_B:ACC_FACC_A);
    c.add_old=c.op==MATRIX_PV&&b!=0;c.exp_fold=c.op==MATRIX_QK?-4:0;return c;
  endfunction
  function automatic logic [31:0] next_rng(input logic [31:0] x);
    logic [31:0] a,b;a=x^(x<<13);b=a^(a>>17);return b^(b<<5);
  endfunction
  // Drive only on negedge; every completion remains asserted until accepted.
  always @(negedge clk) begin
    if(reset||clear)begin matrix_ready=0;vpu_ready=0;sfu_ready=0;matrix_done_valid=0;vpu_done_valid=0;sfu_done_valid=0;end
    else begin
      rng=next_rng(rng);
      matrix_ready=accepted-completed<2&&(phase==0||rng[0])&&(phase==0||cycle%101>16);
      vpu_ready=vt<0&&(phase==0||rng[1])&&(phase==0||cycle%271>80);
      sfu_ready=st<0&&(phase==0||rng[2])&&(phase==0||cycle%307>100);
      if(mt==0&&!matrix_done_valid)begin matrix_done=mqueue[completed];matrix_done_valid=1;
        if(corrupt=="MATRIX")matrix_done.epoch=matrix_done.epoch^1;end
      if(vt==0&&!vpu_done_valid)begin vpu_done_valid=1;if(corrupt=="VPU")vpu_done.head=vpu_done.head^1;end
      if(st==0&&!sfu_done_valid)begin sfu_done_valid=1;if(corrupt=="SFU")sfu_done.epoch=sfu_done.epoch^1;end
    end
  end
  always @(posedge clk) begin
    if(reset||clear)begin
      accepted=0;completed=0;executed=0;vc=0;sc=0;mt=-1;vt=-1;st=-1;cycle=0;tail_commit=-1;
      ms=0;vs=0;ss=0;ds=0;reciprocal=0;afin=0;
      for(int b=0;b<BLOCKS;b++)begin qk_done[b]=0;qpost[b]=0;alpha[b]=0;pexp[b]=0;pready[b]=0;scaled[b]=b==0;pv_done[b]=0;end
    end else begin
      cycle++;
      if(ms&&(!matrix_valid||matrix_cmd!==held_m))$fatal(1,"Matrix command changed while stalled");
      if(vs&&(!vpu_valid||vpu_cmd!==held_v))$fatal(1,"VPU command changed while stalled");
      if(ss&&(!sfu_valid||sfu_cmd!==held_s))$fatal(1,"SFU command changed while stalled");
      if(ds&&!done_valid)$fatal(1,"Attention done not held");
      ms=matrix_valid&&!matrix_ready;vs=vpu_valid&&!vpu_ready;ss=sfu_valid&&!sfu_ready;ds=done_valid&&!done_ready;
      held_m=matrix_cmd;held_v=vpu_cmd;held_s=sfu_cmd;
      matrix_stalls+=int'(ms);vpu_stalls+=int'(vs);sfu_stalls+=int'(ss);
      if((int'(matrix_done_valid&&matrix_done_ready)+int'(vpu_done_valid&&vpu_done_ready)+int'(sfu_done_valid&&sfu_done_ready))>1)simultaneous++;
      if(matrix_valid&&matrix_ready)begin
        if(accepted>=JOBS||matrix_cmd!==expected(accepted))$fatal(1,"Matrix order/generation mismatch %0d",accepted);
        if(matrix_cmd.job_last&&!pv_done[BLOCKS-2])$fatal(1,"tail descriptor accepted before previous PV commit");
        mqueue[accepted]=matrix_cmd;accepted++;
      end
      if(vpu_valid&&vpu_ready)begin
        if(vt>=0)$fatal(1,"VPU duplicate command");
        if(vpu_cmd.epoch!=start_epoch||vpu_cmd.head!=start_head||vpu_cmd.block_id>=BLOCKS)$fatal(1,"VPU generation mismatch");
        case(vpu_cmd.op)
          VPU_QK_POST: if(!qk_done[vpu_cmd.block_id]||qpost[vpu_cmd.block_id])$fatal(1,"QK_POST dependency/duplicate");
          VPU_P_POST: if(!pexp[vpu_cmd.block_id]||pready[vpu_cmd.block_id])$fatal(1,"P_POST dependency/duplicate");
          VPU_OACC_SCALE: if(!alpha[vpu_cmd.block_id]||scaled[vpu_cmd.block_id])$fatal(1,"SCALE dependency/duplicate");
          VPU_AFIN: if(!reciprocal||afin)$fatal(1,"AFIN dependency/duplicate");
          default:$fatal(1,"unexpected VPU opcode");
        endcase
        vpu_done=vpu_cmd;vt=phase==0?1:(vpu_cmd.block_id%3==0?190:3+int'(rng[6:3]));vc++;
      end
      if(sfu_valid&&sfu_ready)begin
        if(st>=0)$fatal(1,"SFU duplicate command");
        if(sfu_cmd.epoch!=start_epoch||sfu_cmd.head!=start_head||sfu_cmd.block_id>=BLOCKS)$fatal(1,"SFU generation mismatch");
        case(sfu_cmd.op)
          SFU_ALPHA_EXP: if(!qpost[sfu_cmd.block_id]||alpha[sfu_cmd.block_id])$fatal(1,"ALPHA dependency/duplicate");
          SFU_P_EXP: if(!alpha[sfu_cmd.block_id]||pexp[sfu_cmd.block_id])$fatal(1,"P_EXP dependency/duplicate");
          SFU_RECIP: if(!pv_done[BLOCKS-1]||reciprocal)$fatal(1,"RECIP dependency/duplicate");
          default:$fatal(1,"unexpected SFU opcode");
        endcase
        sfu_done=sfu_cmd;st=phase==0?1:(sfu_cmd.block_id%4==0?230:2+int'(rng[10:7]));sc++;
      end
      if(mt>0)mt--;if(vt>0)vt--;if(st>0)st--;
      if(matrix_done_valid&&matrix_done_ready)begin
        if(matrix_done!==expected(completed))begin
          if(corrupt!="MATRIX")$fatal(1,"unexpected matrix completion");
        end else begin
          if(matrix_done.op==MATRIX_QK)qk_done[matrix_done.block_id]=1;
          else begin pv_done[matrix_done.block_id]=1;if(matrix_done.block_id==BLOCKS-2)tail_commit=cycle;end
        end
        completed++;mt=-1;
        // Nonblocking deassert avoids racing the scheduler's assertion.
        matrix_done_valid<=0;
      end
      if(vpu_done_valid&&vpu_done_ready)begin
        case(vpu_done.op)
          VPU_QK_POST:qpost[vpu_done.block_id]=1;
          VPU_P_POST:pready[vpu_done.block_id]=1;
          VPU_OACC_SCALE:scaled[vpu_done.block_id]=1;
          VPU_AFIN:afin=1;
          default:;
        endcase
        vt=-1;vpu_done_valid<=0;
      end
      if(sfu_done_valid&&sfu_done_ready)begin
        case(sfu_done.op)
          SFU_ALPHA_EXP:alpha[sfu_done.block_id]=1;
          SFU_P_EXP:pexp[sfu_done.block_id]=1;
          SFU_RECIP:reciprocal=1;
          default:;
        endcase
        st=-1;sfu_done_valid<=0;
      end
      if(mt<0&&completed<accepted&&(!mqueue[completed].job_last||tail_launch_ready))begin
        if(mqueue[completed].op==MATRIX_PV)begin
          if(!pready[mqueue[completed].block_id]||!scaled[mqueue[completed].block_id])$fatal(1,"PV launched before P/scale committed");
          if(mqueue[completed].job_last&&(tail_commit<0||cycle-tail_commit<GUARD))$fatal(1,"full tail guard shortened");
        end
        mt=phase==0?17:4+int'(rng[15:12]);executed++;
      end
      if(done_valid&&(!afin||completed!=JOBS||executed!=JOBS||vc!=3*BLOCKS||sc!=2*BLOCKS+1))
        $fatal(1,"job coverage mismatch matrix=%0d/%0d vpu=%0d sfu=%0d",completed,executed,vc,sc);
      if(cycle>200000)$fatal(1,"scheduler watchdog");
    end
  end
  initial begin
    corrupt="";
    if($test$plusargs("BAD_MATRIX"))corrupt="MATRIX";
    if($test$plusargs("BAD_VPU"))corrupt="VPU";
    if($test$plusargs("BAD_SFU"))corrupt="SFU";
    repeat(5)@(negedge clk);reset=0;
    for(int run=0;run<2;run++)begin
      phase=run;start_epoch=EPOCH_BITS'(3+run);start_head=3'(2+run);
      @(negedge clk);start_valid=1;@(negedge clk);start_valid=0;
      wait(done_valid);repeat(7)@(negedge clk);done_ready=1;@(negedge clk);done_ready=0;
      @(negedge clk);if(busy)$fatal(1,"scheduler failed to retire job");
      @(negedge clk);clear=1;@(negedge clk);clear=0;
    end
    if(corrupt!="")$fatal(1,"Expected corruption rejection was not triggered");
    if(!matrix_stalls||!vpu_stalls||!sfu_stalls||!simultaneous)$fatal(1,"missing stall/simultaneous completion coverage");
    $display("tb_v3_attention_scheduler PASS scheduler=v4 runs=2 jobs_per_run=110 matrix_stalls=%0d vpu_stalls=%0d sfu_stalls=%0d simultaneous_done=%0d",matrix_stalls,vpu_stalls,sfu_stalls,simultaneous);$finish;
  end
endmodule
