`timescale 1ns/1ps
import pcore3_pkg::*;

module tb_v3_local_a_protocol;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,load_valid=0,load_ready;
  a2_t load_entry,out_entry,held;
  logic [EPOCH_BITS-1:0] load_epoch=3,epoch[0:1];
  logic [2:0] load_head=2,head[0:1];
  logic [5:0] load_block=4,block_id[0:1];
  logic [1:0] active=0,release_bank=0,complete;
  logic protocol_error,rd_valid=0,rd_ready,rd_bank=0,out_valid,out_ready=0;
  logic [3:0] rd_tile=0;
  logic [PAIR_BITS-1:0] rd_pair=0;
  logic [TILE_BITS-1:0] rd_transport=32;
  int negatives=0;
  dea8_local_a_store_v3 #(.TILES(1),.BANKS(2)) dut(.*);
  task automatic clean;
    @(negedge clk);clear=1;load_valid=0;rd_valid=0;out_ready=0;active=0;release_bank=0;
    @(negedge clk);clear=0;load_epoch=3;load_head=2;load_block=4;
  endtask
  task automatic entry(input int p);
    load_entry='0;load_entry.pair_idx=PAIR_BITS'(p);load_entry.row_valid=row_mask(p);
    load_entry.row[0].scale=128;load_entry.row[1].scale=129;
    load_entry.row[0].data=128'(100+p);load_entry.row[1].data=128'(200+p);
  endtask
  task automatic send_pair(input int p);
    @(negedge clk);entry(p);load_valid=1;
    #1;if(!load_ready) $fatal(1,"legal load rejected pair=%0d",p);
    @(posedge clk);@(negedge clk);load_valid=0;
  endtask
  task automatic reject;
    load_valid=1;
    #1;if(load_ready) $fatal(1,"illegal producer request accepted");
    @(posedge clk);#1;if(!protocol_error) $fatal(1,"missing sticky protocol error");
    @(negedge clk);load_valid=0;
    repeat(2) @(negedge clk);
    if(!protocol_error) $fatal(1,"protocol error not sticky");
    negatives++;
  endtask
  initial begin
    load_entry='0;repeat(5) @(negedge clk);reset=0;
    // Wrong first pair, malformed tail, context changes mid-region.
    entry(1);reject();clean();
    entry(0);load_entry.slot=1;reject();clean();
    entry(0);load_entry.row_valid=2'b01;reject();clean();
    send_pair(0);entry(1);load_epoch=4;reject();clean();
    send_pair(0);entry(1);load_block=6;reject();clean();
    active=1;entry(0);reject();clean();
    for(int p=0;p<PAIRS;p++) send_pair(p);
    if(complete!==2'b01||epoch[0]!=3||head[0]!=2||block_id[0]!=4)
      $fatal(1,"descriptor not committed");
    // A synchronous response must survive arbitrary consumer backpressure.
    @(negedge clk);rd_valid=1;rd_pair=0;
    @(posedge clk);#1;held=out_entry;
    if(!out_valid||held.row[0].data!=100||held.row[1].data!=200||held.tile_idx!=32)
      $fatal(1,"reader data/transport mismatch");
    @(negedge clk);rd_pair=1;
    repeat(4) begin @(posedge clk);#1;if(rd_ready||out_entry!==held||!out_valid) $fatal(1,"stalled response changed");end
    @(negedge clk);out_ready=1;
    @(posedge clk);#1;if(out_entry.row[0].data!=101) $fatal(1,"elastic replacement lost");
    @(negedge clk);rd_pair=PAIRS-1;
    @(posedge clk);#1;if(out_entry.row_valid!=1||out_entry.row[1]!=='0) $fatal(1,"tail odd row leaked");
    @(negedge clk);rd_valid=0;
    @(negedge clk);entry(0);reject(); // already full
    clean();
    for(int p=0;p<PAIRS;p++) send_pair(p);
    @(negedge clk);release_bank=1;
    @(negedge clk);release_bank=0;load_block=6;
    for(int p=0;p<PAIRS;p++) send_pair(p);
    if(!complete[0]||block_id[0]!=6) $fatal(1,"bank reuse descriptor stale");
    clean();
    if(complete||out_valid||protocol_error) $fatal(1,"clear did not cancel region");
    $display("tb_v3_local_a_protocol PASS negative_cases=%0d backpressure=1 tail=1 reuse=1 clear=1",negatives);
    $finish;
  end
  initial begin #20000;$fatal(1,"local A protocol watchdog");end
endmodule
