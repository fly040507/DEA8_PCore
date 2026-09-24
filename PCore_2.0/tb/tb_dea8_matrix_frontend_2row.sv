`timescale 1ns/1ps
import pcore2_pkg::*;
module tb_dea8_matrix_frontend_2row;
  localparam int TILES=8;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,job_valid=0,job_ready,busy,done,protocol_error;
  job_t job,model_job;
  a2_t xbc_entry;
  logic [EPOCH_BITS-1:0] xbc_epoch;
  logic xbc_valid=0,xbc_ready;
  a_write_t qoz_write,pbuf_write;
  logic hbm_valid=0,hbm_ready,kv_valid=0,kv_ready;
  logic [HBM_BITS-1:0] hbm_data;
  b_t kv_entry;
  logic rsp_valid;
  logic [1:0] rsp_row_valid;
  logic signed [1:0][TILE-1:0][PSUM_BITS-1:0] psum;
  logic [1:0][SCALE_BITS-1:0] rsp_scale;
  logic [TILE-1:0][SCALE_BITS-1:0] rsp_e_stat;
  tag_t rsp_tag[0:1];
  dest_t rsp_dest[0:1];
  logic [1:0] wr_mask[1:2];
  logic wr_bank[1:2];
  logic [TILE_BITS-1:0] wr_tile[1:2];
  logic [PAIR_BITS-1:0] wr_pair[1:2];
  logic [1:0][DATA_BITS-1:0] wr_data[1:2];
  logic [1:0][SCALE_BITS-1:0] wr_scale[1:2];
  int mode=0,job_seen=0,total_seen=0,cycle=0,issue_count=0,last_issue=0,overlap=0;
  int due[0:PAIRS*(1<<TILE_BITS)-1];
  int first_issue=0;
  int signed golden;
  dea8_matrix_engine_2row #(.QOZ_TILES(TILES)) dut(.*);
  for(genvar s=1;s<=2;s++) begin : g_stability
    bit held_valid=0;
    a2_t held_entry;
    logic [EPOCH_BITS-1:0] held_epoch;
    always @(posedge clk) begin
      if(reset || clear) held_valid=0;
      else begin
        if(held_valid && (!dut.a_valid[s] || dut.a_entry[s]!==held_entry || dut.a_epoch[s]!==held_epoch))
          $fatal(1,"RAM response changed under backpressure source=%0d",s);
        held_valid=dut.a_valid[s] && !dut.a_ready[s];
        held_entry=dut.a_entry[s];held_epoch=dut.a_epoch[s];
      end
    end
  end
  always_comb begin
    qoz_write='{mask:wr_mask[1],bank:wr_bank[1],tile_idx:wr_tile[1],
      pair_idx:wr_pair[1],data:wr_data[1],scale:wr_scale[1]};
    pbuf_write='{mask:wr_mask[2],bank:wr_bank[2],tile_idx:wr_tile[2],
      pair_idx:wr_pair[2],data:wr_data[2],scale:wr_scale[2]};
  end
  function automatic int signed av(input int m,t,p,r,k);
    return $signed(8'(m*31+(m==2 ? 0 : t)*61+p*23+r*97+k*11));
  endfunction
  function automatic int signed bv(input int m,t,k,n);
    return $signed(8'(m*71+t*47+k*13+n*17-128));
  endfunction
  function automatic a2_t ae(input int m,t,p);
    a2_t v;
    v='0;v.slot=model_job.slot;v.tile_idx=t;v.pair_idx=p;v.row_valid=row_mask(p);
    for(int r=0;r<ROW_LANES;r++) begin
      v.scale[r]=8'(m*29+(m==2 ? 0 : t)*7+p*3+r);
      for(int k=0;k<TILE;k++) v.data[r][k*INT_BITS+:INT_BITS]=8'(av(m,t,p,r,k));
    end
    return v;
  endfunction
  always @(posedge clk) begin
    cycle++;
    if(!reset && !clear) begin
      if(dut.frontend.issue_valid) begin
        if(issue_count==0) first_issue=cycle;
        else if(mode!=0 && issue_count%PAIRS==0 && cycle!=last_issue+2)
          $fatal(1,"Ready RAM/KV job did not maintain one tile-gap cycle");
        due[issue_count]=cycle+STAGES-1;
        if(issue_count%PAIRS!=0 && cycle!=last_issue+1) $fatal(1,"Frontend intra-tile bubble");
        last_issue=cycle;issue_count++;
      end
      if(dut.frontend.issue_valid && dut.frontend.load_valid) overlap++;
    end
    #1;
    if(!reset && !clear && rsp_valid) begin
      if(cycle!=due[job_seen]) $fatal(1,"Frontend latency");
      if(rsp_row_valid!==row_mask(job_seen%PAIRS)) $fatal(1,"Frontend tail mask");
      for(int r=0;r<ROW_LANES;r++) begin
        if(rsp_tag[r].row!==6'(2*(job_seen%PAIRS)+r) || rsp_tag[r].epoch!==model_job.epoch ||
           rsp_tag[r].head!==model_job.head ||
           rsp_tag[r].kt!==8'(model_job.kt_base+(mode==2 ? 0 : job_seen/PAIRS)) ||
           rsp_tag[r].nt!==8'(model_job.nt_base+(mode==2 ? job_seen/PAIRS : 0)) ||
           rsp_tag[r].final_k!==(mode==2 || job_seen/PAIRS==model_job.tiles-1) ||
           rsp_tag[r].last!==(job_seen==model_job.tiles*PAIRS-1))
          $fatal(1,"Frontend tag mode=%0d index=%0d",mode,job_seen);
        if(rsp_dest[r].address!==10'(model_job.dest_base+(2*(job_seen%PAIRS)+r)*model_job.dest_stride+
           (mode==2 ? job_seen/PAIRS : 0)) || rsp_dest[r].bank!==model_job.dest_bank ||
           rsp_dest[r].zero!==(mode==2 || job_seen/PAIRS==0)) $fatal(1,"Frontend destination");
        if(rsp_row_valid[r] && rsp_scale[r]!==8'(mode*29+(mode==2 ? 0 : job_seen/PAIRS)*7+(job_seen%PAIRS)*3+r))
          $fatal(1,"Frontend E_STREAM");
        for(int n=0;n<TILE;n++) begin
          golden=0;
          if(rsp_row_valid[r]) for(int k=0;k<TILE;k++)
            golden+=av(mode,job_seen/PAIRS,job_seen%PAIRS,r,k)*bv(mode,job_seen/PAIRS,k,n);
          if($signed(psum[r][n])!==golden)
            $fatal(1,"Frontend Psum mode=%0d pair=%0d row=%0d n=%0d got=%0d expect=%0d",
              mode,job_seen,r,n,$signed(psum[r][n]),golden);
          if(rsp_e_stat[n]!==8'(mode*37+(job_seen/PAIRS)*19+n)) $fatal(1,"Frontend E_STAT");
        end
      end
      job_seen++;total_seen++;
    end
  end
  task automatic fill_memory(input int s);
    a2_t v;
    for(int t=0;t<(s==1 ? TILES : 1);t++) for(int p=0;p<PAIRS;p++) begin
      v=ae(s,t,p);
      // Both dual-row and separate parity writes; no odd write for row 50.
      if(p%2==0) begin
        @(negedge clk);wr_mask[s]=v.row_valid;wr_bank[s]=s==2;
        wr_tile[s]=t;wr_pair[s]=p;wr_data[s]=v.data;wr_scale[s]=v.scale;
      end else begin
        for(int r=0;r<ROW_LANES;r++) if(v.row_valid[r]) begin
          @(negedge clk);wr_mask[s]=2'(1<<r);wr_bank[s]=s==2;
          wr_tile[s]=t;wr_pair[s]=p;wr_data[s]=v.data;wr_scale[s]=v.scale;
        end
      end
    end
    @(negedge clk);wr_mask[s]=0;
  endtask
  task automatic send_a(input int tile_limit=-1);
    if(tile_limit<0) tile_limit=model_job.tiles;
    if(mode!=0) return; // QOZ/PBUF request generation is implemented in RTL.
    for(int t=0;t<tile_limit;t++) for(int p=0;p<PAIRS;p++) begin
      if((t+p)%13==3) begin
        @(negedge clk);xbc_valid=0;
        repeat(2) @(negedge clk);
      end
      @(negedge clk);
      xbc_entry=ae(mode,t,p);xbc_epoch=model_job.epoch;xbc_valid=1;
      do @(posedge clk);while(!xbc_ready);
    end
    @(negedge clk);xbc_valid=0;
  endtask
  task automatic send_b(input int tile_limit=-1);
    if(tile_limit<0) tile_limit=model_job.tiles;
    if(mode!=0) repeat(100) @(negedge clk); // Force RAM/A2 backpressure.
    for(int t=0;t<tile_limit;t++) begin
      if(mode==0) begin
        for(int b=0;b<HBM_BEATS;b++) begin
          @(negedge clk);hbm_data='0;hbm_valid=1;
          if(b<DATA_BEATS) begin
            for(int h=0;h<HBM_BITS/DATA_BITS;h++) for(int n=0;n<TILE;n++)
              hbm_data[(h*TILE+n)*INT_BITS+:INT_BITS]=8'(bv(mode,t,b*2+h,n));
          end else for(int n=0;n<TILE;n++) hbm_data[n*SCALE_BITS+:SCALE_BITS]=8'(mode*37+t*19+n);
          do @(posedge clk);while(!hbm_ready);
        end
      end else begin
        for(int n=0;n<TILE;n++) begin
          @(negedge clk);kv_valid=1;
          for(int k=0;k<TILE;k++) kv_entry.data[k*INT_BITS+:INT_BITS]=8'(bv(mode,t,k,n));
          kv_entry.scale=8'(mode*37+t*19+n);
          do @(posedge clk);while(!kv_ready);
        end
      end
    end
    @(negedge clk);hbm_valid=0;kv_valid=0;
  endtask
  initial begin
    job='0;model_job='0;xbc_entry='0;xbc_epoch=0;hbm_data=0;kv_entry='0;
    for(int s=1;s<=2;s++) begin
      wr_mask[s]=0;wr_bank[s]=0;wr_tile[s]=0;wr_pair[s]=0;wr_data[s]=0;wr_scale[s]=0;
    end
    repeat(32) @(negedge clk);reset=0;
    for(int m=0;m<3;m++) begin
      mode=m;job_seen=0;issue_count=0;
      model_job='0;model_job.a_source=a_source_t'(m);model_job.b_from_kv=m!=0;
      model_job.tiles=TILES;model_job.epoch=m+1;model_job.slot=m%2;
      model_job.head=3;model_job.along_n=m==2;model_job.kt_base=4;model_job.nt_base=5;
      model_job.pbuf_bank=m==2;
      model_job.dest_base=3;model_job.dest_stride=m==2 ? TILES : 1;model_job.dest_bank=m;
      if(m!=0) fill_memory(m);
      @(negedge clk);job=model_job;job_valid=1;
      do @(posedge clk);while(!job_ready);
      @(negedge clk);job_valid=0;job='1; // Configuration must remain latched.
      fork send_a();send_b();join
      wait(done);@(negedge clk);
      if(protocol_error || busy || job_seen!=TILES*PAIRS) $fatal(1,"Frontend job completion");
      $display("Frontend source=%0d completed tiles=%0d pairs=%0d",m,TILES,job_seen);
      $display("Issue window source=%0d cycles=%0d useful=%0d gaps=%0d utilization=%0.2f%%",
        m,last_issue-first_issue+1,issue_count,last_issue-first_issue+1-issue_count,
        100.0*issue_count/(last_issue-first_issue+1));
    end
    if(overlap==0) $fatal(1,"No concurrent B load/compute");
    // A stale epoch must be rejected and require clear before a new job.
    @(negedge clk);job=model_job;job.a_source=A_XBC;job.b_from_kv=0;job_valid=1;
    @(negedge clk);job_valid=0;xbc_valid=1;xbc_entry=ae(mode,0,0);xbc_epoch=0;
    repeat(3) @(negedge clk);
    if(!protocol_error || xbc_ready) $fatal(1,"Stale epoch not rejected");
    xbc_valid=0;clear=1;
    @(negedge clk);clear=0;
    @(negedge clk);
    if(protocol_error || busy || !job_ready || rsp_valid) $fatal(1,"Clear did not reset ownership");

    // Abort a tile after five S0 issues but before its first S6 output.
    mode=0;job_seen=0;issue_count=0;model_job='0;
    model_job.a_source=A_XBC;model_job.tiles=1;model_job.epoch=7;
    @(negedge clk);job=model_job;job_valid=1;
    @(negedge clk);job_valid=0;
    fork send_a(1);send_b(1);join
    wait(issue_count==5);
    @(negedge clk);clear=1;
    @(negedge clk);clear=0;
    repeat(12) begin
      @(negedge clk);
      if(rsp_valid || done || busy) $fatal(1,"Aborted work escaped after clear");
    end
    if(job_seen!=0) $fatal(1,"Abort point was too late");

    // Restart after cancellation with a different epoch and newly loaded banks.
    job_seen=0;issue_count=0;
    model_job.tiles=TILES;model_job.epoch=8;
    @(negedge clk);job=model_job;job_valid=1;
    @(negedge clk);job_valid=0;
    fork send_a();send_b();join
    wait(done);@(negedge clk);
    if(protocol_error || busy || job_seen!=TILES*PAIRS) $fatal(1,"Restart failed");
    // Exercise the minimum and maximum job lengths, including the 63->64 counter boundary.
    for(int boundary=0;boundary<2;boundary++) begin
      job_seen=0;issue_count=0;
      model_job.tiles=boundary==0 ? 1 : (1<<TILE_BITS);
      model_job.epoch=9+boundary;model_job.dest_stride=3;model_job.dest_base=17;
      @(negedge clk);job=model_job;job_valid=1;
      do @(posedge clk);while(!job_ready);
      @(negedge clk);job_valid=0;
      fork send_a();send_b();join
      wait(done);@(negedge clk);
      if(protocol_error || busy || job_seen!=int'(model_job.tiles)*PAIRS)
        $fatal(1,"Boundary job length=%0d failed",model_job.tiles);
      $display("Boundary job tiles=%0d pairs=%0d issue_window=%0d gaps=%0d",
        model_job.tiles,job_seen,last_issue-first_issue+1,last_issue-first_issue+1-issue_count);
    end
    $display("tb_dea8_matrix_frontend_2row PASS tiles=97 pairs=%0d psums=%0d load_compute_overlap=%0d",
      total_seen,total_seen*ROW_LANES*TILE,overlap);
    $finish;
  end
  initial begin #100000;$fatal(1,"Frontend watchdog");end
endmodule
