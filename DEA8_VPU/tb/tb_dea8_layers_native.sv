`timescale 1ns/1ps
import pcore_pkg::*;
import pcore_control_pkg::*;
import dea8_tile_link_pkg::*;
import gcore_pkg::*;

// Server acceptance: real GCore + eight complete PCores. No arithmetic service
// is implemented in this TB. Only HBM, DEA8 policy and final receiving are TB.
module tb_dea8_layers_native;
  logic clk=0;always #2 clk=~clk;
  logic reset=1;
  logic [7:0] pc_config_valid=0,pc_config_ready,pc_configured;
  logic [15:0] pc_config_context=16'h1234,pc_mask_version=1,pc_rope_version=1,pc_position=816;
  logic [7:0] pc_rope_load_valid=0,pc_rope_load_ready,pc_rope_loaded;
  logic [10:0] pc_rope_load_address=0;logic [255:0] pc_rope_load_data=0;logic pc_rope_load_last=0;
  logic [1023:0] rope_coefficients[408];
  logic [7:0] pc_job_valid=0,pc_job_ready,pc_done_valid,pc_done_ready='1,pc_busy,pc_fault;
  control_job_t pc_job[8];control_completion_t pc_done[8];
  logic [7:0] hbm_valid,hbm_offer=0,hbm_ready;b2_t hbm[8];
  logic hbm_stopped=0,release_drain=0;
  logic gc_config_valid=0,gc_config_ready,gc_config_done_valid,gc_config_done_ready=1;
  gcore_context_t gc_config;gcore_status_e gc_config_status;
  logic preloaded_valid=0,preloaded_ready,preloaded_done_valid,preloaded_done_ready=1;
  gcore_preloaded_t preloaded;gcore_status_e preloaded_status;
  logic layer_valid=0,layer_ready,layer_done_valid,layer_done_ready=1;
  gcore_layer_t layer_data;gcore_status_e layer_status;
  logic gc_job_valid=0,gc_job_ready,gc_job_done_valid,gc_job_done_ready=1,gc_job_busy;
  gcore_job_t gc_job;gcore_job_done_t gc_job_done;gcore_xhat_t xhat_status;
  logic gamma_fetch_valid,gamma_fetch_ready,gamma_data_valid,gamma_data_ready;
  gamma_fetch_t gamma_fetch,gamma_request;gamma_beat_t gamma_data;
  logic final_valid,final_ready=1;gcore_final_t final_data;
  logic cmd_valid=0,cmd_ready,done_valid,done_ready=1;gcore_cmd_t cmd;gcore_done_t done;
  logic import_valid=0,import_ready;residual_import_t import_data;
  logic gamma_load_valid=0,gamma_load_ready,gamma_done_valid,gamma_done_ready=1;
  gamma_load_t gamma_load;gcore_status_e gamma_status;logic [15:0] gamma_loaded_id;
  logic invalidate_valid=0,invalidate_ready;logic [OBJECTS-1:0] invalidate_mask=0;
  logic kv_release_valid=0,kv_release_ready,kv_lease;
  logic cancel_valid=0,cancel_ready,cancel_done_valid,cancel_done_ready=1;
  logic hbm_flush_valid,hbm_flush_ack=0;logic [SERVICES-1:0] gc_busy;logic gc_fault;
  dea8_layer_top dut(.*);
  assign hbm_valid=hbm_offer&{8{!hbm_flush_valid&&!hbm_stopped}};
  logic [255:0] initial_resid[VECTOR_WORDS],mid_resid[VECTOR_WORDS],next_resid[VECTOR_WORDS];
  logic [135:0] xhat0[VECTOR_WORDS],xhat1[VECTOR_WORDS],xhat2[VECTOR_WORDS];
  logic [511:0] final_gold[VECTOR_WORDS];logic [31:0] gamma0[1024],gamma1[1024];
  bit gc_complete[16],pc_complete[8][16],cmd_complete[256];
  int cycle=0,layer_number=1,phase=0,quant_count=0,write_count=0,final_count=0,kv_commits=0,fp_tiles=0;
  int matrix_issues[8],xbc_count[8],kvb_count[8],pc_job_count[8],qoz_words[8],p_words[8];
  int gc_job_count=0,fetch_count=0,gamma_words=0,job_start[8][16],job_end[8][16];
  int qk_count[8],pv_count[8],wire_count[8];
  int gamma_index=0,flush_age=0;
  bit gamma_active=0,gamma_offer=0,stress=0,negative=0,cancellation_quiescent=0;
  bit cancelled=0,recover=0;
  string cancel_at="";

  // Residual and prefix RAM initialization exceptions execute only at time
  // zero. RoPE coefficients use the public preload transaction below.
  initial begin
    $readmemh("tb/data/layer_native/initial.mem",initial_resid);
    $readmemh("tb/data/layer_native/mid.mem",mid_resid);
    $readmemh("tb/data/layer_native/next.mem",next_resid);
    $readmemh("tb/data/layer_native/xhat0.mem",xhat0);
    $readmemh("tb/data/layer_native/xhat1.mem",xhat1);
    $readmemh("tb/data/layer_native/xhat2.mem",xhat2);
    $readmemh("tb/data/layer_native/final.mem",final_gold);
    $readmemh("tb/data/layer_native/gamma0.mem",gamma0);
    $readmemh("tb/data/layer_native/gamma1.mem",gamma1);
    for(int a=0;a<VECTOR_WORDS;a++)dut.gcore.services.residual_store.memory[a]=initial_resid[a];
  end
  for(genvar kind=0;kind<2;kind++)begin: initial_kind
    for(genvar feature=0;feature<16;feature++)begin: initial_feature
      for(genvar parity=0;parity<2;parity++)begin: initial_parity
        logic [135:0] prefix_words[PREFIX_BANK_DEPTH];
        initial begin
          $readmemh($sformatf("tb/data/layer_native/prefix_%0d_%0d_%0d.mem",kind,feature,parity),prefix_words);
          for(int a=0;a<PREFIX_BANK_DEPTH;a++)
            dut.gcore.services.kv_store.preload_prefix(kind,feature,parity,a,prefix_words[a]);
        end
      end
    end
  end
  function automatic int weight(input int core_id,input pcore_op_e op,input int nt,kt,col,input bit up);
    int value;value=1+(core_id*5+nt*16+col+kt%3)%7;
    if(op==OP_GU&&!up&&(nt*16+col+core_id)%4==0)value=-value;
    if(op==OP_GU&&up)value=1+value%3;
    return value;
  endfunction
  function automatic b2_t bword(input int c,n,k,g,transport,input bit up);
    b2_t b;b='0;b.tile_idx=TILE_BITS'(transport);b.group_idx=3'(g);b.epoch=gc_config.pcore_epoch;
    for(int column=0;column<2;column++)begin
      b.col[column].scale=128;
      for(int j=0;j<16;j++)b.col[column].data[8*j+:8]=8'(weight(c,pc_job[c].header.op,n,k,2*g+column,up));
    end
    return b;
  endfunction
  task automatic send_b(input int c,n,k,g,transport,input bit up);
    @(negedge clk);hbm[c]=bword(c,n,k,g,transport,up);
    if(stress&&(cycle+c*7)%31==0)begin hbm_offer[c]=0;repeat(c%3+1)@(negedge clk);end
    hbm_offer[c]=1;do @(posedge clk);while(!hbm_ready[c]);
  endtask
  task automatic feed_core(input int c,input pcore_op_e op,input int id);
    int nt,kt;
    wait(job_start[c][id]>0);
    if(op==OP_ATTENTION)begin @(negedge clk);hbm_offer[c]=0;end
    else if(op==OP_GU)begin
      for(int n=0;n<32;n++)for(int tile=0;tile<128;tile++)for(int g=0;g<8;g++)
        send_b(c,n,tile/2,g,tile%64,tile[0]);
      @(negedge clk);hbm_offer[c]=0;
    end else begin
      nt=(op==OP_K_PROJ||op==OP_V_PROJ)?2:(op==OP_Q_PROJ?16:64);
      kt=op==OP_O_PROJ?16:(op==OP_DOWN_PROJ?32:64);
      for(int n=0;n<nt;n++)for(int k=0;k<kt;k++)for(int g=0;g<8;g++)
        send_b(c,n,k,g,(op==OP_O_PROJ||op==OP_DOWN_PROJ)?(n*kt+k)%64:k,0);
      @(negedge clk);hbm_offer[c]=0;
    end
  endtask
  task automatic send_pc_jobs(input pcore_op_e op,input int id);
    for(int c=0;c<8;c++)begin
      pc_job[c]='0;pc_job[c].header='{job_id:16'(id),epoch:gc_config.pcore_epoch,head:3'(c),op:op};
      pc_job[c].core_id=3'(c);pc_job[c].data_context=gc_config.data_context;pc_job[c].position_base=gc_config.position_base;
      pc_job[c].rope_pair_base=8'(16*c);pc_job[c].user_tag={32'(layer_number),32'(id)};
      case(op)
        OP_K_PROJ:pc_job[c].transfer=gc_config.k_transfer;
        OP_V_PROJ:pc_job[c].transfer=gc_config.v_transfer;
        OP_O_PROJ:pc_job[c].transfer=gc_config.o_transfer;
        OP_DOWN_PROJ:pc_job[c].transfer=gc_config.down_transfer;
        default:pc_job[c].transfer='0;
      endcase
    end
    @(negedge clk);pc_job_valid='1;
    while(pc_job_valid!=0)begin
      logic [7:0] accepted;
      @(posedge clk);accepted=pc_job_valid&pc_job_ready;
      @(negedge clk);pc_job_valid&=~accepted;
    end
  endtask
  task automatic send_gc_job(input gcore_job_e op,input int id);
    @(negedge clk);gc_job='{op:op,command_id:16'(id),context_id:gc_config.context_id,
      generation:gc_config.generation,layer_id:5'(layer_number)};gc_job_valid=1;
    do @(posedge clk);while(!gc_job_ready);@(negedge clk);gc_job_valid=0;
  endtask
  function automatic bit all_pc_done(input int id);
    for(int c=0;c<8;c++)if(!pc_complete[c][id])return 0;
    return 1;
  endfunction
  task automatic negative_cancel;
    int writes_before;
    case(cancel_at)
      "K","Q":wait(dut.cluster.core[0].pcore.rope_req_valid&&dut.cluster.core[0].pcore.rope_req_ready);
      "Attention":begin
        wait(dut.cluster.core[0].pcore.function_valid&&dut.cluster.core[0].pcore.function_ready&&
          dut.cluster.core[0].pcore.function_cmd.function_id==FUNCTION_P_EXP);
        repeat(50)@(negedge clk);
      end
      "SCALE":wait(dut.cluster.core[0].pcore.acc_wr_valid&&dut.cluster.core[0].pcore.acc_wr_ready);
      "GU":begin
        wait(dut.cluster.core[0].pcore.function_data_valid&&dut.cluster.core[0].pcore.function_data_ready);
        repeat(50)@(negedge clk);
      end
      "O","Down":wait(dut.gcore.services.ram_wr_valid&&dut.gcore.services.ram_wr_ready);
      "Final":wait(final_valid);
      default:$fatal(1,"Unsupported cancellation stage %s",cancel_at);
    endcase
    @(negedge clk);negative=1;cancel_valid=1;
    do @(posedge clk);while(!cancel_ready);@(negedge clk);cancel_valid=0;
    wait(cancel_done_valid);wait(!dut.gc_flush);repeat(8)@(negedge clk);
    cancellation_quiescent=1;
    writes_before=write_count;
    repeat(100)@(negedge clk);
    if(write_count!=writes_before||(|pc_busy)||gc_job_busy||gc_fault||(|pc_fault)||dut.gcore.services.context_valid)
      $fatal(1,"Cancel did not retire all old-generation work");
    if(recover)begin
      $display("CANCEL_DRAINED stage=%s real_cores=8 external_drain=1 no_stale_write=1",cancel_at);
      cancelled=1;
    end else begin
      $display("tb_dea8_layers_native PASS negative=cancel stage=%s real_cores=8 external_drain=1 no_stale_write=1",cancel_at);$finish;
    end
  endtask
  task automatic phase_run(input pcore_op_e op,input gcore_job_e gop,input int id,input bit wait_gcore=1);
    int begin_cycle;
    phase=id;begin_cycle=cycle;
    fork
      feed_core(0,op,id);feed_core(1,op,id);feed_core(2,op,id);feed_core(3,op,id);
      feed_core(4,op,id);feed_core(5,op,id);feed_core(6,op,id);feed_core(7,op,id);
      send_gc_job(gop,id);send_pc_jobs(op,id);
      begin
        if((op==OP_K_PROJ&&cancel_at=="K")||(op==OP_Q_PROJ&&cancel_at=="Q")||
          (op==OP_ATTENTION&&(cancel_at=="Attention"||cancel_at=="SCALE"))||
          (op==OP_GU&&cancel_at=="GU")||(op==OP_O_PROJ&&cancel_at=="O")||
          (op==OP_DOWN_PROJ&&(cancel_at=="Down"||cancel_at=="Final")))negative_cancel();
      end
    join
    wait(all_pc_done(id));if(wait_gcore)wait(gc_complete[id]);
    $display("LAYER_PERF layer=%0d phase=%0d cycles=%0d",layer_number,id,cycle-begin_cycle);
  endtask
  // HBM gamma is an external transaction, not an ersatz Norm/SFU service.
  always_comb begin
    gamma_fetch_ready=!gamma_active&&!hbm_flush_valid;
    gamma_data_valid=gamma_active&&gamma_offer&&!hbm_flush_valid;
    gamma_data='0;gamma_data.token=gamma_request.token;
    gamma_data.value=gamma_index<1024?gamma0[gamma_index%1024]:gamma1[gamma_index%1024];
    gamma_data.last=gamma_index==(gamma_request.final_group?1023:2047);
  end
  always @(posedge clk)begin
    cycle++;
    if(reset)begin gamma_active<=0;gamma_offer<=0;flush_age<=0;hbm_flush_ack<=0;hbm_stopped<=0;end
    else begin
      if(hbm_flush_valid)begin
        gamma_active<=0;gamma_offer<=0;hbm_stopped<=1;
        if(flush_age<7)flush_age<=flush_age+1;else hbm_flush_ack<=1;
      end else begin flush_age<=0;hbm_flush_ack<=0;if(release_drain)hbm_stopped<=0;end
      if(!gamma_offer||(gamma_data_valid&&gamma_data_ready))gamma_offer<=!stress||cycle%11>2;
      if(gamma_fetch_valid&&gamma_fetch_ready)begin
        gamma_request<=gamma_fetch;gamma_active<=1;gamma_index<=0;fetch_count++;
      end
      if(gamma_data_valid&&gamma_data_ready)begin
        gamma_words++;if(gamma_data.last)gamma_active<=0;else gamma_index<=gamma_index+1;
      end
      if(!negative&&(gc_fault||(|pc_fault)))$fatal(1,"Real layer fault phase=%0d gc=%b pc=%h",phase,gc_fault,pc_fault);
      if(gc_job_done_valid&&gc_job_done_ready)begin
        if(!negative&&gc_job_done.status!=GC_OK)$fatal(1,"GCore macro failed id=%0d status=%0d",gc_job_done.job.command_id,gc_job_done.status);
        if(gc_complete[gc_job_done.job.command_id])$fatal(1,"Duplicate GCore completion");
        gc_complete[gc_job_done.job.command_id]=1;gc_job_count++;
      end
      if(done_valid&&done_ready)begin
        if(done.status!=GC_OK)$fatal(1,"GCore management command failed");
        cmd_complete[done.command_id]=1;
      end
      for(int c=0;c<8;c++)begin
        if(pc_job_valid[c]&&pc_job_ready[c])job_start[c][pc_job[c].header.job_id]=cycle;
        if(pc_done_valid[c]&&pc_done_ready[c])begin
          if(!negative&&(pc_done[c].status!=CONTROL_OK||pc_done[c].job!==pc_job[c]))$fatal(1,"PCore completion core=%0d",c);
          if(pc_complete[c][pc_done[c].job.header.job_id])$fatal(1,"Duplicate PCore completion");
          pc_complete[c][pc_done[c].job.header.job_id]=1;job_end[c][pc_done[c].job.header.job_id]=cycle;pc_job_count[c]++;
        end
        if(dut.xbc_valid[c]&&dut.xbc_ready[c])xbc_count[c]++;
        if(dut.kv_valid[c]&&dut.kv_ready[c])kvb_count[c]++;
        if(dut.tx_valid[c]&&dut.tx_ready[c])wire_count[c]++;
        if(dut.kv_commit_valid[c]&&dut.kv_commit_ready[c])kv_commits++;
      end
      if(dut.gcore.services.fp_retire)fp_tiles++;
      if(dut.gcore.services.activation_valid&&dut.gcore.services.activation_ready)begin
        logic [135:0] gold;int index;
        index=dut.gcore.services.activation_index;
        gold=quant_count<VECTOR_WORDS?xhat0[index]:(quant_count<2*VECTOR_WORDS?xhat1[index]:xhat2[index]);
        if(!negative&&dut.gcore.services.activation_word!==gold)$fatal(1,"Real GCore quant group=%0d index=%0d actual=%h expected=%h",quant_count/VECTOR_WORDS,index,dut.gcore.services.activation_word,gold);
        quant_count++;
      end
      if(dut.gcore.services.ram_wr_valid&&dut.gcore.services.ram_wr_ready)begin
        int a;a=dut.gcore.services.ram_wr_addr;
        if(!negative&&dut.gcore.services.ram_wr_data!==(write_count<VECTOR_WORDS?mid_resid[a]:next_resid[a]))
          $fatal(1,"Real GCore reduce/residual group=%0d index=%0d",write_count/VECTOR_WORDS,a);
        write_count++;
      end
      if(final_valid&&final_ready)begin
        if(layer_number!=18||final_data.index!=final_count||final_data.last!=(final_count==VECTOR_WORDS-1))$fatal(1,"Final coordinates");
        for(int j=0;j<16;j++)begin
          longint signed delta;logic [31:0] actual,gold;
          actual=final_data.data[j*32+:32];gold=final_gold[final_count][j*32+:32];
          delta=longint'({1'b0,actual[30:0]})-longint'({1'b0,gold[30:0]});
          if((^actual)===1'bx||actual[31]!=gold[31]||delta>5||delta< -5)$fatal(1,"Final FP32 index=%0d lane=%0d actual=%h expected=%h",final_count,j,actual,gold);
        end
        final_count++;
      end
    end
  end
  for(genvar c=0;c<8;c++)begin: check_core
    logic [135:0] qgold[816],ogold[816],zgold[1632],pgold[2805],kgold[102],vgold[128];
    logic [511:0] o_partial[VECTOR_WORDS],down_partial[VECTOR_WORDS];
    logic [31:0] score_gold[44880];
    int packet_index=0,beat=0;bit payload=0;tile_header_t header;
    always @(posedge clk)if(negative)begin payload=0;beat=0;end
    always @(posedge clk)if(cancellation_quiescent)begin
      if(dut.cluster.core[c].pcore.control.exec.dispatch.matrix.commit_write_valid||
        (dut.cluster.core[c].pcore.acc_wr_valid&&dut.cluster.core[c].pcore.acc_wr_ready)||
        (dut.cluster.core[c].pcore.control.exec.qoz.store.wr_valid&&dut.cluster.core[c].pcore.control.exec.qoz.store.wr_ready)||
        (dut.cluster.core[c].pcore.vector_mem_valid&&dut.cluster.core[c].pcore.vector_mem_ready&&dut.cluster.core[c].pcore.vector_mem_req.write)||
        (dut.cluster.core[c].pcore.function_mem_valid&&dut.cluster.core[c].pcore.function_mem_ready&&dut.cluster.core[c].pcore.function_mem_req.write)||
        dut.tx_valid[c])$fatal(1,"Old generation wrote after flush core=%0d",c);
    end
    initial begin
      $readmemh($sformatf("tb/data/layer_native/core%0d/q.mem",c),qgold);
      $readmemh($sformatf("tb/data/layer_native/core%0d/o.mem",c),ogold);
      $readmemh($sformatf("tb/data/layer_native/core%0d/z.mem",c),zgold);
      $readmemh($sformatf("tb/data/layer_native/core%0d/p.mem",c),pgold);
      $readmemh($sformatf("tb/data/layer_native/core%0d/k.mem",c),kgold);
      $readmemh($sformatf("tb/data/layer_native/core%0d/v.mem",c),vgold);
      $readmemh($sformatf("tb/data/layer_native/core%0d/score.mem",c),score_gold);
      $readmemh($sformatf("tb/data/layer_native/core%0d/reduce_o.mem",c),o_partial);
      $readmemh($sformatf("tb/data/layer_native/core%0d/reduce_down.mem",c),down_partial);
    end
    always @(posedge clk)if(!reset&&!negative)begin
      if(dut.cluster.core[c].pcore.control.exec.dispatch.matrix.req_valid)matrix_issues[c]++;
      if(dut.cluster.core[c].pcore.control.exec.attention.mdv&&dut.cluster.core[c].pcore.control.exec.attention.mdr)begin
        if(dut.cluster.core[c].pcore.control.exec.attention.md.op==MATRIX_QK)qk_count[c]++;else pv_count[c]++;
      end
      if(dut.cluster.core[c].pcore.control.exec.qoz.store.wr_valid&&dut.cluster.core[c].pcore.control.exec.qoz.store.wr_ready)begin
        int a;logic [135:0] g0,g1;
        a=51*dut.cluster.core[c].pcore.control.exec.qoz.store.wr_tile+2*dut.cluster.core[c].pcore.control.exec.qoz.store.wr_pair;
        case(dut.cluster.core[c].pcore.control.exec.qoz.store.wr_owner)
          QOZ_Q:begin g0=qgold[a];g1=a%51==50?0:qgold[a+1];end
          QOZ_O:begin g0=ogold[a];g1=a%51==50?0:ogold[a+1];end
          default:begin g0=zgold[a];g1=a%51==50?0:zgold[a+1];end
        endcase
        if(dut.cluster.core[c].pcore.control.exec.qoz.store.wr_even!==g0||
          (dut.cluster.core[c].pcore.control.exec.qoz.store.wr_row_valid[1]&&dut.cluster.core[c].pcore.control.exec.qoz.store.wr_odd!==g1))
          $fatal(1,"Core QOZ numerical core=%0d owner=%0d address=%0d",c,dut.cluster.core[c].pcore.control.exec.qoz.store.wr_owner,a);
        qoz_words[c]++;
      end
      if(dut.cluster.core[c].pcore.vector_result_valid&&dut.cluster.core[c].pcore.vector_result_ready&&
         dut.cluster.core[c].pcore.vpu.cmd.function_id==VECTOR_P_POST)begin
        int a;a=dut.cluster.core[c].pcore.vpu.cmd.tile*51+2*dut.cluster.core[c].pcore.vector_result.index;
        for(int r=0;r<2;r++)if(dut.cluster.core[c].pcore.vector_result.vector_valid[r]&&
          dut.cluster.core[c].pcore.vector_result.vector_data[r]!==pgold[a+r])$fatal(1,"P exact quant core=%0d address=%0d",c,a+r);
        p_words[c]++;
      end
      if(dut.cluster.core[c].pcore.vector_mem_valid&&dut.cluster.core[c].pcore.vector_mem_ready&&
         dut.cluster.core[c].pcore.vector_mem_req.write&&dut.cluster.core[c].pcore.vector_mem_req.buffer_id==WORK_SCORE)begin
        int a;a=(dut.cluster.core[c].pcore.vpu.cmd.tile*51+dut.cluster.core[c].pcore.vector_mem_req.index)*16;
        for(int j=0;j<16;j++)if(dut.cluster.core[c].pcore.vector_mem_req.data[j]!==score_gold[a+j])
          $fatal(1,"QK/Mask exact core=%0d address=%0d",c,a+j);
      end
      if(dut.tx_valid[c]&&dut.tx_ready[c])begin
        if(!payload)begin
          if(!packet_header_legal(dut.tx_data[c]))$fatal(1,"Wire header core=%0d",c);
          header=tile_header_t'(dut.tx_data[c][127:0]);beat=0;payload=1;
          if(header.source_id!=c)$fatal(1,"Wire source identity");
        end else begin
          logic [135:0] gold;logic [511:0] fp;
          if(header.kind==TILE_K||header.kind==TILE_V)begin
            gold=header.kind==TILE_K?kgold[header.tile_seq*51+beat]:vgold[header.tile_seq*64+beat];
            if({dut.tx_data[c][127:0],dut.tx_data[c][135:128]}!==gold)$fatal(1,"Wire KV numerical core=%0d beat=%0d",c,beat);
          end else begin
            fp=header.kind==TILE_O?o_partial[51*header.tile_seq+beat/2]:down_partial[51*header.tile_seq+beat/2];
            if(dut.tx_data[c]!==fp[256*(beat%2)+:256])$fatal(1,"Wire FP32 numerical core=%0d tile=%0d beat=%0d",c,header.tile_seq,beat);
          end
          beat++;if(dut.tx_last[c])payload=0;
        end
      end
    end
  end
  task automatic load_gamma(input bit slot);
    for(int i=0;i<1024;i++)begin
      @(negedge clk);gamma_load='{context_id:gc_config.context_id,generation:gc_config.generation,
        param_id:slot?16'h211:16'h210,slot:slot,index:10'(i),value:slot?gamma1[i]:gamma0[i],last:i==1023};
      gamma_load_valid=1;do @(posedge clk);while(!gamma_load_ready);
    end
    @(negedge clk);gamma_load_valid=0;wait(gamma_done_valid);if(gamma_status!=GC_OK)$fatal(1,"Gamma load");@(negedge clk);
  endtask
  task automatic preload_rope;
    $readmemh("Pcore/units/rom/rope_wide.mem",rope_coefficients);
    for(int address=0;address<1632;address++)begin
      @(negedge clk);pc_rope_load_valid='1;pc_rope_load_address=11'(address);pc_rope_load_last=address==1631;
      for(int bank=0;bank<4;bank++)for(int word=0;word<2;word++)
        pc_rope_load_data[bank*64+word*32+:32]=rope_coefficients[address/4][64*(2*bank+8*(address%2)+word)+32*((address/2)%2)+:32];
      while(pc_rope_load_valid!=0)begin
        logic [7:0] accepted;
        @(posedge clk);accepted=pc_rope_load_valid&pc_rope_load_ready;
        @(negedge clk);pc_rope_load_valid&=~accepted;
      end
    end
    pc_rope_load_last=0;wait(&pc_rope_loaded);
  endtask
  task automatic cold_norm;
    load_gamma(0);load_gamma(1);
    @(negedge clk);cmd='0;cmd.opcode=GC_NORM;cmd.command_id=100;cmd.context_id=gc_config.context_id;cmd.generation=gc_config.generation;
    cmd.src_object=100;cmd.src_version=1;cmd.dst_object=200;cmd.dst_version=1;cmd.core_mask='1;
    cmd.epsilon_fp32=32'h358637bd;cmd.norm_param_id=16'h210;cmd_valid=1;
    do @(posedge clk);while(!cmd_ready);@(negedge clk);cmd_valid=0;wait(cmd_complete[100]);
  endtask
  task automatic clear_scoreboards;
    quant_count=0;write_count=0;final_count=0;kv_commits=0;fp_tiles=0;
    gc_job_count=0;fetch_count=0;gamma_words=0;phase=0;
    for(int j=0;j<16;j++)gc_complete[j]=0;
    for(int j=0;j<256;j++)cmd_complete[j]=0;
    for(int c=0;c<8;c++)begin
      pc_job[c]='0;hbm[c]='0;matrix_issues[c]=0;xbc_count[c]=0;kvb_count[c]=0;
      pc_job_count[c]=0;qoz_words[c]=0;p_words[c]=0;qk_count[c]=0;pv_count[c]=0;wire_count[c]=0;
      for(int j=0;j<16;j++)begin job_start[c][j]=0;job_end[c][j]=0;pc_complete[c][j]=0;end
    end
  endtask
  task automatic restore_residual;
    // Refill via the public import service. Never restore an internal RAM
    // through hierarchy after the time-zero initialization exception.
    @(negedge clk);cmd='0;cmd.opcode=GC_IMPORT_RESID;cmd.command_id=90;
    cmd.context_id=gc_config.context_id;cmd.generation=gc_config.generation;
    cmd.core_mask='1;cmd.dst_object=100;cmd.dst_version=1;cmd_valid=1;
    do @(posedge clk);while(!cmd_ready);@(negedge clk);cmd_valid=0;
    for(int a=0;a<VECTOR_WORDS;a++)begin
      import_data='{data:initial_resid[a],index:VECTOR_ADDR_BITS'(a),last:a==VECTOR_WORDS-1,token:command_token(cmd)};
      import_valid=1;do @(posedge clk);while(!import_ready);@(negedge clk);
    end
    import_valid=0;wait(cmd_complete[90]);
    $display("RECOVERY_IMPORT generation=%0d external_vectors=3264",gc_config.generation);
  endtask
  task automatic run_layer(input bit restored);
    int run_start;run_start=cycle;
    @(negedge clk);gc_config='0;gc_config.context_id=9;gc_config.generation=restored?3:2;gc_config.pcore_epoch=restored?4:3;
    gc_config.data_context=pc_config_context;gc_config.position_base=816;gc_config.rope_version=1;gc_config.gamma_online=1;
    gc_config.prefix_version=7;gc_config.suffix_version=8;
    gc_config.k_transfer='{16'd1,16'd9,16'd1,16'd816};gc_config.v_transfer='{16'd2,16'd9,16'd2,16'd816};
    gc_config.o_transfer='{16'd5,16'd9,16'd4,16'd816};gc_config.down_transfer='{16'd7,16'd9,16'd6,16'd816};
    if(restored)begin
      gc_config.k_transfer.transfer_epoch=10;gc_config.v_transfer.transfer_epoch=10;
      gc_config.o_transfer.transfer_epoch=10;gc_config.down_transfer.transfer_epoch=10;
    end
    gc_config_valid=1;do @(posedge clk);while(!gc_config_ready);@(negedge clk);gc_config_valid=0;
    wait(gc_config_done_valid);if(gc_config_status!=GC_OK)$fatal(1,"GCore context");
    @(negedge clk);pc_config_valid='1;
    while(pc_config_valid!=0)begin logic [7:0] a;@(posedge clk);a=pc_config_valid&pc_config_ready;@(negedge clk);pc_config_valid&=~a;end
    wait(&pc_configured);
    preloaded='{context_id:gc_config.context_id,generation:gc_config.generation,residual_object:16'd100,residual_version:16'd1,prefix_object:16'd300,prefix_version:16'd7};
    preloaded_valid=1;do @(posedge clk);while(!preloaded_ready);@(negedge clk);preloaded_valid=0;
    wait(preloaded_done_valid);if(preloaded_status!=GC_OK)$fatal(1,"GCore preloaded registration");
    if(restored)begin
      restore_residual();
      @(negedge clk);release_drain=1;@(negedge clk);release_drain=0;
    end
    if(layer_number!=1)cold_norm();
    @(negedge clk);layer_data.context_data=gc_config;layer_data.layer_id=5'(layer_number);
    layer_data.prefix_object=300;layer_data.xhat_object=200;layer_data.k_object=400;layer_data.v_object=500;
    layer_data.attn_gamma=16'h210;layer_data.ffn_gamma=16'h211;layer_data.next_attn_gamma=16'h310;
    layer_data.next_ffn_gamma=16'h311;layer_data.final_gamma=16'h410;layer_data.epsilon_fp32=32'h358637bd;
    layer_valid=1;do @(posedge clk);while(!layer_ready);@(negedge clk);layer_valid=0;
    wait(layer_done_valid);if(layer_status!=GC_OK)$fatal(1,"GCore layer bind");
    if(layer_number==1)begin send_gc_job(GJ_START,1);wait(gc_complete[1]);end
    phase_run(OP_K_PROJ,GJ_K,2);phase_run(OP_V_PROJ,GJ_V,3);phase_run(OP_Q_PROJ,GJ_Q,4);
    phase_run(OP_ATTENTION,GJ_ATTENTION,5);
    @(negedge clk);kv_release_valid=1;do @(posedge clk);while(!kv_release_ready);@(negedge clk);kv_release_valid=0;
    phase_run(OP_O_PROJ,GJ_O,6,0);
    wait(xhat_status.valid&&xhat_status.ffn);
    phase_run(OP_GU,GJ_GU,7);wait(gc_complete[6]);
    phase_run(OP_DOWN_PROJ,GJ_DOWN,8);
    if(write_count!=6528||kv_commits!=32||fp_tiles!=128||quant_count!=(layer_number==18?6528:9792)||
      final_count!=(layer_number==18?3264:0)||gc_job_count!=(layer_number==1?8:7))$fatal(1,"Layer aggregate counts");
    for(int c=0;c<8;c++)if(matrix_issues[c]!=265408||pc_job_count[c]!=7||qoz_words[c]!=1664||p_words[c]!=1430||
      qk_count[c]!=55||pv_count[c]!=55||xbc_count[c]!=43264||kvb_count[c]!=14080||wire_count[c]!=13418)
      $fatal(1,"Layer core counts core=%0d issues=%0d xbc=%0d kvb=%0d wire=%0d",c,matrix_issues[c],xbc_count[c],kvb_count[c],wire_count[c]);
    for(int a=0;a<VECTOR_WORDS;a++)if(dut.gcore.services.residual_store.memory[a]!==next_resid[a])$fatal(1,"Final physical RESID index=%0d",a);
    $display("LAYER_TOTAL layer=%0d cycles=%0d matrix_issues=2123264 KV_commits=32 FP_tiles=128 residual_writes=6528 final=%0d restored=%0d",layer_number,cycle-run_start,final_count,restored);
    $display("tb_dea8_layers_native PASS layer=%0d cores=8 internal_tb_models=0 checkpoint_only=1 recovered=%0d",layer_number,restored);
  endtask
  initial begin
    gc_config='0;preloaded='0;layer_data='0;gc_job='0;cmd='0;import_data='0;gamma_load='0;
    clear_scoreboards();
    if(!$value$plusargs("LAYER=%d",layer_number))layer_number=1;
    if(layer_number!=1&&layer_number!=9&&layer_number!=18)$fatal(1,"Layer must be independent checkpoint 1,9,18");
    stress=$test$plusargs("STRESS");recover=$test$plusargs("RECOVER");
    if($value$plusargs("CANCEL_AT=%s",cancel_at))begin end
    if(recover&&cancel_at=="")$fatal(1,"RECOVER requires CANCEL_AT");
    if(cancel_at!=""&&cancel_at!="K"&&cancel_at!="Q"&&cancel_at!="Attention"&&cancel_at!="SCALE"&&
      cancel_at!="GU"&&cancel_at!="O"&&cancel_at!="Down"&&cancel_at!="Final")$fatal(1,"Unknown CANCEL_AT");
    if(cancel_at=="Final"&&layer_number!=18)$fatal(1,"Final cancellation requires layer18");
    repeat(35)@(negedge clk);reset=0;
    preload_rope();
    fork: execution
      run_layer(0);
      begin wait(cancelled);end
    join_any
    disable execution;
    if(cancelled)begin
      @(negedge clk);pc_job_valid=0;gc_job_valid=0;gc_config_valid=0;pc_config_valid=0;
      preloaded_valid=0;layer_valid=0;cmd_valid=0;import_valid=0;gamma_load_valid=0;hbm_offer=0;
      cancellation_quiescent=0;negative=0;cancel_at="";clear_scoreboards();
      run_layer(1);
    end
    $finish;
  end
  initial begin #12000000;$fatal(1,"Layer watchdog phase=%0d pc_busy=%h gcore_busy=%h",phase,pc_busy,gc_busy);end
endmodule
