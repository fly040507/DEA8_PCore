`timescale 1ns/1ps
module tb_gcore_gamma_fetch;
  import gcore_pkg::*;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0,start_valid=0,start_ready,request_valid,request_ready=0;
  gamma_fetch_t start='0,request;
  logic data_valid=0,data_ready,release_valid,release_ready,load_valid,load_ready;
  gamma_beat_t data='0;gamma_load_t load;
  logic loaded_valid,loaded_ready,done_valid,done_ready=0,busy,protocol_error,loading;
  gcore_status_e loaded_status,status;logic [15:0] loaded_id;
  gcore_context_t context_data='0;
  logic allow_load=1,found,slot,read_enable=0,read_slot=0;
  logic [15:0] lookup_id=0;
  logic [9:0] read_index=0;logic [31:0] read_data;
  int checks=0,cycle=0,words=0;
  dea8_gcore_gamma_fetch dut(.*);
  dea8_gcore_gamma cache(
    .clk,.reset,.clear,.allow_load,.context_valid(1'b1),.context_data,
    .release_valid,.release_ready,.loading,.load_valid,.load_ready,.load,
    .done_valid(loaded_valid),.done_ready(loaded_ready),.status(loaded_status),.loaded_id,
    .lookup_id,.found,.slot,.read_enable,.read_slot,.read_index,.read_data
  );
  always @(negedge clk)begin cycle++;allow_load=cycle%7!=0;end
  always @(posedge clk)if(load_valid&&load_ready)words++;
  task automatic launch(input bit final_group,input int id0=10,id1=11);
    gamma_fetch_t held;
    @(negedge clk);start='0;start.context_id=9;start.generation=2;start.token=32'h20040;
    start.layer_id=final_group?18:2;start.final_group=final_group;start.param0=16'(id0);start.param1=16'(id1);
    start_valid=1;do @(posedge clk);while(!start_ready);@(negedge clk);start_valid=0;
    wait(request_valid);held=request;
    repeat(4)begin @(negedge clk);if(!request_valid||request!==held)$fatal(1,"fetch request not held");end
    request_ready=1;do @(posedge clk);while(!request_valid);@(negedge clk);request_ready=0;
  endtask
  task automatic beat(input int i,input bit last_word,input logic [31:0] value=32'h3f800000,input bit bad_token=0);
    @(negedge clk);data.token=start.token+int'(bad_token);data.value=value;data.last=last_word;data_valid=1;
    do @(posedge clk);while(!data_ready);@(negedge clk);data_valid=0;
  endtask
  task automatic retire(input gcore_status_e expected);
    wait(done_valid);@(negedge clk);
    if(status!=expected||protocol_error!=(expected!=GC_OK))$fatal(1,"fetch result actual=%0d expected=%0d",status,expected);
    repeat(4)begin @(negedge clk);if(!done_valid||status!=expected)$fatal(1,"fetch completion not held");end
    done_ready=1;@(negedge clk);done_ready=0;checks++;
  endtask
  task automatic flush;
    @(negedge clk);clear=1;data_valid=0;@(negedge clk);clear=0;
    if(done_valid||busy||protocol_error||loading)$fatal(1,"fetch clear did not drain state");
  endtask
  task automatic read_word(input int id,index_value,input logic [31:0] expected);
    @(negedge clk);lookup_id=16'(id);#0.1;
    if(!found)$fatal(1,"complete gamma missing id=%0d",id);
    read_slot=slot;read_index=10'(index_value);read_enable=1;
    @(negedge clk);read_enable=0;if(read_data!==expected)$fatal(1,"gamma RAM mismatch");checks++;
  endtask
  initial begin
    context_data.context_id=9;context_data.generation=2;
    repeat(5)@(negedge clk);reset=0;
    launch(0);
    lookup_id=10;
    for(int i=0;i<2*HIDDEN;i++)begin
      beat(i,i==2*HIDDEN-1,32'h3f800000+32'(i));
      if(i<HIDDEN-1&&found)$fatal(1,"partial gamma published");
    end
    retire(GC_OK);read_word(10,0,32'h3f800000);read_word(11,1023,32'h3f8007ff);
    launch(1,20,21);lookup_id=11;#0.1;if(found)$fatal(1,"release retained old slot");
    for(int i=0;i<HIDDEN;i++)beat(i,i==HIDDEN-1,32'h40000000+32'(i));
    retire(GC_OK);read_word(20,1023,32'h400003ff);
    launch(0,30,31);beat(0,0,32'h3f800000,1);retire(GC_SOURCE_PROTOCOL);flush();
    launch(0,40,41);beat(0,1);retire(GC_SOURCE_PROTOCOL);flush();
    launch(0,50,51);beat(0,0,32'h7fc00000);retire(GC_NUMERIC_FAULT);flush();
    launch(0,60,60);
    for(int i=0;i<HIDDEN;i++)beat(i,0);
    beat(HIDDEN,0);retire(GC_SOURCE_PROTOCOL);flush();
    launch(0,70,71);for(int i=0;i<17;i++)beat(i,0);flush();
    lookup_id=70;#0.1;if(found)$fatal(1,"cancelled partial parameter survived");checks++;
    launch(1,80,81);for(int i=0;i<HIDDEN;i++)beat(i,i==HIDDEN-1);
    retire(GC_OK);read_word(80,16,32'h3f800000);
    if(checks!=12)$fatal(1,"gamma fetch coverage count=%0d",checks);
    $display("tb_gcore_gamma_fetch PASS pair=1 final=1 bad_token=1 bad_last=1 nan=1 duplicate_id=1 cancel_restart=1 checks=%0d words=%0d",checks,words);$finish;
  end
  initial begin #1000000;$fatal(1,"gamma fetch watchdog state=%0d",dut.state);end
endmodule
