`timescale 1ns/1ps
import pcore3_pkg::*;
import dea8_fp32_v3_pkg::*;

// Full 55-KV-block matrix run. VPU/SFU arithmetic and external A/B/P supplies
// are TB models; scheduler, ingress, MXU, DEQACC and accumulators are RTL.
module tb_v3_attention_55;
  localparam int BLOCKS=KV_BLOCKS;
  localparam int JOBS=2*BLOCKS;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0;
  logic start_valid=0,start_ready,busy,done_valid,done_ready=1;
  logic [2:0] start_head=3'd2;
  logic [EPOCH_BITS-1:0] start_epoch=4'h5;
  logic matrix_valid,matrix_ready,matrix_done_valid,matrix_done_ready;
  matrix_cmd_t matrix_cmd,matrix_done;
  logic vpu_valid,vpu_ready=1,vpu_done_valid=0,vpu_done_ready;
  vpu_cmd_t vpu_cmd,vpu_done;
  logic sfu_valid,sfu_ready=1,sfu_done_valid=0,sfu_done_ready;
  sfu_cmd_t sfu_cmd,sfu_done;
  logic xbc_valid=0,xbc_ready; xbc4_t xbc_entry;
  logic replay_load_valid=0,replay_load_ready; xbc4_t replay_load_entry;
  logic hbm_valid=0,hbm_ready; b2_t hbm_entry;
  logic kv_valid=0,kv_ready; b2_t kv_entry;
  logic a_error,b_error;
  logic dbg_valid=0,dbg_parity=0; acc_sel_e dbg_sel=ACC_OACC;
  logic [9:0] dbg_addr=0; logic [3:0] dbg_lane=0; logic [31:0] dbg_data;
  int accepts=0,completions=0,checked=0,loads=0,a_beats=0,b_beats=0;
  int cycle_count=0,maximum_job_cycles=0,max_qk_cycles=0,max_pv_cycles=0;
  int accepted_cycle[0:JOBS-1];
  matrix_cmd_t accepted_cmd[0:JOBS-1];

  dea8_attention_scheduler_v3 #(.BLOCKS(BLOCKS)) scheduler(
    .clk,.reset,.clear,.start_valid,.start_ready,.busy,.start_head,.start_epoch,
    .done_valid,.done_ready,.matrix_valid,.matrix_ready,.matrix_cmd,
    .matrix_done_valid,.matrix_done_ready,.matrix_done,
    .vpu_valid,.vpu_ready,.vpu_cmd,.vpu_done_valid,.vpu_done_ready,.vpu_done,
    .sfu_valid,.sfu_ready,.sfu_cmd,.sfu_done_valid,.sfu_done_ready,.sfu_done);

  dea8_attention_matrix_v3 matrix(
    .clk,.reset,.clear,.cmd_valid(matrix_valid),.cmd_ready(matrix_ready),.cmd(matrix_cmd),
    .done_valid(matrix_done_valid),.done_ready(matrix_done_ready),.done_cmd(matrix_done),
    .xbc_valid,.xbc_ready,.xbc_entry,
    .replay_load_valid,.replay_load_ready,.replay_load_entry,
    .hbm_valid,.hbm_ready,.hbm_entry,.kv_valid,.kv_ready,.kv_entry,.b_source(B_HBM),
    .a_protocol_error(a_error),.b_protocol_error(b_error),
    .result_rd_owner(ACC_READ_RESULT),.result_rd_valid(1'b0),.result_rd_sel(ACC_OACC),
    .result_rd_addr('0),.result_rd_data_valid(),.result_even_data(),.result_odd_data(),
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);

  function automatic int q_value(input int row);
    return 1+(row%3);
  endfunction
  function automatic int p_value(input int block,input int row);
    return 1+(block%2)+((row%3)==1);
  endfunction
  function automatic int b_value(input int block,input int column);
    return 1+(block%3)+(column%2);
  endfunction
  function automatic qvec16_t qvec(input int value);
    qvec16_t v;
    v='0;v.scale=8'd128;
    for(int k=0;k<TILE;k++) v.data[k*8+:8]=8'(value);
    return v;
  endfunction
  function automatic logic [31:0] scaled_psum(input int psum,input int fold);
    int lead;
    logic [31:0] normalized;
    if(psum==0) return 32'b0;
    lead=0;
    for(int bit_idx=0;bit_idx<32;bit_idx++) if(psum[bit_idx]) lead=bit_idx;
    normalized=32'(psum) << (31-lead);
    return pack_scaled32(1'b0,normalized,128+128-DOT_EXP_OFFSET+fold+lead,1'b0,1'b0);
  endfunction
  function automatic logic [31:0] qk_expected(input int block,input int row,input int col);
    logic [31:0] partial,result;
    partial=scaled_psum(TILE*q_value(row)*b_value(block,col),-4);
    result=partial;
    for(int t=1;t<ATTN_K_TILES;t++) result=fp32_add(result,partial);
    return result;
  endfunction
  function automatic logic [31:0] pv_expected(input int block,input int row,input int col);
    logic [31:0] result,partial;
    result=0;
    for(int b=0;b<=block;b++) begin
      partial=scaled_psum(TILE*p_value(b,row)*b_value(b,col),0);
      result=(b==0)?partial:fp32_add(result,partial);
    end
    return result;
  endfunction

  task automatic send_a(input int tile,input int group);
    xbc4_t e;
    e='0;e.tile_idx=TILE_BITS'(tile);e.group_idx=4'(group);
    e.row_valid=(group==XBC_GROUPS-1)?4'b0111:4'b1111;
    for(int r=0;r<4;r++) e.row[r]=qvec(q_value(4*group+r));
    xbc_entry=e; xbc_valid=1;
    do begin @(posedge clk); end while(xbc_ready!==1'b1);
    @(negedge clk); xbc_valid=0;
  endtask
  task automatic send_b(input int tile,input int group,input int block);
    b2_t e;
    e='0;e.tile_idx=TILE_BITS'(tile);e.group_idx=3'(group);e.epoch=start_epoch;
    e.col[0]=qvec(b_value(block,2*group));
    e.col[1]=qvec(b_value(block,2*group+1));
    hbm_entry=e; hbm_valid=1;
    do begin @(posedge clk); end while(hbm_ready!==1'b1);
    @(negedge clk); hbm_valid=0;
  endtask
  task automatic send_replay(input int block,input int group);
    xbc4_t e; int guard;
    e='0;e.tile_idx=TILE_BITS'(block);e.slot=block[0];e.group_idx=4'(group);
    e.row_valid=(group==XBC_GROUPS-1)?4'b0111:4'b1111;
    for(int r=0;r<4;r++) e.row[r]=qvec(p_value(block,4*group+r));
    guard=0; replay_load_entry=e; replay_load_valid=1;
    do begin
      @(posedge clk); guard++;
      if(guard>100) $fatal(1,"replay load did not become ready block=%0d group=%0d",block,group);
    end while(replay_load_ready!==1'b1);
    @(negedge clk); replay_load_valid=0;
  endtask
  task automatic produce_job(input matrix_cmd_t c,input int stream_base);
    fork
      begin
        if(c.op==MATRIX_QK)
          for(int t=0;t<ATTN_K_TILES;t++)
            for(int g=0;g<XBC_GROUPS;g++) send_a(stream_base+t,g);
      end
      begin
        for(int t=0;t<ATTN_K_TILES;t++)
          for(int g=0;g<TILE/2;g++) send_b(stream_base+t,g,int'(c.block_id));
      end
    join
  endtask

  task automatic read_check(input acc_sel_e sel,input int row,input int col,
                            input logic [31:0] expected,input int block);
    dbg_valid=1;dbg_sel=sel;dbg_parity=row[0];
    dbg_addr=10'(sel==ACC_OACC?oacc_addr(row/2,col/TILE):row/2);
    dbg_lane=4'(col%TILE);
    #1;
    if(dbg_data!==expected)
      $fatal(1,"numeric mismatch block=%0d sel=%0d row=%0d col=%0d got=%h want=%h",
        block,sel,row,col,dbg_data,expected);
  endtask
  task automatic check_block(input matrix_cmd_t c);
    int b;
    b=int'(c.block_id);
    #1;
    if(c.op==MATRIX_QK) begin
      for(int r_sel=0;r_sel<3;r_sel++) begin
        int row;
        row=(r_sel==0)?0:((r_sel==1)?1:50);
        for(int n_sel=0;n_sel<3;n_sel++) begin
          int col;
          col=(n_sel==0)?0:((n_sel==1)?1:15);
          read_check(c.acc_sel,row,col,qk_expected(b,row,col),b);
        end
      end
    end else begin
      for(int r_sel=0;r_sel<3;r_sel++) begin
        int row;
        row=(r_sel==0)?0:((r_sel==1)?1:50);
        for(int n_sel=0;n_sel<4;n_sel++) begin
          int col;
          col=(n_sel==0)?0:((n_sel==1)?15:((n_sel==2)?128:255));
          read_check(ACC_OACC,row,col,pv_expected(b,row,col),b);
        end
      end
    end
    dbg_valid=0;
    checked++;
  endtask

  // One outstanding command per modeled unit. PBUF is populated by the VPU
  // post-P model; SFU exp takes its specified 408 cycles independently.
  initial begin : vpu_model
    vpu_cmd_t c;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(vpu_valid&&vpu_ready) begin
        c=vpu_cmd;
        if(c.op==VPU_P_POST) begin
          for(int g=0;g<XBC_GROUPS;g++) send_replay(int'(c.block_id),g);
          loads++;
          repeat(20) @(negedge clk);
        end else if(c.op==VPU_OACC_SCALE||c.op==VPU_AFIN)
          repeat(416) @(negedge clk);
        else repeat(20) @(negedge clk);
        @(negedge clk);vpu_done=c;vpu_done_valid=1;
        @(negedge clk);vpu_done_valid=0;
      end
    end
  end
  initial begin : sfu_model
    sfu_cmd_t c;
    wait(!reset);
    forever begin
      @(posedge clk);
      if(sfu_valid&&sfu_ready) begin
        c=sfu_cmd;
        if(c.op==SFU_P_EXP) repeat(408) @(negedge clk);
        else repeat(26) @(negedge clk);
        @(negedge clk);sfu_done=c;sfu_done_valid=1;
        @(negedge clk);sfu_done_valid=0;
      end
    end
  end

  always @(posedge clk) if(!reset&&!clear) begin
    int expected_block;
    matrix_op_e expected_op;
    cycle_count++;
    if(xbc_valid&&xbc_ready) a_beats++;
    if(hbm_valid&&hbm_ready) b_beats++;
    if(matrix_valid&&matrix_ready) begin
      if(accepts>=JOBS) $fatal(1,"extra matrix command");
      if(accepts==0) begin expected_op=MATRIX_QK;expected_block=0;end
      else if(accepts==JOBS-1) begin expected_op=MATRIX_PV;expected_block=BLOCKS-1;end
      else if(accepts%2) begin expected_op=MATRIX_QK;expected_block=(accepts+1)/2;end
      else begin expected_op=MATRIX_PV;expected_block=accepts/2-1;end
      if(matrix_cmd.op!=expected_op||matrix_cmd.block_id!=expected_block||
         matrix_cmd.a_id!=((expected_op==MATRIX_QK)?0:expected_block)||
         matrix_cmd.b_id!=expected_block*ATTN_K_TILES||
         matrix_cmd.add_old!=(expected_op==MATRIX_PV&&expected_block!=0))
        $fatal(1,"matrix command order/context mismatch index=%0d op=%0d block=%0d a=%0d b=%0d",
          accepts,matrix_cmd.op,matrix_cmd.block_id,matrix_cmd.a_id,matrix_cmd.b_id);
      accepted_cmd[accepts]=matrix_cmd;
      accepted_cycle[accepts]=cycle_count;
      accepts++;
      fork produce_job(matrix_cmd,TILE_BITS'((accepts-1)*ATTN_K_TILES)); join_none
    end
    if(matrix_done_valid&&matrix_done_ready) begin
      int job_cycles;
      if(completions>=accepts||matrix_done!==accepted_cmd[completions])
        $fatal(1,"matrix completion context mismatch index=%0d",completions);
      job_cycles=cycle_count-accepted_cycle[completions];
      if(job_cycles>maximum_job_cycles) maximum_job_cycles=job_cycles;
      if(matrix_done.op==MATRIX_QK && job_cycles>max_qk_cycles) max_qk_cycles=job_cycles;
      if(matrix_done.op==MATRIX_PV && job_cycles>max_pv_cycles) max_pv_cycles=job_cycles;
      completions++;
      fork check_block(matrix_done); join_none
      if(completions%20==0) $display("attention55 progress jobs=%0d/%0d cycle=%0d",completions,JOBS,cycle_count);
    end
    if(a_error||b_error) $fatal(1,"Attention ingress protocol error a=%0d b=%0d",a_error,b_error);
  end

  initial begin
    repeat(20) @(negedge clk);
    reset=0;
    @(negedge clk);start_valid=1;
    @(negedge clk);start_valid=0;
    wait(done_valid);
    wait(checked==JOBS);
    if(accepts!=JOBS||completions!=JOBS||loads!=BLOCKS||
       a_beats!=BLOCKS*ATTN_K_TILES*XBC_GROUPS||
       b_beats!=JOBS*ATTN_K_TILES*(TILE/2))
      $fatal(1,"coverage count accept=%0d complete=%0d loads=%0d A=%0d B=%0d",
        accepts,completions,loads,a_beats,b_beats);
    // Full final OACC comparison: every valid row and all 256 columns.
    for(int row=0;row<ROWS;row++)
      for(int col=0;col<TILE*TILE;col++)
        read_check(ACC_OACC,row,col,pv_expected(BLOCKS-1,row,col),BLOCKS-1);
    // Row 51 is invalid and must not have acquired an OACC valid bit.
    for(int col=0;col<TILE*TILE;col++) read_check(ACC_OACC,ROWS,col,0,BLOCKS-1);
    dbg_valid=0;
    $display("tb_v3_attention_55 PASS QK=%0d PV=%0d P_loads=%0d A_beats=%0d B_beats=%0d final_values=%0d max_qk_cycles=%0d max_pv_cycles=%0d max_job_cycles=%0d total_cycles=%0d",
      BLOCKS,BLOCKS,loads,a_beats,b_beats,ROWS*TILE*TILE,max_qk_cycles,max_pv_cycles,maximum_job_cycles,cycle_count);
    $finish;
  end
  initial begin #2000000;$fatal(1,"attention55 watchdog accept=%0d complete=%0d checked=%0d",accepts,completions,checked);end
endmodule

