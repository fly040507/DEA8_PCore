`timescale 1ns/1ps
import pcore_pkg::*;
import pcore_control_pkg::*;
import dea8_tile_link_pkg::*;

// Only external HBM/XBC/KVB/control and GCore's receiving endpoint are agents.
// Hierarchical references below are passive acceptance/performance monitors.
module tb_pcore_seven_native;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,config_valid=0,config_ready,configured;
  logic [15:0] config_context=16'h1234,config_mask_version=1,config_rope_version=1,config_position=816;
  logic job_valid=0,job_ready,done_valid,done_ready=0,busy,protocol_error,flush_done;
  control_job_t job;control_completion_t done;
  logic xbc_valid=0,xbc_ready,hbm_valid=0,hbm_ready,kv_valid=0,kv_ready;
  xbc4_t xbc_entry;b2_t hbm_entry,kv_entry;
  logic tx_valid,tx_ready,tx_last;logic [255:0] tx_data;
  logic kv_commit_valid=0,kv_commit_ready;tile_commit_t kv_commit;
  logic gu_prefetch_valid,gu_prefetch_ready=1;logic [5:0] gu_prefetch_n;
  logic kv_hdr_valid,kv_hdr_ready=1,kv_out_valid,kv_out_ready=1,kv_out_last;
  logic reduce_hdr_valid,reduce_hdr_ready=1,reduce_out_valid,reduce_out_ready=1,reduce_out_last;
  tile_header_t kv_hdr,reduce_hdr,kh,rh;
  logic [135:0] kv_out;logic [511:0] reduce_out;
  logic [135:0] qgold[816],ogold[816],zgold[1632],kgold[102],vgold[128],pgold[2805];
  logic [31:0] sgold[44880],reduce_gold[102];logic [127:0] stat_gold[2805];
  int cycle=0,completed=0,allowed_n=0,kv_beat=0,reduce_beat=0;
  int issues[7],job_cycles[7],sent[7],qoz_count[7],p_count=0,starts=0,qks=0,pvs=0;
  int start_cycle,block_start[110],stage_start[32],stage_max[32],scale_margin_min=1000000;
  int total_cycles=0,checked_fp=0,checked_q=0;
  bit stress=0,k_only=0,kvq_only=0,through_gu=0;
  dea8_pcore_top dut(.*);
  tb_packet_decode receiver(.clk,.reset,.clear,.tx_valid,.tx_ready,.tx_data,.tx_last,
    .kv_hdr_valid,.kv_hdr_ready,.kv_hdr,.kv_out_valid,.kv_out_ready,.kv_out,.kv_out_last,
    .reduce_hdr_valid,.reduce_hdr_ready,.reduce_hdr,.reduce_out_valid,.reduce_out_ready,.reduce_out,.reduce_out_last);

  function automatic int aint(input int row);return row%3-1;endfunction
  function automatic qvec16_t qv(input int x);
    qvec16_t v;v.scale=128;for(int j=0;j<16;j++)v.data[8*j+:8]=8'(x);return v;
  endfunction
  function automatic int weight(input int n,col,input bit up);
    int feature;feature=job.header.op==OP_Q_PROJ?n/2+(n%2)*8:n;
    if(job.header.op==OP_GU)return up?2:1;
    if(job.header.op==OP_K_PROJ||job.header.op==OP_V_PROJ||job.header.op==OP_Q_PROJ)
      return 1+(16*feature+col)%3;
    return 1;
  endfunction
  function automatic string op_name(input pcore_op_e op);
    case(op)
      OP_K_PROJ:return "K";OP_V_PROJ:return "V";OP_Q_PROJ:return "Q";
      OP_ATTENTION:return "Attention";OP_O_PROJ:return "O";OP_GU:return "G-U";default:return "Down";
    endcase
  endfunction
  task automatic fp_check(input logic [31:0] actual,expected,input int allowance,input string label_text,input int address);
    longint signed distance;
    distance=longint'({1'b0,actual[30:0]})-longint'({1'b0,expected[30:0]});
    if((^actual)===1'bx||((actual!==expected)&&
      ((&actual[30:23])||actual[31]!=expected[31]||distance>allowance||distance< -allowance)))
      $fatal(1,"%s address=%0d got=%h expected=%h ulp=%0d",label_text,address,actual,expected,distance);
    checked_fp++;
  endtask
  task automatic q_check(input qvec16_t actual,input logic [135:0] expected,input string label_text,input int address);
    if(actual!==expected)$fatal(1,"%s address=%0d got=%h expected=%h",label_text,address,actual,expected);
    checked_q++;
  endtask
  task automatic send_b(input int transport,group,n,input bit from_kvb,input int block,input bit pv);
    b2_t b;b='0;b.tile_idx=TILE_BITS'(transport);b.group_idx=3'(group);b.epoch=job.header.epoch;
    for(int c=0;c<2;c++)begin
      b.col[c]=qv(0);
      for(int i=0;i<16;i++)b.col[c].data[8*i+:8]=8'(from_kvb?(pv?1:1+block%3):weight(n,2*group+c,transport[0]));
    end
    @(negedge clk);
    if(stress&&cycle%17==0)begin
      if(from_kvb)kv_valid=0;else hbm_valid=0;
      repeat(3)@(negedge clk);
    end
    if(from_kvb)begin kv_entry=b;kv_valid=1;do @(posedge clk);while(!kv_ready);end
    else begin hbm_entry=b;hbm_valid=1;do @(posedge clk);while(!hbm_ready);end
  endtask
  task automatic send_xbc(input int k,g);
    @(negedge clk);xbc_entry='0;xbc_entry.tile_idx=TILE_BITS'(k);xbc_entry.group_idx=4'(g);
    xbc_entry.row_valid=g==XBC_GROUPS-1?4'b0111:4'b1111;
    for(int r=0;r<4;r++)xbc_entry.row[r]=qv(aint(4*g+r));
    xbc_valid=1;do @(posedge clk);while(!xbc_ready);
  endtask
  task automatic feed_projection(input int nt,kt,input bit local_a);
    fork
      begin
        if(!local_a)for(int n=0;n<nt;n++)for(int k=0;k<kt;k++)for(int g=0;g<XBC_GROUPS;g++)send_xbc(k,g);
        @(negedge clk);xbc_valid=0;
      end
      begin
        for(int n=0;n<nt;n++)for(int k=0;k<kt;k++)for(int g=0;g<8;g++)
          send_b(local_a?(n*kt+k)%64:k,g,n,0,0,0);
        @(negedge clk);hbm_valid=0;
      end
    join
  endtask
  task automatic feed_gu;
    fork
      begin
        for(int n=0;n<32;n++)begin
          if(n>0)wait(allowed_n>=n);
          for(int k=0;k<64;k++)for(int g=0;g<XBC_GROUPS;g++)send_xbc(k,g);
        end
        @(negedge clk);xbc_valid=0;
      end
      begin
        for(int n=0;n<32;n++)for(int t=0;t<128;t++)for(int g=0;g<8;g++)send_b(t%64,g,n,0,0,0);
        @(negedge clk);hbm_valid=0;
      end
    join
  endtask
  task automatic feed_attention;
    int block;bit pv;
    for(int j=0;j<110;j++)begin
      if(j==0)begin block=0;pv=0;end
      else if(j==109)begin block=54;pv=1;end
      else begin pv=!j[0];block=j[0]?(j+1)/2:j/2-1;end
      for(int t=0;t<16;t++)for(int g=0;g<8;g++)send_b((j*16+t)%64,g,0,1,block,pv);
    end
    @(negedge clk);kv_valid=0;
  endtask
  task automatic run_job(input pcore_op_e op,input int id,expected_issues);
    @(negedge clk);job='0;job.header='{job_id:16'(id),epoch:4'd3,head:3'd0,op:op};
    job.data_context=config_context;job.user_tag=64'ha500000000000000|id;
    job.position_base=config_position;job.core_id=0;job.rope_pair_base=0;
    job.transfer='{transfer_id:16'(id),transfer_epoch:16'd9,destination_id:16'(op),token_origin:16'd816};
    job_valid=1;do @(posedge clk);while(!job_ready);
    start_cycle=cycle;@(negedge clk);job_valid=0;
    fork
      begin
        case(op)
          OP_K_PROJ,OP_V_PROJ:feed_projection(2,64,0);
          OP_Q_PROJ:feed_projection(16,64,0);
          OP_ATTENTION:feed_attention();
          OP_O_PROJ:feed_projection(64,16,1);
          OP_GU:feed_gu();
          OP_DOWN_PROJ:feed_projection(64,32,1);
        endcase
      end
      begin
        wait(done_valid);@(negedge clk);
        if(done.job!==job||done.status!=CONTROL_OK||issues[op]!=expected_issues)
          $fatal(1,"Job completion op=%0d status=%0d issues=%0d expected=%0d",op,done.status,issues[op],expected_issues);
        job_cycles[op]=cycle-start_cycle;total_cycles+=job_cycles[op];
        $display("JOB_PERF name=%s op=%0d cycles=%0d matrix_issues=%0d occupancy=%0.4f sent=%0d qoz=%0d",
          op_name(op),op,job_cycles[op],issues[op],real'(issues[op])/job_cycles[op],sent[op],qoz_count[op]);
        repeat(3)begin @(negedge clk);if(!done_valid||job_ready||done.job!==job)$fatal(1,"Completion hold");end
        done_ready=1;@(negedge clk);done_ready=0;completed++;
      end
    join
  endtask
  always @(posedge clk)begin
    cycle++;
    if(!reset&&!clear)begin
      if(protocol_error)$fatal(1,"PCore protocol cycle=%0d op=%0d ctrl=%b exec=%b post=%b sfu=%b vpu_state=%0d",
        cycle,job.header.op,dut.control.fault_event,dut.control.ee,dut.control.se,dut.sfu.protocol_error,dut.vpu.state);
      if(gu_prefetch_valid&&gu_prefetch_ready)allowed_n=gu_prefetch_n;
      if(dut.control.exec.dispatch.matrix.req_valid)issues[job.header.op]++;
      if(dut.control.exec.attention.mv&&dut.control.exec.attention.mr)begin
        if(starts>=110)$fatal(1,"Extra attention subjob");
        block_start[starts]=cycle;starts++;
      end
      if(dut.control.exec.attention.mdv&&dut.control.exec.attention.mdr)begin
        if(dut.control.exec.attention.md.op==MATRIX_QK)qks++;else pvs++;
      end
      if(dut.vector_valid&&dut.vector_ready)stage_start[dut.vector_cmd.function_id]=cycle;
      if(dut.function_valid&&dut.function_ready)stage_start[dut.function_cmd.function_id]=cycle;
      if(dut.vector_done_valid&&dut.vector_done_ready)begin
        int f,d;f=dut.vector_done.command.function_id;d=cycle-stage_start[f];
        if(d>stage_max[f])stage_max[f]=d;
      end
      if(dut.function_done_valid&&dut.function_done_ready)begin
        int f,d;f=dut.function_done.command.function_id;d=cycle-stage_start[f];
        if(d>stage_max[f])stage_max[f]=d;
      end
      if(dut.control.exec.qoz.store.wr_valid&&dut.control.exec.qoz.store.wr_ready)begin
        int address;address=dut.control.exec.qoz.store.wr_tile*51+2*dut.control.exec.qoz.store.wr_pair;
        case(dut.control.exec.qoz.store.wr_owner)
          QOZ_Q:begin
            q_check(dut.control.exec.qoz.store.wr_even,qgold[address],"Q QOZ",address);
            if(dut.control.exec.qoz.store.wr_row_valid[1])q_check(dut.control.exec.qoz.store.wr_odd,qgold[address+1],"Q QOZ",address+1);
          end
          QOZ_O:begin
            q_check(dut.control.exec.qoz.store.wr_even,ogold[address],"O QOZ",address);
            if(dut.control.exec.qoz.store.wr_row_valid[1])q_check(dut.control.exec.qoz.store.wr_odd,ogold[address+1],"O QOZ",address+1);
          end
          QOZ_Z:begin
            q_check(dut.control.exec.qoz.store.wr_even,zgold[address],"Z QOZ",address);
            if(dut.control.exec.qoz.store.wr_row_valid[1])q_check(dut.control.exec.qoz.store.wr_odd,zgold[address+1],"Z QOZ",address+1);
          end
          default:$fatal(1,"Unexpected QOZ owner");
        endcase
        qoz_count[job.header.op]++;
      end
      if(dut.vector_result_valid&&dut.vector_result_ready&&dut.vpu.cmd.function_id==VECTOR_P_POST)begin
        int block,p;block=dut.vpu.cmd.tile;p=dut.vector_result.index;
        for(int r=0;r<2;r++)if(dut.vector_result.vector_valid[r])
          q_check(dut.vector_result.vector_data[r],pgold[51*block+2*p+r],"P quant",51*block+2*p+r);
        p_count++;
      end
      if(dut.vector_mem_valid&&dut.vector_mem_ready&&dut.vector_mem_req.write)begin
        int block,index;block=dut.vpu.cmd.tile;index=dut.vector_mem_req.index;
        for(int j=0;j<16;j++)if(dut.vector_mem_req.mask[j])begin
          case(dut.vector_mem_req.buffer_id)
            WORK_SCORE:fp_check(dut.vector_mem_req.data[j],sgold[(block*51+index)*16+j],0,"Score/Mask",(block*51+index)*16+j);
            WORK_M:fp_check(dut.vector_mem_req.data[j],stat_gold[block*51+index+j][127:96],0,"m",block*51+index+j);
            WORK_AA:fp_check(dut.vector_mem_req.data[j],stat_gold[block*51+index+j][95:64],0,"aa",block*51+index+j);
            WORK_L:fp_check(dut.vector_mem_req.data[j],stat_gold[block*51+index+j][31:0],24,"l",block*51+index+j);
          endcase
        end
      end
      if(kv_commit_valid&&kv_commit_ready)kv_commit_valid<=0;
      if(kv_hdr_valid&&kv_hdr_ready)begin
        if(kv_hdr.source_id!=0||kv_hdr.tile_seq>=2||kv_hdr.column_base!=
          (job.header.op==OP_K_PROJ?(kv_hdr.tile_seq==0?0:128):16*kv_hdr.tile_seq))$fatal(1,"KV coordinates");
        kh=kv_hdr;kv_beat=0;
      end
      if(kv_out_valid&&kv_out_ready)begin
        q_check(qvec16_t'({kv_out[127:0],kv_out[135:128]}),job.header.op==OP_K_PROJ?
          kgold[kh.tile_seq*51+kv_beat]:vgold[kh.tile_seq*64+kv_beat],"KV packet",sent[job.header.op]);
        if(kv_out_last!=(kv_beat==(job.header.op==OP_K_PROJ?50:63)))$fatal(1,"KV last");
        kv_beat++;sent[job.header.op]++;
        if(kv_out_last)begin
          kv_commit<='{transfer_id:kh.transfer_id,transfer_epoch:kh.transfer_epoch,
            tile_seq:kh.tile_seq,source_id:kh.source_id,status:0,reserved:0};
          kv_commit_valid<=1;
        end
      end
      if(reduce_hdr_valid&&reduce_hdr_ready)begin
        if(reduce_hdr.source_id!=0||reduce_hdr.column_base!=16*reduce_hdr.tile_seq)$fatal(1,"Reduce coordinates");
        rh=reduce_hdr;reduce_beat=0;
      end
      if(reduce_out_valid&&reduce_out_ready)begin
        for(int j=0;j<16;j++)fp_check(reduce_out[32*j+:32],reduce_gold[(job.header.op==OP_DOWN_PROJ?51:0)+reduce_beat],0,"FP32 output",sent[job.header.op]*16+j);
        if(reduce_out_last!=(reduce_beat==50))$fatal(1,"Reduce last");
        reduce_beat++;sent[job.header.op]++;
      end
    end
  end
  initial begin
    job='0;xbc_entry='0;hbm_entry='0;kv_entry='0;kv_commit='0;
    $readmemh("tb/data/seven_job/q.mem",qgold);$readmemh("tb/data/seven_job/k.mem",kgold);
    $readmemh("tb/data/seven_job/v.mem",vgold);$readmemh("tb/data/seven_job/o.mem",ogold);
    $readmemh("tb/data/seven_job/z.mem",zgold);$readmemh("tb/data/seven_job/p.mem",pgold);
    $readmemh("tb/data/seven_job/score.mem",sgold);$readmemh("tb/data/seven_job/stats.mem",stat_gold);
    $readmemh("tb/data/seven_job/reduce.mem",reduce_gold);
    stress=$test$plusargs("STRESS");k_only=$test$plusargs("K_ONLY");
    kvq_only=$test$plusargs("KVQ_ONLY");through_gu=$test$plusargs("THROUGH_GU");
    repeat(35)@(negedge clk);reset=0;repeat(8)@(negedge clk);
    config_valid=1;do @(posedge clk);while(!config_ready);
    @(negedge clk);config_valid=0;wait(configured);
    run_job(OP_K_PROJ,1,3328);
    if(k_only)begin $display("tb_pcore_seven_native PASS subset=K_ONLY internal_tb_models=0");$finish;end
    run_job(OP_V_PROJ,2,3328);run_job(OP_Q_PROJ,3,26624);
    if(kvq_only)begin $display("tb_pcore_seven_native PASS subset=KVQ_ONLY internal_tb_models=0");$finish;end
    run_job(OP_ATTENTION,4,45760);run_job(OP_O_PROJ,5,26624);run_job(OP_GU,6,106496);
    if(through_gu)begin $display("tb_pcore_seven_native PASS subset=THROUGH_GU internal_tb_models=0");$finish;end
    run_job(OP_DOWN_PROJ,7,53248);
    if(completed!=7||starts!=110||qks!=55||pvs!=55||p_count!=55*26||
      qoz_count[OP_Q_PROJ]!=416||qoz_count[OP_ATTENTION]!=416||qoz_count[OP_GU]!=832||
      sent[OP_K_PROJ]!=102||sent[OP_V_PROJ]!=128||sent[OP_O_PROJ]!=3264||sent[OP_DOWN_PROJ]!=3264)
      $fatal(1,"Seven Job transaction accounting");
    $display("TOTAL cycles=%0d matrix_issues=265408 checked_q=%0d checked_fp=%0d",total_cycles,checked_q,checked_fp);
    $display("HIDING qk_post=%0d alpha=%0d P_exp=%0d P_post=%0d scale=%0d recip=%0d afin=%0d gu=%0d",
      stage_max[VECTOR_QK_POST],stage_max[FUNCTION_ALPHA_EXP],stage_max[FUNCTION_P_EXP],stage_max[VECTOR_P_POST],
      stage_max[VECTOR_OACC_SCALE],stage_max[FUNCTION_RECIP],stage_max[VECTOR_AFIN_QUANT],stage_max[FUNCTION_GELU]);
    $display("tb_pcore_seven_native PASS jobs=7 QK=55 PV=55 internal_tb_models=0 synthesis=0");$finish;
  end
  initial begin #4000000;$fatal(1,"Seven Job timeout cycle=%0d op=%0d ctrl=%b vpu=%0d sfu=%0d issues=%0d",
    cycle,job.header.op,dut.control.active_q,dut.vpu.state,dut.sfu.state,issues[job.header.op]);end
endmodule
