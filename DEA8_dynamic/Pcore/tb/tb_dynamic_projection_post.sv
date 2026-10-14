`timescale 1ns/1ps
import pcore_pkg::*;
// Protocol/component test: capture fixtures replace the upstream ACC reader.
// Full matrix arithmetic and RoPE values are checked in tb_dynamic_q_projection.
module tb_dynamic_projection_post;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,start_valid=0,start_ready;
  pcore_job_t context_job='0;job_token_t context_token=32'h12340055;
  logic [ROW_COUNT_BITS-1:0] context_rows=3;
  logic capture_cmd_valid=0,capture_cmd_ready,capture_valid=0,capture_ready;
  capture_desc_t capture_cmd='0;pair_capture_t capture='0;
  logic acquire_valid,acquire_ready,store_valid,store_ready,store_complete;
  local_object_t acquire_object;local_write_t store_write;
  logic unit_cmd_valid,unit_cmd_ready=0,unit_armed_valid=0,unit_armed_ready,unit_go_valid,unit_go_ready=0;
  unit_cmd_t unit_cmd,current;
  job_token_t unit_armed_token=0,unit_go_token,unit_done_token=0;
  logic unit_rd_valid=0,unit_rd_ready,unit_out_valid,unit_out_ready=0;
  pair_read_t unit_rd='0;pair_reply_t unit_out_reply;
  logic unit_wr_valid=0,unit_wr_ready,unit_done_valid=0,unit_done_ready,unit_done_error=0;
  local_write_t unit_wr='0;unit_function_e unit_done_function=UNIT_ROPE_QUANT;
  logic profile_pending=0,unit_running,done,protocol_error;
  job_token_t active_unit_token;
  logic unit_quant_valid=0,unit_quant_ready,kv_quant_valid,kv_quant_ready=0,kv_output_done=0;
  kv_quant_t unit_quant='0,kv_quant;
  dea8_projection_post dut(.*);
  logic memory_error,memory_active,memory_bound,memory_empty;
  dea8_quant_store #(.QOZ(1)) memory(.clk,.reset,.clear,
    .acquire_valid,.acquire_ready,.acquire_set(1'b0),.acquire_object,.producer_token(context_token),
    .bind_valid(1'b0),.bind_ready(),.bind_set(1'b0),.bind_object(local_object_t'('0)),.consumer_token(TOKEN_BITS'('0)),
    .release_valid(1'b0),.release_ready(),.release_request(local_release_t'('0)),
    .wr_valid(store_valid),.wr_ready(store_ready),.wr(store_write),
    .rd_valid(1'b0),.rd_ready(),.rd(local_read_t'('0)),.out_valid(),.out_ready(1'b0),.out_response(),
    .active(memory_active),.complete(store_complete),.bound(memory_bound),.protocol_error(memory_error),.empty(memory_empty));
  int commands=0,replies=0,writes=0,negative_checks=0,cycle=0;
  bit allow_error=0;
  function automatic logic [31:0] fp_fixture(input int nt,row,n);
    return 32'h3f800000+32'(nt*4096+row*128+n);
  endfunction
  always @(posedge clk)begin
    cycle++;
    if(store_valid&&store_ready)writes++;
    #1;if(memory_error||(!allow_error&&protocol_error))
      $fatal(1,"Projection post unexpected fault memory=%b post=%b pair=%b capture_valid=%b ready=%b owner=%h cmd=%h rows=%0d pair_object=%h pair_idx=%0d mask=%b written0=%h",memory_error,protocol_error,dut.pair_error,capture_valid,capture_ready,capture.owner,capture_cmd,context_rows,dut.pair_object,capture.pair_idx,capture.mask,dut.pair_buffer.written[0]);
  end
  task automatic flush;
    @(negedge clk);clear=1;start_valid=0;capture_cmd_valid=0;capture_valid=0;
    unit_cmd_ready=0;unit_armed_valid=0;unit_go_ready=0;unit_rd_valid=0;unit_out_ready=0;unit_wr_valid=0;unit_done_valid=0;
    @(negedge clk);clear=0;repeat(2)@(negedge clk);
    if(protocol_error||done||!memory_empty||dut.pair_active)$fatal(1,"Projection post flush");
  endtask
  task automatic begin_job;
    context_job='0;context_job.op=OP_Q_PROJ;context_job.output_version=9;
    context_job.profile_id=7;context_job.profile_version=8;
    @(negedge clk);start_valid=1;@(posedge clk);if(!start_ready)$fatal(1,"Post start refused");
    @(negedge clk);start_valid=0;
    while(!memory_active)@(negedge clk);
  endtask
  task automatic capture_pair(input int seq);
    capture_desc_t d;pair_capture_t c;
    for(int h=0;h<2;h++)begin
      d={context_token,SEQ_BITS'(seq*2+h),(h?ACC_FACC_B:ACC_FACC_A),
        context_rows,TILE_BITS'(seq+h*8),6'(seq),1'(h)};
      @(negedge clk);capture_cmd=d;capture_cmd_valid=1;
      do @(posedge clk);while(!capture_cmd_ready);
      @(negedge clk);capture_cmd_valid=0;
      for(int p=0;p<pairs_for_rows(context_rows);p++)begin
        c='0;c.owner=d;c.pair_idx=PAIR_BITS'(p);c.mask=row_mask_for_rows(context_rows,p);
        for(int r=0;r<ROW_LANES;r++)for(int n=0;n<TILE;n++)c.data[r][n]=fp_fixture(d.nt,p*ROW_LANES+r,n);
        capture=c;capture_valid=1;do @(posedge clk);while(!capture_ready);@(negedge clk);
      end
      capture_valid=0;
    end
    while(!unit_cmd_valid)@(negedge clk);current=unit_cmd;
    repeat(3)begin @(negedge clk);if(unit_cmd!==current||!unit_cmd_valid)$fatal(1,"Post command hold");end
    unit_cmd_ready=1;@(posedge clk);@(negedge clk);unit_cmd_ready=0;commands++;
  endtask
  task automatic go;
    @(negedge clk);unit_armed_token=current.token;unit_armed_valid=1;
    @(posedge clk);if(!unit_armed_ready)$fatal(1,"Post armed refused");
    @(negedge clk);unit_armed_valid=0;unit_go_ready=1;
    do @(posedge clk);while(!unit_go_valid);
    if(unit_go_token!=current.token)$fatal(1,"Post go token");
    @(negedge clk);unit_go_ready=0;
  endtask
  task automatic read_rows;
    pair_reply_t held;
    // Fill two credits before consuming either reply.
    for(int r=0;r<2;r++)begin
      unit_rd.token=current.token;unit_rd.row=ROW_COUNT_BITS'(r);unit_rd_valid=1;
      do @(posedge clk);while(!unit_rd_ready);@(negedge clk);unit_rd_valid=0;
    end
    while(!unit_out_valid)@(negedge clk);held=unit_out_reply;
    repeat(4)begin @(negedge clk);if(!unit_out_valid||unit_out_reply!==held)$fatal(1,"Pair reply hold");end
    unit_out_ready=1;
    for(int r=0;r<2;r++)begin
      do @(posedge clk);while(!unit_out_valid);
      if(unit_out_reply.request.row!=r||unit_out_reply.request.token!=current.token)$fatal(1,"Pair reply ordering");
      for(int h=0;h<2;h++)for(int n=0;n<TILE;n++)
        if(unit_out_reply.data[h][n]!==fp_fixture(h?current.nt1:current.nt0,r,n))$fatal(1,"Pair data fixture");
      replies++;@(negedge clk);
    end
    unit_out_ready=0;unit_rd.row=2;unit_rd_valid=1;
    do @(posedge clk);while(!unit_rd_ready);@(negedge clk);unit_rd_valid=0;unit_out_ready=1;
    do @(posedge clk);while(!unit_out_valid);
    if(unit_out_reply.request.row!=2)$fatal(1,"Pair tail row");replies++;
    @(negedge clk);unit_out_ready=0;
  endtask
  task automatic write_rows;
    local_write_t w;
    for(int h=0;h<2;h++)for(int r=0;r<int'(context_rows);r++)begin
      w='0;w.token=current.token;w.kind=LOCAL_Q;w.content_version=context_job.output_version;
      w.tile=h?current.nt1:current.nt0;w.row[0]=ROW_COUNT_BITS'(r);w.mask=1;
      w.entry[0].scale=130;w.entry[0].data=DATA_BITS'(int'(w.tile)+r+1);
      unit_wr=w;unit_wr_valid=1;do @(posedge clk);while(!unit_wr_ready);@(negedge clk);unit_wr_valid=0;
    end
  endtask
  task automatic negative(input int which);
    int before_writes;
    flush();begin_job();capture_pair(0);before_writes=writes;allow_error=1;
    if(which==5)begin unit_armed_token=current.token+1;unit_armed_valid=1;end
    else if(which==6)begin unit_rd.token=current.token;unit_rd.row=0;unit_rd_valid=1;end
    else begin
      go();
      case(which)
        0:begin unit_done_token=current.token;unit_done_valid=1;end
        1,2,3:begin
          unit_wr='0;unit_wr.token=current.token+(which==1?1:0);unit_wr.kind=LOCAL_Q;
          unit_wr.content_version=context_job.output_version+(which==2?1:0);
          unit_wr.tile=current.nt0;unit_wr.mask=1;unit_wr.row[0]=which==3?context_rows:0;unit_wr_valid=1;
        end
        4:begin
          unit_rd.token=current.token;unit_rd.row=0;unit_rd_valid=1;
          @(posedge clk);if(!unit_rd_ready)$fatal(1,"Negative read fixture");
          @(negedge clk); // Repeat the already accepted row, without consuming its reply.
        end
      endcase
    end
    @(posedge clk);if(store_valid||unit_wr_ready)$fatal(1,"Illegal post write reached memory");
    #1;if(!protocol_error||writes!=before_writes||done||store_complete)$fatal(1,"Post rejection failed which=%0d",which);
    for(int t=0;t<16;t++)if(memory.written[0][t]!=0)$fatal(1,"Rejected post had RAM validity side effects");
    negative_checks++;flush();allow_error=0;
  endtask
  initial begin
    repeat(32)@(negedge clk);reset=0;begin_job();
    for(int seq=0;seq<8;seq++)begin
      capture_pair(seq);go();read_rows();write_rows();unit_done_token=current.token;unit_done_valid=1;
      @(posedge clk);if(!unit_done_ready)$fatal(1,"Post done refused");@(negedge clk);unit_done_valid=0;
      while(dut.pair_active)@(negedge clk);
    end
    if(!done||!store_complete||writes!=48||replies!=24)$fatal(1,"Post region completion fences");
    for(int n=0;n<7;n++)negative(n);
    $display("tb_dynamic_projection_post PASS completed_region=1 Q_pairs=8 replies=%0d writes=%0d negative_checks=%0d two_reply_credits=1 command_hold=1 no_rejected_RAM_write=1",replies,writes,negative_checks);$finish;
  end
  initial begin #100000;$fatal(1,"Projection post watchdog");end
endmodule
