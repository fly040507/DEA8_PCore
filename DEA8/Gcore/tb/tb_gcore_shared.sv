`timescale 1ns/1ps
// Real GCore control/import/compute/storage/XBC. Only DEA8 commands, Reduce
// output rows, rsqrt and the eight XBC consumers are testbench services.
module tb_gcore_shared;
  import gcore_pkg::*;
  import dea8_tile_link_pkg::*;
  import pcore_pkg::OP_Q_PROJ;
  import pcore_pkg::OP_K_PROJ;
  import pcore_pkg::OP_GU;
  import pcore_pkg::OP_O_PROJ;
  import pcore_pkg::OP_DOWN_PROJ;
  import pcore_pkg::xbc4_t;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,config_valid=0,config_ready,config_done_valid,config_done_ready=1,context_valid;
  gcore_context_t config_data,active_context;
  gcore_status_e config_status;
  logic preloaded_valid=0,preloaded_ready,preloaded_done_valid,preloaded_done_ready=1;
  gcore_preloaded_t preloaded='0;
  gcore_status_e preloaded_status;
  logic cmd_valid=0,cmd_ready,done_valid,done_ready=0;
  gcore_cmd_t cmd,service_cmd;
  gcore_done_t done,service_done[SERVICES];
  logic [SERVICES-1:0] service_cmd_valid,service_cmd_ready,service_done_valid,service_done_ready,busy;
  logic [SERVICES-1:0] service_fault;
  gcore_object_t objects[OBJECTS];
  logic invalidate_valid=0,invalidate_ready;
  logic [OBJECTS-1:0] invalidate_mask=0;
  logic kv_release_valid=0,kv_release_ready,kv_lease;
  logic cancel_valid=0,cancel_ready,flush_valid,external_flush_ack,service_clear,fault;
  logic [SERVICES-1:0] flush_ack;
  logic clear_local;

  residual_import_t import_data;
  logic import_valid=0,import_ready,import_cmd_ready,import_done_valid,import_busy;
  gcore_done_t import_done;
  logic import_wr_valid,import_wr_ready;
  logic [VECTOR_ADDR_BITS-1:0] import_wr_addr;
  logic [255:0] import_wr_data;

  logic compute_cmd_ready,compute_done_valid,compute_done_ready,compute_busy,stats_valid,compute_error;
  gcore_done_t compute_done;
  logic header_valid=0,header_ready,data_valid=0,data_ready,last=0,commit_valid,commit_ready=0;
  tile_header_t header;
  tile_commit_t commit;
  logic [511:0] data=0;
  logic ram_rd_valid,ram_rd_ready,ram_rsp_valid,ram_rsp_ready,ram_wr_valid,ram_wr_ready;
  logic [VECTOR_ADDR_BITS-1:0] ram_rd_addr,ram_rsp_addr,ram_wr_addr;
  logic [255:0] ram_rsp_data,ram_wr_data;
  logic activation_valid,activation_ready;
  logic [VECTOR_ADDR_BITS-1:0] activation_index;
  logic [135:0] activation_word;
  logic rsqrt_valid,rsqrt_ready,rsqrt_out_valid,rsqrt_out_ready;
  rsqrt_packet_t rsqrt_request,rsqrt_response;
  localparam int SFU_LATENCY=8;
  logic [SFU_LATENCY-1:0] sfu_valid_q=0;
  rsqrt_packet_t sfu_data_q[SFU_LATENCY];
  logic sfu_advance;
  bit bad_sfu=0,stray_sfu=0;

  logic debug_mode=0,debug_valid=0,debug_ready,debug_rsp_valid,debug_rsp_ready=0;
  logic [VECTOR_ADDR_BITS-1:0] debug_addr=0;
  logic store_rd_valid,store_rd_ready,store_rsp_valid,store_rsp_ready,store_wr_valid,store_wr_ready;
  logic [VECTOR_ADDR_BITS-1:0] store_rd_addr,store_rsp_addr,store_wr_addr;
  logic [255:0] store_rsp_data,store_wr_data;
  logic residual_error,activation_error;
  logic xbc_rd_valid,xbc_rd_ready,xbc_rsp_valid,xbc_rsp_ready,xbc_cmd_ready,xbc_done_valid,xbc_busy,xbc_error;
  logic [5:0] xbc_rd_tile;
  logic [3:0] xbc_rd_group;
  xbc4_t xbc_rsp,xbc;
  logic [CORES-1:0] xbc_valid,xbc_ready=0,gu_valid=0,gu_ready;
  logic [CORES-1:0][5:0] gu_n=0;
  gcore_done_t xbc_done;

  logic [255:0] initial_res[VECTOR_WORDS],mid_res[VECTOR_WORDS],next_res[VECTOR_WORDS];
  logic [511:0] delta_o[VECTOR_WORDS],delta_down[VECTOR_WORDS];
  logic [135:0] q_initial[VECTOR_WORDS],q_mid[VECTOR_WORDS],q_next[VECTOR_WORDS];
  logic [31:0] u_initial[ROWS],u_mid[ROWS],u_next[ROWS];
  logic [31:0] inv_initial[ROWS],inv_mid[ROWS],inv_next[ROWS];
  int cycle=0,numeric_stage=0,activation_count=0,write_count=0,read_count=0,sfu_requests=0;
  int xbc_counts[CORES],grant_counts[CORES],commit_count=0,writes_at_start=0;
  int accepted_jobs=0,completed_jobs=0,total_quantized=0,total_xbc=0,readbacks=0;
  int permit_round=0;
  bit allow_commits=1;
  bit was_stalled=0;
  gcore_done_t held_done;

  assign clear_local=service_clear||flush_valid;
  assign flush_ack={SERVICES{flush_valid}};
  assign external_flush_ack=flush_valid&&!(|sfu_valid_q);
  dea8_gcore_control control(.*);
  always_comb begin
    service_cmd_ready=0; service_done_valid=0; service_fault=0;
    service_fault[S_NORM]=compute_error;
    for(int s=0;s<SERVICES;s++) service_done[s]='0;
    service_cmd_ready[S_IMPORT]=import_cmd_ready;
    service_cmd_ready[S_NORM]=compute_cmd_ready;
    service_cmd_ready[S_RESIDUAL]=compute_cmd_ready;
    service_cmd_ready[S_XBC]=xbc_cmd_ready;
    service_done_valid[S_IMPORT]=import_done_valid; service_done[S_IMPORT]=import_done;
    service_done_valid[S_XBC]=xbc_done_valid; service_done[S_XBC]=xbc_done;
    if(compute_done.opcode==GC_RESIDUAL_APPLY) begin
      service_done_valid[S_RESIDUAL]=compute_done_valid; service_done[S_RESIDUAL]=compute_done;
      compute_done_ready=service_done_ready[S_RESIDUAL];
    end else begin
      service_done_valid[S_NORM]=compute_done_valid; service_done[S_NORM]=compute_done;
      compute_done_ready=service_done_ready[S_NORM];
    end
  end
  dea8_gcore_residual_import importer (
    .clk,.reset,.clear(clear_local),.cmd_valid(service_cmd_valid[S_IMPORT]),.cmd_ready(import_cmd_ready),.cmd(service_cmd),
    .in_valid(import_valid),.in_ready(import_ready),.in_data(import_data),
    .wr_valid(import_wr_valid),.wr_ready(import_wr_ready),.wr_addr(import_wr_addr),.wr_data(import_wr_data),
    .done_valid(import_done_valid),.done_ready(service_done_ready[S_IMPORT]),.done(import_done),.busy(import_busy)
  );
  dea8_gcore_shared_compute compute (
    .clk,.reset,.clear(clear_local),
    .invalidate_stats(service_cmd_valid[S_IMPORT]&&service_cmd_ready[S_IMPORT]),
    .cmd_valid(service_cmd_valid[S_NORM]||service_cmd_valid[S_RESIDUAL]),.cmd_ready(compute_cmd_ready),.cmd(service_cmd),
    .context_data(active_context),.header_valid,.header_ready,.header,.data_valid,.data_ready,.data,.last,
    .commit_valid,.commit_ready,.commit,
    .ram_rd_valid,.ram_rd_ready,.ram_rd_addr,.ram_rsp_valid,.ram_rsp_ready,.ram_rsp_addr,.ram_rsp_data,
    .ram_wr_valid,.ram_wr_ready,.ram_wr_addr,.ram_wr_data,
    .activation_valid,.activation_ready,.activation_index,.activation_word,
    .rsqrt_valid,.rsqrt_ready,.rsqrt_request,.rsqrt_out_valid,.rsqrt_out_ready,.rsqrt_response,
    .done_valid(compute_done_valid),.done_ready(compute_done_ready),.done(compute_done),.busy(compute_busy),.stats_valid,.protocol_error(compute_error)
  );
  assign store_rd_valid=debug_mode?debug_valid:ram_rd_valid;
  assign store_rd_addr=debug_mode?debug_addr:ram_rd_addr;
  assign store_rsp_ready=debug_mode?debug_rsp_ready:ram_rsp_ready;
  assign debug_ready=debug_mode&&store_rd_ready;
  assign debug_rsp_valid=debug_mode&&store_rsp_valid;
  assign ram_rd_ready=!debug_mode&&store_rd_ready;
  assign ram_rsp_valid=!debug_mode&&store_rsp_valid;
  assign ram_rsp_addr=store_rsp_addr;
  assign ram_rsp_data=store_rsp_data;
  assign store_wr_valid=import_wr_valid||ram_wr_valid;
  assign store_wr_addr=import_wr_valid?import_wr_addr:ram_wr_addr;
  assign store_wr_data=import_wr_valid?import_wr_data:ram_wr_data;
  assign import_wr_ready=store_wr_ready;
  assign ram_wr_ready=store_wr_ready&&!import_wr_valid;
  dea8_gcore_residual_store residual_store (
    .clk,.reset,.clear(clear_local),.wr_valid(store_wr_valid),.wr_ready(store_wr_ready),.wr_addr(store_wr_addr),.wr_data(store_wr_data),
    .rd_valid(store_rd_valid),.rd_ready(store_rd_ready),.rd_addr(store_rd_addr),
    .rsp_valid(store_rsp_valid),.rsp_ready(store_rsp_ready),.rsp_data(store_rsp_data),.rsp_addr(store_rsp_addr),.protocol_error(residual_error)
  );
  dea8_gcore_activation_store activation_store (
    .clk,.reset,.clear(clear_local),.wr_valid(activation_valid),.wr_ready(activation_ready),.wr_index(activation_index),.wr_word(activation_word),
    .rd_valid(xbc_rd_valid),.rd_ready(xbc_rd_ready),.rd_tile(xbc_rd_tile),.rd_group(xbc_rd_group),
    .rsp_valid(xbc_rsp_valid),.rsp_ready(xbc_rsp_ready),.rsp(xbc_rsp),.protocol_error(activation_error)
  );
  dea8_gcore_xbc source (
    .clk,.reset,.clear(clear_local),.cmd_valid(service_cmd_valid[S_XBC]),.cmd_ready(xbc_cmd_ready),.cmd(service_cmd),
    .rd_valid(xbc_rd_valid),.rd_ready(xbc_rd_ready),.rd_tile(xbc_rd_tile),.rd_group(xbc_rd_group),
    .rsp_valid(xbc_rsp_valid),.rsp_ready(xbc_rsp_ready),.rsp(xbc_rsp),.xbc_valid,.xbc_ready,.xbc,
    .gu_prefetch_valid(gu_valid),.gu_prefetch_ready(gu_ready),.gu_prefetch_n(gu_n),
    .done_valid(xbc_done_valid),.done_ready(service_done_ready[S_XBC]),.done(xbc_done),.busy(xbc_busy),.protocol_error(xbc_error)
  );
  assign rsqrt_out_valid=sfu_valid_q[SFU_LATENCY-1]||stray_sfu;
  assign rsqrt_response=stray_sfu?rsqrt_packet_t'('0):sfu_data_q[SFU_LATENCY-1];
  assign sfu_advance=!rsqrt_out_valid||rsqrt_out_ready;
  assign rsqrt_ready=sfu_advance&&(cycle%7!=2)&&!clear_local&&!reset;
  always @(posedge clk) begin
    cycle++;
    if(reset||clear_local) sfu_valid_q<=0;
    else if(sfu_advance) begin
      sfu_valid_q[0]<=rsqrt_valid&&rsqrt_ready;
      for(int i=1;i<SFU_LATENCY;i++) begin sfu_valid_q[i]<=sfu_valid_q[i-1]; sfu_data_q[i]<=sfu_data_q[i-1]; end
      if(rsqrt_valid&&rsqrt_ready) begin
        rsqrt_packet_t response;
        logic [31:0] expected_u0,expected_u1;
        response=rsqrt_request;
        case(numeric_stage)
          0:begin expected_u0=u_initial[response.row0]; expected_u1=response.mask[1]?u_initial[response.row1]:0;
            response.data[31:0]=inv_initial[response.row0]; response.data[63:32]=response.mask[1]?inv_initial[response.row1]:0; end
          1:begin expected_u0=u_mid[response.row0]; expected_u1=response.mask[1]?u_mid[response.row1]:0;
            response.data[31:0]=inv_mid[response.row0]; response.data[63:32]=response.mask[1]?inv_mid[response.row1]:0; end
          2:begin expected_u0=u_next[response.row0]; expected_u1=response.mask[1]?u_next[response.row1]:0;
            response.data[31:0]=inv_next[response.row0]; response.data[63:32]=response.mask[1]?inv_next[response.row1]:0; end
          default:$fatal(1,"unknown numerical stage");
        endcase
        if(rsqrt_request.data!=={expected_u1,expected_u0}) $fatal(1,"RSQRT input mismatch stage=%0d row=%0d got=%h expected=%h",numeric_stage,response.row0,rsqrt_request.data,{expected_u1,expected_u0});
        if(bad_sfu) response.token=response.token+1'b1;
        sfu_data_q[0]<=response; sfu_requests++;
      end
    end
  end
  always @(negedge clk) begin
    for(int c=0;c<CORES;c++) begin
      xbc_ready[c]=(cycle+2*c)%17>c%5;
      if(!gu_valid[c]||gu_ready[c]) begin
        gu_valid[c]=xbc_busy&&source.command_q.pcore_op==OP_GU&&grant_counts[c]<32;
        gu_n[c]=6'(grant_counts[c]);
      end
    end
    commit_ready=allow_commits&&(cycle%5!=1);
  end
  always @(posedge clk) if(!reset&&!clear_local) begin
    if(was_stalled&&(!done_valid||done!==held_done)) $fatal(1,"GCore completion changed under backpressure");
    was_stalled=done_valid&&!done_ready; held_done=done;
    if(cmd_valid&&cmd_ready) accepted_jobs++;
    if(done_valid&&done_ready) completed_jobs++;
    if(import_wr_valid&&ram_wr_valid) $fatal(1,"GCore residual write owner collision");
    if(residual_error||activation_error||xbc_error) $fatal(1,"unexpected GCore memory/source error");
    if(ram_rd_valid&&ram_rd_ready) read_count++;
    if(ram_wr_valid&&ram_wr_ready) begin
      logic [255:0] gold;
      gold=numeric_stage==1?mid_res[write_count]:next_res[write_count];
      if(ram_wr_addr!=write_count||ram_wr_data!==gold) $fatal(1,"GCore residual write mismatch stage=%0d index=%0d",numeric_stage,write_count);
      write_count++;
    end
    if(activation_valid&&activation_ready) begin
      logic [135:0] gold;
      case(numeric_stage)
        0:gold=q_initial[activation_count];
        1:gold=q_mid[activation_count];
        2:gold=q_next[activation_count];
      endcase
      if(activation_index!=activation_count||activation_word!==gold) $fatal(1,"GCore XHAT mismatch stage=%0d index=%0d got=%h expected=%h",numeric_stage,activation_count,activation_word,gold);
      activation_count++; total_quantized++;
    end
    if(commit_valid&&commit_ready) begin
      if(commit.tile_seq!=commit_count||write_count<(commit_count+1)*ROWS||commit.status!=0||commit.source_id!=CORES)
        $fatal(1,"GCore committed before residual/statistic completion");
      commit_count++;
    end
    for(int c=0;c<CORES;c++) begin
      if(gu_valid[c]&&gu_ready[c]) grant_counts[c]++;
      if(xbc_valid[c]&&xbc_ready[c]) begin
        int tile,group;
        tile=(xbc_counts[c]/ROW_GROUPS)%HIDDEN_TILES; group=xbc_counts[c]%ROW_GROUPS;
        if(xbc.tile_idx!=tile||xbc.group_idx!=group) $fatal(1,"GCore XBC ordering mismatch");
        for(int r=0;r<4;r++) begin
          logic [135:0] gold;
          int index;
          index=tile*ROWS+4*group+r;
          gold=0;
          if(group*4+r<ROWS) begin
            case(numeric_stage)
              0:gold=q_initial[index];
              1:gold=q_mid[index];
              2:gold=q_next[index];
            endcase
          end
          if(xbc.row[r].data!==gold[127:0]||xbc.row[r].scale!==gold[135:128]) $fatal(1,"computed XBC mismatch stage=%0d core=%0d index=%0d",numeric_stage,c,index);
        end
        xbc_counts[c]++; total_xbc++;
      end
    end
  end
  function automatic logic [$bits(gcore_cmd_t)-1:0] make_command(input gcore_opcode_e op,input int id,
      input int source_version=1,input int target_version=1);
    gcore_cmd_t c;
    c='0; c.opcode=op; c.command_id=16'(id); c.generation=2; c.context_id=9; c.core_mask='1;
    c.src_version=16'(source_version); c.dst_version=16'(target_version);
    case(op)
      GC_IMPORT_RESID:c.dst_object=100;
      GC_NORM:begin c.src_object=100; c.dst_object=200; c.epsilon_fp32=32'h358637bd; end
      GC_XBC_RUN:begin c.src_object=200; c.pcore_op=numeric_stage==1?OP_GU:OP_K_PROJ; end
      GC_RESIDUAL_APPLY:begin c.src_object=100; c.dst_object=100; c.pcore_op=numeric_stage==1?OP_O_PROJ:OP_DOWN_PROJ; end
      default:;
    endcase
    return c;
  endfunction
  task automatic send(input gcore_cmd_t c);
    @(negedge clk); cmd=c; cmd_valid=1;
    do @(posedge clk); while(!cmd_ready);
    @(negedge clk); cmd_valid=0;
  endtask
  task automatic completion(input int id,input gcore_status_e status=GC_OK);
    wait(done_valid); @(negedge clk);
    if(done.command_id!=id||done.status!=status) $fatal(1,"shared job mismatch expected id=%0d status=%0d got=%0d/%0d",id,status,done.command_id,done.status);
    repeat(5) @(negedge clk);
    done_ready=1; @(posedge clk); @(negedge clk); done_ready=0;
  endtask
  task automatic configure;
    @(negedge clk); config_data='0;
    config_data.context_id=9; config_data.generation=2; config_data.gamma_folded=1;
    config_data.prefix_version=7; config_data.suffix_version=8;
    config_data.k_transfer.transfer_id=1; config_data.v_transfer.transfer_id=2;
    config_data.o_transfer.transfer_id=3; config_data.down_transfer.transfer_id=4;
    config_valid=1;
    do @(posedge clk); while(!config_ready);
    @(negedge clk); config_valid=0;
    wait(config_done_valid); if(config_status!=GC_OK) $fatal(1,"shared context rejected");
    @(negedge clk);
  endtask
  task automatic import_residual(input int id,version);
    send(make_command(GC_IMPORT_RESID,id,0,version));
    for(int index=0;index<VECTOR_WORDS;index++) begin
      @(negedge clk); import_valid=1; import_data='0;
      import_data.data=initial_res[index]; import_data.index=VECTOR_ADDR_BITS'(index);
      import_data.last=index==VECTOR_WORDS-1; import_data.token=command_token(cmd);
      do @(posedge clk); while(!import_ready);
    end
    @(negedge clk); import_valid=0; completion(id);
  endtask
  task automatic run_norm(input int id,src_version,dst_version,input bit expect_scan);
    int before_reads,before_sfu;
    @(negedge clk); activation_count=0; before_reads=read_count; before_sfu=sfu_requests;
    send(make_command(GC_NORM,id,src_version,dst_version)); completion(id);
    if(activation_count!=VECTOR_WORDS||read_count-before_reads!=VECTOR_WORDS*(expect_scan?2:1)||sfu_requests-before_sfu!=26)
      $fatal(1,"NORM work/cache count mismatch scan=%0d reads=%0d quant=%0d",expect_scan,read_count-before_reads,activation_count);
    $display("SHARED_METRICS norm=%0d scan=%0d reads=%0d quantized=%0d rsqrt_packets=26",id,expect_scan,read_count-before_reads,activation_count);
  endtask
  task automatic run_xbc(input int id,version);
    @(negedge clk);
    for(int c=0;c<CORES;c++) begin xbc_counts[c]=0; grant_counts[c]=1; end
    send(make_command(GC_XBC_RUN,id,version,0)); completion(id);
    for(int c=0;c<CORES;c++) if(xbc_counts[c]!=expected_items(cmd)) $fatal(1,"computed XBC was incomplete");
  endtask
  task automatic run_residual(input int id,src_version,dst_version);
    tile_transfer_t transfer;
    send(make_command(GC_RESIDUAL_APPLY,id,src_version,dst_version));
    @(negedge clk); write_count=0; commit_count=0;
    transfer=numeric_stage==1?active_context.o_transfer:active_context.down_transfer;
    for(int tile=0;tile<HIDDEN_TILES;tile++) begin
      if(tile==HIDDEN_TILES-1) allow_commits=0;
      @(negedge clk); header='0;
      header.transfer_id=transfer.transfer_id; header.transfer_epoch=transfer.transfer_epoch;
      header.destination_id=transfer.destination_id; header.token_origin=transfer.token_origin;
      header.rows=ROWS; header.columns=TILE; header.column_base=16'(tile*TILE);
      header.kind=numeric_stage==1?TILE_O:TILE_DOWN; header.layout=LAYOUT_FP_ROWS;
      header.source_id=CORES; header.tile_seq=6'(tile); header_valid=1;
      do @(posedge clk); while(!header_ready);
      @(negedge clk); header_valid=0;
      for(int row=0;row<ROWS;row++) begin
        @(negedge clk); data_valid=1; data=numeric_stage==1?delta_o[tile*ROWS+row]:delta_down[tile*ROWS+row]; last=row==ROWS-1;
        do @(posedge clk); while(!data_ready);
      end
      @(negedge clk); data_valid=0; last=0;
      if(tile==HIDDEN_TILES-1) begin
        tile_commit_t held;
        wait(commit_valid); @(negedge clk); held=commit;
        repeat(8) begin
          @(negedge clk);
          if(!commit_valid||commit!==held||done_valid||compute_done_valid)
            $fatal(1,"final Tile commit was not part of the job completion barrier");
        end
        allow_commits=1;
      end
      wait(commit_count==tile+1);
    end
    completion(id);
    if(write_count!=VECTOR_WORDS||commit_count!=HIDDEN_TILES||!stats_valid) $fatal(1,"residual job incomplete");
    $display("SHARED_METRICS residual=%0d writes=%0d tile_commits=%0d stats_valid=1",id,write_count,commit_count);
  endtask
  task automatic cancel_and_reconfigure;
    @(negedge clk); cancel_valid=1;
    do @(posedge clk); while(!cancel_ready);
    @(negedge clk); cancel_valid=0;
    wait(flush_valid); wait(!flush_valid);
    repeat(3) @(negedge clk);
    if(fault||context_valid||stats_valid||(|sfu_valid_q)||compute_error) $fatal(1,"shared flush did not invalidate context/statistics/late SFU responses");
    configure();
  endtask
  task automatic check_residual;
    @(negedge clk); debug_mode=1;
    for(int index=0;index<VECTOR_WORDS;index++) begin
      logic [255:0] gold;
      @(negedge clk); debug_valid=1; debug_addr=VECTOR_ADDR_BITS'(index);
      do @(posedge clk); while(!debug_ready);
      @(negedge clk); debug_valid=0;
      wait(debug_rsp_valid);
      gold=numeric_stage==1?mid_res[index]:next_res[index];
      if(store_rsp_addr!=index||store_rsp_data!==gold) $fatal(1,"residual physical readback mismatch");
      debug_rsp_ready=1; @(posedge clk); readbacks++;
      @(negedge clk); debug_rsp_ready=0;
    end
    @(negedge clk); debug_mode=0;
  endtask
  initial begin
    cmd='0; config_data='0; import_data='0; header='0;
    for(int c=0;c<CORES;c++) begin xbc_counts[c]=0; grant_counts[c]=1; end
    $readmemh("tb/data/initial_residual.mem",initial_res); $readmemh("tb/data/mid_residual.mem",mid_res); $readmemh("tb/data/next_residual.mem",next_res);
    $readmemh("tb/data/reduce_o.mem",delta_o); $readmemh("tb/data/reduce_down.mem",delta_down);
    $readmemh("tb/data/initial_xhat.mem",q_initial); $readmemh("tb/data/mid_xhat.mem",q_mid); $readmemh("tb/data/next_xhat.mem",q_next);
    $readmemh("tb/data/initial_u.mem",u_initial); $readmemh("tb/data/mid_u.mem",u_mid); $readmemh("tb/data/next_u.mem",u_next);
    $readmemh("tb/data/initial_inv.mem",inv_initial); $readmemh("tb/data/mid_inv.mem",inv_mid); $readmemh("tb/data/next_inv.mem",inv_next);
    repeat(5) @(negedge clk); reset=0;
    configure();
    import_residual(1,1); run_norm(2,1,1,1); run_xbc(3,1);
    numeric_stage=1; run_residual(4,1,2); check_residual(); run_norm(5,2,2,0); run_xbc(6,2);
    numeric_stage=2; run_residual(7,2,3); check_residual(); run_norm(8,3,3,0); run_xbc(9,3);
    numeric_stage=0; import_residual(10,4); run_norm(11,4,4,1);
    // A stale/wrong SFU token cannot publish XHAT, even if its FP32 value is plausible.
    bad_sfu=1; send(make_command(GC_NORM,12,4,5)); completion(12,GC_SOURCE_PROTOCOL);
    if(!fault||objects[OBJ_XHAT].state!=OBJECT_INVALID) $fatal(1,"bad SFU token did not invalidate XHAT");
    bad_sfu=0; cancel_and_reconfigure();
    import_residual(13,1); run_norm(14,1,1,1);
    @(negedge clk); stray_sfu=1;
    @(negedge clk); stray_sfu=0;
    repeat(6) begin @(negedge clk); if(done_valid) $fatal(1,"late SFU response generated a second completion"); end
    if(!fault||!compute_error) $fatal(1,"unsolicited SFU response after retirement was ignored");
    cancel_and_reconfigure(); import_residual(15,1);
    numeric_stage=1; write_count=0;
    send(make_command(GC_RESIDUAL_APPLY,16,1,2));
    @(negedge clk); header='0; header.source_id=7; header_valid=1;
    do @(posedge clk); while(!header_ready);
    @(negedge clk); header_valid=0;
    completion(16,GC_BAD_HEADER);
    if(!fault||write_count!=0||objects[OBJ_RESID].state!=OBJECT_INVALID) $fatal(1,"bad Reduce header mutated/published the residual");
    cancel_and_reconfigure(); import_residual(17,1);
    write_count=0;
    send(make_command(GC_RESIDUAL_APPLY,18,1,2));
    @(negedge clk); header='0;
    header.transfer_id=active_context.o_transfer.transfer_id;
    header.rows=ROWS; header.columns=TILE; header.kind=TILE_O; header.layout=LAYOUT_FP_ROWS;
    header.source_id=CORES; header_valid=1;
    do @(posedge clk); while(!header_ready);
    @(negedge clk); header_valid=0; data=0; data[31:0]=32'h7f7fffff; data_valid=1; last=0;
    do @(posedge clk); while(!data_ready);
    @(negedge clk); data_valid=0;
    completion(18,GC_NUMERIC_FAULT);
    if(!fault||write_count!=0||objects[OBJ_RESID].state!=OBJECT_INVALID) $fatal(1,"finite-to-BF16 overflow was committed");
    if(accepted_jobs!=18||completed_jobs!=18) $fatal(1,"shared stage job accounting mismatch");
    $display("tb_gcore_shared PASS real_control_jobs=%0d normalization_jobs=5 residual_jobs=2 tile_commits=128 quantized_vectors=%0d xbc_receives=%0d physical_readbacks=%0d rsqrt_tb_latency=8 sfu_token_rejection=1 late_response_fault=1 bad_header=1 bf16_overflow_rejection=1 flush_recovery=3",completed_jobs,total_quantized,total_xbc,readbacks);
    $finish;
  end
  initial begin #3000000; $fatal(1,"shared GCore watchdog"); end
endmodule
