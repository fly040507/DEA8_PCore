module dea8_collective_top #(
  parameter int KV_DEPTH=2, FP_DEPTH=4
)(
  input logic clk,reset,clear,cancel,
  input logic cmd_valid,output logic cmd_ready,
  input dea8_collective_pkg::collective_config_t cmd,
  output logic done_valid,input logic done_ready,
  output dea8_collective_pkg::collective_completion_t done,
  output logic busy,
  input logic [7:0] kv_valid,output logic [7:0] kv_ready,
  input pcore_control_pkg::collective_packet_t kv_packet[8],
  input logic [7:0] fp_valid,output logic [7:0] fp_ready,
  input pcore_control_pkg::collective_packet_t fp_packet[8],
  output logic g_kv_valid,input logic g_kv_ready,
  output dea8_collective_pkg::collective_kv_t g_kv,
  output logic g_fp_valid,input logic g_fp_ready,
  output dea8_collective_pkg::collective_fp_t g_fp
);
  import pcore_control_pkg::*;
  import dea8_collective_pkg::*;
  typedef enum logic [1:0] {IDLE,RUN,DONE,FAULT} state_t;
  state_t state_q;
  collective_config_t cfg_q;
  collective_completion_t completion_q;
  logic reported_q,kv_mode,cmd_fire,config_legal,run_enable,flush;
  logic [7:0] bad,kv_head_valid,fp_head_valid,kv_pop,fp_pop;
  logic [7:0] kv_space,fp_space,kv_empty,fp_empty;
  logic [7:0][271:0] kv_write,kv_head;
  logic [7:0][1023:0] fp_write,fp_head;
  logic [10:0] received_q[8],kv_dequeued_q[8];
  logic [10:0] group_q,fp_sent_q;
  logic [9:0] kv_dispatched_q,kv_sent_q;
  logic [2:0] rr_q,chosen;
  logic found,kv_load,kv_valid_q,all_received;
  collective_kv_t kv_next,kv_q;
  logic tree_in_valid,tree_in_ready,tree_valid,tree_ready,tree_empty;
  logic [1023:0] tree_data;
  logic [10:0] tree_sequence;
  collective_fp_t fp_next,fp_out;
  logic result_valid,result_empty;
  int expected_count;

  assign cmd_ready=state_q==IDLE&&!reset&&!clear&&!cancel;
  assign cmd_fire=cmd_valid&&cmd_ready;
  assign kv_mode=is_kv(cfg_q.op);
  assign expected_count=packet_count(cfg_q.op);
  assign busy=state_q!=IDLE;
  assign done=completion_q;
  assign done_valid=(state_q==DONE||(state_q==FAULT&&!reported_q))&&!reset&&!clear;
  assign run_enable=state_q==RUN&&!reset&&!clear&&!cancel&&!(|bad);
  assign flush=clear||cmd_fire||cancel||state_q==FAULT;

  always_comb begin
    config_legal=cmd.token_origin<=16'd65485;
    for(int c=0;c<8;c++)begin
      config_legal&=cmd.expected_job[c].core_id==c&&cmd.expected_job[c].layout_id==0;
      case(cmd.op)
        COLLECT_K:config_legal&=cmd.expected_job[c].header.op==pcore3_pkg::OP_K_PROJ&&
          cmd.expected_job[c].rope_pair_base==16*c;
        COLLECT_V:config_legal&=cmd.expected_job[c].header.op==pcore3_pkg::OP_V_PROJ;
        REDUCE_O:config_legal&=cmd.expected_job[c].header.op==pcore3_pkg::OP_O_PROJ;
        REDUCE_DOWN:config_legal&=cmd.expected_job[c].header.op==pcore3_pkg::OP_DOWN_PROJ;
        default:config_legal=0;
      endcase
    end
  end

  // Validate original packet coordinates before storing payload-only FIFO words.
  always_comb begin
    bad='0;kv_write='0;fp_write='0;all_received=1;
    for(int c=0;c<8;c++)begin
      collective_packet_t p;
      int seq,tile,index,feature,token;
      logic legal;
      logic [1:0] vectors;
      logic [15:0] mask;
      p=kv_mode?kv_packet[c]:fp_packet[c];
      seq=int'(received_q[c]);
      tile=seq/((cfg_q.op==COLLECT_V)?32:26);
      index=seq%((cfg_q.op==COLLECT_V)?32:26);
      vectors=(cfg_q.op!=COLLECT_V&&index==25)?2'b01:2'b11;
      mask=kv_mode?((cfg_q.op==COLLECT_V&&index>=24)?16'h0007:16'hffff):16'b0;
      feature=(cfg_q.op==COLLECT_K)?int'(cfg_q.expected_job[c].rope_pair_base)+128*tile:
        ((cfg_q.op==COLLECT_V)?32*c+16*tile+2*(index%8):16*tile);
      token=(cfg_q.op==COLLECT_V)?16*(index/8):2*index;
      legal=seq<expected_count&&p.job==cfg_q.expected_job[c]&&p.op==cfg_q.op&&
        p.quantized==kv_mode&&p.tile==tile&&p.index==index&&p.vector_valid==vectors&&
        p.token_mask==mask&&p.feature_base==feature&&p.token_base==token&&
        p.tile_last==(index==((cfg_q.op==COLLECT_V)?31:25))&&p.last==(seq==expected_count-1);
      if(state_q==RUN)bad[c]=(kv_mode?fp_valid[c]:kv_valid[c])||
        ((kv_mode?kv_valid[c]:fp_valid[c])&&!legal);
      all_received&=received_q[c]==expected_count;
      for(int r=0;r<2;r++)begin
        kv_write[c][256+8*r+:8]=vectors[r]?p.scales[r]:8'b0;
        for(int i=0;i<16;i++)begin
          kv_write[c][8*(16*r+i)+:8]=(vectors[r]&&mask[i])?p.payload[r][i][7:0]:8'b0;
          fp_write[c][32*(16*r+i)+:32]=vectors[r]?p.payload[r][i]:32'b0;
        end
      end
    end
  end
  for(genvar c=0;c<8;c++)begin:ingress
    assign kv_ready[c]=run_enable&&kv_mode&&kv_space[c];
    assign fp_ready[c]=run_enable&&!kv_mode&&fp_space[c];
    dea8_collective_fifo #(.WIDTH(KV_BITS),.DEPTH(KV_DEPTH)) kv_fifo(
      .clk,.reset,.clear(flush),.in_valid(run_enable&&kv_mode&&kv_valid[c]),
      .in_ready(kv_space[c]),.in_data(kv_write[c]),.out_valid(kv_head_valid[c]),
      .out_ready(kv_pop[c]),.out_data(kv_head[c]),.empty(kv_empty[c]),.occupancy());
    dea8_collective_fifo #(.WIDTH(FP_BITS),.DEPTH(FP_DEPTH)) fp_fifo(
      .clk,.reset,.clear(flush),.in_valid(run_enable&&!kv_mode&&fp_valid[c]),
      .in_ready(fp_space[c]),.in_data(fp_write[c]),.out_valid(fp_head_valid[c]),
      .out_ready(fp_pop[c]),.out_data(fp_head[c]),.empty(fp_empty[c]),.occupancy());
  end

  // Pop only when the selected word enters the held output register.
  always_comb begin
    int seq;
    chosen=rr_q;found=0;
    for(int offset=0;offset<8;offset++)begin
      if(!found&&kv_head_valid[(int'(rr_q)+offset)%8])begin
        chosen=3'((int'(rr_q)+offset)%8);found=1;
      end
    end
    kv_load=run_enable&&kv_mode&&found&&(!kv_valid_q||g_kv_ready);
    kv_pop='0;if(kv_load)kv_pop[chosen]=1;
    seq=int'(kv_dequeued_q[chosen]);
    kv_next='0;
    kv_next.collective_id=cfg_q.collective_id;kv_next.destination_id=cfg_q.destination_id;
    kv_next.token_origin=cfg_q.token_origin;kv_next.op=cfg_q.op;kv_next.core_id=chosen;
    kv_next.source_sequence=6'(seq);kv_next.word_index=kv_address(cfg_q.op,int'(chosen),seq);
    kv_next.vector_valid=(cfg_q.op==COLLECT_K&&seq%26==25)?2'b01:2'b11;
    kv_next.token_mask=(cfg_q.op==COLLECT_V&&seq%32>=24)?16'h0007:16'hffff;
    kv_next.data=kv_head[chosen][255:0];kv_next.scales=kv_head[chosen][271:256];
    kv_next.core_last=seq==expected_count-1;
    kv_next.job_last=kv_dispatched_q==8*expected_count-1;
  end
  assign g_kv=kv_q;
  assign g_kv_valid=kv_valid_q&&run_enable&&kv_mode;

  assign tree_in_valid=run_enable&&!kv_mode&&(&fp_head_valid);
  assign fp_pop={8{tree_in_valid&&tree_in_ready}};
  dea8_collective_reduce tree(.clk,.reset,.clear(flush),
    .in_valid(tree_in_valid),.in_ready(tree_in_ready),.in_data(fp_head),.in_sequence(group_q),
    .out_valid(tree_valid),.out_ready(tree_ready),.out_data(tree_data),.out_sequence(tree_sequence),.empty(tree_empty));
  always_comb begin
    fp_next='0;fp_next.collective_id=cfg_q.collective_id;fp_next.destination_id=cfg_q.destination_id;
    fp_next.token_origin=cfg_q.token_origin;fp_next.op=cfg_q.op;fp_next.word_index=tree_sequence;
    fp_next.row_valid=(tree_sequence%26==25)?2'b01:2'b11;
    fp_next.data=tree_data;fp_next.last=tree_sequence==1663;
  end
  dea8_collective_fifo #(.WIDTH($bits(collective_fp_t)),.DEPTH(2)) result_fifo(
    .clk,.reset,.clear(flush),.in_valid(tree_valid),.in_ready(tree_ready),.in_data(fp_next),
    .out_valid(result_valid),.out_ready(run_enable&&g_fp_ready),.out_data(fp_out),.empty(result_empty),.occupancy());
  assign g_fp=fp_out;
  assign g_fp_valid=result_valid&&run_enable&&!kv_mode;

  always_ff @(posedge clk)begin
    if(reset||clear)begin
      state_q<=IDLE;cfg_q<='0;completion_q<='0;reported_q<=0;
      rr_q<=0;kv_valid_q<=0;kv_q<='0;
      group_q<=0;fp_sent_q<=0;kv_dispatched_q<=0;kv_sent_q<=0;
      for(int c=0;c<8;c++)begin received_q[c]<=0;kv_dequeued_q[c]<=0;end
    end else if(cmd_fire)begin
      cfg_q<=cmd;state_q<=config_legal?RUN:FAULT;reported_q<=0;
      completion_q<='0;completion_q.collective_id<=cmd.collective_id;
      completion_q.status<=config_legal?COL_OK:COL_BAD_CONFIG;
      rr_q<=0;kv_valid_q<=0;group_q<=0;fp_sent_q<=0;kv_dispatched_q<=0;kv_sent_q<=0;
      for(int c=0;c<8;c++)begin received_q[c]<=0;kv_dequeued_q[c]<=0;end
    end else begin
      if(done_valid&&done_ready)begin
        if(state_q==DONE)state_q<=IDLE;
        else reported_q<=1;
      end
      if(run_enable)begin
        for(int c=0;c<8;c++)begin
          if((kv_valid[c]&&kv_ready[c])||(fp_valid[c]&&fp_ready[c]))received_q[c]<=received_q[c]+1'b1;
        end
        if(g_kv_valid&&g_kv_ready)begin kv_valid_q<=0;kv_sent_q<=kv_sent_q+1'b1;end
        if(kv_load)begin
          kv_q<=kv_next;kv_valid_q<=1;rr_q<=chosen+3'd1;
          kv_dequeued_q[chosen]<=kv_dequeued_q[chosen]+1'b1;
          kv_dispatched_q<=kv_dispatched_q+1'b1;
        end
        if(tree_in_valid&&tree_in_ready)group_q<=group_q+1'b1;
        if(g_fp_valid&&g_fp_ready)fp_sent_q<=fp_sent_q+1'b1;
        if(all_received&&(&kv_empty)&&(&fp_empty)&&tree_empty&&result_empty&&!kv_valid_q&&
          (kv_mode?kv_sent_q==8*expected_count:fp_sent_q==expected_count))state_q<=DONE;
      end
      if(state_q==RUN&&(cancel||(|bad)))begin
        state_q<=FAULT;reported_q<=0;kv_valid_q<=0;
        completion_q.status<=cancel?COL_CANCELLED:COL_BAD_PACKET;
        for(int c=7;c>=0;c--)if(bad[c])begin
          completion_q.error_core<=3'(c);completion_q.error_sequence<=received_q[c];
        end
      end
    end
  end
endmodule
