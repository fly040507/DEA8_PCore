`timescale 1ns/1ps
import pcore3_pkg::*;

// Direct scheduler <-> Attention Matrix integration for two KV blocks.  The
// VPU/SFU are deliberately modeled as one-cycle command consumers; the test
// focuses on command context, stream sequencing, PBUF ownership and the real
// Matrix completion handshake.
module tb_v3_attention_system;
  localparam int BLOCKS=2;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic start_valid,start_ready,busy;
  logic [2:0] start_head=2; logic [EPOCH_BITS-1:0] start_epoch=4'h5;
  logic done_valid,done_ready=1;
  logic matrix_valid,matrix_ready; matrix_cmd_t matrix_cmd;
  logic matrix_done_valid,matrix_done_ready; matrix_cmd_t matrix_done;
  logic vpu_valid,vpu_ready=1; vpu_cmd_t vpu_cmd;
  logic vpu_done_valid,vpu_done_ready; vpu_cmd_t vpu_done;
  logic sfu_valid,sfu_ready=1; sfu_cmd_t sfu_cmd;
  logic sfu_done_valid,sfu_done_ready; sfu_cmd_t sfu_done;
  logic qoz_load_valid=0,qoz_load_ready; a2_t qoz_load_entry;
  logic replay_load_valid,replay_load_ready; a2_t replay_load_entry;
  logic [5:0] replay_load_block;
  logic hbm_valid,hbm_ready; b2_t hbm_entry;
  logic kv_valid,kv_ready; b2_t kv_entry;
  logic a_error,b_error; int matrix_accepts,matrix_done_count;

  dea8_attention_scheduler_v4 #(.BLOCKS(BLOCKS)) scheduler(
    .clk,.reset,.clear,.start_valid,.start_ready,.busy,.start_head,.start_epoch,
    .done_valid,.done_ready,.matrix_valid,.matrix_ready,.matrix_cmd,
    .matrix_done_valid,.matrix_done_ready,.matrix_done,
    .vpu_valid,.vpu_ready,.vpu_cmd,.vpu_done_valid,.vpu_done_ready,.vpu_done,
    .sfu_valid,.sfu_ready,.sfu_cmd,.sfu_done_valid,.sfu_done_ready,.sfu_done);

  dea8_attention_matrix_v3 matrix(
    .clk,.reset,.clear,.cmd_valid(matrix_valid),.cmd_ready(matrix_ready),.cmd(matrix_cmd),
    .done_valid(matrix_done_valid),.done_ready(matrix_done_ready),.done_cmd(matrix_done),
    .qoz_load_valid,.qoz_load_ready,.qoz_load_entry,.qoz_load_epoch(start_epoch),.qoz_load_head(start_head),
    .replay_load_valid,.replay_load_ready,.replay_load_entry,
    .replay_load_epoch(start_epoch),.replay_load_head(start_head),.replay_load_block,
    .vpu_wr_valid(1'b0),.vpu_wr('0),.vpu_wr_ready(),.result_rd_ready(),
    .hbm_valid,.hbm_ready,.hbm_entry,.kv_valid,.kv_ready,.kv_entry,.b_source(B_HBM),
    .a_protocol_error(a_error),.b_protocol_error(b_error),
    .result_rd_owner(ACC_READ_RESULT),.result_rd_valid(1'b0),.result_rd_sel(ACC_OACC),
    .result_rd_addr('0),.result_rd_data_valid(),.result_even_data(),.result_odd_data(),
    .dbg_valid(1'b0),.dbg_sel(ACC_OACC),.dbg_parity(1'b0),.dbg_addr('0),.dbg_lane('0),.dbg_data());

  function automatic qvec16_t qv(input int value);
    qvec16_t t; begin t='0;t.scale=128;for(int k=0;k<TILE;k++)t.data[k*8+:8]=value[7:0];return t;end
  endfunction

  task automatic send_replay(input int slot,input int group);
    @(negedge clk);
    replay_load_entry='0;replay_load_entry.slot=slot[0];replay_load_entry.pair_idx=PAIR_BITS'(group);
    replay_load_entry.row_valid=row_mask(group);replay_load_block=6'(slot);
    for(int r=0;r<2;r++)replay_load_entry.row[r]=qv(1);
    replay_load_valid=1;
    do @(posedge clk); while(!replay_load_ready);
    @(negedge clk);replay_load_valid=0;
  endtask

  task automatic send_a(input int tile,input int group);
    @(negedge clk);
    qoz_load_entry='0;qoz_load_entry.tile_idx=TILE_BITS'(tile);qoz_load_entry.pair_idx=PAIR_BITS'(group);
    qoz_load_entry.row_valid=row_mask(group);
    for(int r=0;r<2;r++)qoz_load_entry.row[r]=qv(r==1?2:1);
    qoz_load_valid=1;
    do @(posedge clk); while(!qoz_load_ready);
    @(negedge clk);qoz_load_valid=0;
  endtask

  task automatic send_b(input int tile,input int group);
    hbm_entry='0;hbm_entry.tile_idx=tile[TILE_BITS-1:0];hbm_entry.group_idx=group;hbm_entry.epoch=start_epoch;
    hbm_entry.col[0]=qv(1);hbm_entry.col[1]=qv(1);
    do begin @(negedge clk);hbm_valid=1;end while(!hbm_ready);
    @(negedge clk);hbm_valid=0;
  endtask

  task automatic produce_matrix_job(input int b_base);
    for(int t=0;t<ATTN_K_TILES;t++)
      for(int g=0;g<TILE/2;g++)
        send_b(b_base+t,g);
  endtask

  // Immediate one-cycle VPU/SFU models, with context returned unchanged.
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      vpu_done_valid<=0;sfu_done_valid<=0;
    end else begin
      vpu_done_valid<=0;sfu_done_valid<=0;
      if(vpu_valid&&vpu_ready) begin vpu_done<=vpu_cmd;vpu_done_valid<=1;end
      if(sfu_valid&&sfu_ready) begin sfu_done<=sfu_cmd;sfu_done_valid<=1;end
    end
  end

  always @(posedge clk) begin
    if(!reset&&!clear&&matrix_valid&&matrix_ready) begin
      matrix_accepts++;
    end
    if(!reset&&!clear&&matrix_done_valid&&matrix_done_ready) matrix_done_count++;
  end

  initial begin
    start_valid=0;replay_load_valid=0;hbm_valid=0;kv_valid=0;
    matrix_accepts=0;matrix_done_count=0;
    repeat(20)@(negedge clk);reset=0;
    for(int t=0;t<ATTN_K_TILES;t++) for(int p=0;p<PAIRS;p++) send_a(t,p);
    // Fill both PBUF banks before the scheduler starts.  The matrix adapter
    // still checks bank selection at each PV command boundary.
    for(int g=0;g<PAIRS;g++)send_replay(0,g);
    for(int g=0;g<PAIRS;g++)send_replay(1,g);
    @(negedge clk);start_valid=1;
    @(negedge clk);start_valid=0;
    wait(done_valid);
    if(matrix_accepts!=4||matrix_done_count!=4)
      $fatal(1,"scheduler/matrix count accept=%0d done=%0d",matrix_accepts,matrix_done_count);
    if(a_error||b_error) $fatal(1,"scheduler/matrix protocol error a=%0d b=%0d",a_error,b_error);
    $display("tb_v3_attention_system PASS scheduler_matrix_blocks=%0d QK=2 PV=2 PBUF=2",matrix_done_count);
    $finish;
  end
  // The lookahead scheduler may accept the next descriptor while the current
  // Matrix job is active.  Keep one ordered producer so BFIFO never sees
  // interleaved transport streams: QK0, QK1, PV0, PV1.
  initial begin : hbm_prefetch
    wait(!reset);
    @(negedge clk);
    produce_matrix_job(0);
    produce_matrix_job(ATTN_K_TILES);
    produce_matrix_job(2*ATTN_K_TILES);
    produce_matrix_job(3*ATTN_K_TILES);
  end
  initial begin #250000;$fatal(1,"attention system watchdog");end
endmodule
