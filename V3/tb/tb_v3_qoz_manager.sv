`timescale 1ns/1ps
import pcore3_pkg::*;
module tb_v3_qoz_manager;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,req_valid=0,req_ready,region_active,region_complete;
  qoz_region_req_t req,active_req;
  logic release_valid=0,release_ready;job_header_t consumer;
  logic wr_valid=0,wr_ready;post_result_t wr;
  logic rd_valid=0,rd_ready,out_valid,out_ready=1; qoz_owner_e rd_owner=QOZ_Q;
  logic [5:0] rd_tile=0;logic [PAIR_BITS-1:0] rd_pair=0;logic [TILE_BITS-1:0] rd_transport=0;
  a2_t out_entry;logic protocol_error;
  dea8_qoz_manager_v3 dut(.*);
  task automatic acquire(input qoz_owner_e own,input pcore_op_e op,input int id,input int tiles);
    @(negedge clk);req='{header:'{job_id:16'(id),epoch:4'd2,head:3'd1,op:op},owner:own,tiles:6'(tiles)};req_valid=1;
    do @(posedge clk);while(!req_ready);@(negedge clk);req_valid=0;
  endtask
  task automatic clean;
    @(negedge clk);clear=1;wr_valid=0;req_valid=0;release_valid=0;rd_valid=0;
    @(negedge clk);clear=0;
  endtask
  initial begin
    req='0;wr='0;consumer='0;repeat(5)@(negedge clk);reset=0;
    acquire(QOZ_Q,OP_Q_PROJ,1,16);
    for(int t=0;t<16;t++)for(int p=0;p<PAIRS;p++)begin
      @(negedge clk);wr='0;wr.header=req.header;wr.n=6'(t);wr.pair_data.tile_idx=TILE_BITS'(t);
      wr.pair_data.pair_idx=PAIR_BITS'(p);wr.pair_data.row_valid=row_mask(p);wr.last=p==PAIRS-1;
      wr.pair_data.row[0]='{data:128'(t*100+p),scale:8'd128};wr.pair_data.row[1]='{data:128'(t*100+p+1),scale:8'd129};
      wr_valid=1;do @(posedge clk);while(!wr_ready);@(negedge clk);wr_valid=0;
    end
    if(!region_complete||active_req.header.job_id!=1)$fatal(1,"Q region not committed");
    // A different operation job_id is a legal consumer in the same epoch/head.
    consumer='{job_id:16'd2,epoch:4'd2,head:3'd1,op:OP_ATTENTION};
    @(negedge clk);out_ready=0;rd_valid=1;rd_tile=15;rd_pair=PAIRS-1;
    do @(posedge clk);while(!rd_ready);#1;
    if(!out_valid||out_entry.row[0].data!=1525)$fatal(1,"shared final Q read");
    @(negedge clk);rd_valid=0;release_valid=1;
    repeat(32)begin
      @(negedge clk);
      if(release_ready||!region_active||!out_valid||out_entry.row[0].data!=1525)$fatal(1,"release crossed stalled final Q response");
    end
    out_ready=1;@(negedge clk);
    do @(posedge clk);while(!release_ready);@(negedge clk);release_valid=0;
    acquire(QOZ_Z,OP_GU,3,32);
    if(active_req.owner!=QOZ_Z||region_complete)$fatal(1,"Q to Z handover");
    @(negedge clk);wr='0;wr.header=req.header;wr.header.job_id=1;
    wr.pair_data.row_valid=3;wr_valid=1;#1;if(wr_ready)$fatal(1,"stale producer accepted");
    @(negedge clk);wr_valid=0;if(!protocol_error)$fatal(1,"stale producer not detected");
    clean();acquire(QOZ_Q,OP_Q_PROJ,4,16);
    consumer='{job_id:16'd5,epoch:4'd3,head:3'd1,op:OP_ATTENTION};
    @(negedge clk);release_valid=1;@(negedge clk);release_valid=0;
    if(!protocol_error)$fatal(1,"wrong release generation accepted");
    clean();acquire(QOZ_O,OP_ATTENTION,6,16);
    if(active_req.owner!=QOZ_O||active_req.tiles!=QOZ_O_TILES)$fatal(1,"O region contract");
    consumer=req.header;consumer.op=OP_ATTENTION;
    @(negedge clk);release_valid=1;@(negedge clk);release_valid=0;
    if(!protocol_error)$fatal(1,"wrong O consumer accepted");
    clean();acquire(QOZ_Z,OP_GU,7,32);
    for(int t=0;t<32;t++)for(int p=0;p<PAIRS;p++)begin
      @(negedge clk);wr='0;wr.header=req.header;wr.n=6'(t);wr.pair_data.tile_idx=TILE_BITS'(t);
      wr.pair_data.pair_idx=PAIR_BITS'(p);wr.pair_data.row_valid=row_mask(p);wr.last=p==PAIRS-1;
      wr_valid=1;do @(posedge clk);while(!wr_ready);@(negedge clk);wr_valid=0;
    end
    consumer='{job_id:16'd8,epoch:4'd2,head:3'd1,op:OP_DOWN_PROJ};
    @(negedge clk);release_valid=1;#1;if(!release_ready)$fatal(1,"Down consumer rejected");
    @(negedge clk);release_valid=0;if(region_active||protocol_error)$fatal(1,"Z release failed");
    clean();acquire(QOZ_Q,OP_Q_PROJ,9,16);
    @(negedge clk);wr='0;wr.header=req.header;wr.pair_data.row_valid=3;wr.pair_data.pair_idx=1;wr_valid=1;
    repeat(3)@(negedge clk);wr_valid=0;if(!protocol_error)$fatal(1,"unordered write accepted");
    for(int own=1;own<=3;own++)begin
      clean();req='{header:'{job_id:16'd10,epoch:4'd2,head:3'd1,op:own==1?OP_Q_PROJ:own==2?OP_ATTENTION:OP_GU},owner:qoz_owner_e'(own),tiles:6'd15};
      @(negedge clk);req_valid=1;#1;if(req_ready)$fatal(1,"wrong tiles accepted");
      @(negedge clk);req_valid=0;if(!protocol_error)$fatal(1,"wrong tiles not detected");
    end
    $display("tb_v3_qoz_manager PASS physical_store=1 Q_to_Z=1 consumer_job_id=1 stale_producer_rejected=1 wrong_release_rejected=1 O16=1 Z32_Down_release=1 wrong_consumer=1 unordered_write=1 wrong_tiles=3 last_Q_response_release_stall=32");$finish;
  end
  initial begin #30000;$fatal(1,"QOZ manager watchdog");end
endmodule
