`timescale 1ns/1ps
import pcore_pkg::*;
import pcore_control_pkg::*;

// Reach each tested stage through the production datapath. Only external
// producers and the not-yet-implemented VPU/SFU are testbench models.
module tb_pcore_control_faults #(parameter bit CANCEL_SWEEP=0);
  tb_pcore_control #(.MANUAL(1)) env();
  bit feed_enable=0;
  int failures_checked=0,cancels_checked=0,recoveries=0,serial=100;
  control_command_t vc,fc;
  control_token_t old_token;
  control_token_t stale_token;
  logic [15:0][31:0] payload,value,a,b;

  initial begin: sources
    forever begin
      wait(feed_enable);
      fork
        begin
          case(env.job.header.op)
            OP_K_PROJ,OP_V_PROJ:env.feed_projection(2,64,0);
            OP_ATTENTION:env.feed_attention();
            OP_GU:env.feed_gu();
            default:$fatal(1,"fault TB source operation");
          endcase
          wait(!feed_enable);
        end
        begin wait(!feed_enable);end
      join_any
      disable fork;
    end
  end
  task automatic quiesce;
    feed_enable=0;env.agents_enabled=0;
    @(negedge env.clk);
    env.job_valid=0;env.done_ready=0;
    env.xbc_valid=0;env.hbm_valid=0;env.kv_valid=0;
    env.vector_ready=0;env.function_ready=0;
    env.vector_done_valid=0;env.function_done_valid=0;
    env.vector_result_valid=0;env.function_result_valid=0;
    env.vector_data_ready=0;env.function_data_ready=0;
    env.vector_mem_valid=0;env.function_mem_valid=0;
    env.vector_mem_out_ready=0;env.function_mem_out_ready=0;
    env.acc_rd_valid=0;env.acc_wr_valid=0;env.acc_data_ready=0;
    env.rope_req_valid=0;env.rope_sfu_out_valid=0;env.rope_out_ready=0;
    env.kv_out_ready=0;env.reduce_out_ready=0;
  endtask
  task automatic flush_recover(input string name,input bit stale=0);
    logic [GENERATION_BITS-1:0] generation;
    generation=env.dut.generation_q;
    env.vpu_flush_ack=0;env.sfu_flush_ack=0;env.clear=1;
    quiesce();
    repeat(2)@(negedge env.clk);
    if(env.dut.generation_q!=generation+1'b1)$fatal(1,"clear increment must be edge based");
    env.clear=0;
    if(stale)begin
      env.vector_result_valid=1;env.function_result_valid=1;
      env.vector_done_valid=1;env.function_done_valid=1;
      env.rope_sfu_out_valid=1;
    end
    repeat(17)begin
      @(negedge env.clk);
      if(!env.flush_valid||env.job_ready||env.done_valid||env.kv_out_valid||env.reduce_out_valid||
         env.vector_result_ready||env.function_result_ready||env.vector_done_ready||env.function_done_ready||
         env.rope_sfu_out_ready||env.rope_out_valid||env.qoz_region.owner!=QOZ_NONE)
        $fatal(1,"flush barrier/stale side effect %s",name);
    end
    env.vector_result_valid=0;env.function_result_valid=0;
    env.vector_done_valid=0;env.function_done_valid=0;env.rope_sfu_out_valid=0;
    env.vpu_flush_ack=1;@(negedge env.clk);env.vpu_flush_ack=0;
    repeat(7)begin @(negedge env.clk);if(env.job_ready||!env.flush_valid)$fatal(1,"one flush ack %s",name);end
    env.sfu_flush_ack=1;@(negedge env.clk);env.sfu_flush_ack=0;
    repeat(3)@(negedge env.clk);
    if(!env.job_ready||env.protocol_error||env.flush_valid||env.busy)$fatal(1,"recovery %s",name);
    env.hold_kv=0;env.hold_reduce=0;
    for(int i=0;i<7;i++)begin env.issues[i]=0;env.sent[i]=0;env.commands[i]=0;end
    env.allowed_n=0;
  endtask
  task automatic expect_fault(input string name);
    repeat(5)@(negedge env.clk);
    if(!env.protocol_error||!env.done_valid||env.done.status!=CONTROL_UNIT_ERROR||env.done.job!==env.job||env.job_ready)
      $fatal(1,"fault missing %s status=%0d",name,env.done.status);
    failures_checked++;
    $display("CONTROL_FAULT_PASS case=%s total=%0d",name,failures_checked);
    flush_recover(name,1);
  endtask
  task automatic launch(input pcore_op_e op);
    @(negedge env.clk);env.job='0;
    env.job.header='{job_id:16'(serial++),epoch:4'd3,head:3'd1,op:op};
    env.job.core_id=2;env.job.data_context=16'h1234;env.job.position_base=7;env.job.rope_pair_base=32;
    env.job.user_tag=64'h123456789abcdef0;env.job_valid=1;
    do @(posedge env.clk);while(!env.job_ready);
    @(negedge env.clk);env.job_valid=0;feed_enable=1;
  endtask
  task automatic accept_vector;
    fork
      begin wait(env.vector_valid);end
      begin repeat(20000)@(negedge env.clk);$fatal(1,"fault setup vector timeout op=%0d",env.job.header.op);end
    join_any
    disable fork;
    @(negedge env.clk);vc=env.vector_cmd;env.vector_ready=1;
    @(posedge env.clk);if(!env.vector_valid)$fatal(1,"vector command disappeared");
    @(negedge env.clk);env.vector_ready=0;env.acc_token=vc.token;old_token=vc.token;
  endtask
  task automatic accept_function;
    fork
      begin wait(env.function_valid);end
      begin repeat(20000)@(negedge env.clk);$fatal(1,"fault setup SFU timeout op=%0d",env.job.header.op);end
    join_any
    disable fork;
    @(negedge env.clk);fc=env.function_cmd;env.function_ready=1;
    @(posedge env.clk);if(!env.function_valid)$fatal(1,"function command disappeared");
    @(negedge env.clk);env.function_ready=0;
  endtask
  task automatic setup_v;
    launch(OP_V_PROJ);accept_vector();
    if(vc.function_id!=VECTOR_V_QUANT)$fatal(1,"V setup");
  endtask
  task automatic setup_rope;
    launch(OP_K_PROJ);accept_vector();
    if(vc.function_id!=VECTOR_ROPE_QUANT)$fatal(1,"RoPE setup");
  endtask
  task automatic setup_qk;
    env.prepare_q();launch(OP_ATTENTION);accept_vector();
    if(vc.function_id!=VECTOR_QK_POST||vc.tile!=0)$fatal(1,"QK setup");
  endtask
  task automatic setup_pexp;
    setup_qk();
    for(int r=0;r<ROWS;r++)begin
      payload='0;env.memory_access(vc,0,WORK_SCORE,r,0,1,payload,value);
      env.memory_access(vc,0,WORK_M,r,0,1,payload,value);
      env.memory_access(vc,0,WORK_AA,r,0,1,payload,value);
    end
    @(negedge env.clk);env.vector_done='{command:vc,error:0};env.vector_done_valid=1;
    do @(posedge env.clk);while(!env.vector_done_ready);
    @(negedge env.clk);env.vector_done_valid=0;
    accept_function();if(fc.function_id!=FUNCTION_ALPHA_EXP)$fatal(1,"ALPHA setup");
    for(int r=0;r<ROWS;r++)begin
      payload='0;payload[0]=32'h3f800000;env.memory_access(fc,1,WORK_ALPHA,r,0,1,payload,value);
    end
    @(negedge env.clk);env.function_done='{command:fc,error:0};env.function_done_valid=1;
    do @(posedge env.clk);while(!env.function_done_ready);
    @(negedge env.clk);env.function_done_valid=0;
    accept_vector();if(vc.function_id!=VECTOR_P_POST)$fatal(1,"P_POST setup");
    accept_function();if(fc.function_id!=FUNCTION_P_EXP)$fatal(1,"P_EXP setup");
  endtask
  task automatic base_quant;
    env.vector_result='0;env.vector_result.token=vc.token;env.vector_result.tile=vc.tile;
    env.vector_result.quant_axis=QUANT_TOKEN_B16;env.vector_result.vector_valid=3;env.vector_result.token_mask='1;
  endtask
  task automatic base_exp;
    env.function_result='0;env.function_result.job=fc.job;env.function_result.token=fc.token;
    env.function_result.tile=fc.tile;env.function_result.vector_valid=3;
  endtask
  task automatic finish_v_results;
    env.kv_out_ready=1;
    for(int j=0;j<V_PACKETS_PER_TILE;j++)begin
      env.vector_data_ready=1;do @(posedge env.clk);while(!env.vector_data_valid);
      a=env.vector_data.first;b=env.vector_data.second;
      @(negedge env.clk);env.vector_data_ready=0;
      env.result_pair(vc,vc.tile,j,env.quant(a),env.quant(b),1,j>=24?16'h7:16'hffff);
    end
  endtask
  task automatic finish_exp_results;
    env.vector_data_ready=1;
    for(int p=0;p<PAIRS;p++)begin
      base_exp();env.function_result.index=6'(p);env.function_result.vector_valid=row_mask(p);env.function_result.last=p==PAIRS-1;
      env.function_result_valid=1;do @(posedge env.clk);while(!env.function_result_ready);
      @(negedge env.clk);env.function_result_valid=0;
    end
  endtask
  task automatic cancel_here(input string name);
    if(!env.busy||env.done_valid||env.protocol_error)$fatal(1,"cancel not in healthy active job %s",name);
    cancels_checked++;flush_recover(name,1);
    $display("CONTROL_CANCEL_PASS stage=%s total=%0d",name,cancels_checked);
  endtask
  task automatic numerical_recovery;
    env.agents_enabled=1;env.vpu_flush_ack=1;env.sfu_flush_ack=1;
    env.run_job(OP_V_PROJ,900+recoveries,3328);
    if(env.sent[OP_V_PROJ]!=128)$fatal(1,"recovery output count");
    recoveries++;env.agents_enabled=0;
    $display("CONTROL_RECOVERY_PASS jobs=%0d",recoveries);
    flush_recover("after numerical recovery");
  endtask
  task automatic prepare_o;
    @(negedge env.clk);env.ext_qoz_region='0;
    env.ext_qoz_region.header='{job_id:16'd30,epoch:4'd3,head:3'd1,op:OP_ATTENTION};
    env.ext_qoz_region.owner=QOZ_O;env.ext_qoz_region.tiles=16;env.ext_qoz_region_valid=1;
    do @(posedge env.clk);while(!env.ext_qoz_region_ready);
    @(negedge env.clk);env.ext_qoz_region_valid=0;
    for(int t=0;t<16;t++)for(int p=0;p<PAIRS;p++)begin
      env.ogold[t][2*p]=env.qv(1);if(p<25)env.ogold[t][2*p+1]=env.qv(1);
      env.ext_qoz_wr='0;env.ext_qoz_wr.header=env.ext_qoz_region.header;env.ext_qoz_wr.n=6'(t);
      env.ext_qoz_wr.pair_data.tile_idx=6'(t);env.ext_qoz_wr.pair_data.pair_idx=PAIR_BITS'(p);
      env.ext_qoz_wr.pair_data.row_valid=row_mask(p);env.ext_qoz_wr.last=p==PAIRS-1;
      env.ext_qoz_wr.pair_data.row[0]=env.qv(1);env.ext_qoz_wr.pair_data.row[1]=env.qv(1);
      env.ext_qoz_wr_valid=1;do @(posedge env.clk);while(!env.ext_qoz_wr_ready);
      @(negedge env.clk);env.ext_qoz_wr_valid=0;
    end
  endtask
  task automatic run_to_cancel(input pcore_op_e op,input control_function_e target,input string name);
    bit reached;
    reached=0;env.agents_enabled=1;
    fork
      begin env.run_job(op,700+serial++,op==OP_ATTENTION?45760:op==OP_V_PROJ?3328:26624);end
      begin
        if(op==OP_V_PROJ)wait(env.kv_out_valid);
        else if(op==OP_O_PROJ)wait(env.reduce_out_valid);
        else wait(env.dut.vb_q&&env.dut.vheld_q.function_id==target);
        @(negedge env.clk);env.agents_enabled=0;reached=1;
      end
    join_any
    disable fork;
    if(!reached)$fatal(1,"completed before cancel target %s",name);
    cancel_here(name);numerical_recovery();
  endtask
  task automatic cancellation_sweep;
    env.prepare_q();run_to_cancel(OP_ATTENTION,VECTOR_OACC_SCALE,"OACC_SCALE");
    for(int r=0;r<ROWS;r++)begin env.m[r]=32'hff800000;env.lsum[r]=0;end
    env.prepare_q();run_to_cancel(OP_ATTENTION,VECTOR_AFIN_QUANT,"A_FIN");
    env.hold_kv=1;run_to_cancel(OP_V_PROJ,VECTOR_V_QUANT,"KV_output");
    prepare_o();env.hold_reduce=1;run_to_cancel(OP_O_PROJ,VECTOR_CAPTURE,"reduce_output");
    $display("tb_pcore_control_cancel PASS clear_cases=%0d numerical_recoveries=%0d SCALE=1 A_FIN=1 KV_output=1 reduce_output=1",cancels_checked,recoveries);
    $finish;
  endtask
  task automatic rope_request;
    env.rope_req='{token:vc.token,row:6'd3,position:16'(vc.job.position_base+3),frequency_base:vc.rope_frequency_base};
  endtask
  task automatic acc_credit;
    // Four accepted reads reserve all response space; a fifth must wait.
    env.acc_rd_sel=vc.attention_vpu.facc_bank?ACC_FACC_B:ACC_FACC_A;
    for(int i=0;i<4;i++)begin
      @(negedge env.clk);env.acc_rd_addr=10'(i);env.acc_rd_valid=1;
      do @(posedge env.clk);while(!env.acc_rd_ready);
    end
    @(negedge env.clk);env.acc_rd_addr=4;
    repeat(32)begin
      @(negedge env.clk);
      if(env.acc_rd_ready||!env.acc_data_valid||env.done_valid)$fatal(1,"ACC four credits overflow");
    end
    env.acc_data_ready=1;
    for(int i=0;i<5;i++)begin
      do @(posedge env.clk);while(!env.acc_data_valid);
      for(int lane=0;lane<TILE;lane++)begin
        logic [31:0] ge,go;
        ge=0;go=0;
        for(int k=0;k<16;k++)begin
          ge=fp32_legacy_ref_pkg::fp32_add(ge,env.dot_part(env.qgold[k][2*i],1,128,-4));
          go=fp32_legacy_ref_pkg::fp32_add(go,env.dot_part(env.qgold[k][2*i+1],1,128,-4));
        end
        if(env.acc_even[lane]!==ge||env.acc_odd[lane]!==go)$fatal(1,"ACC burst data/order addr=%0d",i);
      end
      @(negedge env.clk);if(i==0)env.acc_rd_valid=0;
    end
    env.acc_data_ready=0;
    repeat(5)@(negedge env.clk);
    if(env.acc_data_valid)$fatal(1,"duplicate ACC response");
    $display("CONTROL_ACC_CREDIT_PASS reserved=4 requests=5 responses=5 full_pop_push=1 hold=32");
  endtask

  initial begin
    wait(!env.reset);env.allow_fault=1;quiesce();
    if(CANCEL_SWEEP)cancellation_sweep();
    // Projection response identity/layout/count faults.
    for(int k=0;k<9;k++)begin
      setup_v();base_quant();
      case(k)
        0:env.vector_result.token.command_id^=2;
        1:env.vector_result.token.generation--;
        2:env.vector_result.tile++;
        3:env.vector_result.index=1;
        4:env.vector_result.vector_valid=1;
        5:env.vector_result.last=1;
        6:env.vector_result.quant_axis=QUANT_FEATURE_B16;
        7:env.vector_result.token_mask=7;
        8:begin end
      endcase
      if(k==8)begin
        repeat(31)begin @(negedge env.clk);if(env.done_valid)$fatal(1,"missing results allowed completion");end
        env.vector_done='{command:vc,error:0};env.vector_done_valid=1;
      end else env.vector_result_valid=1;
      expect_fault($sformatf("projection_result_%0d",k));
    end
    for(int k=0;k<3;k++)begin
      setup_v();finish_v_results();env.vector_done='{command:vc,error:0};
      case(k)
        0:env.vector_done.command.token.command_id^=2;
        1:env.vector_done.command.job.user_tag^=1;
        2:env.vector_done.error=1;
      endcase
      env.vector_done_valid=1;expect_fault($sformatf("command_done_%0d",k));
    end
    setup_v();finish_v_results();
    base_quant();env.vector_result.index=0;env.vector_result_valid=1;
    expect_fault("excess_projection_result");
    setup_v();finish_v_results();
    @(negedge env.clk);env.vector_done='{command:vc,error:0};env.vector_done_valid=1;
    do @(posedge env.clk);while(!env.vector_done_ready);
    @(negedge env.clk);env.vector_done_valid=0;
    @(negedge env.clk);env.vector_done_valid=1;expect_fault("duplicate_done");

    setup_qk();acc_credit();cancel_here("QK_ACC_response");
    for(int k=0;k<7;k++)begin
      setup_qk();env.vector_mem_req='0;env.vector_mem_req.token=vc.token;
      env.vector_mem_req.buffer_id=WORK_M;env.vector_mem_req.mask=1;
      case(k)
        0:env.vector_mem_req.token.command_id^=2;
        1:env.vector_mem_req.index=51;
        2:env.vector_mem_req.buffer_id=WORK_RECIP;
        3:env.vector_mem_req.bank=1;
        4:begin env.vector_mem_req.write=1;env.vector_mem_req.mask=0;end
        5:begin env.vector_mem_req.write=1;env.vector_mem_req.index=50;env.vector_mem_req.mask=3;end
        6:begin
          payload='0;env.memory_access(vc,0,WORK_M,0,0,1,payload,value);
          env.vector_mem_req.write=1;
        end
      endcase
      env.vector_mem_valid=1;expect_fault($sformatf("workspace_%0d",k));
    end
    setup_qk();env.acc_rd_sel=ACC_OACC;env.acc_rd_addr=0;env.acc_rd_valid=1;
    expect_fault("ACC_wrong_store");
    setup_qk();env.acc_rd_sel=vc.attention_vpu.facc_bank?ACC_FACC_B:ACC_FACC_A;
    env.acc_rd_addr=PAIRS;env.acc_rd_valid=1;expect_fault("ACC_range");
    setup_qk();env.acc_rd_sel=vc.attention_vpu.facc_bank?ACC_FACC_B:ACC_FACC_A;
    env.acc_rd_addr=0;env.acc_token.command_id^=2;env.acc_rd_valid=1;expect_fault("ACC_wrong_token");
    setup_qk();env.acc_wr='0;env.acc_wr.sel=ACC_OACC;env.acc_wr_valid=1;
    expect_fault("ACC_write_permission");
    setup_qk();
    for(int r=0;r<ROWS;r++)begin
      payload='0;env.memory_access(vc,0,WORK_SCORE,r,0,1,payload,value);
      env.memory_access(vc,0,WORK_M,r,0,1,payload,value);
      env.memory_access(vc,0,WORK_AA,r,0,1,payload,value);
    end
    env.acc_rd_sel=vc.attention_vpu.facc_bank?ACC_FACC_B:ACC_FACC_A;env.acc_rd_addr=0;
    env.acc_rd_valid=1;env.vector_done='{command:vc,error:0};env.vector_done_valid=1;
    #1;if(env.vector_done_ready)$fatal(1,"done crossed same-edge ACC reservation");
    expect_fault("done_with_new_ACC_request");
    setup_qk();
    for(int r=0;r<ROWS;r++)begin
      payload='0;env.memory_access(vc,0,WORK_SCORE,r,0,1,payload,value);
      env.memory_access(vc,0,WORK_M,r,0,1,payload,value);
      env.memory_access(vc,0,WORK_AA,r,0,1,payload,value);
    end
    env.vector_mem_req='{token:vc.token,buffer_id:WORK_M,bank:0,write:0,index:0,mask:1,data:'0};
    env.vector_mem_valid=1;do @(posedge env.clk);while(!env.vector_mem_ready);
    @(negedge env.clk);env.vector_mem_valid=0;wait(env.vector_mem_out_valid);
    repeat(32)begin @(negedge env.clk);if(env.done_valid)$fatal(1,"held RAM response completion");end
    env.vector_done='{command:vc,error:0};env.vector_done_valid=1;
    expect_fault("early_done_with_RAM_response");

    for(int k=0;k<11;k++)begin
      setup_pexp();base_exp();
      case(k)
        0:env.function_result.token.command_id^=2;
        1:env.function_result.token.generation--;
        2:env.function_result.tile=1;
        3:env.function_result.index=1;
        4:env.function_result.vector_valid=1;
        5:env.function_result.last=1;
        6:env.function_result.job.user_tag^=1;
        7:begin end
      endcase
      if(k>=7)begin
        if(k>7)finish_exp_results();
        env.function_done='{command:fc,error:0};
        if(k==8)env.function_done.command.job.user_tag^=1;
        if(k==9)env.function_done.error=1;
        if(k==10)env.function_done.command.token.generation--;
        env.function_done_valid=1;
      end
      else env.function_result_valid=1;
      expect_fault($sformatf("P_EXP_return_%0d",k));
    end
    setup_pexp();finish_exp_results();
    base_exp();env.function_result.index=PAIRS;env.function_result_valid=1;expect_fault("excess_P_EXP_result");
    setup_pexp();finish_exp_results();
    @(negedge env.clk);env.function_done='{command:fc,error:0};env.function_done_valid=1;
    do @(posedge env.clk);while(!env.function_done_ready);
    @(negedge env.clk);env.function_done_valid=0;
    @(negedge env.clk);env.function_done_valid=1;expect_fault("duplicate_SFU_done");
    setup_pexp();finish_exp_results();
    env.function_mem_req='{token:fc.token,buffer_id:WORK_M,bank:0,write:0,index:0,mask:1,data:'0};
    env.function_mem_valid=1;do @(posedge env.clk);while(!env.function_mem_ready);
    @(negedge env.clk);env.function_mem_valid=0;wait(env.function_mem_out_valid);
    repeat(32)@(negedge env.clk);
    env.function_done='{command:fc,error:0};env.function_done_valid=1;
    expect_fault("SFU_done_with_held_RAM_response");
    for(int k=0;k<5;k++)begin
      setup_pexp();env.function_mem_req='{token:fc.token,buffer_id:WORK_M,bank:0,write:0,index:0,mask:1,data:'0};
      case(k)
        0:env.function_mem_req.token.command_id^=2;
        1:env.function_mem_req.index=51;
        2:env.function_mem_req.bank=1;
        3:env.function_mem_req.write=1;
        4:env.function_mem_req.buffer_id=WORK_ALPHA;
      endcase
      env.function_mem_valid=1;expect_fault($sformatf("SFU_workspace_%0d",k));
    end
    setup_pexp();cancel_here("P_EXP");
    for(int k=0;k<4;k++)begin
      setup_rope();rope_request();
      case(k)
        0:begin env.rope_req.row=51;env.rope_req.position=16'(vc.job.position_base+51);end
        1:env.rope_req.position++;
        2:env.rope_req.frequency_base++;
        3:env.rope_req.token.command_id^=2;
      endcase
      env.rope_req_valid=1;expect_fault($sformatf("RoPE_request_%0d",k));
    end
    for(int k=0;k<5;k++)begin
      setup_rope();rope_request();env.rope_sfu_ready=0;env.rope_req_valid=1;
      repeat(17)begin @(negedge env.clk);if(env.rope_req_ready||!env.rope_sfu_valid)$fatal(1,"RoPE request backpressure");end
      env.rope_sfu_ready=1;@(posedge env.clk);@(negedge env.clk);env.rope_req_valid=0;
      repeat(13)@(negedge env.clk);
      env.rope_sfu_out='0;env.rope_sfu_out.request=env.rope_req;
      case(k)
        0:env.rope_sfu_out.request.row++;
        1:env.rope_sfu_out.request.position++;
        2:env.rope_sfu_out.request.frequency_base++;
        3:env.rope_sfu_out.request.token.generation--;
        4:begin
          env.rope_sfu_out_valid=1;
          repeat(32)begin @(negedge env.clk);if(!env.rope_out_valid||env.rope_sfu_out_ready)$fatal(1,"RoPE response backpressure");end
          env.rope_out_ready=1;@(posedge env.clk);@(negedge env.clk);env.rope_sfu_out_valid=0;env.rope_out_ready=0;
          @(negedge env.clk);
        end
      endcase
      env.rope_sfu_out_valid=1;expect_fault($sformatf("RoPE_response_%0d",k));
    end
    launch(OP_V_PROJ);repeat(40)@(negedge env.clk);cancel_here("Projection_matrix");
    setup_rope();rope_request();env.rope_req_valid=1;
    do @(posedge env.clk);while(!env.rope_req_ready);
    @(negedge env.clk);env.rope_req_valid=0;cancel_here("RoPE_pending");
    launch(OP_GU);accept_vector();accept_function();
    if(fc.function_id!=FUNCTION_GELU)$fatal(1,"GELU cancel stage");
    cancel_here("GU_GELU");
    numerical_recovery();
    stale_token=old_token;
    setup_v();base_quant();env.vector_result.token=stale_token;env.vector_result_valid=1;
    expect_fault("old_generation_after_recovery");
    numerical_recovery();
    $display("tb_pcore_control_faults PASS fault_cases=%0d clear_cases=%0d numerical_recoveries=%0d real_matrix=1 acc_credit=4",failures_checked,cancels_checked,recoveries);
    $finish;
  end
endmodule

module tb_pcore_control_cancel;
  tb_pcore_control_faults #(.CANCEL_SWEEP(1)) tests();
endmodule
