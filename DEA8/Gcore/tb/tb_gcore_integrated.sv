`timescale 1ns/1ps
module tb_gcore_integrated #(parameter bit NATIVE_RSQRT=1'b1,INTERNAL_NATIVE=1'b1,MACRO_JOBS=1'b0);
  import gcore_pkg::*;
  import pcore_pkg::xbc4_t,pcore_pkg::b2_t,pcore_pkg::pcore_op_e;
  import pcore_pkg::OP_Q_PROJ,pcore_pkg::OP_K_PROJ,pcore_pkg::OP_V_PROJ;
  import pcore_pkg::OP_ATTENTION,pcore_pkg::OP_O_PROJ,pcore_pkg::OP_DOWN_PROJ;
  import dea8_tile_link_pkg::*;
  import gcore_tb_pkg::*;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,config_valid=0,config_ready,config_done_valid,config_done_ready=1;
  gcore_context_t config_data;gcore_status_e config_status;
  logic preloaded_valid=0,preloaded_ready,preloaded_done_valid,preloaded_done_ready=1;
  gcore_preloaded_t preloaded;gcore_status_e preloaded_status;
  logic cmd_valid=0,cmd_ready,done_valid,done_ready;
  gcore_cmd_t cmd;gcore_done_t done;
  logic import_valid=0,import_ready;residual_import_t import_data;
  logic [7:0] xbc_valid,xbc_ready,gu_prefetch_valid=0,gu_prefetch_ready;
  logic [7:0][5:0] gu_prefetch_n=0;xbc4_t xbc;
  logic [7:0] rx_valid,rx_ready,rx_last;logic [7:0][255:0] rx_data;
  logic [7:0] kv_commit_valid,kv_commit_ready;tile_commit_t kv_commit[8];
  logic [7:0] kv_valid,kv_ready;b2_t kv;
  logic gamma_load_valid=0,gamma_load_ready,gamma_done_valid,gamma_done_ready=1;
  gamma_load_t gamma_load;gcore_status_e gamma_status;logic [15:0] gamma_loaded_id;
  logic rsqrt_valid,rsqrt_ready,rsqrt_out_valid,rsqrt_out_ready;
  rsqrt_packet_t rsqrt_request,rsqrt_response;
  logic invalidate_valid=0,invalidate_ready;logic [OBJECTS-1:0] invalidate_mask=0;
  logic kv_release_valid=0,kv_release_ready,kv_lease,cancel_valid=0,cancel_ready,flush_valid,external_flush_ack,fault;
  logic [SERVICES-1:0] busy;
  logic layer_valid=0,layer_ready,layer_done_valid,layer_done_ready=1;
  gcore_layer_t layer_data='0;gcore_status_e layer_status;
  logic job_valid=0,job_ready,job_done_valid,job_done_ready=1,job_busy;
  gcore_job_t job='0;gcore_job_done_t job_done;gcore_xhat_t xhat_status;
  logic gamma_fetch_valid,gamma_fetch_ready=0,gamma_data_valid=0,gamma_data_ready;
  gamma_fetch_t gamma_fetch;gamma_beat_t gamma_data='0;
  logic final_valid,final_ready=1;gcore_final_t final_data;
  int layer_number=1,macro_starts[16],macro_ends[16],macro_count=0,fetch_count=0,fetch_words=0,final_count=0;
  bit macro_complete[16];gcore_status_e macro_status[16];
  logic [511:0] final_gold[VECTOR_WORDS];
  logic hbm_active=0,hbm_offer=0,hbm_corrupt=0;gamma_fetch_t hbm_request;
  logic delayed_kv_allowed=0;
  int hbm_index=0,hbm_start=0,ffn_ready_cycle=0,gu_overlap=0;
  logic final_held=0,job_held=0,request_held=0;
  gcore_final_t held_final;gcore_job_done_t held_job;gamma_fetch_t held_request;
  dea8_gcore #(.INTERNAL_RSQRT(NATIVE_RSQRT&&INTERNAL_NATIVE)) dut(.*);
  logic [255:0] initial_x[VECTOR_WORDS],mid_x[VECTOR_WORDS],next_x[VECTOR_WORDS];
  logic [511:0] delta_o[VECTOR_WORDS],delta_down[VECTOR_WORDS];
  logic [135:0] q0[VECTOR_WORDS],q1[VECTOR_WORDS],q2[VECTOR_WORDS];
  logic [31:0] u0[ROWS],u1[ROWS],u2[ROWS],inv0[ROWS],inv1[ROWS],inv2[ROWS];
  logic [31:0] gamma0[HIDDEN],gamma1[HIDDEN];
  int cycle=0,stage=0,quant_count=0,write_count=0,inverse_count=0,retire_count=0,kv_count=0;
  int port_phase[8],port_tile[8],port_beat[8],kvb_count[8],xbc_count[8];
  int start_cycle[256],end_cycle[256];
  bit completed[256];gcore_status_e completion_status[256];
  bit stream_active=0,stream_fp=0,stream_value=0,stress=0,allow_fault=0;
  logic [7:0] offer_q=0;
  int fp_tile_start=0,fp_tile_gap=0,fp_last_retire=0,fp_max_service=0;
  int fp_header_cycle[64],fp_service_max=0;
  bit bad_header=0,bad_packet=0;
  assign external_flush_ack=flush_valid;
  assign done_ready=!stress||cycle%9>2;
  if(NATIVE_RSQRT)begin:native_inputs
    if(INTERNAL_NATIVE)begin
      assign rsqrt_ready=0;assign rsqrt_out_valid=0;assign rsqrt_response='0;
    end else begin
      dea8_gcore_rsqrt native_service(.clk,.reset,.clear(flush_valid),.in_valid(rsqrt_valid),.in_ready(rsqrt_ready),
        .request(rsqrt_request),.out_valid(rsqrt_out_valid),.out_ready(rsqrt_out_ready),.response(rsqrt_response),.empty(),.protocol_error());
    end
  end else begin:reference_service
    logic [7:0] valids=0;rsqrt_packet_t packets[8];logic advance;
    assign advance=!valids[7]||rsqrt_out_ready;
    assign rsqrt_ready=advance&&!reset&&!flush_valid;
    assign rsqrt_out_valid=valids[7];assign rsqrt_response=packets[7];
    always @(posedge clk)begin
      if(reset||flush_valid)valids<=0;
      else if(advance)begin
        valids[0]<=rsqrt_valid&&rsqrt_ready;
        for(int s=1;s<8;s++)begin valids[s]<=valids[s-1];packets[s]<=packets[s-1];end
        if(rsqrt_valid&&rsqrt_ready)begin
          packets[0]<=rsqrt_request;
          packets[0].data<={32'b0,stage==0?inv0[rsqrt_request.row0]:(stage==1?inv1[rsqrt_request.row0]:inv2[rsqrt_request.row0])};
        end
      end
    end
  end
  always @(negedge clk)cycle++;
  // Scoreboard counters change at posedge; never drive a wire handshake from
  // them in the same active region as the receiver's sampling edge.
  always @(negedge clk)delayed_kv_allowed=xbc_count[7]>=1664;
  for(genvar port_number=0;port_number<CORES;port_number++)begin:wire_checks
    logic held=0;logic [255:0] held_data;logic held_last;
    always @(posedge clk)begin
      if(reset||flush_valid||allow_fault||fault)held=0;
      else begin
        if(held&&(!rx_valid[port_number]||rx_data[port_number]!==held_data||rx_last[port_number]!==held_last))
          $fatal(1,"TB producer changed a stalled packet port=%0d phase=%0d tile=%0d beat=%0d",port_number,port_phase[port_number],port_tile[port_number],port_beat[port_number]);
        held=rx_valid[port_number]&&!rx_ready[port_number];held_data=rx_data[port_number];held_last=rx_last[port_number];
        if(!allow_fault&&rx_valid[port_number]&&rx_ready[port_number]&&
          ((dut.services.packet_receiver.state_q[port_number]==0&&!dut.services.packet_receiver.header_ok[port_number])||
           (dut.services.packet_receiver.state_q[port_number]==1&&!dut.services.packet_receiver.word_ok[port_number])))
          $fatal(1,"wire framing port=%0d rx_state=%0d source_phase=%0d tile=%0d beat=%0d received=%0d expected=%0d last=%b data=%h",port_number,
            dut.services.packet_receiver.state_q[port_number],port_phase[port_number],port_tile[port_number],port_beat[port_number],
            dut.services.packet_receiver.received[port_number],dut.services.packet_receiver.expected[port_number],rx_last[port_number],rx_data[port_number]);
      end
    end
  end
  for(genvar k=0;k<2;k++)begin:preload_kind
    for(genvar f=0;f<16;f++)begin:preload_feature
      for(genvar p=0;p<2;p++)begin:preload_parity
        initial for(int a=0;a<PREFIX_BANK_DEPTH;a++)
          dut.services.kv_store.preload_prefix(k,f,p,a,kv_word(k,1,f,k?(a/8)*16+(a%8)*2+p:2*a+p));
      end
    end
  end
  function automatic logic [31:0] partial(input logic [31:0] x,input int c);
    logic [31:0] result;
    if(c==7||x[30:0]==0)return 0;
    result=x;result[30:23]=8'(int'(x[30:23])-(3-(c%4)));
    result[31]=x[31]^(c>=4);return result;
  endfunction
  function automatic logic [$bits(gcore_cmd_t)-1:0] command(input gcore_opcode_e op,input int id,input pcore_op_e p=OP_Q_PROJ);
    gcore_cmd_t c;c='0;c.opcode=op;c.command_id=16'(id);c.context_id=9;c.generation=2;c.core_mask='1;c.pcore_op=p;
    case(op)
      GC_NORM:begin c.src_object=100;c.src_version=16'(stage+1);c.dst_object=200;c.dst_version=c.src_version;
        c.epsilon_fp32=32'h358637bd;c.norm_param_id=stage==1?16'h211:16'h210;end
      GC_XBC_RUN:begin c.src_object=200;c.src_version=16'(stage+1);end
      GC_KV_RX:begin c.dst_object=p==OP_K_PROJ?400:500;c.dst_version=8;end
      GC_KVB_RUN:begin c.src_object=300;c.src_version=7;end
      GC_RESIDUAL_APPLY:begin c.src_object=100;c.src_version=16'(stage);c.dst_object=100;c.dst_version=16'(stage+1);end
      default:;
    endcase
    return c;
  endfunction
  always_comb begin
    job_done_ready=!stress||cycle%13>4;
    rx_valid=0;rx_data=0;rx_last=0;
    for(int c=0;c<CORES;c++)begin
      tile_header_t h;tile_transfer_t transfer;
      int col,row,half;
      logic [511:0] d;
      h='0;transfer=stream_fp?(stage==1?config_data.o_transfer:config_data.down_transfer):
        (stream_value?config_data.v_transfer:config_data.k_transfer);
      col=stream_fp?port_tile[c]*16:(stream_value?c*32+port_tile[c]*16:c*16+port_tile[c]*128);
      h.transfer_id=transfer.transfer_id;h.transfer_epoch=transfer.transfer_epoch;h.destination_id=transfer.destination_id;
      h.token_origin=transfer.token_origin;h.rows=ROWS;h.columns=TILE;h.source_id=4'(c);h.tile_seq=6'(port_tile[c]);h.column_base=16'(col);
      h.kind=stream_fp?(stage==1?TILE_O:TILE_DOWN):(stream_value?TILE_V:TILE_K);
      h.layout=stream_fp?LAYOUT_FP_ROWS:(stream_value?LAYOUT_V_GROUPS:LAYOUT_K_ROWS);
      if(bad_header&&c==7)h.destination_id=h.destination_id+1'b1;
      if(stream_active&&offer_q[c]&&port_tile[c]<(stream_fp?64:2)&&port_phase[c]<2&&
        (!MACRO_JOBS||!stress||stream_fp||c!=7||delayed_kv_allowed)&&
        (!stream_fp||cycle>=fp_tile_start+port_tile[c]*fp_tile_gap))begin
        rx_valid[c]=1;
        if(port_phase[c]==0)rx_data[c]=encode_packet_header(h);
        else if(stream_fp)begin
          row=port_beat[c]/2;half=port_beat[c]%2;
          d=stage==1?delta_o[port_tile[c]*ROWS+row]:delta_down[port_tile[c]*ROWS+row];
          for(int i=0;i<8;i++)rx_data[c][32*i+:32]=partial(d[32*(8*half+i)+:32],c);
          rx_last[c]=port_beat[c]==101;
          if(bad_packet&&c==3&&port_beat[c]==5)rx_last[c]=1;
        end else begin
          rx_data[c][135:0]=kv_word(stream_value,0,col/16,port_beat[c]);
          rx_last[c]=port_beat[c]==(stream_value?63:50);
        end
      end
      kv_commit_ready[c]=!stress||(cycle+c)%7>1;
      kv_ready[c]=!stress||(cycle+c)%5!=1;
      xbc_ready[c]=!stress||(cycle+c)%5>1;
    end
  end
  always @(posedge clk)if(!reset)begin
    if(fault&&!allow_fault)$fatal(1,"integrated fault state=%0d compute_error=%b packet=%b cycle=%0d",dut.services.compute.state,dut.services.compute_error,dut.services.packet_error,cycle);
    if(cmd_valid&&cmd_ready)start_cycle[cmd.command_id]=cycle;
    if(done_valid&&done_ready)begin
      if(completed[done.command_id])$fatal(1,"duplicate completion");
      completed[done.command_id]=1;completion_status[done.command_id]=done.status;end_cycle[done.command_id]=cycle;
      $display("METRICS job=%0d opcode=%0d status=%0d cycles=%0d",done.command_id,done.opcode,done.status,cycle-start_cycle[done.command_id]);
    end
    if(dut.services.activation_valid&&dut.services.activation_ready)begin
      logic [135:0] expected;
      expected=stage==0?q0[dut.services.activation_index]:(stage==1?q1[dut.services.activation_index]:q2[dut.services.activation_index]);
      if(dut.services.activation_word!==expected)$fatal(1,"quant mismatch stage=%0d index=%0d actual=%h gold=%h",stage,dut.services.activation_index,dut.services.activation_word,expected);
      quant_count++;
    end
    if(dut.services.ram_wr_valid&&dut.services.ram_wr_ready)begin
      if(dut.services.ram_wr_data!==(stage==1?mid_x[dut.services.ram_wr_addr]:next_x[dut.services.ram_wr_addr]))
        $fatal(1,"residual mismatch stage=%0d index=%0d actual=%h gold=%h",stage,dut.services.ram_wr_addr,dut.services.ram_wr_data,stage==1?mid_x[dut.services.ram_wr_addr]:next_x[dut.services.ram_wr_addr]);
      write_count++;
    end
    if(rsqrt_valid&&(INTERNAL_NATIVE?dut.local_rsqrt_ready:rsqrt_ready))begin
      if(rsqrt_request.mask!=1||rsqrt_request.data[63:32]!=0||
        rsqrt_request.data[31:0]!==(stage==0?u0[rsqrt_request.row0]:(stage==1?u1[rsqrt_request.row0]:u2[rsqrt_request.row0])))
        $fatal(1,"inverse input mismatch stage=%0d row=%0d actual=%h gold=%h",stage,rsqrt_request.row0,rsqrt_request.data[31:0],stage==0?u0[rsqrt_request.row0]:(stage==1?u1[rsqrt_request.row0]:u2[rsqrt_request.row0]));
      inverse_count++;
    end
    if(dut.services.fp_retire)begin
      int elapsed;elapsed=cycle-fp_last_retire;
      if(cycle-fp_header_cycle[retire_count%64]>fp_service_max)fp_service_max=cycle-fp_header_cycle[retire_count%64];
      if(retire_count%64!=0&&elapsed>fp_max_service)fp_max_service=elapsed;
      fp_last_retire=cycle;retire_count++;
    end
    for(int c=0;c<CORES;c++)begin
      if(!stream_active)offer_q[c]<=0;
      else if(!offer_q[c]||(rx_valid[c]&&rx_ready[c]))offer_q[c]<=!stress||(cycle+c*3)%7!=2;
      if(rx_valid[c]&&rx_ready[c])begin
        if(port_phase[c]==0)begin
          port_phase[c]<=1;
          if(stream_fp&&c==0)fp_header_cycle[port_tile[c]]=cycle;
        end
        else if(rx_last[c])begin
          if(stream_fp)begin port_phase[c]<=0;port_tile[c]<=port_tile[c]+1;end
          else port_phase[c]<=2;
          port_beat[c]<=0;
        end else port_beat[c]<=port_beat[c]+1;
      end
      if(kv_commit_valid[c]&&kv_commit_ready[c])begin
        if(port_phase[c]!=2)$fatal(1,"early KV commit");
        port_tile[c]<=port_tile[c]+1;port_phase[c]<=0;kv_count++;
      end
      if(kv_valid[c]&&kv_ready[c])begin
        if(kv!==kvb_expected(kvb_count[c],config_data.pcore_epoch))$fatal(1,"KVB mismatch core=%0d beat=%0d",c,kvb_count[c]);
        kvb_count[c]++;
      end
      if(xbc_valid[c]&&xbc_ready[c])begin
        int tile,group_index;tile=(xbc_count[c]/ROW_GROUPS)%HIDDEN_TILES;group_index=xbc_count[c]%ROW_GROUPS;
        for(int r=0;r<4;r++)begin
          logic [135:0] expected;int row;row=4*group_index+r;
          expected=row<ROWS?(stage==0?q0[tile*ROWS+row]:(stage==1?q1[tile*ROWS+row]:q2[tile*ROWS+row])):0;
          if(xbc.row[r].data!==expected[127:0]||xbc.row[r].scale!==expected[135:128])$fatal(1,"XBC mismatch");
        end
        xbc_count[c]++;
      end
    end
  end
  // HBM supplies values only; address/parameter selection and slot lifecycle are RTL.
  always_comb begin
    gamma_fetch_ready=MACRO_JOBS&&(!stress||cycle%7!=0)&&!hbm_active;
    gamma_data_valid=hbm_active&&cycle>=hbm_start&&hbm_offer;
    gamma_data='0;gamma_data.token=hbm_request.token^32'(hbm_corrupt);
    gamma_data.value=hbm_index<HIDDEN?gamma0[hbm_index%HIDDEN]:gamma1[hbm_index%HIDDEN];
    gamma_data.last=hbm_index==(hbm_request.final_group?HIDDEN:2*HIDDEN)-1;
    final_ready=!stress||cycle%17>6;
  end
  always @(posedge clk)if(!reset&&MACRO_JOBS)begin
    if(!hbm_active)hbm_offer<=1;
    else if(!hbm_offer||(gamma_data_valid&&gamma_data_ready))hbm_offer<=!stress||cycle%11>2;
    if(job_held&&(!job_done_valid||job_done!==held_job))$fatal(1,"macro completion changed under backpressure");
    job_held=job_done_valid&&!job_done_ready;held_job=job_done;
    if(final_held&&(!final_valid||final_data!==held_final))$fatal(1,"final output changed under backpressure");
    final_held=final_valid&&!final_ready;held_final=final_data;
    if(request_held&&(!gamma_fetch_valid||gamma_fetch!==held_request))$fatal(1,"HBM request changed under backpressure");
    request_held=gamma_fetch_valid&&!gamma_fetch_ready;held_request=gamma_fetch;
    if(gamma_fetch_valid&&gamma_fetch_ready)begin
      if(hbm_active)$fatal(1,"overlapping HBM transactions");
      if(gamma_fetch.context_id!=9||gamma_fetch.generation!=2||gamma_fetch.layer_id>18)$fatal(1,"HBM identity");
      if(fetch_count==0&&layer_number==1)begin
        if(gamma_fetch.param0!=16'h210||gamma_fetch.param1!=16'h211||gamma_fetch.layer_id!=1||gamma_fetch.final_group)$fatal(1,"START gamma request");
      end else if(layer_number==18)begin
        if(!gamma_fetch.final_group||gamma_fetch.param0!=16'h410||gamma_fetch.layer_id!=18)$fatal(1,"last layer gamma request");
      end else if(gamma_fetch.param0!=16'h310||gamma_fetch.param1!=16'h311||gamma_fetch.layer_id!=layer_number+1||gamma_fetch.final_group)$fatal(1,"next layer gamma request");
      hbm_request<=gamma_fetch;hbm_active<=1;hbm_index<=0;
      // Keep O pending long enough to demonstrate GU launch on xhat_ready, not O done.
      hbm_start<=cycle+(gamma_fetch.token[15:0]==6?200:3);fetch_count++;
      if($test$plusargs("GAMMA_FAULT_DOWN")&&gamma_fetch.token[15:0]==6)hbm_start<=1000000000;
    end
    if(gamma_data_valid&&gamma_data_ready)begin
      fetch_words++;
      if(gamma_data.last)hbm_active<=0;else hbm_index<=hbm_index+1;
    end
    if(job_valid&&job_ready)begin macro_starts[job.command_id]=cycle;
      if(job.op==GJ_GU&&!macro_complete[6])gu_overlap++;
    end
    if(job_done_valid&&job_done_ready)begin
      if(job_done.job.context_id!=9||job_done.job.generation!=2||job_done.job.layer_id!=layer_number||macro_complete[job_done.job.command_id])$fatal(1,"macro identity/duplicate");
      macro_complete[job_done.job.command_id]=1;macro_status[job_done.job.command_id]=job_done.status;
      macro_ends[job_done.job.command_id]=cycle;macro_count++;
      $display("METRICS layer=%0d job=%0d op=%0d status=%0d cycles=%0d",layer_number,job_done.job.command_id,job_done.job.op,job_done.status,job_done.cycles);
    end
    for(int c=0;c<8;c++)if(gu_prefetch_valid[c]&&gu_prefetch_ready[c])gu_prefetch_n[c]<=gu_prefetch_n[c]+1'b1;
    if(final_valid&&final_ready)begin
      if(layer_number!=18||final_data.command_id!=8||final_data.context_id!=9||final_data.generation!=2||final_data.layer_id!=18||
        final_data.index!=final_count||final_data.last!=(final_count==VECTOR_WORDS-1))$fatal(1,"final identity/index");
      for(int i=0;i<TILE;i++)begin
        logic [31:0] actual,gold;longint distance;
        actual=final_data.data[32*i+:32];gold=final_gold[final_count][32*i+:32];
        distance=actual>gold?longint'(actual)-longint'(gold):longint'(gold)-longint'(actual);
        // Native rsqrt is at most one ULP from the independent oracle; two
        // rounded multiplications can propagate this into at most three ULP.
        if((actual[31]!=gold[31]&&actual[30:0]!=0&&gold[30:0]!=0)||distance>3)
          $fatal(1,"final FP32 mismatch index=%0d lane=%0d actual=%h gold=%h ulp=%0d",final_count,i,actual,gold,distance);
      end
      final_count++;
    end
  end
  task automatic send_job(input gcore_job_e op,input int id);
    @(negedge clk);job='0;job.op=op;job.command_id=16'(id);job.context_id=9;job.generation=2;job.layer_id=5'(layer_number);job_valid=1;
    do @(posedge clk);while(!job_ready);@(negedge clk);job_valid=0;
  endtask
  task automatic wait_job(input int id);
    wait(macro_complete[id]);@(negedge clk);if(macro_status[id]!=GC_OK)$fatal(1,"macro job rejected id=%0d status=%0d",id,macro_status[id]);
  endtask
  task automatic bind_layer;
    @(negedge clk);layer_data='0;layer_data.context_data=config_data;layer_data.layer_id=5'(layer_number);
    layer_data.prefix_object=300;layer_data.xhat_object=200;layer_data.k_object=400;layer_data.v_object=500;
    layer_data.attn_gamma=16'h210;layer_data.ffn_gamma=16'h211;
    if(layer_number==2)begin layer_data.attn_gamma=16'h310;layer_data.ffn_gamma=16'h311;end
    layer_data.next_attn_gamma=16'h310;layer_data.next_ffn_gamma=16'h311;layer_data.final_gamma=16'h410;
    if(layer_number==18)begin layer_data.next_attn_gamma=0;layer_data.next_ffn_gamma=0;end
    layer_data.epsilon_fp32=32'h358637bd;layer_valid=1;
    do @(posedge clk);while(!layer_ready);@(negedge clk);layer_valid=0;
    wait(layer_done_valid);if(layer_status!=GC_OK)$fatal(1,"layer binding");@(negedge clk);
  endtask
  task automatic macro_cancel;
    send_job(GJ_START,10);wait(fetch_words>=32);
    @(negedge clk);hbm_active=0;cancel_valid=1;
    do @(posedge clk);while(!cancel_ready);@(negedge clk);cancel_valid=0;
    wait(macro_complete[10]);
    if(macro_status[10]!=GC_CANCELLED)$fatal(1,"active macro cancellation lost");
    wait(!flush_valid&&!job_busy&&!dut.services.jobs_owned);repeat(3)@(negedge clk);
    if(dut.services.context_valid||dut.services.stats_valid||quant_count||write_count||dut.services.gamma_loading)
      $fatal(1,"macro cancel retained context/data activity");
    @(negedge clk);config_valid=1;do @(posedge clk);while(!config_ready);@(negedge clk);config_valid=0;
    wait(config_done_valid);if(config_status!=GC_OK)$fatal(1,"macro recovery config");
    @(negedge clk);preloaded_valid=1;do @(posedge clk);while(!preloaded_ready);@(negedge clk);preloaded_valid=0;
    wait(preloaded_done_valid);if(preloaded_status!=GC_OK)$fatal(1,"macro recovery preloaded");
    bind_layer();fetch_count=0;fetch_words=0;
    send_job(GJ_START,1);wait_job(1);
    if(quant_count!=VECTOR_WORDS||inverse_count!=ROWS||fetch_words!=2048||!xhat_status.valid||fault)
      $fatal(1,"macro restart did not execute real cold NORM");
    $display("tb_gcore_layers PASS cancel_start=1 restart_start=1 quant=%0d inverse=%0d",quant_count,inverse_count);$finish;
  endtask
  task automatic macro_layer;
    int total_start,norm_start;
    if(!$value$plusargs("LAYER=%d",layer_number))layer_number=1;
    if($test$plusargs("LAYER9"))layer_number=9;
    if($test$plusargs("LAYER18"))layer_number=18;
    if(layer_number!=1&&layer_number!=9&&layer_number!=18)$fatal(1,"representative layer must be 1,9,18");
    $readmemh("tb/data/group_final_fp32.mem",final_gold);
    // A middle/last-layer fixture has its input RESID and matching XHAT ready.
    // Build that XHAT with real NORM, not by injecting a golden RAM image.
    if(layer_number!=1)begin load_gamma(0);load_gamma(1);send(command(GC_NORM,1));wait_done(1);end
    bind_layer();total_start=cycle;
    if($test$plusargs("CANCEL_START"))macro_cancel();
    if(layer_number==1)begin send_job(GJ_START,1);wait_job(1);end
    if(!xhat_status.valid||xhat_status.ffn||xhat_status.layer_id!=layer_number)$fatal(1,"initial xhat state");
    for(int kind=0;kind<2;kind++)begin
      @(negedge clk);stream_fp=0;stream_value=1'(kind);
      for(int c=0;c<CORES;c++)begin port_phase[c]=0;port_tile[c]=0;port_beat[c]=0;xbc_count[c]=0;end
      send_job(kind==0?GJ_K:GJ_V,kind+2);stream_active=1;wait_job(kind+2);stream_active=0;
      for(int c=0;c<CORES;c++)if(port_tile[c]!=2||xbc_count[c]!=1664)$fatal(1,"K/V macro must wait for receive AND XBC");
      if(kind==0&&$test$plusargs("K_ONLY"))begin
        $display("tb_gcore_layers PASS K_only=1 delayed_core=7 joined_xbc_and_receive=1");$finish;
      end
    end
    for(int c=0;c<CORES;c++)xbc_count[c]=0;
    send_job(GJ_Q,4);wait_job(4);
    for(int c=0;c<CORES;c++)if(xbc_count[c]!=13312)$fatal(1,"Q XBC count");
    send_job(GJ_ATTENTION,5);wait_job(5);
    for(int c=0;c<CORES;c++)if(kvb_count[c]!=KVB_WORDS)$fatal(1,"Attention KVB count");
    if(!kv_lease)$fatal(1,"KVB completion prematurely released KV");
    // DEA8 releases the lease only after its eight (TB) PCores finish Attention.
    repeat(12)@(negedge clk);kv_release_valid=1;
    do @(posedge clk);while(!kv_release_ready);@(negedge clk);kv_release_valid=0;
    stage=1;stream_fp=1;fp_tile_start=cycle;fp_tile_gap=stress?0:416;
    for(int c=0;c<CORES;c++)begin port_phase[c]=0;port_tile[c]=0;port_beat[c]=0;xbc_count[c]=0;end
    send_job(GJ_O,6);stream_active=1;
    wait(xhat_status.valid&&xhat_status.ffn);@(negedge clk);stream_active=0;ffn_ready_cycle=cycle;
    if(macro_complete[6])$fatal(1,"O retired before background gamma could overlap GU");
    gu_prefetch_valid='1;for(int c=0;c<CORES;c++)gu_prefetch_n[c]=1;
    send_job(GJ_GU,7);wait_job(7);gu_prefetch_valid=0;
    if(!$test$plusargs("GAMMA_FAULT_DOWN"))wait_job(6);
    for(int c=0;c<CORES;c++)if(xbc_count[c]!=26624||gu_prefetch_n[c]!=32)$fatal(1,"GU XBC/grants count");
    stage=2;stream_fp=1;fp_tile_start=cycle;fp_tile_gap=stress?0:832;
    for(int c=0;c<CORES;c++)begin port_phase[c]=0;port_tile[c]=0;port_beat[c]=0;end
    send_job(GJ_DOWN,8);stream_active=1;
    if($test$plusargs("GAMMA_FAULT_DOWN"))gamma_fault_down();
    wait_job(8);stream_active=0;
    if(quant_count!=(layer_number==18?2:3)*VECTOR_WORDS||write_count!=2*VECTOR_WORDS||
      inverse_count!=3*ROWS||retire_count!=128||kv_count!=32||gu_overlap!=1||
      macro_count!=(layer_number==1?8:7)||fetch_count!=(layer_number==1?2:1)||
      fetch_words!=(layer_number==1?4096:(layer_number==18?1024:2048))||final_count!=(layer_number==18?VECTOR_WORDS:0))
      $fatal(1,"macro totals q=%0d wr=%0d inv=%0d tiles=%0d jobs=%0d fetch=%0d words=%0d final=%0d overlap=%0d",quant_count,write_count,inverse_count,retire_count,macro_count,fetch_count,fetch_words,final_count,gu_overlap);
    for(int a=0;a<VECTOR_WORDS;a++)if(dut.services.residual_store.memory[a]!==next_x[a])$fatal(1,"final RESID memory mismatch");
    if(layer_number==18)begin
      if(xhat_status.valid)$fatal(1,"last layer must not publish layer19 XHAT");
    end else begin
      if(!xhat_status.valid||xhat_status.ffn||xhat_status.layer_id!=layer_number+1||!dut.services.stats_valid)$fatal(1,"next layer state");
    end
    $display("METRICS layer=%0d total_macro_cycles=%0d ffn_ready=%0d O_done=%0d GU_start=%0d gamma_words=%0d final_words=%0d",layer_number,cycle-total_start,ffn_ready_cycle,macro_ends[6],macro_starts[7],fetch_words,final_count);
    if(layer_number==1)begin
      // Ordinary layer binding, not clear/invalidate, must preserve SQ/RESID.
      layer_number=2;config_data.pcore_epoch=4'hc;config_data.prefix_version=8;config_data.suffix_version=9;
      config_data.k_transfer.transfer_epoch++;config_data.v_transfer.transfer_epoch++;
      config_data.o_transfer.transfer_epoch++;config_data.down_transfer.transfer_epoch++;
      bind_layer();
      if(!dut.services.stats_valid||dut.services.objects[OBJ_RESID].version!=3||dut.services.active_context.pcore_epoch!=4'hc)$fatal(1,"cross layer state lost");
      norm_start=cycle;
      begin gcore_cmd_t c;c=command(GC_NORM,11);c.norm_param_id=layer_data.attn_gamma;send(c);end
      wait_done(11);
      if(cycle-norm_start>7000)$fatal(1,"layer bind invalidated hot statistics");
      $display("CHECKS cross_layer_bind=1 preserved_sq=1 hot_norm_cycles=%0d",cycle-norm_start);
    end
    $display("tb_gcore_layers PASS layer_case=%0d stress=%0d native_rsqrt=1 full_macro_chain=1",layer_number==2?1:layer_number,stress);$finish;
  endtask
  task automatic gamma_fault_down;
    int stopped_writes,stopped_quant,stopped_inverse;
    wait(write_count>=VECTOR_WORDS+5);
    @(negedge clk);allow_fault=1;hbm_corrupt=1;hbm_start=cycle;
    wait(fault);wait(macro_complete[6]&&macro_complete[8]);
    if(macro_status[6]==GC_OK||macro_status[8]==GC_OK)$fatal(1,"background gamma fault published successful O/Down");
    @(negedge clk);hbm_active=0;stream_active=0;
    stopped_writes=write_count;stopped_quant=quant_count;stopped_inverse=inverse_count;
    repeat(40)@(negedge clk);
    if(write_count!=stopped_writes||quant_count!=stopped_quant||dut.services.stats_valid)
      $fatal(1,"late write/statistics survived background gamma failure");
    cancel_valid=1;do @(posedge clk);while(!cancel_ready);@(negedge clk);cancel_valid=0;
    wait(!flush_valid&&!job_busy&&!dut.services.jobs_owned);repeat(3)@(negedge clk);
    if(busy!=0||fault||dut.services.context_valid)$fatal(1,"background gamma flush did not recover");
    // Partial residual arithmetic cannot be rolled back by clearing valid bits.
    stage=0;hbm_corrupt=0;fetch_count=0;fetch_words=0;
    for(int a=0;a<VECTOR_WORDS;a++)dut.services.residual_store.memory[a]=initial_x[a];
    config_valid=1;do @(posedge clk);while(!config_ready);@(negedge clk);config_valid=0;
    wait(config_done_valid);if(config_status!=GC_OK)$fatal(1,"background recovery config");
    @(negedge clk);preloaded_valid=1;do @(posedge clk);while(!preloaded_ready);@(negedge clk);preloaded_valid=0;
    wait(preloaded_done_valid);if(preloaded_status!=GC_OK)$fatal(1,"background recovery registration");
    bind_layer();allow_fault=0;send_job(GJ_START,12);wait_job(12);
    if(write_count!=stopped_writes||quant_count!=stopped_quant+VECTOR_WORDS||inverse_count!=stopped_inverse+ROWS||fault)
      $fatal(1,"background failure restart did not compute real cold NORM");
    $display("tb_gcore_layers PASS gamma_fault_down=1 O_Down_aborted=1 no_late_write=1 input_restored=1 restart_norm=3264");$finish;
  endtask
  task automatic send(input gcore_cmd_t c);
    @(negedge clk);cmd=c;cmd_valid=1;do @(posedge clk);while(!cmd_ready);@(negedge clk);cmd_valid=0;
  endtask
  task automatic wait_done(input int id,input gcore_status_e expected=GC_OK);
    wait(completed[id]);@(negedge clk);if(completion_status[id]!=expected)$fatal(1,"completion status id=%0d",id);
  endtask
  task automatic load_gamma(input bit slot);
    for(int i=0;i<HIDDEN;i++)begin
      @(negedge clk);gamma_load.context_id=9;gamma_load.generation=2;gamma_load.param_id=slot?16'h211:16'h210;
      gamma_load.slot=slot;gamma_load.index=10'(i);gamma_load.value=slot?gamma1[i]:gamma0[i];gamma_load.last=i==HIDDEN-1;
      gamma_load_valid=1;do @(posedge clk);while(!gamma_load_ready);
    end
    @(negedge clk);gamma_load_valid=0;wait(gamma_done_valid);if(gamma_status!=GC_OK)$fatal(1,"gamma rejected");@(negedge clk);
  endtask
  task automatic receive_kv(input int id,input bit value_kind);
    @(negedge clk);stream_fp=0;stream_value=value_kind;
    for(int c=0;c<CORES;c++)begin port_phase[c]=0;port_tile[c]=0;port_beat[c]=0;end
    send(command(GC_KV_RX,id,value_kind?OP_V_PROJ:OP_K_PROJ));
    @(negedge clk);stream_active=1;wait_done(id);stream_active=0;
    for(int c=0;c<CORES;c++)if(port_tile[c]!=2)$fatal(1,"incomplete KV packets");
  endtask
  task automatic apply_residual(input int id,input pcore_op_e op);
    @(negedge clk);stream_fp=1;fp_tile_start=cycle;fp_tile_gap=stress?0:(op==OP_O_PROJ?416:832);fp_max_service=0;fp_service_max=0;
    for(int c=0;c<CORES;c++)begin port_phase[c]=0;port_tile[c]=0;port_beat[c]=0;end
    send(command(GC_RESIDUAL_APPLY,id,op));@(negedge clk);stream_active=1;wait_done(id);stream_active=0;
    for(int a=0;a<VECTOR_WORDS;a++)if(dut.services.residual_store.memory[a]!==(stage==1?mid_x[a]:next_x[a]))$fatal(1,"physical residual check");
    if(!stress&&fp_service_max>416)$fatal(1,"tile compute cannot hide: %0d",fp_service_max);
    $display("CHECKS residual stage=%0d words=%0d retire=%0d max_tile_interval=%0d max_header_to_retire=%0d",stage,VECTOR_WORDS,retire_count,fp_max_service,fp_service_max);
  endtask
  task automatic fault_scenario;
    int writes_before,quant_before;
    bit header_case,packet_case;
    header_case=bad_header;packet_case=bad_packet;
    allow_fault=1;stage=1;stream_fp=1;fp_tile_gap=0;
    send(command(GC_RESIDUAL_APPLY,20,OP_O_PROJ));
    @(negedge clk);stream_active=1;
    if($test$plusargs("CANCEL_ACTIVE"))begin
      wait(write_count>=5);@(negedge clk);stream_active=0;cancel_valid=1;
      do @(posedge clk);while(!cancel_ready);@(negedge clk);cancel_valid=0;
      wait_done(20,GC_CANCELLED);wait(!flush_valid);
    end else begin
      wait_done(20,GC_SOURCE_PROTOCOL);wait(fault);@(negedge clk);stream_active=0;
    end
    writes_before=write_count;quant_before=quant_count;
    repeat(30)@(negedge clk);
    if(write_count!=writes_before||quant_count!=quant_before||dut.services.stats_valid)
      $fatal(1,"writes/statistics survived abort");
    if(!$test$plusargs("CANCEL_ACTIVE"))begin
      cancel_valid=1;do @(posedge clk);while(!cancel_ready);@(negedge clk);cancel_valid=0;wait(!flush_valid);
    end
    repeat(5)@(negedge clk);
    if(fault||busy!=0||dut.services.packet_busy||dut.services.context_valid)$fatal(1,"flush recovery state");
    // Restoring RESID is mandatory: a cancelled partial residual update is not
    // a reusable old-version object. Reconfigure and execute a real cold NORM.
    stage=0;bad_header=0;bad_packet=0;
    for(int a=0;a<VECTOR_WORDS;a++)dut.services.residual_store.memory[a]=initial_x[a];
    config_valid=1;do @(posedge clk);while(!config_ready);@(negedge clk);config_valid=0;
    wait(config_done_valid);if(config_status!=GC_OK)$fatal(1,"recovery context");
    @(negedge clk);preloaded_valid=1;do @(posedge clk);while(!preloaded_ready);@(negedge clk);preloaded_valid=0;
    wait(preloaded_done_valid);if(preloaded_status!=GC_OK)$fatal(1,"recovery registration");
    load_gamma(0);send(command(GC_NORM,21));wait_done(21);
    if(quant_count!=quant_before+VECTOR_WORDS||fault||!dut.services.stats_valid)$fatal(1,"recovery NORM failed");
    $display("tb_gcore_integrated PASS negative=1 bad_header=%0d bad_packet=%0d active_cancel=%0d no_stale_write=1 restart_norm=3264",header_case,packet_case,$test$plusargs("CANCEL_ACTIVE"));$finish;
  endtask
  initial begin
    config_data='0;preloaded='0;cmd='0;import_data='0;gamma_load='0;
    stress=$test$plusargs("STRESS");
    for(int i=0;i<16;i++)begin macro_complete[i]=0;macro_status[i]=GC_OK;macro_starts[i]=0;macro_ends[i]=0;end
    bad_header=$test$plusargs("BAD_HEADER");bad_packet=$test$plusargs("BAD_PACKET");
    for(int i=0;i<256;i++)begin completed[i]=0;completion_status[i]=GC_OK;end
    for(int c=0;c<8;c++)begin port_phase[c]=0;port_tile[c]=0;port_beat[c]=0;kvb_count[c]=0;xbc_count[c]=0;end
    $readmemh("tb/data/group_initial_residual.mem",initial_x);$readmemh("tb/data/group_mid_residual.mem",mid_x);$readmemh("tb/data/group_next_residual.mem",next_x);
    $readmemh("tb/data/reduce_o.mem",delta_o);$readmemh("tb/data/reduce_down.mem",delta_down);
    $readmemh("tb/data/group_initial_xhat.mem",q0);$readmemh("tb/data/group_mid_xhat.mem",q1);$readmemh("tb/data/group_next_xhat.mem",q2);
    $readmemh("tb/data/group_initial_u.mem",u0);$readmemh("tb/data/group_mid_u.mem",u1);$readmemh("tb/data/group_next_u.mem",u2);
    $readmemh("tb/data/group_initial_inv.mem",inv0);$readmemh("tb/data/group_mid_inv.mem",inv1);$readmemh("tb/data/group_next_inv.mem",inv2);
    $readmemh("tb/data/group_gamma0.mem",gamma0);$readmemh("tb/data/group_gamma1.mem",gamma1);
    for(int a=0;a<VECTOR_WORDS;a++)dut.services.residual_store.memory[a]=initial_x[a];
    repeat(35)@(negedge clk);reset=0;
    @(negedge clk);config_data.context_id=9;config_data.generation=2;config_data.gamma_online=1;
    config_data.pcore_epoch=4'hb;config_data.prefix_version=7;config_data.suffix_version=8;
    config_data.k_transfer='{16'd1,16'd11,16'd21,16'd31};config_data.v_transfer='{16'd2,16'd12,16'd22,16'd32};
    config_data.o_transfer='{16'd3,16'd13,16'd23,16'd33};config_data.down_transfer='{16'd4,16'd14,16'd24,16'd34};config_valid=1;
    do @(posedge clk);while(!config_ready);@(negedge clk);config_valid=0;wait(config_done_valid);if(config_status!=GC_OK)$fatal(1,"config");
    @(negedge clk);preloaded.context_id=9;preloaded.generation=2;preloaded.residual_object=100;preloaded.residual_version=1;
    preloaded.prefix_object=300;preloaded.prefix_version=7;preloaded_valid=1;
    do @(posedge clk);while(!preloaded_ready);@(negedge clk);preloaded_valid=0;wait(preloaded_done_valid);
    if(preloaded_status!=GC_OK)$fatal(1,"registration");
    if(MACRO_JOBS)macro_layer();
    load_gamma(0);load_gamma(1);
    if(bad_header||bad_packet||$test$plusargs("CANCEL_ACTIVE"))fault_scenario();
    send(command(GC_NORM,1));wait_done(1);
    if($test$plusargs("NORM_ONLY"))begin $display("tb_gcore_integrated PASS norm_only=1 words=%0d",quant_count);$finish;end
    receive_kv(2,0);receive_kv(3,1);
    send(command(GC_XBC_RUN,4,OP_Q_PROJ));wait_done(4);
    send(command(GC_KVB_RUN,5,OP_ATTENTION));wait_done(5);
    for(int c=0;c<8;c++)if(kvb_count[c]!=KVB_WORDS)$fatal(1,"KVB total count");
    @(negedge clk);kv_release_valid=1;do @(posedge clk);while(!kv_release_ready);@(negedge clk);kv_release_valid=0;
    stage=1;apply_residual(6,OP_O_PROJ);
    send(command(GC_NORM,7));wait_done(7);
    stage=2;apply_residual(8,OP_DOWN_PROJ);
    send(command(GC_NORM,9));wait_done(9);
    if(quant_count!=3*VECTOR_WORDS||write_count!=2*VECTOR_WORDS||retire_count!=128||inverse_count!=3*ROWS||kv_count!=32)
      $fatal(1,"final counts q=%0d wr=%0d retire=%0d inv=%0d kv=%0d",quant_count,write_count,retire_count,inverse_count,kv_count);
    $display("tb_gcore_integrated PASS stress=%0d real_rsqrt=1 standalone_reduce=0 quant=%0d residual=%0d tiles=%0d gamma_sets=2 kv_commits=%0d kvb_jobs=110",stress,quant_count,write_count,retire_count,kv_count);$finish;
  end
  initial begin #4000000;$fatal(1,"integrated watchdog state=%0d reads=%0d scan=%0d acc=%0d gamma=%b",dut.services.compute.state,dut.services.compute.reads_q,dut.services.compute.scan_retired,dut.services.compute.acc_retired,dut.services.compute.gamma_cache_valid);end
endmodule
