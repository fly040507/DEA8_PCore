`timescale 1ns/1ps
import pcore3_pkg::*;

module tb_v3_attention_matrix;
  localparam int TOTAL_TILES=32;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic cmd_valid,cmd_ready,done_valid,done_ready=1;
  matrix_cmd_t cmd,done_cmd;
  logic xbc_valid,xbc_ready; xbc4_t xbc_entry;
  logic replay_load_valid,replay_load_ready; xbc4_t replay_load_entry;
  logic hbm_valid,hbm_ready; b2_t hbm_entry;
  logic kv_valid,kv_ready; b2_t kv_entry;
  logic a_error,b_error; int done_count;

  dea8_attention_matrix_v3 dut(
    .clk,.reset,.clear,.cmd_valid,.cmd_ready,.cmd,.done_valid,.done_ready,.done_cmd,
    .xbc_valid,.xbc_ready,.xbc_entry,.hbm_valid,.hbm_ready,.hbm_entry,
    .replay_load_valid,.replay_load_ready,.replay_load_entry,
    .kv_valid,.kv_ready,.kv_entry,.b_source(B_HBM),
    .a_protocol_error(a_error),.b_protocol_error(b_error));

  function automatic qvec16_t qv(input int value);
    qvec16_t t; begin t='0;t.scale=128;
      for(int k=0;k<TILE;k++)t.data[k*8+:8]=value[7:0];
      return t;
    end
  endfunction
  task automatic send_a(input int tile,input int group);
    xbc_entry='0;xbc_entry.tile_idx=tile;xbc_entry.group_idx=group;
    xbc_entry.row_valid=(group==XBC_GROUPS-1)?4'b0111:4'b1111;
    for(int r=0;r<4;r++)xbc_entry.row[r]=qv(r==1?2:1);
    do begin @(negedge clk);xbc_valid=1;end while(!xbc_ready);
    @(negedge clk);xbc_valid=0;
  endtask
  task automatic send_b(input int tile,input int group);
    hbm_entry='0;hbm_entry.tile_idx=tile;hbm_entry.group_idx=group;hbm_entry.epoch=1;
    hbm_entry.col[0]=qv(1);hbm_entry.col[1]=qv(1);
    do begin @(negedge clk);hbm_valid=1;end while(!hbm_ready);
    @(negedge clk);hbm_valid=0;
  endtask
  task automatic send_replay(input int group);
    replay_load_entry='0;replay_load_entry.tile_idx=16;replay_load_entry.group_idx=group;
    replay_load_entry.row_valid=(group==XBC_GROUPS-1)?4'b0111:4'b1111;
    for(int r=0;r<4;r++)replay_load_entry.row[r]=qv(3);
    do begin @(negedge clk);replay_load_valid=1;end while(!replay_load_ready);
    @(negedge clk);replay_load_valid=0;
  endtask
  task automatic send_cmd(input matrix_cmd_t c);
    do begin @(negedge clk);cmd=c;cmd_valid=1;end while(!cmd_ready);
    @(negedge clk);cmd_valid=0;
  endtask
  always @(posedge clk) #1 if(done_valid) begin
    done_count++;
    if(done_cmd.op==MATRIX_QK && done_count!=1)$fatal(1,"QK block order");
    if(done_cmd.op==MATRIX_PV && done_count!=2)$fatal(1,"PV block order");
  end
  initial begin
    matrix_cmd_t qk,pv;
    cmd_valid=0;xbc_valid=0;replay_load_valid=0;hbm_valid=0;kv_valid=0;done_count=0;
    qk='0;qk.mode=MAT_ATTENTION;qk.op=MATRIX_QK;qk.a_id=0;qk.b_id=0;qk.m_rows=ROWS;
    qk.acc_sel=ACC_FACC_A;qk.result_last=1;qk.job_last=0;qk.epoch=1;
    pv=qk;pv.op=MATRIX_PV;pv.a_id=16;pv.b_id=16;pv.acc_sel=ACC_OACC;
    pv.add_old=0;pv.job_last=1;
    repeat(20)@(negedge clk);reset=0;
    fork
      begin
        send_cmd(qk);
        wait(done_count==1);
        send_cmd(pv);
      end
      begin
        for(int t=0;t<16;t++)
          for(int g=0;g<XBC_GROUPS;g++)send_a(t,g);
      end
      begin
        for(int g=0;g<XBC_GROUPS;g++)send_replay(g);
      end
      begin
        for(int t=0;t<TOTAL_TILES;t++)
          for(int g=0;g<8;g++)send_b(t,g);
      end
    join
    wait(done_count==2);#1;
    if(a_error||b_error)$fatal(1,"Attention matrix ingress error");
    $display("tb_v3_attention_matrix PASS QK_tiles=16 PV_tiles=16 blocks=%0d",done_count);
    $finish;
  end
  initial begin #100000;
    $display("WATCH state=%0d cmd_ready=%0d matrix_start=%0d matrix_busy=%0d matrix_done=%0d aerr=%0d berr=%0d req=%0d ac=%0d bc=%0d ts=%0d",
      dut.state_q,dut.cmd_ready,dut.matrix_start_q,dut.matrix_busy,dut.matrix_done,a_error,b_error,
      dut.matrix.req_valid,dut.matrix.a_count,dut.matrix.b_count,dut.matrix.tile_seq_q);
    $display("  a_run=%0d a_avail=%0d a_out=%0d acpl=%0d b_avail=%0d br=%b bt0=%0d bt1=%0d",
      dut.matrix.a_running,dut.matrix.a_tile_available,dut.matrix.a_out_valid,
      dut.matrix.a_complete,dut.matrix.b_tile_available,dut.matrix.bank_ready,
      dut.matrix.bank_tile[0],dut.matrix.bank_tile[1]);
    $display("  reserve=%0d started=%0d jobbusy=%0d cur=%0d next=%0d tiles=%0d ahead=%0d",
      dut.matrix.a_reserve,dut.matrix.tile_started_q,dut.matrix.job_busy_q,
      dut.matrix.current_b,dut.matrix.next_b,dut.matrix.tiles_q,dut.matrix.a_head.tile_idx);
    $fatal(1,"attention matrix watchdog");
  end
endmodule
