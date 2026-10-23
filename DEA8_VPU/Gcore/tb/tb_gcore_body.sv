`timescale 1ns/1ps
// Structural GCore + real eight-way Reduce. PCore arithmetic/host/global
// controller are not instantiated: their boundary streams are TB agents.
module tb_gcore_body #(parameter bit NATIVE_RSQRT=1'b0);
  import gcore_pkg::*;
  import pcore_pkg::xbc4_t;
  import pcore_pkg::b2_t;
  import pcore_pkg::pcore_op_e;
  import pcore_pkg::OP_Q_PROJ;
  import pcore_pkg::OP_K_PROJ;
  import pcore_pkg::OP_V_PROJ;
  import pcore_pkg::OP_ATTENTION;
  import pcore_pkg::OP_O_PROJ;
  import pcore_pkg::OP_GU;
  import pcore_pkg::OP_DOWN_PROJ;
  import dea8_tile_link_pkg::*;
  import gcore_tb_pkg::*;
  logic clk=0; always #2 clk=~clk;
  logic reset=1,config_valid=0,config_ready,config_done_valid,config_done_ready=1;
  gcore_context_t config_data;
  gcore_status_e config_status;
  logic preloaded_valid=0,preloaded_ready,preloaded_done_valid,preloaded_done_ready=0;
  gcore_preloaded_t preloaded;
  gcore_status_e preloaded_status;
  logic cmd_valid=0,cmd_ready,done_valid,done_ready;
  gcore_cmd_t cmd;
  gcore_done_t done;
  logic import_valid=0,import_ready;
  residual_import_t import_data='0;
  logic [CORES-1:0] xbc_valid,xbc_ready,gu_prefetch_valid,gu_prefetch_ready;
  logic [CORES-1:0][5:0] gu_prefetch_n;
  xbc4_t xbc;
  logic [CORES-1:0] kv_header_valid=0,kv_header_ready,kv_data_valid=0,kv_data_ready,kv_last=0;
  tile_header_t kv_header [CORES];
  logic [CORES-1:0][135:0] kv_data=0;
  logic [CORES-1:0] kv_commit_valid,kv_commit_ready;
  tile_commit_t kv_commit [CORES];
  logic [CORES-1:0] kv_valid,kv_ready;
  b2_t kv;
  logic reduce_header_valid,reduce_header_ready,reduce_data_valid,reduce_data_ready,reduce_last;
  tile_header_t reduce_header;
  logic [127:0] reduce_header_bits;
  logic [511:0] reduce_data;
  logic reduce_commit_valid,reduce_commit_ready;
  tile_commit_t reduce_commit;
  logic rsqrt_valid,rsqrt_ready,rsqrt_out_valid,rsqrt_out_ready;
  rsqrt_packet_t rsqrt_request,rsqrt_response;
  logic invalidate_valid=0,invalidate_ready;
  logic [OBJECTS-1:0] invalidate_mask=0;
  logic kv_release_valid=0,kv_release_ready,kv_lease;
  logic cancel_valid=0,cancel_ready,flush_valid,external_flush_ack,fault;
  logic [SERVICES-1:0] busy;
  logic [7:0] reduce_in_hdr_valid=0,reduce_in_hdr_ready,reduce_in_data_valid=0,reduce_in_data_ready,reduce_in_last=0;
  logic [7:0][127:0] reduce_in_hdr_bits=0;
  logic [7:0][511:0] reduce_in_data=0;
  logic reduce_busy,reduce_error;
  dea8_gcore #(.INTERNAL_RSQRT(NATIVE_RSQRT)) dut (.*);
  assign reduce_header=tile_header_t'(reduce_header_bits);
  dea8_reduce_top reduce_tree (
    .clk,.reset,.clear(flush_valid),
    .in_hdr_valid(reduce_in_hdr_valid),.in_hdr_ready(reduce_in_hdr_ready),.in_hdr_bits(reduce_in_hdr_bits),
    .in_data_valid(reduce_in_data_valid),.in_data_ready(reduce_in_data_ready),.in_data(reduce_in_data),.in_last(reduce_in_last),
    .out_hdr_valid(reduce_header_valid),.out_hdr_ready(reduce_header_ready),.out_hdr_bits(reduce_header_bits),
    .out_data_valid(reduce_data_valid),.out_data_ready(reduce_data_ready),.out_data(reduce_data),.out_last(reduce_last),
    .commit_valid(reduce_commit_valid),.commit_ready(reduce_commit_ready),.commit(reduce_commit),
    .busy(reduce_busy),.protocol_error(reduce_error)
  );
  logic [255:0] initial_res[VECTOR_WORDS],mid_res[VECTOR_WORDS],next_res[VECTOR_WORDS];
  logic [511:0] delta_o[VECTOR_WORDS],delta_down[VECTOR_WORDS];
  logic [135:0] q_initial[VECTOR_WORDS],q_mid[VECTOR_WORDS];
  logic [31:0] u_initial[ROWS],u_mid[ROWS],inv_initial[ROWS],inv_mid[ROWS];
  int cycle=0,numeric_stage=0;
  // All ready/stimulus derived from cycle must settle before the sample edge.
  always @(negedge clk)cycle++;
  int xbc_count[CORES],kv_count[CORES],grant_count[CORES];
  int rx_phase[CORES],rx_tile[CORES],rx_word[CORES];
  int reduce_phase[CORES],reduce_tile[CORES],reduce_row[CORES];
  int quantized=0,kv_writes=0,kv_commits=0,reduce_rows=0,reduce_commits=0,completed_jobs=0;
  int physical_checks=0,rsqrt_packets=0;
  bit rx_active=0,rx_value=0,reduce_active=0;
  bit retired[256];
  gcore_status_e retired_status[256];
  logic [7:0] sfu_valid_q=0;
  rsqrt_packet_t sfu_data_q[8];
  logic sfu_advance;
  bit held_done=0;
  gcore_done_t saved_done;

  for(genvar k=0;k<2;k++) begin: preload_kinds
    for(genvar f=0;f<16;f++) begin: preload_features
      for(genvar p=0;p<2;p++) begin: preload_parities
        initial for(int a=0;a<PREFIX_BANK_DEPTH;a++)
          dut.services.kv_store.preload_prefix(k,f,p,a,
            kv_word(k,1,f,k?(a/8)*16+(a%8)*2+p:2*a+p));
      end
    end
  end
  assign done_ready=cycle%9>2;
  if(!NATIVE_RSQRT) begin: tb_rsqrt_service
  assign rsqrt_out_valid=sfu_valid_q[7];
  assign rsqrt_response=sfu_data_q[7];
  assign sfu_advance=!rsqrt_out_valid||rsqrt_out_ready;
  assign rsqrt_ready=sfu_advance&&cycle%7!=2&&!flush_valid&&!reset;
  assign external_flush_ack=flush_valid&&!(|sfu_valid_q);
  always @(posedge clk) begin
    if(reset||flush_valid) sfu_valid_q<=0;
    else if(sfu_advance) begin
      sfu_valid_q[0]<=rsqrt_valid&&rsqrt_ready;
      for(int i=1;i<8;i++) begin sfu_valid_q[i]<=sfu_valid_q[i-1]; sfu_data_q[i]<=sfu_data_q[i-1]; end
      if(rsqrt_valid&&rsqrt_ready) begin
        rsqrt_packet_t r;
        logic [31:0] u0,u1;
        r=rsqrt_request;
        u0=numeric_stage==0?u_initial[r.row0]:u_mid[r.row0];
        u1=r.mask[1]?(numeric_stage==0?u_initial[r.row1]:u_mid[r.row1]):0;
        if(r.data!=={u1,u0}) $fatal(1,"body rsqrt input mismatch row=%0d",r.row0);
        r.data[31:0]=numeric_stage==0?inv_initial[r.row0]:inv_mid[r.row0];
        r.data[63:32]=r.mask[1]?(numeric_stage==0?inv_initial[r.row1]:inv_mid[r.row1]):0;
        sfu_data_q[0]<=r; rsqrt_packets++;
      end
    end
  end
  end else begin: real_rsqrt_service
    assign rsqrt_ready=0;assign rsqrt_out_valid=0;assign rsqrt_response='0;
    assign sfu_advance=0;assign external_flush_ack=flush_valid;
    always @(posedge clk) begin
      if(!reset&&!flush_valid&&rsqrt_valid&&dut.local_rsqrt_ready) begin
        logic [31:0] u0,u1;
        u0=numeric_stage==0?u_initial[rsqrt_request.row0]:u_mid[rsqrt_request.row0];
        u1=rsqrt_request.mask[1]?(numeric_stage==0?u_initial[rsqrt_request.row1]:u_mid[rsqrt_request.row1]):0;
        if(rsqrt_request.data!=={u1,u0})$fatal(1,"native body rsqrt input mismatch");
        rsqrt_packets++;
      end
      if(!reset&&!flush_valid&&dut.local_rsqrt_valid&&dut.compute_rsqrt_ready)
        for(int lane=0;lane<2;lane++)if(dut.local_rsqrt_response.mask[lane])begin
          int row;int unsigned actual,gold,distance;
          row=lane?dut.local_rsqrt_response.row1:dut.local_rsqrt_response.row0;
          actual=dut.local_rsqrt_response.data[32*lane+:32];
          gold=numeric_stage==0?inv_initial[row]:inv_mid[row];
          distance=actual>gold?actual-gold:gold-actual;
          if(distance>1)$fatal(1,"native body rsqrt ULP mismatch");
        end
    end
  end

  function automatic logic [$bits(tile_header_t)-1:0] source_header(input int c,t,input bit value_kind,is_reduce);
    tile_header_t h;
    tile_transfer_t transfer;
    transfer=is_reduce?(numeric_stage==1?config_data.o_transfer:config_data.down_transfer):
      (value_kind?config_data.v_transfer:config_data.k_transfer);
    h='0; h.transfer_id=transfer.transfer_id; h.transfer_epoch=transfer.transfer_epoch;
    h.destination_id=transfer.destination_id; h.token_origin=transfer.token_origin;
    h.rows=ROWS; h.columns=TILE; h.source_id=4'(c); h.tile_seq=6'(t);
    h.column_base=16'(is_reduce?t*16:(value_kind?c*32+t*16:c*16+t*128));
    h.kind=is_reduce?(numeric_stage==1?TILE_O:TILE_DOWN):(value_kind?TILE_V:TILE_K);
    h.layout=is_reduce?LAYOUT_FP_ROWS:(value_kind?LAYOUT_V_GROUPS:LAYOUT_K_ROWS);
    return h;
  endfunction
  function automatic logic [511:0] partial_delta(input int index);
    logic [511:0] w,d;
    logic [31:0] v;
    d=numeric_stage==1?delta_o[index]:delta_down[index];
    for(int i=0;i<TILE;i++) begin
      v=d[32*i+:32];
      if(v[30:0]!=0) begin
        if(v[30:23]<=3) $fatal(1,"TB /8 requires normal reference input");
        v[30:23]=v[30:23]-8'd3;
      end
      w[32*i+:32]=v;
    end
    return w;
  endfunction
  always @(negedge clk) if(!reset) begin
    for(int c=0;c<CORES;c++) begin
      xbc_ready[c]=(cycle+c*3)%13>c%4;
      kv_ready[c]=(cycle+c*5)%17>c%6;
      kv_commit_ready[c]=cycle%7!=c%7;
      if(!gu_prefetch_valid[c]||gu_prefetch_ready[c]) begin
        gu_prefetch_valid[c]=dut.xbc_busy&&dut.xbc_source.command_q.pcore_op==OP_GU&&grant_count[c]<32;
        gu_prefetch_n[c]=6'(grant_count[c]);
      end
      if(!kv_header_valid[c]||kv_header_ready[c]) begin
        kv_header_valid[c]=rx_active&&rx_phase[c]==0&&rx_tile[c]<2&&(cycle+c)%5!=0;
        kv_header[c]=source_header(c,rx_tile[c],rx_value,0);
      end
      if(!kv_data_valid[c]||kv_data_ready[c]) begin
        kv_data_valid[c]=rx_active&&rx_phase[c]==1&&(cycle+c)%7!=1;
        kv_data[c]=kv_word(rx_value,0,rx_value?2*c+rx_tile[c]:c+8*rx_tile[c],rx_word[c]);
        kv_last[c]=rx_word[c]==(rx_value?63:50);
      end
      if(!reduce_in_hdr_valid[c]||reduce_in_hdr_ready[c]) begin
        reduce_in_hdr_valid[c]=reduce_active&&reduce_phase[c]==0&&reduce_tile[c]<64&&(cycle+c)%5!=1;
        reduce_in_hdr_bits[c]=source_header(c,reduce_tile[c],0,1);
      end
      if(!reduce_in_data_valid[c]||reduce_in_data_ready[c]) begin
        reduce_in_data_valid[c]=reduce_active&&reduce_phase[c]==1&&(cycle+c)%7!=2;
        if(reduce_tile[c]<64) reduce_in_data[c]=partial_delta(reduce_tile[c]*ROWS+reduce_row[c]);
        reduce_in_last[c]=reduce_row[c]==50;
      end
    end
  end
  always @(posedge clk) if(!reset) begin
    if(held_done&&(!done_valid||done!==saved_done)) $fatal(1,"body completion changed under backpressure");
    held_done=done_valid&&!done_ready; saved_done=done;
    if(fault||reduce_error) $fatal(1,"body top error: gcore=%b reduce=%b",fault,reduce_error);
    if(done_valid&&done_ready) begin
      if(retired[done.command_id]) $fatal(1,"body duplicate completion");
      retired[done.command_id]=1; retired_status[done.command_id]=done.status; completed_jobs++;
    end
    if(dut.activation_valid&&dut.activation_ready) begin
      logic [135:0] gold;
      gold=numeric_stage==0?q_initial[dut.activation_index]:q_mid[dut.activation_index];
      if(dut.activation_word!==gold) $fatal(1,"body quantized RAM write mismatch");
      quantized++;
    end
    for(int c=0;c<CORES;c++) begin
      if(gu_prefetch_valid[c]&&gu_prefetch_ready[c]) grant_count[c]++;
      if(xbc_valid[c]&&xbc_ready[c]) begin
        int t,g;
        logic [135:0] w;
        t=(xbc_count[c]/ROW_GROUPS)%HIDDEN_TILES; g=xbc_count[c]%ROW_GROUPS;
        if(xbc.tile_idx!=t||xbc.group_idx!=g) $fatal(1,"body XBC metadata mismatch");
        for(int p=0;p<4;p++) begin
          w=0;
          if(g*4+p<ROWS) w=numeric_stage==0?q_initial[t*ROWS+g*4+p]:q_mid[t*ROWS+g*4+p];
          if({xbc.row[p].scale,xbc.row[p].data}!==w) $fatal(1,"body XBC payload mismatch");
        end
        xbc_count[c]++;
      end
      if(kv_header_valid[c]&&kv_header_ready[c]) rx_phase[c]=1;
      if(kv_data_valid[c]&&kv_data_ready[c]) begin
        if(kv_last[c]) rx_phase[c]=2;
        rx_word[c]++;
      end
      if(kv_commit_valid[c]&&kv_commit_ready[c]) begin
        tile_header_t h;
        h=source_header(c,rx_tile[c],rx_value,0);
        if(!commit_matches(kv_commit[c],h)||rx_phase[c]!=2) $fatal(1,"body KV commit mismatch");
        rx_tile[c]++; rx_word[c]=0; rx_phase[c]=0; kv_commits++;
      end
      if(dut.kv_wr_valid[c]&&dut.kv_wr_ready[c]) kv_writes++;
      if(kv_valid[c]&&kv_ready[c]) begin
        b2_t gold;
        gold=kvb_expected(kv_count[c],config_data.pcore_epoch);
        if(kv!==gold) $fatal(1,"body KVB mismatch core=%0d beat=%0d got=%h gold=%h",c,kv_count[c],kv,gold);
        kv_count[c]++;
      end
      if(reduce_in_hdr_valid[c]&&reduce_in_hdr_ready[c]) reduce_phase[c]=1;
      if(reduce_in_data_valid[c]&&reduce_in_data_ready[c]) begin
        if(reduce_in_last[c]) begin reduce_phase[c]=0; reduce_tile[c]++; reduce_row[c]=0; end
        else reduce_row[c]++;
      end
    end
    if(reduce_data_valid&&reduce_data_ready) begin
      logic [511:0] gold;
      gold=numeric_stage==1?delta_o[reduce_rows%VECTOR_WORDS]:delta_down[reduce_rows%VECTOR_WORDS];
      if(reduce_data!==gold||reduce_last!=(reduce_rows%ROWS==50)) $fatal(1,"body real Reduce sum mismatch index=%0d",reduce_rows);
      reduce_rows++;
    end
    if(reduce_commit_valid&&reduce_commit_ready) reduce_commits++;
  end
  function automatic logic [$bits(gcore_cmd_t)-1:0] command(input gcore_opcode_e op,input int id,input pcore_op_e p=OP_Q_PROJ);
    gcore_cmd_t c;
    c='0; c.opcode=op; c.command_id=16'(id); c.context_id=9; c.generation=2; c.core_mask='1; c.pcore_op=p;
    case(op)
      GC_NORM:begin c.src_object=100; c.src_version=16'(numeric_stage+1); c.dst_object=200; c.dst_version=c.src_version; c.epsilon_fp32=32'h358637bd; end
      GC_XBC_RUN:begin c.src_object=200; c.src_version=16'(numeric_stage+1); end
      GC_KV_RX:begin c.dst_object=p==OP_K_PROJ?400:500; c.dst_version=8; end
      GC_KVB_RUN:begin c.src_object=300; c.src_version=7; end
      GC_RESIDUAL_APPLY:begin c.src_object=100; c.src_version=16'(numeric_stage); c.dst_object=100; c.dst_version=16'(numeric_stage+1); end
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
    wait(retired[id]); @(negedge clk);
    if(retired_status[id]!=status) $fatal(1,"body completion mismatch id=%0d got=%0d expected=%0d",id,retired_status[id],status);
  endtask
  task automatic registration(input bit legal);
    @(negedge clk); preloaded.context_id=9; preloaded.generation=2;
    preloaded.residual_object=100; preloaded.residual_version=1;
    preloaded.prefix_object=300; preloaded.prefix_version=legal?7:99; preloaded_valid=1;
    do @(posedge clk); while(!preloaded_ready);
    @(negedge clk); preloaded_valid=0;
    wait(preloaded_done_valid);
    repeat(4) begin
      @(negedge clk);
      if(!preloaded_done_valid||preloaded_status!=(legal?GC_OK:GC_BAD_CONTEXT)) $fatal(1,"body preloaded registration mismatch");
    end
    preloaded_done_ready=1; @(posedge clk); @(negedge clk); preloaded_done_ready=0;
  endtask
  task automatic start_xbc(input int id,input pcore_op_e op);
    @(negedge clk);
    for(int c=0;c<CORES;c++) begin xbc_count[c]=0; grant_count[c]=1; end
    send(command(GC_XBC_RUN,id,op));
  endtask
  task automatic finish_xbc(input int id,input pcore_op_e op);
    completion(id);
    for(int c=0;c<CORES;c++) if(xbc_count[c]!=xbc_tiles(op)*HIDDEN_TILES*ROW_GROUPS) $fatal(1,"body incomplete XBC replay");
  endtask
  task automatic receive_kv(input int id,input bit is_value);
    @(negedge clk); rx_value=is_value;
    for(int c=0;c<CORES;c++) begin rx_phase[c]=0; rx_tile[c]=0; rx_word[c]=0; end
    send(command(GC_KV_RX,id,is_value?OP_V_PROJ:OP_K_PROJ));
    @(negedge clk); rx_active=1; completion(id); rx_active=0;
    for(int c=0;c<CORES;c++) if(rx_tile[c]!=2) $fatal(1,"body incomplete suffix KV");
  endtask
  task automatic apply_residual(input int id);
    @(negedge clk);
    for(int c=0;c<CORES;c++) begin reduce_phase[c]=0; reduce_tile[c]=0; reduce_row[c]=0; end
    send(command(GC_RESIDUAL_APPLY,id,numeric_stage==1?OP_O_PROJ:OP_DOWN_PROJ));
    @(negedge clk); reduce_active=1; completion(id); reduce_active=0;
    for(int a=0;a<VECTOR_WORDS;a++) begin
      if(dut.residual_store.memory[a] !== (numeric_stage==1?mid_res[a]:next_res[a]))
        $fatal(1,"body residual RAM mismatch stage=%0d index=%0d",numeric_stage,a);
      physical_checks++;
    end
  endtask
  initial begin
    cmd='0; config_data='0; preloaded='0; xbc_ready=0; kv_ready=0; kv_commit_ready=0;
    gu_prefetch_valid=0; gu_prefetch_n=0;
    for(int c=0;c<CORES;c++) begin
      xbc_count[c]=0; kv_count[c]=0; grant_count[c]=1; rx_phase[c]=0; rx_tile[c]=0; rx_word[c]=0;
      reduce_phase[c]=0; reduce_tile[c]=0; reduce_row[c]=0; kv_header[c]='0;
    end
    for(int i=0;i<256;i++) begin retired[i]=0; retired_status[i]=GC_OK; end
    $readmemh("tb/data/initial_residual.mem",initial_res); $readmemh("tb/data/mid_residual.mem",mid_res); $readmemh("tb/data/next_residual.mem",next_res);
    $readmemh("tb/data/reduce_o.mem",delta_o); $readmemh("tb/data/reduce_down.mem",delta_down);
    $readmemh("tb/data/initial_xhat.mem",q_initial); $readmemh("tb/data/mid_xhat.mem",q_mid);
    $readmemh("tb/data/initial_u.mem",u_initial); $readmemh("tb/data/mid_u.mem",u_mid);
    $readmemh("tb/data/initial_inv.mem",inv_initial); $readmemh("tb/data/mid_inv.mem",inv_mid);
    for(int a=0;a<VECTOR_WORDS;a++) dut.residual_store.memory[a]=initial_res[a];
    repeat(30) @(negedge clk); reset=0;
    @(negedge clk); config_data.context_id=9; config_data.generation=2; config_data.gamma_folded=1;
    config_data.pcore_epoch=4'hb; config_data.prefix_version=7; config_data.suffix_version=8;
    config_data.k_transfer='{16'd1,16'd11,16'd21,16'd31};
    config_data.v_transfer='{16'd2,16'd12,16'd22,16'd32};
    config_data.o_transfer='{16'd3,16'd13,16'd23,16'd33};
    config_data.down_transfer='{16'd4,16'd14,16'd24,16'd34};
    config_valid=1;
    do @(posedge clk); while(!config_ready);
    @(negedge clk); config_valid=0; wait(config_done_valid);
    if(config_status!=GC_OK) $fatal(1,"body context rejected");
    registration(0); registration(1);
    send(command(GC_KVB_RUN,90,OP_ATTENTION)); completion(90,GC_PRECONDITION);
    send(command(GC_NORM,1)); completion(1);
    start_xbc(2,OP_K_PROJ); receive_kv(3,0); finish_xbc(2,OP_K_PROJ);
    start_xbc(4,OP_V_PROJ); receive_kv(5,1); finish_xbc(4,OP_V_PROJ);
    start_xbc(6,OP_Q_PROJ); finish_xbc(6,OP_Q_PROJ);
    send(command(GC_KVB_RUN,7,OP_ATTENTION)); completion(7);
    for(int c=0;c<CORES;c++) if(kv_count[c]!=KVB_WORDS) $fatal(1,"body incomplete 55-block KVB");
    if(!kv_lease) $fatal(1,"body KV lease released before Attention global barrier");
    @(negedge clk); kv_release_valid=1;
    do @(posedge clk); while(!kv_release_ready);
    @(negedge clk); kv_release_valid=0;
    numeric_stage=1; apply_residual(8);
    send(command(GC_NORM,9)); completion(9);
    start_xbc(10,OP_GU); finish_xbc(10,OP_GU);
    numeric_stage=2; apply_residual(11);
    if(quantized!=2*VECTOR_WORDS||kv_writes!=816+1024||kv_commits!=32||
        reduce_rows!=2*VECTOR_WORDS||reduce_commits!=128||rsqrt_packets!=52||completed_jobs!=12)
      $fatal(1,"body final work count mismatch");
    $display("tb_gcore_body PASS structural_top=1 real_reduce=1 jobs=%0d norms=2 suffix_words=%0d kv_commits=%0d kvb_jobs=110 kvb_beats_per_core=14080 reduce_rows=%0d reduce_commits=%0d residual_checks=%0d prefix_receive=0 real_pcore=0",completed_jobs,kv_writes,kv_commits,reduce_rows,reduce_commits,physical_checks);
    $finish;
  end
  initial begin #3000000; $fatal(1,"GCore body watchdog"); end
endmodule
