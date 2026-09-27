`timescale 1ns/1ps
import pcore3_pkg::*;

module tb_v3_attention_scheduler;
  localparam int BLOCKS=KV_BLOCKS;
  localparam int TAIL=MATRIX_STEADY_BUDGET;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic start_valid=0,start_ready,busy,done_valid,done_ready=0;
  logic [2:0] start_head=3; logic [EPOCH_BITS-1:0] start_epoch=4'h7;
  logic matrix_valid,matrix_ready=1,matrix_done_valid=0,matrix_done_ready;
  matrix_cmd_t matrix_cmd,matrix_done;
  logic vpu_valid,vpu_ready=1,vpu_done_valid=0,vpu_done_ready;
  vpu_cmd_t vpu_cmd,vpu_done;
  logic sfu_valid,sfu_ready=1,sfu_done_valid=0,sfu_done_ready;
  sfu_cmd_t sfu_cmd,sfu_done;
  int cycle_count=0,m_count=0,p_count=0,qk_count=0,pv_count=0;
  int matrix_accept_cycle[0:2*BLOCKS-1];
  logic [5:0] matrix_block[0:2*BLOCKS-1];
  logic matrix_is_qk[0:2*BLOCKS-1];
  int m_delay,v_delay,s_delay;
  matrix_cmd_t m_hold; vpu_cmd_t v_hold; sfu_cmd_t s_hold;
  logic m_active,v_active,s_active;

  dea8_attention_scheduler_v3 #(.BLOCKS(BLOCKS),.TAIL_SCALE_SLOT_CYCLES(TAIL)) dut(
    .clk,.reset,.clear,.start_valid,.start_ready,.busy,.start_head,.start_epoch,
    .done_valid,.done_ready,.matrix_valid,.matrix_ready,.matrix_cmd,
    .matrix_done_valid,.matrix_done_ready,.matrix_done,
    .vpu_valid,.vpu_ready,.vpu_cmd,.vpu_done_valid,.vpu_done_ready,.vpu_done,
    .sfu_valid,.sfu_ready,.sfu_cmd,.sfu_done_valid,.sfu_done_ready,.sfu_done);

  always @(posedge clk) begin
    if(reset||clear) begin
      cycle_count<=0;m_count<=0;p_count<=0;m_active<=0;v_active<=0;s_active<=0;
      matrix_done_valid<=0;vpu_done_valid<=0;sfu_done_valid<=0;
    end else begin
      cycle_count<=cycle_count+1;
      if(matrix_done_valid&&matrix_done_ready) begin matrix_done_valid<=0;m_active<=0;end
      if(vpu_done_valid&&vpu_done_ready) begin vpu_done_valid<=0;v_active<=0;end
      if(sfu_done_valid&&sfu_done_ready) begin sfu_done_valid<=0;s_active<=0;end
      if(m_active&&!matrix_done_valid) begin
        if(m_delay!=0)m_delay<=m_delay-1;
        else begin matrix_done<=m_hold;matrix_done_valid<=1;end
      end
      if(v_active&&!vpu_done_valid) begin
        if(v_delay!=0)v_delay<=v_delay-1;
        else begin vpu_done<=v_hold;vpu_done_valid<=1;end
      end
      if(s_active&&!sfu_done_valid) begin
        if(s_delay!=0)s_delay<=s_delay-1;
        else begin sfu_done<=s_hold;sfu_done_valid<=1;end
      end
      if(matrix_valid&&matrix_ready) begin
        if(m_active)$fatal(1,"matrix model overlap");
        m_hold<=matrix_cmd;m_delay<=5;m_active<=1;
        matrix_accept_cycle[m_count]=cycle_count;
        matrix_block[m_count]=matrix_cmd.block_id;
        matrix_is_qk[m_count]=(matrix_cmd.op==MATRIX_QK);
        m_count++;
      end
      if(vpu_valid&&vpu_ready) begin v_hold<=vpu_cmd;v_delay<=1;v_active<=1;end
      if(sfu_valid&&sfu_ready) begin s_hold<=sfu_cmd;s_delay<=1;s_active<=1;end
      if(matrix_done_valid&&matrix_done_ready) begin
        if(matrix_done.op==MATRIX_QK) qk_count++; else pv_count++;
      end
    end
  end

  initial begin
    repeat(20)@(negedge clk);reset=0;
    @(negedge clk);start_valid=1;
    @(negedge clk);start_valid=0;
    wait(done_valid);
    if(m_count!=2*BLOCKS||qk_count!=BLOCKS||pv_count!=BLOCKS)
      $fatal(1,"matrix count m=%0d qk=%0d pv=%0d",m_count,qk_count,pv_count);
    for(int oi=0;oi<2*BLOCKS;oi++) begin
      if(oi==0 && (!matrix_is_qk[oi]||matrix_block[oi]!=0)) $fatal(1,"QK/PV startup order mismatch at %0d",oi);
      else if(oi==2*BLOCKS-1 && (matrix_is_qk[oi]||matrix_block[oi]!=BLOCKS-1)) $fatal(1,"tail PV order mismatch at %0d",oi);
      else if(oi>0 && oi<2*BLOCKS-1 && oi[0] && (!matrix_is_qk[oi]||matrix_block[oi]!=(oi+1)/2)) $fatal(1,"QK order mismatch at %0d",oi);
      else if(oi>1 && oi<2*BLOCKS-1 && !oi[0] && (matrix_is_qk[oi]||matrix_block[oi]!=(oi/2)-1)) $fatal(1,"PV order mismatch at %0d",oi);
    end
    if(0 && (!matrix_is_qk[0]||matrix_block[0]!=0||
       !matrix_is_qk[1]||matrix_block[1]!=1||
       matrix_is_qk[2]||matrix_block[2]!=0||
       !matrix_is_qk[3]||matrix_block[3]!=2||
       matrix_is_qk[4]||matrix_block[4]!=1||
       !matrix_is_qk[5]||matrix_block[5]!=3||
       matrix_is_qk[6]||matrix_block[6]!=2||
       matrix_is_qk[7]||matrix_block[7]!=3))
      $display("legacy short-sequence check skipped for full BLOCKS=%0d",BLOCKS);
    if(matrix_accept_cycle[2*BLOCKS-1]-matrix_accept_cycle[2*BLOCKS-2]<TAIL)
      $fatal(1,"tail scale slot too short gap=%0d",matrix_accept_cycle[2*BLOCKS-1]-matrix_accept_cycle[2*BLOCKS-2]);
    done_ready=1;@(negedge clk);
    $display("tb_v3_attention_scheduler PASS QK=%0d PV=%0d matrix=%0d tail_gap=%0d budget=%0d",
      qk_count,pv_count,m_count,matrix_accept_cycle[2*BLOCKS-1]-matrix_accept_cycle[2*BLOCKS-2],MATRIX_STEADY_BUDGET);
    $finish;
  end
  initial begin #100000;$fatal(1,"attention scheduler watchdog");end
endmodule
