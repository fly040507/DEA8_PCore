`timescale 1ns/1ps
import pcore_pkg::*;import pcore_control_pkg::*;import dea8_tile_link_pkg::*;

// Production PCore only. Producers/receiver below are its external boundary.
module tb_pcore_cancel_native;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,config_valid=0,config_ready,configured;
  logic [15:0] config_context=16'h1234,config_mask_version=1,config_rope_version=1,config_position=816;
  logic job_valid=0,job_ready,done_valid,done_ready=0,busy,protocol_error,flush_done;
  control_job_t job;control_completion_t done;
  logic xbc_valid=0,xbc_ready,hbm_valid=0,hbm_ready,kv_valid=0,kv_ready;
  xbc4_t xbc_entry;b2_t hbm_entry,kv_entry;
  logic tx_valid,tx_ready=1,tx_last;logic [255:0] tx_data;
  logic kv_commit_valid=0,kv_commit_ready;tile_commit_t kv_commit;
  logic gu_prefetch_valid,gu_prefetch_ready=1;logic [5:0] gu_prefetch_n;
  logic stop_supply=0,quiescent=0,restarting=0;
  bit packet_active=0;tile_header_t header;
  logic [135:0] kgold[102];
  int cycle=0,packet_row=0,received=0,commits=0,issues=0;
  dea8_pcore_top #(.MASK_FILE("Pcore/units/rom/mask.mem"),.ROPE_FILE("Pcore/units/rom/rope.mem")) dut(.*);

  function automatic qvec16_t activation(input int row);
    qvec16_t value;value.scale=128;
    for(int j=0;j<16;j++)value.data[8*j+:8]=8'(row%3-1);
    return value;
  endfunction
  task automatic configure;
    @(negedge clk);config_valid=1;do @(posedge clk);while(!config_ready);
    @(negedge clk);config_valid=0;
    wait(configured);@(negedge clk);
  endtask
  task automatic submit;
    @(negedge clk);job_valid=1;do @(posedge clk);while(!job_ready);
    @(negedge clk);job_valid=0;
  endtask
  task automatic provide_a;
    for(int n=0;n<2&&!stop_supply;n++)for(int k=0;k<64&&!stop_supply;k++)
      for(int g=0;g<XBC_GROUPS&&!stop_supply;g++)begin
        @(negedge clk);xbc_entry='0;xbc_entry.tile_idx=TILE_BITS'(k);xbc_entry.group_idx=4'(g);
        xbc_entry.row_valid=g==XBC_GROUPS-1?4'b0111:4'b1111;
        for(int r=0;r<4;r++)xbc_entry.row[r]=activation(4*g+r);
        xbc_valid=!stop_supply;
        do @(posedge clk);while(!xbc_ready&&!stop_supply);
      end
    @(negedge clk);xbc_valid=0;
  endtask
  task automatic provide_b;
    for(int n=0;n<2&&!stop_supply;n++)for(int k=0;k<64&&!stop_supply;k++)
      for(int g=0;g<8&&!stop_supply;g++)begin
        @(negedge clk);hbm_entry='0;hbm_entry.tile_idx=TILE_BITS'(k);
        hbm_entry.group_idx=3'(g);hbm_entry.epoch=job.header.epoch;
        for(int c=0;c<2;c++)begin
          hbm_entry.col[c].scale=128;
          for(int j=0;j<16;j++)hbm_entry.col[c].data[8*j+:8]=8'(1+(n*16+2*g+c)%3);
        end
        hbm_valid=!stop_supply;
        do @(posedge clk);while(!hbm_ready&&!stop_supply);
      end
    @(negedge clk);hbm_valid=0;
  endtask
  always @(posedge clk)begin
    cycle++;
    if(!reset&&!clear)begin
      if(protocol_error)$fatal(1,"PCore cancel/restart protocol fault");
      if(quiescent&&(dut.control.exec.dispatch.matrix.commit_write_valid||
        (dut.acc_wr_valid&&dut.acc_wr_ready)||
        (dut.control.exec.qoz.store.wr_valid&&dut.control.exec.qoz.store.wr_ready)||
        (dut.vector_mem_valid&&dut.vector_mem_ready&&dut.vector_mem_req.write)||
        (dut.function_mem_valid&&dut.function_mem_ready&&dut.function_mem_req.write)||tx_valid))
        $fatal(1,"Old PCore generation wrote after flush");
      if(restarting&&dut.control.exec.dispatch.matrix.req_valid)issues++;
      if(kv_commit_valid&&kv_commit_ready)begin kv_commit_valid<=0;commits++;end
      if(tx_valid&&tx_ready)begin
        if(!restarting)$fatal(1,"Unexpected packet before restart");
        if(!packet_active)begin
          if(!packet_header_legal(tx_data))$fatal(1,"Restart packet header");
          header=tile_header_t'(tx_data[127:0]);packet_active=1;packet_row=0;
          if(header.source_id!=0||header.kind!=TILE_K||header.tile_seq>=2)$fatal(1,"Restart packet coordinates");
        end else begin
          if({tx_data[127:0],tx_data[135:128]}!==kgold[header.tile_seq*ROWS+packet_row])
            $fatal(1,"Restart K numerical tile=%0d row=%0d",header.tile_seq,packet_row);
          if(tx_last!=(packet_row==ROWS-1))$fatal(1,"Restart packet last");
          received++;packet_row++;
          if(tx_last)begin
            packet_active=0;kv_commit_valid<=1;
            kv_commit<='{transfer_id:header.transfer_id,transfer_epoch:header.transfer_epoch,
              tile_seq:header.tile_seq,source_id:header.source_id,status:0,reserved:0};
          end
        end
      end
    end
  end
  initial begin
    $readmemh("Pcore/tb/data/seven_job/k.mem",kgold);
    job='0;xbc_entry='0;hbm_entry='0;kv_entry='0;kv_commit='0;
    job.header='{job_id:16'd1,epoch:4'd3,head:3'd0,op:OP_K_PROJ};
    job.core_id=0;job.data_context=config_context;job.position_base=config_position;
    job.transfer='{transfer_id:16'd1,transfer_epoch:16'd9,destination_id:16'd1,token_origin:16'd816};
    repeat(35)@(negedge clk);reset=0;repeat(8)@(negedge clk);
    // A missing context must reject without entering the matrix pipeline.
    submit();wait(done_valid);
    if(done.status!=CONTROL_CONTEXT_ERROR)$fatal(1,"Missing context was not rejected");
    repeat(3)begin @(negedge clk);if(!done_valid)$fatal(1,"Rejected done was not held");end
    done_ready=1;@(negedge clk);done_ready=0;
    configure();submit();
    fork
      provide_a();provide_b();
      begin
        wait(dut.rope_req_valid&&dut.rope_req_ready);
        @(negedge clk);stop_supply=1;clear=1;
        @(negedge clk);clear=0;
      end
    join
    wait(flush_done);quiescent=1;
    repeat(100)@(negedge clk);
    if(busy||done_valid||xbc_valid||hbm_valid)$fatal(1,"Cancel did not drain boundary");
    // Explicitly rebind the same observation and use a new Job epoch/id.
    quiescent=0;configure();job.header.job_id=2;job.header.epoch=4;
    stop_supply=0;restarting=1;submit();
    fork provide_a();provide_b();join
    wait(done_valid);
    if(done.status!=CONTROL_OK||done.job!==job||issues!=3328||received!=102||commits!=2)
      $fatal(1,"Restart accounting status=%0d issues=%0d rows=%0d commits=%0d",done.status,issues,received,commits);
    $display("tb_pcore_cancel_native PASS missing_context=1 cancel_rope_inflight=1 no_stale_write=1 restart_K=1 checked_K=102 issues=3328 internal_tb_models=0");$finish;
  end
  initial begin #100000;$fatal(1,"PCore cancel/restart timeout busy=%b flush=%b vpu=%0d",busy,flush_done,dut.vpu.state);end
endmodule
