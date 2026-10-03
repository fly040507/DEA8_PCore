`timescale 1ns/1ps
import pcore3_pkg::*;

module tb_v3_qoz_stale_write_after_release;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,clear=0,req_valid=0,req_ready,active,complete;
  qoz_region_req_t req,active_req;
  logic release_valid=0,release_ready; job_header_t consumer;
  logic wr_valid=0,wr_ready; post_result_t wr;
  logic rd_valid=0,rd_ready,out_valid,out_ready=1;
  logic [5:0] rd_tile=0; logic [PAIR_BITS-1:0] rd_pair=0;
  logic [TILE_BITS-1:0] rd_transport=0; qoz_owner_e rd_owner=QOZ_Q;
  a2_t out_entry; logic protocol_error;

  dea8_qoz_manager_v3 dut(.*,
    .region_active(active),.region_complete(complete));

  task automatic acquire;
    @(negedge clk);
    req='{header:'{job_id:16'd21,epoch:4'd3,head:3'd2,op:OP_Q_PROJ},
          owner:QOZ_Q,tiles:QOZ_Q_TILES};
    req_valid=1; do @(posedge clk); while(!req_ready);
    @(negedge clk); req_valid=0;
  endtask

  task automatic fill_q;
    for(int t=0;t<QOZ_Q_TILES;t++) for(int p=0;p<PAIRS;p++) begin
      @(negedge clk); wr='0; wr.header=req.header; wr.n=6'(t);
      wr.pair_data.tile_idx=TILE_BITS'(t); wr.pair_data.pair_idx=PAIR_BITS'(p);
      wr.pair_data.row_valid=row_mask(p); wr.last=(p==PAIRS-1);
      wr.pair_data.row[0].data=128'(t*100+p);
      wr.pair_data.row[1].data=128'(t*100+p+1);
      wr_valid=1; do @(posedge clk); while(!wr_ready);
      @(negedge clk); wr_valid=0;
    end
  endtask

  initial begin
    req='0; wr='0; consumer='0;
    repeat(5) @(negedge clk); reset=0;
    acquire(); fill_q();
    if(!complete) $fatal(1,"Q region did not complete");
    consumer='{job_id:16'd22,epoch:4'd3,head:3'd2,op:OP_ATTENTION};
    @(negedge clk); release_valid=1; do @(posedge clk); while(!release_ready);
    @(negedge clk); release_valid=0;
    if(active || active_req.owner!=QOZ_NONE) $fatal(1,"release left active generation");

    // A delayed producer token from the released generation must be rejected.
    @(negedge clk); wr='0; wr.header=req.header; wr.n=0;
    wr.pair_data.tile_idx=0; wr.pair_data.pair_idx=0;
    wr.pair_data.row_valid=row_mask(0); wr_valid=1; #1;
    if(wr_ready) $fatal(1,"stale write became ready after release");
    @(posedge clk); @(negedge clk); wr_valid=0;
    if(!protocol_error) $fatal(1,"stale write did not raise protocol_error");
    $display("tb_v3_qoz_stale_write_after_release PASS active_cleared=1 stale_write_rejected=1");
    $finish;
  end
  initial begin #30000; $fatal(1,"stale-write watchdog"); end
endmodule
