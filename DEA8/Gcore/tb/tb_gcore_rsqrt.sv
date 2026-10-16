`timescale 1ns/1ps
module tb_gcore_rsqrt;
  import gcore_pkg::*;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,in_valid=0,in_ready,out_valid,out_ready=0,empty,protocol_error;
  rsqrt_packet_t request='0,response;
  logic [63:0] vectors[8192];
  rsqrt_packet_t expected[$];
  int cycle=0,checked=0,accepted=0,stall_cycles=0,ulp_max=0;
  bit held=0;
  rsqrt_packet_t held_response;
  dea8_gcore_rsqrt #(.CHANNELS(1)) dut(.*);
  always @(negedge clk) begin
    cycle++;
    out_ready=cycle%53>35;
  end
  always @(posedge clk) if(!reset&&!clear) begin
    if(held&&(!out_valid||response!==held_response))$fatal(1,"rsqrt response changed under backpressure");
    held=out_valid&&!out_ready;held_response=response;
    if(held)stall_cycles++;
    if(out_valid&&out_ready) begin
      rsqrt_packet_t e;
      if(expected.size()==0)$fatal(1,"unsolicited rsqrt response");
      e=expected.pop_front();
      if({response.token,response.row0,response.row1,response.mask}!=={e.token,e.row0,e.row1,e.mask})
        $fatal(1,"rsqrt response metadata mismatch");
      for(int lane=0;lane<2;lane++) begin
        int unsigned actual,gold,distance;
        actual=response.data[32*lane+:32];gold=e.data[32*lane+:32];
        distance=actual>gold?actual-gold:gold-actual;
        if(!e.mask[lane]) begin if(actual!=0)$fatal(1,"invalid rsqrt lane not zero");end
        else begin
          if(actual[31]||actual[30:23]==8'hff||actual==0||distance>1)
            $fatal(1,"rsqrt numerical error checked=%0d lane=%0d got=%h expected=%h ulp=%0d",checked,lane,actual,gold,distance);
          if(distance>ulp_max)ulp_max=distance;
        end
      end
      checked++;
    end
    if(in_valid&&in_ready) begin
      rsqrt_packet_t e;
      e=request;
      e.data={32'b0,vectors[accepted%8192][31:0]};
      expected.push_back(e);accepted++;
    end
  end
  initial begin
    $readmemh("tb/data/rsqrt.mem",vectors);
    repeat(30)@(negedge clk);reset=0;
    for(int p=0;p<8192;p++)begin
      @(negedge clk);
      request='0;request.token=32'(p+1);request.row0=6'(p%51);request.row1=request.row0+1'b1;
      request.mask=2'b01;
      request.data={32'b0,vectors[p][63:32]};in_valid=1;
      do @(posedge clk);while(!in_ready);
      @(negedge clk);in_valid=0;
    end
    wait(checked==8192);@(negedge clk);
    if(protocol_error||expected.size()!=0||!empty||stall_cycles==0)$fatal(1,"rsqrt coverage/state error");
    // Cancel a request before it can retire, then prove no stale output leaks.
    request='0;request.token=32'hdeadbeef;request.row1=1;request.mask=1;request.data={32'b0,32'h3f800000};
    in_valid=1;do @(posedge clk);while(!in_ready);
    @(negedge clk);in_valid=0;clear=1;expected.delete();held=0;
    repeat(2)@(negedge clk);clear=0;
    repeat(80)begin @(negedge clk);if(out_valid)$fatal(1,"rsqrt stale response after clear");end
    if(!empty||protocol_error)$fatal(1,"rsqrt flush did not empty pipeline");
    $display("tb_gcore_rsqrt PASS rows=8192 channels=1 positive_fp32_edges=1 subnormals=1 max_ulp=%0d stall_cycles=%0d flush=1",ulp_max,stall_cycles);
    $finish;
  end
  initial begin #5000000;$fatal(1,"rsqrt watchdog");end
endmodule
