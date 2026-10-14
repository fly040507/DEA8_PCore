`timescale 1ns/1ps
import pcore_pkg::*;
module tb_dynamic_local_loader;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0;
  logic cmd_valid=0,cmd_ready,desc_valid,desc_ready=0,data_valid,data_ready=0;
  local_load_cmd_t cmd='0;a_slot_desc_t desc,consumed;
  a3_beat_t data;local_read_t rd;
  logic rd_valid,rd_ready,out_valid,out_ready,empty,protocol_error,consumed_valid;
  local_response_t out_response;
  dea8_local_a_loader dut(.*);
  local_response_t replies[0:1],held;
  int wptr=0,rptr=0,count=0,cycle=0,cases=0,requests=0,beats=0,tiles=0,negative_checks=0;
  int request_before_desc=0,backpressure=0,cmd_peak=0;
  int expected_desc=0,expected_tile=0,expected_group=0,rows=0,source_seq=0,version=0;
  bit run=0,allow_error=0,was_held=0,force_bad=0;
  local_response_t bad='0;
  job_token_t token=0;
  function automatic logic [ROW_BITS-1:0] value_ref(input int tile,row);
    logic [DATA_BITS-1:0] d;
    for(int k=0;k<TILE;k++)d[k*INT_BITS+:INT_BITS]=8'(tile*29+row*17+k*11+version);
    return {d,8'(127+(tile+row)%8)};
  endfunction
  always_comb begin
    rd_ready=!reset&&!clear&&!force_bad&&count<2;
    out_valid=force_bad||count!=0;out_response=bad;
    if(!force_bad&&count!=0)out_response=replies[rptr];
  end
  always @(negedge clk)if(run)begin
    desc_ready=cycle%9!=2&&cycle%9!=3;
    data_ready=cycle%7!=1&&cycle%7!=2&&cycle%7!=3;
  end
  always @(posedge clk)begin
    local_response_t reply;int row;
    cycle++;
    if(reset||clear)begin wptr<=0;rptr<=0;count<=0;was_held=0;end
    else begin
      // Only directed fault injection may corrupt a previously held source beat.
      if(was_held&&!force_bad&&out_response!==held)$fatal(1,"Loader source model violated holding");
      if(dut.count>cmd_peak)cmd_peak=dut.count;
      if(desc_valid&&desc_ready)begin
        if(desc.token!==token||desc.occurrence_seq!==SEQ_BITS'(expected_desc)||
          desc.first_tile!==SEQ_BITS'(expected_desc)||desc.m_rows!==ROW_COUNT_BITS'(rows))
          $fatal(1,"Loader descriptor ordering");
        expected_desc++;
      end
      if(data_valid&&data_ready)begin
        if(data.token!==token||data.work_seq!==SEQ_BITS'(version)||
          data.occurrence_seq!==SEQ_BITS'(expected_tile)||data.group_idx!==A_GROUP_BITS'(expected_group)||
          data.row_valid!==a_group_mask(rows,expected_group))$fatal(1,"Loader destination identity");
        for(int i=0;i<A_INPUT_ROWS;i++)if(data.row_valid[i])
          if(data.row[i]!==value_ref(expected_tile,expected_group*A_INPUT_ROWS+i))$fatal(1,"Loader row data/scale");
        if(consumed_valid!==((expected_group+1)*A_INPUT_ROWS>=rows))$fatal(1,"Loader completion not tied to final accepted reply");
        if(consumed_valid)begin
          if(consumed.occurrence_seq!==SEQ_BITS'(expected_tile))$fatal(1,"Loader completion descriptor");
          expected_tile++;expected_group=0;tiles++;
        end else expected_group++;
        beats++;
      end else if(consumed_valid)$fatal(1,"Loader premature consumed fence");
      // NBA keeps the source reply stable for every receiver on this edge.
      if(!force_bad&&out_valid&&out_ready)rptr<=(rptr+1)%2;
      case({rd_valid&&rd_ready,!force_bad&&out_valid&&out_ready})
        2'b10:count<=count+1;
        2'b01:count<=count-1;
        default:;
      endcase
      if(rd_valid&&rd_ready)begin
        if(rd.token!==token||rd.request_seq!==SEQ_BITS'(source_seq)||rd.content_version!==16'(version))
          $fatal(1,"Loader request identity/serial");
        reply='0;reply.request=rd;reply.mask=a_group_mask(rows,rd.group_idx);
        for(int i=0;i<A_INPUT_ROWS;i++)if(reply.mask[i])begin
          row=int'(rd.group_idx)*A_INPUT_ROWS+i;reply.entry[i]=value_ref(rd.tile,row);
        end
        replies[wptr]<=reply;wptr<=(wptr+1)%2;requests++;
        if(!desc_ready)request_before_desc++;
        if((int'(rd.group_idx)+1)*A_INPUT_ROWS>=rows)source_seq++;
      end
      if(out_valid&&!out_ready)backpressure++;
      was_held=out_valid&&!out_ready&&!force_bad;held=out_response;
    end
    #1;if(protocol_error&&!allow_error)$fatal(1,"Local loader unexpected fault");
  end
  task automatic flush;
    @(negedge clk);clear=1;cmd_valid=0;run=0;desc_ready=0;data_ready=0;force_bad=0;
    @(negedge clk);clear=0;expected_desc=0;expected_tile=0;expected_group=0;source_seq=0;
    repeat(2)@(negedge clk);if(!empty||protocol_error||desc_valid||data_valid||rd_valid)$fatal(1,"Local loader clear");
  endtask
  task automatic command(input int tile);
    local_load_cmd_t c;
    c='0;c.destination.token=token;c.destination.work_seq=SEQ_BITS'(version);
    c.destination.occurrence_seq=SEQ_BITS'(tile);c.destination.first_tile=SEQ_BITS'(tile);
    c.destination.m_rows=ROW_COUNT_BITS'(rows);c.destination.uses=1;
    c.kind=LOCAL_Q;c.content_version=16'(version);c.tile=TILE_BITS'(tile);
    @(negedge clk);cmd=c;cmd_valid=1;do @(posedge clk);while(!cmd_ready);
    @(negedge clk);cmd_valid=0;
  endtask
  task automatic valid_case(input int m);
    rows=m;version=cases+1;token=32'h88770000+32'(version);
    // First prefetch is allowed before destination storage is granted.
    command(0);command(1);repeat(5)@(negedge clk);
    if(data_valid||consumed_valid||dut.count!=2||count==0)$fatal(1,"Loader bypassed destination reservation");
    run=1;
    for(int t=2;t<12;t++)command(t);
    while(!empty||count!=0)@(negedge clk);
    if(expected_tile!=12||expected_desc!=12)$fatal(1,"Loader lost wrapped descriptors");
    cases++;flush();
  endtask
  task automatic wrong_reply(input bit stale);
    local_read_t old_request;
    rows=3;version=100+negative_checks;token=32'h99110000+32'(version);
    command(0);while(count==0)@(negedge clk);old_request=replies[rptr].request;
    if(stale)begin
      flush();version++;token++;command(0);while(count==0)@(negedge clk);
    end
    @(negedge clk);bad=replies[rptr];bad.request=old_request;
    if(!stale)bad.request.request_seq++;
    allow_error=1;force_bad=1;desc_ready=1;data_ready=1;
    @(posedge clk);if(data_valid||out_ready||consumed_valid)$fatal(1,"Loader accepted wrong or stale reply");
    #1;if(!protocol_error)$fatal(1,"Loader did not report wrong/stale identity");
    negative_checks++;flush();allow_error=0;
  endtask
  initial begin
    repeat(32)@(negedge clk);reset=0;
    valid_case(1);valid_case(11);valid_case(51);
    wrong_reply(0);wrong_reply(1);
    if(cmd_peak!=2||request_before_desc==0||backpressure==0)$fatal(1,"Loader coverage incomplete");
    $display("tb_dynamic_local_loader PASS cases=%0d tiles=%0d requests=%0d beats=%0d command_peak=%0d prefetch_before_grant=%0d reply_backpressure=%0d negative_checks=%0d",cases,tiles,requests,beats,cmd_peak,request_before_desc,backpressure,negative_checks);
    $finish;
  end
  initial begin #100000;$fatal(1,"Local loader watchdog");end
endmodule
