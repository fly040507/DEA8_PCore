`timescale 1ns/1ps
import pcore3_pkg::*;
import fp32_legacy_ref_pkg::*;

// Full Q Projection check: [51,1024] x [1024,256] -> [51,256].
// A row0 is one and row1 is two.  B column c uses a distinct value
// (global_column mod 15)+1, so every output Tile and every lane is checked.
module tb_v3_projection;
  localparam int K_TILES=64,N_TILES=16;
  localparam bit LOCAL_A=0;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0,start=0;
  logic [EPOCH_BITS-1:0] epoch=1; logic [2:0] head=0;
  logic signed [EXP_FOLD_BITS-1:0] exp_fold=0;
  logic busy,done;
  logic [MATRIX_TILE_COUNT_BITS-1:0] job_k_tiles=K_TILES;
  logic [MATRIX_TILE_COUNT_BITS-1:0] job_n_tiles=N_TILES;
  logic local_a_valid=0,local_a_ready; a2_t local_a_entry='0;
  logic xbc_valid,xbc_ready; xbc4_t xbc_entry;
  logic hbm_valid,hbm_ready; b2_t hbm_entry;
  logic qoz_wr_valid; logic [TILE_BITS-1:0] qoz_wr_tile; logic [PAIR_BITS-1:0] qoz_wr_pair;
  logic [1:0] qoz_wr_row_valid; logic [15:0][31:0] qoz_even,qoz_odd;
  logic a_error,b_error; int outputs;
  logic qoz_wr_ready=0,stalled=0;
  logic [1034:0] held;
  int cycles=0,beats=0;
  always @(negedge clk) begin
    cycles++;
    qoz_wr_ready=(cycles%11>3)&&!(qoz_wr_tile==0&&cycles<4500);
  end

  dea8_projection_v3 dut(
    .clk,.reset,.clear,.start,.job_epoch(epoch),.job_head(head),.job_exp_fold(exp_fold),
    .job_k_tiles,.job_n_tiles,.job_a_source(LOCAL_A?A_LOCAL:A_XBC),.job_b_source(B_HBM),
    .local_a_valid,.local_a_entry,
    .busy,.done,.xbc_valid,.xbc_ready,.xbc_entry,.hbm_valid,.hbm_ready,.hbm_entry,
    .qoz_wr_valid,.qoz_wr_ready,.qoz_wr_tile,.qoz_wr_pair,.qoz_wr_row_valid,
    .qoz_wr_even_fp32(qoz_even),.qoz_wr_odd_fp32(qoz_odd),
    .matrix_a_protocol_error(a_error),.matrix_b_protocol_error(b_error));

  function automatic logic [31:0] expected_float(input int integer_sum);
    logic [31:0] mag,norm; int lead;
    begin
      mag=integer_sum; lead=0;
      for(int b=0;b<32;b++) if(mag[b]) lead=b;
      norm=mag << (31-lead);
      expected_float=pack_scaled32(0,norm,lead-10,0,0);
    end
  endfunction

  function automatic qvec16_t qv(input int value,input int scale);
    qvec16_t t; begin
      t='0;t.scale=scale[7:0];
      for(int k=0;k<TILE;k++) t.data[k*8+:8]=value[7:0];
      return t;
    end
  endfunction

  task automatic send_a4(input int tile,input int group);
    xbc_entry.tile_idx=tile[TILE_BITS-1:0];xbc_entry.group_idx=group[3:0];
    xbc_entry.slot=0;xbc_entry.reserved=0;
    xbc_entry.row_valid=(group==XBC_GROUPS-1)?4'b0111:4'b1111;
    xbc_entry.row[0]=qv(1,128);xbc_entry.row[1]=qv(2,128);
    xbc_entry.row[2]=qv(1,128);xbc_entry.row[3]=qv(1,128);
    do begin @(negedge clk);xbc_valid=1;end while(!xbc_ready);
    @(negedge clk);xbc_valid=0;
  endtask

  task automatic send_b2(input int n_tile,input int tile,input int group);
    int col0,col1; col0=n_tile*16+group*2;col1=col0+1;
    hbm_entry.tile_idx=tile[TILE_BITS-1:0];hbm_entry.group_idx=group[2:0];
    hbm_entry.epoch=1;hbm_entry.reserved=0;
    hbm_entry.col[0]=qv((col0%15)+1,128);hbm_entry.col[1]=qv((col1%15)+1,128);
    do begin @(negedge clk);hbm_valid=1;end while(!hbm_ready);
    @(negedge clk);hbm_valid=0;
  endtask

  task automatic send_local(input int tile,input int pair_id);
    @(negedge clk);
    local_a_entry='0;local_a_entry.tile_idx=TILE_BITS'(tile);
    local_a_entry.pair_idx=PAIR_BITS'(pair_id);local_a_entry.row_valid=row_mask(pair_id);
    local_a_entry.row[0]=qv(1,128);
    local_a_entry.row[1]=qv(pair_id%2==0?2:1,128);
    local_a_valid=1;
    do @(posedge clk);while(!local_a_ready);
    @(negedge clk);local_a_valid=0;
  endtask

  always @(posedge clk) begin
    if(stalled && (!qoz_wr_valid||{qoz_wr_tile,qoz_wr_pair,qoz_wr_row_valid,qoz_even,qoz_odd}!==held))
      $fatal(1,"Projection output changed under backpressure");
    stalled=qoz_wr_valid&&!qoz_wr_ready;
    held={qoz_wr_tile,qoz_wr_pair,qoz_wr_row_valid,qoz_even,qoz_odd};
    if(qoz_wr_valid&&qoz_wr_ready) begin
      int global_col,bval;
      if(qoz_wr_tile!=beats/PAIRS||qoz_wr_pair!=beats%PAIRS) $fatal(1,"Projection output reordered");
      beats++;
      global_col=qoz_wr_tile*16;
      for(int n=0;n<16;n++) begin
        bval=((global_col+n)%15)+1;
        if(qoz_even[n]!==expected_float(K_TILES*TILE*bval))
          $fatal(1,"Q Projection even mismatch tile=%0d pair=%0d lane=%0d got=%h",
            qoz_wr_tile,qoz_wr_pair,n,qoz_even[n]);
        // The stimulus repeats the XBC4 pattern on every group: its first
        // pair is 1/2 and its second pair is 1/1.  Pair 25 has one row.
        if(qoz_wr_row_valid[1]&&qoz_odd[n]!==expected_float(K_TILES*TILE*(qoz_wr_pair[0]==0?2:1)*bval))
          $fatal(1,"Q Projection odd mismatch tile=%0d pair=%0d lane=%0d got=%h",
            qoz_wr_tile,qoz_wr_pair,n,qoz_odd[n]);
      end
      if(qoz_wr_pair==PAIRS-1&&!qoz_wr_row_valid[1]) outputs++;
    end
  end

  initial begin
    xbc_valid=0;hbm_valid=0;outputs=0;
    repeat(20) @(negedge clk);reset=0;
    @(negedge clk);start=1;
    @(negedge clk);start=0;
    fork
      begin
        for(int nt=0;nt<N_TILES;nt++)
          for(int t=0;t<K_TILES;t++) begin
            if(LOCAL_A)for(int p=0;p<PAIRS;p++)send_local(t,p);
            else for(int g=0;g<XBC_GROUPS;g++)send_a4(t,g);
          end
      end
      begin
        for(int nt=0;nt<N_TILES;nt++)
          for(int t=0;t<K_TILES;t++) for(int g=0;g<8;g++) send_b2(nt,t,g);
      end
    join
    wait(done);#2;
    if(a_error||b_error) $fatal(1,"Projection ingress protocol error");
    if(outputs!=N_TILES) $fatal(1,"QOZ output Tile count=%0d expected=%0d",outputs,N_TILES);
    $display("tb_v3_projection PASS shape=[%0d,%0d]x[%0d,%0d] local_a=%0d output_tiles=%0d",ROWS,K_TILES*TILE,K_TILES*TILE,N_TILES*TILE,LOCAL_A,outputs);
    $finish;
  end
  initial begin #5000000;$fatal(1,"v3 Projection watchdog"); end
endmodule
