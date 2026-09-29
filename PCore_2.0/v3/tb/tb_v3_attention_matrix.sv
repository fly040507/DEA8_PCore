`timescale 1ns/1ps
import pcore3_pkg::*;
import dea8_fp32_v3_pkg::*;

module tb_v3_attention_matrix;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic cmd_valid,cmd_ready,done_valid,done_ready=1;
  matrix_cmd_t cmd,done_cmd;
  logic xbc_valid,xbc_ready; xbc4_t xbc_entry;
  logic replay_load_valid,replay_load_ready; xbc4_t replay_load_entry;
  logic hbm_valid,hbm_ready; b2_t hbm_entry;
  logic kv_valid,kv_ready; b2_t kv_entry;
  logic a_error,b_error; int done_count;
  logic dbg_valid,dbg_parity; acc_sel_e dbg_sel; logic [9:0] dbg_addr;
  logic [3:0] dbg_lane; logic [31:0] dbg_data;
  logic [31:0] oacc0[0:15];
  logic [31:0] pv0[0:15];

  dea8_attention_matrix_v3 dut(
    .clk,.reset,.clear,.cmd_valid,.cmd_ready,.cmd,.done_valid,.done_ready,.done_cmd,
    .xbc_valid,.xbc_ready,.xbc_entry,
    .replay_load_valid,.replay_load_ready,.replay_load_entry,
    .hbm_valid,.hbm_ready,.hbm_entry,.kv_valid,.kv_ready,.kv_entry,.b_source(B_HBM),
    .a_protocol_error(a_error),.b_protocol_error(b_error),
    .result_rd_owner(ACC_READ_RESULT),.result_rd_valid(1'b0),.result_rd_sel(ACC_OACC),
    .result_rd_addr('0),.result_rd_data_valid(),.result_even_data(),.result_odd_data(),
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);

  function automatic qvec16_t qv(input int value,input int scale);
    qvec16_t t; begin
      t='0;t.scale=scale[7:0];
      for(int k=0;k<TILE;k++) t.data[k*8+:8]=value[7:0];
      return t;
    end
  endfunction

  task automatic send_cmd(input matrix_cmd_t c);
    do begin @(negedge clk);cmd=c;cmd_valid=1;end while(!cmd_ready);
    @(negedge clk);cmd_valid=0;
  endtask

  task automatic send_a(input int tile,input int group);
    xbc_entry='0;xbc_entry.tile_idx=tile[TILE_BITS-1:0];xbc_entry.group_idx=group;
    xbc_entry.slot=0;xbc_entry.row_valid=(group==XBC_GROUPS-1)?4'b0111:4'b1111;
    xbc_entry.row[0]=qv(1,128);xbc_entry.row[1]=qv(2,128);
    xbc_entry.row[2]=qv(1,128);xbc_entry.row[3]=qv(1,128);
    do begin @(negedge clk);xbc_valid=1;end while(!xbc_ready);
    @(negedge clk);xbc_valid=0;
  endtask

  task automatic send_b(input int tile,input int group,input int value);
    hbm_entry='0;hbm_entry.tile_idx=tile[TILE_BITS-1:0];hbm_entry.group_idx=group;
    hbm_entry.epoch=1;hbm_entry.col[0]=qv(value,128);hbm_entry.col[1]=qv(value,128);
    do begin @(negedge clk);hbm_valid=1;end while(!hbm_ready);
    @(negedge clk);hbm_valid=0;
  endtask

  task automatic send_replay(input int slot,input int group,input int value);
    replay_load_entry='0;replay_load_entry.tile_idx=slot;replay_load_entry.group_idx=group;
    replay_load_entry.slot=slot[0];
    replay_load_entry.row_valid=(group==XBC_GROUPS-1)?4'b0111:4'b1111;
    for(int r=0;r<4;r++) replay_load_entry.row[r]=qv(value,128);
    do begin @(negedge clk);replay_load_valid=1;end while(!replay_load_ready);
    @(negedge clk);replay_load_valid=0;
  endtask

  task automatic run_qk(input int block,input int a_base,input int b_base);
    matrix_cmd_t c; int target;
    c='0;c.mode=MAT_ATTENTION;c.op=MATRIX_QK;c.block_id=block;
    c.a_id=0;c.b_id=block*ATTN_K_TILES;c.m_rows=ROWS;
    c.acc_sel=block[0]?ACC_FACC_B:ACC_FACC_A;c.result_last=1;c.job_last=0;c.epoch=1;
    target=done_count+1;
    fork
      begin send_cmd(c); end
      begin for(int t=0;t<ATTN_K_TILES;t++) for(int g=0;g<XBC_GROUPS;g++) send_a(a_base+t,g); end
      begin for(int t=0;t<ATTN_K_TILES;t++) for(int g=0;g<8;g++) send_b(b_base+t,g,1); end
    join
    wait(done_count==target);
  endtask

  task automatic run_pv(input int block,input int b_base);
    matrix_cmd_t c; int target;
    c='0;c.mode=MAT_ATTENTION;c.op=MATRIX_PV;c.block_id=block;
    c.a_id=block;c.b_id=block*ATTN_K_TILES;c.m_rows=ROWS;
    c.acc_sel=ACC_OACC;c.add_old=(block!=0);c.result_last=1;c.job_last=block==1;c.epoch=1;
    target=done_count+1;
    fork
      begin send_cmd(c); end
      begin for(int t=0;t<ATTN_K_TILES;t++) for(int g=0;g<8;g++) send_b(b_base+t,g,1); end
    join
    wait(done_count==target);
  endtask

  task automatic read_oacc(input int nt,output logic [31:0] value);
    dbg_valid=1;dbg_sel=ACC_OACC;dbg_parity=0;dbg_addr=oacc_addr(0,nt);dbg_lane=0;#1;
    value=dbg_data;
  endtask

  always @(posedge clk) #1 if(done_valid) begin
    done_count++;
    if(done_cmd.op==MATRIX_PV && done_count<3) $fatal(1,"PV completed before both QK blocks");
  end

  initial begin
    cmd_valid=0;xbc_valid=0;replay_load_valid=0;hbm_valid=0;kv_valid=0;done_count=0;
    dbg_valid=0;dbg_sel=ACC_OACC;dbg_parity=0;dbg_addr=0;dbg_lane=0;
    repeat(20)@(negedge clk);reset=0;

    // P0 can be loaded before QK0.  P1 is deliberately loaded while QK1 is
    // running, proving that the alternate PBUF bank is independent.
    fork
      begin for(int g=0;g<XBC_GROUPS;g++) send_replay(0,g,1); end
      begin run_qk(0,0,0); end
    join
    fork
      begin run_qk(1,16,16); end
      begin for(int g=0;g<XBC_GROUPS;g++) send_replay(1,g,1); end
    join
    run_pv(0,32);
    for(int nt=0;nt<16;nt++) begin
      read_oacc(nt,pv0[nt]);
      if(pv0[nt]===32'b0) $fatal(1,"PV0 OACC nt%0d was not written",nt);
    end
    run_qk(2,48,48);
    run_pv(1,64);
    #1;
    if(a_error||b_error) $fatal(1,"Attention matrix protocol error a=%0d b=%0d",a_error,b_error);
    if(done_count!=5) $fatal(1,"Attention block count=%0d",done_count);

    // PV0 writes one value per N tile; PV1 uses add_old on the same OACC
    // addresses.  Since both test PVs use the same P/V operands, every lane
    // must be exactly FP32(PV0+PV0), proving replay, address selection and
    // cross-block accumulation rather than only checking done pulses.
    for(int nt=0;nt<16;nt++) begin
      read_oacc(nt,oacc0[nt]);
      if(oacc0[nt]!==fp32_add(pv0[nt],pv0[nt]))
        $fatal(1,"OACC add_old mismatch nt%0d old=%h new=%h expected=%h",
          nt,pv0[nt],oacc0[nt],fp32_add(pv0[nt],pv0[nt]));
    end
    $display("tb_v3_attention_matrix PASS QK=3 PV=2 PBUF_banks=2 replay_nt=16 OACC_add_old=1");
    $finish;
  end
  initial begin #250000;$fatal(1,"attention matrix watchdog");end
endmodule
