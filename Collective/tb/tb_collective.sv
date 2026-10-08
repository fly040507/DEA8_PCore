`timescale 1ns/1ps
module tb_collective;
  import pcore_control_pkg::*;
  import dea8_collective_pkg::*;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,cancel=0,cmd_valid=0,cmd_ready,done_valid,done_ready=0,busy;
  collective_config_t cmd;
  collective_completion_t done;
  logic [7:0] kv_valid=0,kv_ready,fp_valid=0,fp_ready;
  collective_packet_t kv_packet[8],fp_packet[8];
  logic g_kv_valid,g_kv_ready=0,g_fp_valid,g_fp_ready=0;
  collective_kv_t g_kv,kv_hold;
  collective_fp_t g_fp,fp_hold;
  dea8_collective_top dut(.*);
  logic [255:0] operands[1024];
  logic [31:0] expected[1024];
  logic [255:0] gcore_data[512];
  logic [15:0] gcore_scale[512];
  bit visited[512];
  int sent[8],committed[8],out_count,cycle=0;
  int kv_stalls=0,fp_stalls=0,tree_stalls=0,jobs=0,error_tests=0;
  bit [7:0] accepted;
  bit checking=0,kv_stalled=0,fp_stalled=0;

  function automatic logic [7:0] sample(input int row,col,input collective_op_e op);
    return 8'((row*13+col*7+int'(op)*31)%255);
  endfunction
  function automatic logic [7:0] scale_value(input int row,col,input collective_op_e op);
    return (op==COLLECT_K)?8'(100+(col/16+row)%20):8'(90+(col+row/16)%25);
  endfunction
  function automatic collective_packet_t packet(input int c,q);
    collective_packet_t p;
    int t,j,row,col,which;
    p='0;p.job=cmd.expected_job[c];p.op=cmd.op;p.quantized=is_kv(cmd.op);
    t=q/((cmd.op==COLLECT_V)?32:26);j=q%((cmd.op==COLLECT_V)?32:26);
    p.tile=6'(t);p.index=10'(j);p.vector_valid=(cmd.op!=COLLECT_V&&j==25)?1:3;
    p.token_mask=is_kv(cmd.op)?((cmd.op==COLLECT_V&&j>=24)?16'h7:16'hffff):0;
    p.feature_base=16'((cmd.op==COLLECT_K)?16*c+128*t:((cmd.op==COLLECT_V)?32*c+16*t+2*(j%8):16*t));
    p.token_base=16'((cmd.op==COLLECT_V)?16*(j/8):2*j);
    p.tile_last=j==((cmd.op==COLLECT_V)?31:25);p.last=q==packet_count(cmd.op)-1;
    for(int r=0;r<2;r++)begin
      row=(cmd.op==COLLECT_V)?16*(j/8):2*j+r;
      col=(cmd.op==COLLECT_V)?int'(p.feature_base)+r:int'(p.feature_base);
      if(is_kv(cmd.op))p.scales[r]=scale_value(row,col,cmd.op);
      for(int i=0;i<16;i++)begin
        if(is_kv(cmd.op))p.payload[r][i]={24'b0,sample(row+((cmd.op==COLLECT_V)?i:0),col+((cmd.op==COLLECT_K)?i:0),cmd.op)};
        else begin
          which=(q*32+16*r+i+int'(cmd.op)*17)%1024;
          p.payload[r][i]=operands[which][32*c+:32];
        end
      end
    end
    return p;
  endfunction

  always @(posedge clk)begin
    cycle++;
    accepted=0;
    if(checking)begin
      if(kv_stalled&&(!g_kv_valid||g_kv!==kv_hold))$fatal(1,"KV changed under backpressure");
      if(fp_stalled&&(!g_fp_valid||g_fp!==fp_hold))$fatal(1,"FP changed under backpressure");
      kv_stalled=g_kv_valid&&!g_kv_ready;kv_hold=g_kv;
      fp_stalled=g_fp_valid&&!g_fp_ready;fp_hold=g_fp;
      for(int c=0;c<8;c++)begin
        accepted[c]=(kv_valid[c]&&kv_ready[c])||(fp_valid[c]&&fp_ready[c]);
        if(accepted[c])sent[c]++;
        if(kv_valid[c]&&!kv_ready[c])kv_stalls++;
        if(fp_valid[c]&&!fp_ready[c])fp_stalls++;
      end
      if(dut.tree.out_valid&&!dut.tree.out_ready)tree_stalls++;
      if(g_kv_valid&&g_kv_ready)begin
        int c,q,word,t,j;
        c=int'(g_kv.core_id);q=committed[c];
        t=q/((cmd.op==COLLECT_V)?32:26);j=q%((cmd.op==COLLECT_V)?32:26);
        word=(cmd.op==COLLECT_K)?(8*t+c)*26+j:(16*c+8*t+j%8)*4+j/8;
        if(g_kv.collective_id!=cmd.collective_id||g_kv.destination_id!=cmd.destination_id||
          g_kv.token_origin!=cmd.token_origin||g_kv.op!=cmd.op||g_kv.source_sequence!=q||
          g_kv.word_index!=word||visited[word])$fatal(1,"KV identity/address/duplicate");
        if(g_kv.vector_valid!=((cmd.op==COLLECT_K&&j==25)?1:3)||
          g_kv.token_mask!=((cmd.op==COLLECT_V&&j>=24)?16'h7:16'hffff))$fatal(1,"KV mask");
        if(g_kv.core_last!=(q==packet_count(cmd.op)-1)||
          g_kv.job_last!=(out_count==8*packet_count(cmd.op)-1))$fatal(1,"KV completion boundary");
        visited[word]=1;gcore_data[word]=g_kv.data;gcore_scale[word]=g_kv.scales;
        committed[c]++;out_count++;
      end
      if(g_fp_valid&&g_fp_ready)begin
        if(g_fp.collective_id!=cmd.collective_id||g_fp.destination_id!=cmd.destination_id||
          g_fp.token_origin!=cmd.token_origin||g_fp.op!=cmd.op||g_fp.word_index!=out_count||
          g_fp.row_valid!=((out_count%26==25)?1:3)||g_fp.last!=(out_count==1663))$fatal(1,"FP metadata");
        for(int lane=0;lane<32;lane++)begin
          logic [31:0] gold;
          gold=(out_count%26==25&&lane>=16)?32'b0:expected[(out_count*32+lane+int'(cmd.op)*17)%1024];
          if(g_fp.data[32*lane+:32]!==gold)$fatal(1,"FP mismatch seq=%0d lane=%0d got=%h expected=%h",out_count,lane,g_fp.data[32*lane+:32],gold);
        end
        out_count++;
      end
    end
  end

  task automatic configure(input collective_op_e op,input int id);
    @(negedge clk);
    cmd='0;cmd.op=op;cmd.collective_id=64'(id);cmd.destination_id=16'(id+100);cmd.token_origin=19;
    for(int c=0;c<8;c++)begin
      cmd.expected_job[c].core_id=3'(c);cmd.expected_job[c].rope_pair_base=8'(16*c);
      cmd.expected_job[c].header.job_id=16'(id*8+c);cmd.expected_job[c].header.head=3'(c);
      cmd.expected_job[c].user_tag=64'(id*256+c);cmd.expected_job[c].data_context=16'(id);
      case(op)
        COLLECT_K:cmd.expected_job[c].header.op=pcore3_pkg::OP_K_PROJ;
        COLLECT_V:cmd.expected_job[c].header.op=pcore3_pkg::OP_V_PROJ;
        REDUCE_O:cmd.expected_job[c].header.op=pcore3_pkg::OP_O_PROJ;
        REDUCE_DOWN:cmd.expected_job[c].header.op=pcore3_pkg::OP_DOWN_PROJ;
      endcase
    end
  endtask
  task automatic launch;
    cmd_valid=1;
    do @(posedge clk);while(!cmd_ready);
    @(negedge clk);cmd_valid=0;
  endtask
  task automatic check_memory;
    // Read the destination by matrix coordinates, not in arrival order.
    for(int row=0;row<51;row++)for(int col=0;col<256;col++)begin
      int word,byte_lane,scale_lane;
      if(cmd.op==COLLECT_K)begin
        word=(col/16)*26+row/2;byte_lane=(row%2)*16+col%16;scale_lane=row%2;
      end else begin
        word=(col/2)*4+row/16;byte_lane=(col%2)*16+row%16;scale_lane=col%2;
      end
      if(!visited[word]||gcore_data[word][8*byte_lane+:8]!==sample(row,col,cmd.op)||
        gcore_scale[word][8*scale_lane+:8]!==scale_value(row,col,cmd.op))$fatal(1,"GCore matrix placement row=%0d col=%0d",row,col);
    end
    for(int w=0;w<8*packet_count(cmd.op);w++)begin
      if(!visited[w])$fatal(1,"GCore missing word");
      if(cmd.op==COLLECT_K&&w%26==25)begin
        if(gcore_data[w][255:128]!==128'b0||gcore_scale[w][15:8]!==8'b0)$fatal(1,"K tail not zero");
      end
      if(cmd.op==COLLECT_V&&w%4==3)for(int r=0;r<2;r++)for(int i=3;i<16;i++)
        if(gcore_data[w][8*(16*r+i)+:8]!==8'b0)$fatal(1,"V tail not zero");
    end
  endtask
  task automatic run_job(input collective_op_e op,input int id,input bit gaps);
    int start_cycle;
    collective_completion_t held_done;
    configure(op,id);
    out_count=0;kv_stalled=0;fp_stalled=0;
    for(int c=0;c<8;c++)begin sent[c]=0;committed[c]=0;end
    for(int w=0;w<512;w++)visited[w]=0;
    checking=1;launch();start_cycle=cycle;
    while(!done_valid)begin
      g_kv_ready=!gaps||cycle%19>=6;
      g_fp_ready=!gaps||(cycle%173>=43&&cycle%13!=0);
      for(int c=0;c<8;c++)begin
        if(is_kv(op))begin
          if(!kv_valid[c]||accepted[c])begin
            kv_valid[c]=sent[c]<packet_count(op)&&(!gaps||cycle%11!=c);
            kv_packet[c]=packet(c,sent[c]);
          end
        end else if(!fp_valid[c]||accepted[c])begin
          fp_valid[c]=sent[c]<packet_count(op)&&(!gaps||cycle%11!=c);
          fp_packet[c]=packet(c,sent[c]);
        end
      end
      @(negedge clk);
    end
    kv_valid=0;fp_valid=0;
    if(done.status!=COL_OK||done.collective_id!=cmd.collective_id||
      out_count!=(is_kv(op)?8*packet_count(op):packet_count(op)))$fatal(1,"Job completion");
    for(int c=0;c<8;c++)if(sent[c]!=packet_count(op))$fatal(1,"Input count");
    if(is_kv(op))check_memory();
    $display("JOB PASS op=%0d inputs_per_core=%0d outputs=%0d cycles=%0d gaps=%0d",op,packet_count(op),out_count,cycle-start_cycle,gaps);
    held_done=done;
    repeat(5)begin @(negedge clk);if(!done_valid||done!==held_done||cmd_ready)$fatal(1,"Done hold");end
    done_ready=1;@(negedge clk);done_ready=0;checking=0;jobs++;
  endtask
  task automatic finish_fault(input collective_status_e status);
    int timeout;
    timeout=0;
    while(!done_valid&&timeout<20)begin @(negedge clk);timeout++;end
    if(!done_valid||done.status!=status)$fatal(1,"Expected fault %0d",status);
    if(g_kv_valid||g_fp_valid||cmd_ready)$fatal(1,"Fault leaked output");
    kv_valid=0;fp_valid=0;cancel=0;done_ready=1;
    @(negedge clk);done_ready=0;
    repeat(3)begin @(negedge clk);if(cmd_ready||done_valid)$fatal(1,"Fault not retained");end
    clear=1;@(negedge clk);clear=0;
    error_tests++;
  endtask

  initial begin
    $readmemh("tb/operands.hex",operands);$readmemh("tb/expected.hex",expected);
    cmd='0;for(int c=0;c<8;c++)begin kv_packet[c]='0;fp_packet[c]='0;end
    repeat(5)@(negedge clk);reset=0;
    run_job(COLLECT_K,1,1);run_job(COLLECT_V,2,1);
    run_job(REDUCE_O,3,1);run_job(REDUCE_DOWN,4,0);
    for(int kind=0;kind<5;kind++)begin
      configure(COLLECT_K,10+kind);launch();
      kv_packet[0]=packet(0,0);
      case(kind)
        0:kv_packet[0].feature_base=16;
        1:kv_packet[0].last=1;
        2:kv_packet[0].job.user_tag=0;
        3:kv_packet[0].vector_valid=1;
        4:kv_packet[0].token_mask=0;
      endcase
      kv_valid[0]=1;finish_fault(COL_BAD_PACKET);
    end
    configure(COLLECT_V,20);launch();fp_packet[0]=packet(0,0);fp_valid[0]=1;finish_fault(COL_BAD_PACKET);
    configure(COLLECT_K,21);cmd.expected_job[4].rope_pair_base=0;launch();finish_fault(COL_BAD_CONFIG);
    configure(REDUCE_O,22);launch();g_fp_ready=0;
    for(int c=0;c<8;c++)fp_packet[c]=packet(c,0);
    fp_valid='1;@(negedge clk);fp_valid=0;
    repeat(5)@(negedge clk);cancel=1;finish_fault(COL_CANCELLED);
    run_job(COLLECT_K,30,0);
    if(kv_stalls==0||fp_stalls==0||tree_stalls==0)$fatal(1,"Missing backpressure coverage");
    $display("tb_collective PASS jobs=%0d faults=%0d kv_stalls=%0d fp_stalls=%0d tree_stalls=%0d",jobs,error_tests,kv_stalls,fp_stalls,tree_stalls);
    $finish;
  end
  initial begin #2000000;$fatal(1,"Collective timeout");end
endmodule
