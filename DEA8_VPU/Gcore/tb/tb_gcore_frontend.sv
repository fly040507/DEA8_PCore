`timescale 1ns/1ps
module tb_gcore_frontend;
  import gcore_pkg::*;
  import dea8_tile_link_pkg::*;
  logic clk=0;always #2 clk=~clk;
  logic reset=1,clear=0;
  logic q_valid=0,q_ready,q_out,q_accept=0,q_fault;
  logic [15:0][31:0] values=0;
  logic [VECTOR_ADDR_BITS-1:0] index=0,out_index;
  logic [135:0] result;
  logic [648:0] vectors[256];
  int sent=0,checked=0,cycle=0,held_cycles=0;
  bit held=0,check_quant=1;
  logic [135:0] held_result;
  logic [VECTOR_ADDR_BITS-1:0] held_index;
  dea8_gcore_quant8 quantizer(.clk,.reset,.clear,.in_valid(q_valid),.in_ready(q_ready),.values,.index,
    .out_valid(q_out),.out_ready(q_accept),.result,.out_index,.numeric_fault(q_fault));
  logic allow_load=1,context_valid=1,load_valid=0,load_ready,done_valid,done_ready=1,found,slot;
  gcore_context_t context_data;
  gamma_load_t load;
  gcore_status_e status;
  logic [15:0] loaded_id,lookup_id=16'h10;
  logic read_enable=0,read_slot=0;
  logic [GAMMA_INDEX_BITS-1:0] read_index=0;
  logic [31:0] read_data;
  logic release_valid=0,release_ready,loading;
  dea8_gcore_gamma gamma_store(.*);
  always @(negedge clk)begin cycle++;q_accept=cycle%23>7;end
  always @(posedge clk)if(!reset&&!clear&&check_quant)begin
    if(held&&(!q_out||result!==held_result||out_index!==held_index))$fatal(1,"quant8 changed while stalled");
    held=q_out&&!q_accept;held_result=result;held_index=out_index;
    if(held)held_cycles++;
    if(q_valid&&q_ready)sent++;
    if(q_out&&q_accept)begin
      if(out_index!=checked||result!==vectors[checked][135:0])$fatal(1,"quant8 numerical/order mismatch index=%0d",checked);
      checked++;
    end
  end
  task automatic gamma_word(input int n,input bit last_word,input logic [31:0] value);
    @(negedge clk);load.index=10'(n);load.last=last_word;load.value=value;load_valid=1;
    do @(posedge clk);while(!load_ready);@(negedge clk);load_valid=0;
  endtask
  initial begin
    context_data='0;context_data.context_id=3;context_data.generation=4;load='0;
    load.context_id=3;load.generation=4;load.param_id=16'h10;
    $readmemh("tb/data/quantize.mem",vectors);
    repeat(5)@(negedge clk);reset=0;
    for(int n=0;n<256;n++)begin
      @(negedge clk);values=vectors[n][648:137];index=VECTOR_ADDR_BITS'(n);q_valid=1;
      do @(posedge clk);while(!q_ready);@(negedge clk);q_valid=0;
    end
    wait(checked==256);@(negedge clk);
    if(sent!=256||held_cycles==0)$fatal(1,"quant8 coverage");
    check_quant=0;values=0;values[7]=32'h7f800000;q_valid=1;
    do @(posedge clk);while(!q_ready);@(negedge clk);q_valid=0;
    if(!q_fault)$fatal(1,"quant8 lost nonfinite fault");
    clear=1;@(negedge clk);clear=0;
    if(q_out||q_fault)$fatal(1,"quant8 clear");
    // An incomplete parameter set must never be visible to NORM.
    gamma_word(0,0,32'h3f800000);
    if(found)$fatal(1,"partial gamma published");
    allow_load=0;load_valid=1;
    repeat(5)begin @(negedge clk);if(load_ready)$fatal(1,"gamma changed during compute");end
    load_valid=0;allow_load=1;
    for(int n=1;n<HIDDEN;n++)gamma_word(n,n==HIDDEN-1,32'h3f800000+32'(n));
    if(!found||slot!=0||!done_valid||status!=GC_OK)$fatal(1,"gamma publication");
    @(negedge clk);read_enable=1;read_index=10'd913;
    @(negedge clk);read_enable=0;
    if(read_data!==32'h3f800000+913)$fatal(1,"gamma RAM read");
    // Duplicate identity, nonfinite values and discontinuous loads are errors.
    load.slot=1;gamma_word(0,0,32'h3f800000);
    if(!done_valid||status!=GC_SOURCE_PROTOCOL)$fatal(1,"duplicate gamma id");
    @(negedge clk);load.param_id=16'h11;gamma_word(0,0,32'h7fc00000);
    if(!done_valid||status!=GC_NUMERIC_FAULT)$fatal(1,"gamma numeric validation");
    @(negedge clk);gamma_word(0,0,32'h3f800000);gamma_word(2,0,32'h3f800000);
    if(!done_valid||status!=GC_SOURCE_PROTOCOL)$fatal(1,"gamma sequence validation");
    clear=1;@(negedge clk);clear=0;
    if(found||done_valid)$fatal(1,"gamma flush");
    $display("tb_gcore_frontend PASS quant8=256 held_cycles=%0d gamma_full=1024 partial=1 duplicate=1 nan=1 sequence=1 flush=1",held_cycles);$finish;
  end
  initial begin #200000;$fatal(1,"frontend watchdog");end
endmodule
