`timescale 1ns/1ps
import pcore3_pkg::*;
import fp32_legacy_ref_pkg::*;

module tb_v3_attention_matrix;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic cmd_valid,cmd_ready,done_valid,done_ready=1;
  matrix_cmd_t cmd,done_cmd;
  logic qoz_load_valid=0,qoz_load_ready; a2_t qoz_load_entry;
  logic q_store_wr_ready;
  logic qoz_begin_valid=0,qoz_begin_ready,qoz_active,qoz_complete;
  logic qoz_release_valid=0,qoz_release_ready;
  logic qoz_rd_valid,qoz_rd_ready;
  logic [3:0] qoz_rd_tile;
  logic [PAIR_BITS-1:0] qoz_rd_pair;
  logic [TILE_BITS-1:0] qoz_rd_transport;
  logic qoz_out_valid,qoz_out_ready;
  a2_t qoz_out_entry;
  logic qoz_error;
  logic replay_load_valid,replay_load_ready; a2_t replay_load_entry;
  logic [5:0] replay_load_block;
  logic hbm_valid,hbm_ready; b2_t hbm_entry;
  logic kv_valid,kv_ready; b2_t kv_entry;
  logic a_error,b_error; int done_count;
  logic dbg_valid,dbg_parity; acc_sel_e dbg_sel; logic [9:0] dbg_addr;
  logic [3:0] dbg_lane; logic [31:0] dbg_data;
  logic [31:0] oacc0[0:15];
  logic [31:0] pv0[0:15];
  logic tail_launch_ready=1;
  matrix_cmd_t accepted_cmds[0:15];int accept_count=0;

  dea8_qoz_store_v3 q_store(
    .clk,.reset,.clear,
    .region_begin_valid(qoz_begin_valid),.region_begin_ready(qoz_begin_ready),
    .region_owner(QOZ_Q),.region_epoch(4'd1),.region_head(3'd0),.region_tiles(6'd16),
    .region_active(qoz_active),.region_complete(qoz_complete),
    .region_release_valid(qoz_release_valid),.region_release_ready(qoz_release_ready),
    .wr_valid(qoz_load_valid),.wr_ready(q_store_wr_ready),.wr_owner(QOZ_Q),
    .wr_tile(qoz_load_entry.tile_idx),.wr_pair(qoz_load_entry.pair_idx),
    .wr_row_valid(qoz_load_entry.row_valid),.wr_even(qoz_load_entry.row[0]),
    .wr_odd(qoz_load_entry.row[1]),.wr_epoch(4'd1),.wr_head(3'd0),
    .rd_valid(qoz_rd_valid),.rd_ready(qoz_rd_ready),.rd_owner(QOZ_Q),
    .rd_tile({2'b0,qoz_rd_tile}),.rd_pair(qoz_rd_pair),.rd_transport(qoz_rd_transport),
    .rd_out_valid(qoz_out_valid),.rd_out_ready(qoz_out_ready),.rd_entry(qoz_out_entry),
    .active_epoch(),.active_head(),.active_owner(),.protocol_error(qoz_error));

  dea8_attention_matrix_v3 #(.EXTERNAL_QOZ(1'b1)) dut(
    .tail_launch_ready,
    .clk,.reset,.clear,.cmd_valid,.cmd_ready,.cmd,.done_valid,.done_ready,.done_cmd,
    .qoz_load_valid,.qoz_load_ready,.qoz_load_entry,.qoz_load_epoch(4'd1),.qoz_load_head(3'd0),
    .replay_load_valid,.replay_load_ready,.replay_load_entry,
    .replay_load_epoch(4'd1),.replay_load_head(3'd0),.replay_load_block,
    .qoz_ext_load_ready(q_store_wr_ready),
    .qoz_ext_rd_valid(qoz_rd_valid),.qoz_ext_rd_ready(qoz_rd_ready),
    .qoz_ext_rd_tile(qoz_rd_tile),.qoz_ext_rd_pair(qoz_rd_pair),
    .qoz_ext_rd_transport(qoz_rd_transport),
    .qoz_ext_out_valid(qoz_out_valid),.qoz_ext_out_ready(qoz_out_ready),
    .qoz_ext_out_entry(qoz_out_entry),.qoz_ext_complete(qoz_complete),
    .qoz_ext_epoch(4'd1),.qoz_ext_head(3'd0),
    .vpu_wr_valid(1'b0),.vpu_wr('0),.vpu_wr_ready(),.result_rd_ready(),
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
    @(negedge clk);cmd=c;cmd_valid=1;
    do @(posedge clk); while(!cmd_ready);
    @(negedge clk);cmd_valid=0;
  endtask

  task automatic send_a(input int tile,input int group);
    @(negedge clk);
    qoz_load_entry='0;qoz_load_entry.tile_idx=TILE_BITS'(tile);qoz_load_entry.pair_idx=PAIR_BITS'(group);
    qoz_load_entry.row_valid=row_mask(group);
    qoz_load_entry.row[0]=qv(1,128);qoz_load_entry.row[1]=qv((group%2==0)?2:1,128);
    qoz_load_valid=1;
    do @(posedge clk); while(!q_store_wr_ready);
    @(negedge clk);qoz_load_valid=0;
  endtask

  task automatic send_b(input int tile,input int group,input int value);
    hbm_entry='0;hbm_entry.tile_idx=tile[TILE_BITS-1:0];hbm_entry.group_idx=group;
    hbm_entry.epoch=1;hbm_entry.col[0]=qv(value,128);hbm_entry.col[1]=qv(value,128);
    do begin @(negedge clk);hbm_valid=1;end while(!hbm_ready);
    @(negedge clk);hbm_valid=0;
  endtask

  task automatic send_replay(input int slot,input int group,input int value);
    @(negedge clk);
    replay_load_entry='0;replay_load_entry.pair_idx=PAIR_BITS'(group);replay_load_block=6'(slot);
    replay_load_entry.slot=slot[0];
    replay_load_entry.row_valid=row_mask(group);
    for(int r=0;r<2;r++) replay_load_entry.row[r]=qv(value,128);
    replay_load_valid=1;
    do @(posedge clk); while(!replay_load_ready);
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

  always @(posedge clk) begin
    if(reset||clear)begin accept_count=0;done_count=0;end
    else begin
      if(cmd_valid&&cmd_ready)begin accepted_cmds[accept_count]=cmd;accept_count++;end
      if(done_valid&&done_ready)begin
        if(done_count>=accept_count||done_cmd!==accepted_cmds[done_count])
          $fatal(1,"wrapper completion order/context mismatch");
        done_count++;
      end
    end
  end

  initial begin
    cmd_valid=0;replay_load_valid=0;hbm_valid=0;kv_valid=0;done_count=0;
    qoz_begin_valid=0;qoz_release_valid=0;
    dbg_valid=0;dbg_sel=ACC_OACC;dbg_parity=0;dbg_addr=0;dbg_lane=0;
    repeat(20)@(negedge clk);reset=0;
    @(negedge clk);qoz_begin_valid=1;
    do @(posedge clk); while(!qoz_begin_ready);
    @(negedge clk);qoz_begin_valid=0;
    for(int t=0;t<ATTN_K_TILES;t++) for(int p=0;p<PAIRS;p++) send_a(t,p);

    // P0 can be loaded before QK0.  P1 is deliberately loaded while QK1 is
    // running, proving that the alternate PBUF bank is independent.
    fork
      begin for(int g=0;g<PAIRS;g++) send_replay(0,g,1); end
      begin run_qk(0,0,0); end
    join
    fork
      begin run_qk(1,16,16); end
      begin for(int g=0;g<PAIRS;g++) send_replay(1,g,1); end
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
    if(!qoz_complete||!qoz_active) $fatal(1,"external QOZ did not complete Q region");
    @(negedge clk);qoz_release_valid=1;
    do @(posedge clk); while(!qoz_release_ready);
    @(negedge clk);qoz_release_valid=0;

    // Completion backpressure must not let the next launch replace cmd_q.
    @(negedge clk);clear=1;
    @(negedge clk);clear=0;done_ready=0;
    @(negedge clk);qoz_begin_valid=1;
    do @(posedge clk); while(!qoz_begin_ready);
    @(negedge clk);qoz_begin_valid=0;
    for(int t=0;t<ATTN_K_TILES;t++)for(int p=0;p<PAIRS;p++)send_a(t,p);
    fork
      begin
        matrix_cmd_t c;
        c='0;c.mode=MAT_ATTENTION;c.op=MATRIX_QK;c.m_rows=ROWS;c.epoch=1;c.result_last=1;c.acc_sel=ACC_FACC_A;
        send_cmd(c);c.block_id=1;c.b_id=16;c.acc_sel=ACC_FACC_B;send_cmd(c);
      end
      begin for(int t=0;t<32;t++)for(int g=0;g<8;g++)send_b(t,g,1);end
      begin
        matrix_cmd_t held;
        wait(done_valid);@(negedge clk);held=done_cmd;
        repeat(30)begin
          @(negedge clk);
          if(!done_valid||done_cmd!==held||dut.launch_fire||done_count!=0)
            $fatal(1,"completion backpressure lost current descriptor");
        end
        done_ready=1;
      end
    join
    wait(done_count==2);
    // Accept PV before producer completion; source-ready must change without
    // a descriptor change. Then hold launch while its A credit is prefetched.
    tail_launch_ready=0;
    fork
      begin
        matrix_cmd_t c;
        c='0;c.mode=MAT_ATTENTION;c.op=MATRIX_PV;c.m_rows=ROWS;c.epoch=1;
        c.acc_sel=ACC_OACC;c.result_last=1;c.job_last=1;
        send_cmd(c);repeat(20)@(negedge clk);
        if(!dut.pending_valid_q||dut.source_ready||dut.launch_fire)$fatal(1,"pending PV did not wait for P");
        for(int p=0;p<PAIRS;p++)send_replay(0,p,1);
        repeat(20)@(negedge clk);
        if(!dut.source_ready||!dut.prefetched_q||dut.matrix.a_count<4||dut.launch_fire)
          $fatal(1,"tail source did not prefetch while launch blocked");
        tail_launch_ready=1;
      end
      begin for(int t=32;t<48;t++)for(int g=0;g<8;g++)send_b(t,g,1);end
    join
    wait(done_count==3);
    if(a_error||b_error||qoz_error)$fatal(1,"delayed source protocol error a=%0d b=%0d qoz=%0d",a_error,b_error,qoz_error);
    // A full parity bank is insufficient: PV must match block, epoch and head.
    for(int scenario=0;scenario<3;scenario++) begin
      @(negedge clk);clear=1;cmd_valid=0;
      @(negedge clk);clear=0;
      for(int p=0;p<PAIRS;p++) send_replay(0,p,1);
      @(negedge clk);cmd='0;cmd.mode=MAT_ATTENTION;cmd.op=MATRIX_PV;cmd.m_rows=ROWS;
      cmd.epoch=(scenario==1)?2:1;cmd.head=(scenario==2)?1:0;
      cmd.block_id=(scenario==0)?2:0;cmd.a_id=cmd.block_id;cmd_valid=1;
      #1;if(cmd_ready) $fatal(1,"stale PBUF command accepted scenario=%0d",scenario);
      @(posedge clk);#1;if(!a_error) $fatal(1,"stale PBUF command not diagnosed");
      @(negedge clk);cmd_valid=0;
    end
    $display("tb_v3_attention_matrix PASS QK=3 PV=2 PBUF_banks=2 replay_nt=16 OACC_add_old=1 stale_context_cases=3 done_backpressure=1 delayed_source=1 tail_prefetch=1");
    $finish;
  end
  initial begin #250000;$fatal(1,"attention matrix watchdog");end
endmodule
