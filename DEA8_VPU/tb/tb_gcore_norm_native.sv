`timescale 1ns/1ps
import pcore_pkg::*;
import gcore_pkg::*;
import dea8_tile_link_pkg::*;

module tb_gcore_norm_native;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,config_valid=0,config_ready,config_done_valid,config_done_ready=1;
  gcore_context_t config_data;gcore_status_e config_status;
  logic preloaded_valid=0,preloaded_ready,preloaded_done_valid,preloaded_done_ready=1;
  gcore_preloaded_t preloaded;gcore_status_e preloaded_status;
  logic layer_valid=0,layer_ready,layer_done_valid,layer_done_ready=1;gcore_layer_t layer_data;gcore_status_e layer_status;
  logic job_valid=0,job_ready,job_done_valid,job_done_ready=1,job_busy;gcore_job_t job;gcore_job_done_t job_done;gcore_xhat_t xhat_status;
  logic gamma_fetch_valid,gamma_fetch_ready=0,gamma_data_valid=0,gamma_data_ready;gamma_fetch_t gamma_fetch;gamma_beat_t gamma_data;
  logic final_valid,final_ready=1;gcore_final_t final_data;
  logic cmd_valid=0,cmd_ready,done_valid,done_ready=0;gcore_cmd_t cmd;gcore_done_t done;
  logic import_valid=0,import_ready;residual_import_t import_data;
  logic [7:0] xbc_valid,xbc_ready=0,gu_prefetch_valid=0,gu_prefetch_ready,rx_valid=0,rx_ready,rx_last=0;
  xbc4_t xbc;logic [7:0][255:0] rx_data=0;logic [7:0][5:0] gu_prefetch_n=0;
  logic [7:0] kv_commit_valid,kv_commit_ready='1,kv_valid,kv_ready=0;tile_commit_t kv_commit[8];b2_t kv;
  logic gamma_load_valid=0,gamma_load_ready,gamma_done_valid,gamma_done_ready=0;gamma_load_t gamma_load;
  gcore_status_e gamma_status;logic [15:0] gamma_loaded_id;
  logic rsqrt_valid,rsqrt_ready=0,rsqrt_out_valid=0,rsqrt_out_ready;rsqrt_packet_t rsqrt_request,rsqrt_response;
  logic invalidate_valid=0,invalidate_ready;logic [OBJECTS-1:0] invalidate_mask=0;
  logic kv_release_valid=0,kv_release_ready,kv_lease,cancel_valid=0,cancel_ready,flush_valid,external_flush_ack=0,fault;
  logic [SERVICES-1:0] busy;
  logic [255:0] initial_resid[VECTOR_WORDS];logic [135:0] xgold[VECTOR_WORDS];logic [31:0] gamma[1024],ugold[51];
  int count=0,inverse_count=0,cycle=0,start_cycle;
  dea8_gcore dut(.*);
  always @(posedge clk)begin
    cycle++;
    if(!reset)begin
      if(fault)$fatal(1,"Native GCore cold Norm fault state=%0d",dut.services.compute.state);
      if(dut.services.activation_valid&&dut.services.activation_ready)begin
        if(dut.services.activation_word!==xgold[dut.services.activation_index])
          $fatal(1,"GCore native Norm quant index=%0d got=%h expected=%h",dut.services.activation_index,dut.services.activation_word,xgold[dut.services.activation_index]);
        count++;
      end
      if(rsqrt_valid&&dut.local_rsqrt_ready)begin
        if(rsqrt_request.data[31:0]!==ugold[rsqrt_request.row0])$fatal(1,"GCore native squared sum row=%0d got=%h expected=%h",rsqrt_request.row0,rsqrt_request.data[31:0],ugold[rsqrt_request.row0]);
        inverse_count++;
      end
    end
  end
  initial begin
    $readmemh("tb/data/layer_native/initial.mem",initial_resid);$readmemh("tb/data/layer_native/xhat0.mem",xgold);
    $readmemh("tb/data/layer_native/gamma0.mem",gamma);$readmemh("tb/data/layer_native/u0.mem",ugold);
    if(!$test$plusargs("IMPORT_FIRST"))
      for(int a=0;a<VECTOR_WORDS;a++)dut.services.residual_store.memory[a]=initial_resid[a];
    config_data='0;preloaded='0;layer_data='0;job='0;gamma_data='0;cmd='0;import_data='0;gamma_load='0;rsqrt_response='0;
    repeat(35)@(negedge clk);reset=0;
    @(negedge clk);config_data.context_id=9;config_data.generation=2;config_data.gamma_online=1;
    config_data.prefix_version=7;config_data.k_transfer.transfer_id=1;config_data.v_transfer.transfer_id=2;
    config_data.o_transfer.transfer_id=3;config_data.down_transfer.transfer_id=4;config_valid=1;
    do @(posedge clk);while(!config_ready);@(negedge clk);config_valid=0;
    wait(config_done_valid);if(config_status!=GC_OK)$fatal(1,"GCore config");
    @(negedge clk);preloaded='{context_id:16'd9,generation:16'd2,residual_object:16'd100,residual_version:16'd1,prefix_object:16'd300,prefix_version:16'd7};preloaded_valid=1;
    do @(posedge clk);while(!preloaded_ready);@(negedge clk);preloaded_valid=0;
    wait(preloaded_done_valid);if(preloaded_status!=GC_OK)$fatal(1,"GCore register");
    if($test$plusargs("IMPORT_FIRST"))begin
      @(negedge clk);cmd='0;cmd.opcode=GC_IMPORT_RESID;cmd.command_id=90;
      cmd.context_id=9;cmd.generation=2;cmd.core_mask='1;cmd.dst_object=100;cmd.dst_version=1;
      cmd_valid=1;do @(posedge clk);while(!cmd_ready);@(negedge clk);cmd_valid=0;
      for(int a=0;a<VECTOR_WORDS;a++)begin
        import_data='{data:initial_resid[a],index:VECTOR_ADDR_BITS'(a),last:a==VECTOR_WORDS-1,token:command_token(cmd)};
        import_valid=1;do @(posedge clk);while(!import_ready);@(negedge clk);
      end
      import_valid=0;done_ready=1;wait(done_valid);
      if(done.status!=GC_OK||done.completed_items!=VECTOR_WORDS)$fatal(1,"Formal RESID import failed");
      @(posedge clk);@(negedge clk);done_ready=0;
      $display("GCORE_EXTERNAL_IMPORT vectors=3264 hierarchy_writes=0");
    end
    for(int i=0;i<1024;i++)begin
      @(negedge clk);gamma_load='{context_id:16'd9,generation:16'd2,param_id:16'h210,slot:1'b0,index:10'(i),value:gamma[i],last:i==1023};
      gamma_load_valid=1;do @(posedge clk);while(!gamma_load_ready);
    end
    @(negedge clk);gamma_load_valid=0;wait(gamma_done_valid);if(gamma_status!=GC_OK)$fatal(1,"Gamma load");
    @(negedge clk);gamma_done_ready=1;@(negedge clk);gamma_done_ready=0;
    cmd='0;cmd.opcode=GC_NORM;cmd.command_id=1;cmd.context_id=9;cmd.generation=2;cmd.core_mask='1;
    cmd.src_object=100;cmd.src_version=1;cmd.dst_object=200;cmd.dst_version=1;cmd.norm_param_id=16'h210;cmd.epsilon_fp32=32'h358637bd;
    cmd_valid=1;do @(posedge clk);while(!cmd_ready);start_cycle=cycle;@(negedge clk);cmd_valid=0;
    wait(done_valid);
    if(done.status!=GC_OK||count!=VECTOR_WORDS||inverse_count!=51)$fatal(1,"Native Norm completion count=%0d inverse=%0d status=%0d",count,inverse_count,done.status);
    $display("tb_gcore_norm_native PASS quant=%0d inv=%0d cycles=%0d native_add=%0d native_mul=%0d real_rsqrt=1 external_import=%0d",count,inverse_count,cycle-start_cycle,ADD_LATENCY,MUL_LATENCY,$test$plusargs("IMPORT_FIRST"));$finish;
  end
  initial begin #150000;$fatal(1,"GCore Norm watchdog state=%0d count=%0d",dut.services.compute.state,count);end
endmodule
