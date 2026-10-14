`timescale 1ns/1ps
import pcore_pkg::*;
// Component fixture only; actual V matrix results are checked by the KV job TB.
module tb_dynamic_v_pair;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,acquire_valid=0,acquire_ready,capture_valid=0,capture_ready;
  pair_object_t acquire_object='0,object_state;
  pair_capture_t capture='0;
  logic bind_valid=0,bind_ready,rd_valid=0,rd_ready,out_valid,out_ready=0;
  job_token_t bind_token=32'h23450001,release_token=32'h23450001;
  pair_read_t rd='0;pair_reply_t out_reply;
  logic release_valid=0,release_ready,active,complete,bound,protocol_error;
  dea8_pair_buffer dut(.*);
  int replies=0,negatives=0;
  bit allow_error=0;
  function automatic logic [31:0] fixture(input int row,col);return 32'h3f800000+32'(row*256+col);endfunction
  always @(posedge clk)begin
    if(out_valid&&out_ready)begin
      int j,row,col;
      j=replies;
      if(out_reply.request.row!=j||out_reply.request.token!=bind_token)$fatal(1,"V response FIFO order/token");
      for(int t=0;t<TILE;t++)for(int h=0;h<ROW_LANES;h++)begin
        row=j/(TILE/ROW_LANES)*TILE+t;col=j%(TILE/ROW_LANES)*ROW_LANES+h;
        if(out_reply.data[h][t]!== (row<ROWS?fixture(row,col):32'd0))$fatal(1,"V bank transpose/padding j=%0d token=%0d h=%0d",j,t,h);
      end
      replies++;
    end
    #1;if(protocol_error&&!allow_error)$fatal(1,"Unexpected V Pair error");
  end
  task automatic flush;
    @(negedge clk);clear=1;capture_valid=0;rd_valid=0;release_valid=0;bind_valid=0;out_ready=0;
    @(negedge clk);clear=0;allow_error=0;replies=0;
    if(active||complete||bound||protocol_error||out_valid)$fatal(1,"V Pair flush state");
  endtask
  task automatic acquire;
    @(negedge clk);acquire_object='0;acquire_object.token=32'h23450099;acquire_object.kind=PAIR_V;
    acquire_object.nt0=1;acquire_object.nt1=1;acquire_object.pair_seq=1;acquire_object.rows=ROWS;acquire_valid=1;
    @(posedge clk);if(!acquire_ready)$fatal(1,"V Pair acquire");@(negedge clk);acquire_valid=0;
  endtask
  task automatic fill;
    for(int p=0;p<PAIRS;p++)begin
      capture='0;capture.owner.token=acquire_object.token;capture.owner.nt=1;
      capture.owner.rows=ROWS;capture.owner.pair_seq=1;capture.pair_idx=PAIR_BITS'(p);
      capture.mask=row_mask_for_rows(ROWS,p);
      for(int r=0;r<ROW_LANES;r++)for(int c=0;c<TILE;c++)capture.data[r][c]=fixture(p*ROW_LANES+r,c);
      capture_valid=1;@(posedge clk);if(!capture_ready)$fatal(1,"V Pair capture");@(negedge clk);
    end
    capture_valid=0;if(!complete)$fatal(1,"V Pair single-half completion");
    bind_valid=1;@(posedge clk);if(!bind_ready)$fatal(1,"V Pair bind");@(negedge clk);bind_valid=0;
  endtask
  initial begin
    pair_reply_t held;
    repeat(32)@(negedge clk);reset=0;acquire();fill();
    for(int j=0;j<2;j++)begin
      rd.token=bind_token;rd.row=ROW_COUNT_BITS'(j);rd_valid=1;
      @(posedge clk);if(!rd_ready)$fatal(1,"V Pair two credits");@(negedge clk);
    end
    rd_valid=0;while(!out_valid)@(negedge clk);held=out_reply;
    rd.row=2;rd_valid=1;
    repeat(5)begin @(posedge clk);if(rd_ready)$fatal(1,"V Pair exceeded two credits");@(negedge clk);
      if(!out_valid||out_reply!==held)$fatal(1,"V Pair response hold");end
    rd_valid=0;release_valid=1;
    repeat(3)begin @(posedge clk);if(release_ready)$fatal(1,"V Pair release before consumption");@(negedge clk);end
    release_valid=0;out_ready=1;
    for(int j=2;j<V_PACKETS_PER_TILE;j++)begin
      rd.row=ROW_COUNT_BITS'(j);rd_valid=1;
      do @(posedge clk);while(!rd_ready);@(negedge clk);
      if(j%7==4)begin rd_valid=0;out_ready=0;repeat(4)@(negedge clk);out_ready=1;end
    end
    rd_valid=0;while(replies<V_PACKETS_PER_TILE)@(negedge clk);out_ready=0;
    release_valid=1;@(posedge clk);if(!release_ready)$fatal(1,"V Pair release drain");@(negedge clk);release_valid=0;
    if(active||out_valid)$fatal(1,"V Pair retained completed refs");
    for(int kind=0;kind<3;kind++)begin
      flush();acquire();
      if(kind==0)begin
        capture='0;capture.owner.token=acquire_object.token;capture.owner.rows=ROWS;
        capture.owner.nt=1;capture.owner.pair_seq=1;capture.owner.half=1;capture.mask=3;
        allow_error=1;capture_valid=1;
        @(posedge clk);if(capture_ready)$fatal(1,"V Pair accepted unused half");@(negedge clk);capture_valid=0;
        if(!protocol_error||dut.written[0]!=0||dut.written[1]!=0)$fatal(1,"V wrong-half changed validity");
      end else begin
        fill();rd.token=kind==1?bind_token+1:bind_token;rd.row=kind==2?V_PACKETS_PER_TILE:0;
        allow_error=1;rd_valid=1;@(posedge clk);if(rd_ready)$fatal(1,"V invalid request accepted");@(negedge clk);rd_valid=0;
        if(!protocol_error||out_valid||dut.refs!=0)$fatal(1,"V invalid request created reference");
      end
      negatives++;
    end
    flush();acquire();fill();rd.token=bind_token;rd.row=0;rd_valid=1;
    @(posedge clk);if(!rd_ready)$fatal(1,"V cancel pending fixture");@(negedge clk);rd_valid=0;
    clear=1;@(negedge clk);clear=0;repeat(3)@(negedge clk);
    if(active||out_valid||dut.refs!=0)$fatal(1,"V clear leaked pending response");
    $display("tb_dynamic_v_pair PASS transpose_replies=32 two_credits=1 response_hold=1 refs_until_consumed=1 masked_tail_rows=13 negative_checks=%0d cancel_pending=1",negatives);
    $finish;
  end
  initial begin #500000;$fatal(1,"V Pair watchdog");end
endmodule
