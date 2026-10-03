import pcore3_pkg::*;

module tb_v3_gu_matrix;
  localparam int KTEST=64;
  logic clk=0,reset=1,clear=0,start=0;
  always #2 clk=~clk;
  logic [EPOCH_BITS-1:0] epoch=4'h3; logic [2:0] head=3'h2; logic [5:0] n=0;
  logic a_valid,a_ready; a2_t a_entry;
  logic b_valid,b_ready; b2_t b_entry;
  logic busy,matrix_done,pair_ready,pair_accept,out_valid,out_ready=1;
  logic [5:0] out_row; logic [15:0][31:0] out_gate,out_up; logic [1:0] out_row_valid; logic out_last;
  logic out_consumed;
  logic vz_valid=0,vz_ready; logic [5:0] vz_tile=0; logic [PAIR_BITS-1:0] vz_pair=0; logic [1:0] vz_rv=0; logic [135:0] vz_even=0,vz_odd=0; logic [EPOCH_BITS-1:0] vz_epoch=0; logic [2:0] vz_head=0; logic [5:0] vz_n=0; logic vz_last=0;
  logic qz_valid,qz_ready=1; logic [5:0] qz_tile; logic [PAIR_BITS-1:0] qz_pair; logic [1:0] qz_rv; logic [135:0] qz_even,qz_odd; logic [EPOCH_BITS-1:0] qz_epoch; logic [2:0] qz_head; logic [5:0] qz_n; logic qz_last;
  logic ae,be,ge;
  int out_count=0,watchdog=0; logic last_seen=0;
  logic [31:0] g_mem[0:ROWS-1][0:TILE-1],u_mem[0:ROWS-1][0:TILE-1];
  logic [1023:0] golden[0:ROWS-1];
  logic [135:0] z_golden[0:ROWS-1];
  int z_count=0; logic z_last_seen=0;
  logic [135:0] qoz_z_mem[0:31][0:PAIRS-1][0:1];
  logic qoz_z_owner_active=0,qoz_z_complete=0;

  function automatic logic [31:0] gelu_bits(input logic [31:0] x);
    // The fixture supplies G=U=1.0.  This is the SFU lookup result for
    // tanh-GELU(1.0), kept bit-exact and simulator-portable.
    return (x==32'h3f800000)?32'h3f57625f:x;
  endfunction
  function automatic int aval(input int row,input int k,input int i);
    return (row+2*k+3*i)%9-4;
  endfunction
  function automatic int bval(input int k,input int i,input int col,input bit up);
    if(up) return (3*k+2*col+i)%13-6;
    return (k+col+2*i)%11-5;
  endfunction

  dea8_gu_matrix_v3 #(.K_TILES(KTEST),.GU_TILES(2*KTEST)) dut(
    .clk,.reset,.clear,.start,.job_epoch(epoch),.job_head(head),.job_n(n),
    .local_a_valid(a_valid),.local_a_ready(a_ready),.local_a_entry(a_entry),
    .hbm_valid(b_valid),.hbm_ready(b_ready),.hbm_entry(b_entry),
    .gu_busy(busy),.gu_matrix_done(matrix_done),.gu_pair_ready(pair_ready),.gu_pair_ready_accept(pair_accept),
    .gu_out_valid(out_valid),.gu_out_ready(out_ready),.gu_out_row(out_row),.gu_gate(out_gate),.gu_up(out_up),.gu_out_row_valid(out_row_valid),.gu_out_last(out_last),
    .gu_out_consumed(out_consumed),.vpu_z_valid(vz_valid),.vpu_z_ready(vz_ready),.vpu_z_tile(vz_tile),
    .vpu_z_pair(vz_pair),.vpu_z_row_valid(vz_rv),.vpu_z_even(vz_even),.vpu_z_odd(vz_odd),
    .vpu_z_epoch(vz_epoch),.vpu_z_head(vz_head),.vpu_z_n(vz_n),.vpu_z_last(vz_last),
    .qoz_z_wr_valid(qz_valid),.qoz_z_wr_ready(qz_ready),.qoz_z_wr_tile(qz_tile),
    .qoz_z_wr_pair(qz_pair),.qoz_z_wr_row_valid(qz_rv),.qoz_z_wr_even(qz_even),.qoz_z_wr_odd(qz_odd),
    .qoz_z_wr_epoch(qz_epoch),.qoz_z_wr_head(qz_head),.qoz_z_wr_n(qz_n),.qoz_z_wr_last(qz_last),
    .a_protocol_error(ae),.b_protocol_error(be),.gu_protocol_error(ge));

  task automatic send_a(input int t,input int p);
    a2_t v;
    begin
      v='0; v.tile_idx=t[5:0]; v.pair_idx=p[PAIR_BITS-1:0]; v.row_valid=row_mask(p);
      for(int i=0;i<TILE;i++) begin
        v.row[0].data[i*INT_BITS +: INT_BITS]=aval(2*p,t,i);
        v.row[1].data[i*INT_BITS +: INT_BITS]=aval(2*p+1,t,i);
      end
      v.row[0].scale=8'(128+(2*p)%3);v.row[1].scale=8'(128+(2*p+1)%3);
      @(negedge clk); a_entry=v;a_valid=1;
      do @(posedge clk); while(!a_ready);
      @(negedge clk);a_valid=0;
    end
  endtask

  task automatic send_b(input int t,input int g);
    b2_t v;
    begin
      v='0;v.tile_idx=t[5:0];v.group_idx=g[2:0];v.epoch=epoch;
      for(int c=0;c<2;c++) begin
        int col; col=2*g+c;
        v.col[c].data='0;
        // Matrix transport is interleaved: G(k)=2*k, U(k)=2*k+1.
        for(int i=0;i<TILE;i++) v.col[c].data[i*INT_BITS +: INT_BITS]=bval(t/2,i,col,t[0]);
        v.col[c].scale=8'(128+col%2);
      end
      @(negedge clk);b_entry=v;b_valid=1;
      do @(posedge clk); while(!b_ready);
      @(negedge clk);b_valid=0;
    end
  endtask

  task automatic emit_z_pair(input int p);
    logic [135:0] ze,zo;
    begin
      ze=z_golden[2*p];zo=(p<PAIRS-1)?z_golden[2*p+1]:'0;
      @(negedge clk);vz_tile=0;vz_pair=p;vz_rv=row_mask(p);vz_even=ze;vz_odd=zo;
      vz_epoch=epoch;vz_head=head;vz_n=n;vz_last=(p==PAIRS-1);vz_valid=1;
      do @(posedge clk); while(!vz_ready);
      @(negedge clk);vz_valid=0;
    end
  endtask

  initial begin
    a_valid=0;b_valid=0;a_entry='0;b_entry='0;pair_accept=1;
    $readmemh("tb/data/gu_n0_fp32.mem",golden);
    $readmemh("tb/data/gu_n0_z_mxint8.mem",z_golden);
    repeat(35) @(posedge clk); reset=0;
    // STREAMING AFIFO requires a real initial credit window.  Prefill one
    // complete A tile and one B tile before accepting the matrix job.
    for(int t=0;t<2;t++) for(int p=0;p<PAIRS;p++) send_a(t,p);
    for(int t=0;t<2;t++) for(int g=0;g<8;g++) send_b(t,g);
    @(negedge clk);start=1;
    fork
      begin for(int t=2;t<KTEST;t++) for(int p=0;p<PAIRS;p++) send_a(t,p); end
      begin for(int t=2;t<2*KTEST;t++) for(int g=0;g<8;g++) send_b(t,g); end
    join_none
    @(negedge clk);start=0;
    wait(matrix_done); wait(pair_ready);
    while(out_count<ROWS) @(posedge clk);
    if(out_count!=ROWS||!last_seen) $fatal(1,"GU row stream mismatch count=%0d last_seen=%0d",out_count,last_seen);
    if(ae||be||ge) $fatal(1,"GU protocol error ae=%0d be=%0d ge=%0d",ae,be,ge);
    qoz_z_owner_active=1;
    for(int p=0;p<PAIRS;p++) emit_z_pair(p);
    repeat(2) @(posedge clk);
    if(z_count!=PAIRS||!z_last_seen||!qoz_z_complete)
      $fatal(1,"Z write mismatch pairs=%0d last=%0d complete=%0d",z_count,z_last_seen,qoz_z_complete);
    $display("tb_v3_gu_matrix PASS matrix_done=1 pair_rows=%0d pair_cycles=51 z_pairs=%0d",out_count,z_count);
    #20;$finish;
  end
  always @(posedge clk) begin
    if(out_valid&&out_ready) begin
      if(out_count==0) begin
        $display("GU first row gate0=%h up0=%h row_valid=%b",out_gate[0],out_up[0],out_row_valid);
      end
      for(int i=0;i<TILE;i++) begin
        if(out_gate[i]!==golden[out_row][i*32 +: 32] ||
           out_up[i]!==golden[out_row][512+i*32 +: 32])
          $fatal(1,"GU golden mismatch row=%0d lane=%0d gate=%h/%h up=%h/%h",out_row,i,
            out_gate[i],golden[out_row][i*32 +: 32],out_up[i],golden[out_row][512+i*32 +: 32]);
      end
      for(int i=0;i<TILE;i++) begin
        g_mem[out_row][i]<=out_gate[i];u_mem[out_row][i]<=out_up[i];
      end
      out_count++; last_seen<=out_last;
    end
    if(qz_valid&&qz_ready) begin
      if(!qoz_z_owner_active||qz_tile>=32||qz_pair>=PAIRS)
        $fatal(1,"QOZ owner/address mismatch tile=%0d pair=%0d",qz_tile,qz_pair);
      if(qz_pair!=z_count||qz_tile!=0||qz_n!=n||qz_epoch!=epoch||qz_head!=head||
         qz_rv!=row_mask(z_count))
        $fatal(1,"Z context mismatch pair=%0d expected=%0d tile=%0d n=%0d rv=%b",qz_pair,z_count,qz_tile,qz_n,qz_rv);
      if(qz_even!==z_golden[2*z_count]||
         (z_count<PAIRS-1&&qz_odd!==z_golden[2*z_count+1]))
        $fatal(1,"Z quantization mismatch pair=%0d even=%h odd=%h",z_count,qz_even,qz_odd);
      z_count++;z_last_seen<=qz_last;
      qoz_z_mem[qz_tile][qz_pair][0]<=qz_even;
      qoz_z_mem[qz_tile][qz_pair][1]<=qz_odd;
      if(qz_last) begin qoz_z_complete<=1;qoz_z_owner_active<=0;end
    end
    watchdog++;
    if(watchdog%1000==0) $display("GU progress cyc=%0d job=%0d seq=%0d",watchdog,dut.private_matrix.matrix.job_busy_q,dut.private_matrix.matrix.tile_seq_q);
    if(watchdog>20000) $fatal(1,"GU watchdog");
  end
endmodule
