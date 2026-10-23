module dea8_gcore_gamma_fetch (
  input logic clk,reset,clear,
  input logic start_valid,output logic start_ready,input gcore_pkg::gamma_fetch_t start,
  output logic request_valid,input logic request_ready,output gcore_pkg::gamma_fetch_t request,
  input logic data_valid,output logic data_ready,input gcore_pkg::gamma_beat_t data,
  output logic release_valid,input logic release_ready,
  output logic load_valid,input logic load_ready,output gcore_pkg::gamma_load_t load,
  input logic loaded_valid,output logic loaded_ready,
  input gcore_pkg::gcore_status_e loaded_status,input logic [15:0] loaded_id,
  output logic done_valid,input logic done_ready,output gcore_pkg::gcore_status_e status,
  output logic busy,protocol_error
);
  import gcore_pkg::*;
  typedef enum logic [2:0] {IDLE,RELEASE,REQUEST,DATA,WAIT_SLOT,FINISH} state_e;
  state_e state;
  gamma_fetch_t descriptor;
  logic [10:0] index;
  logic beat_legal,last_slot;
  assign busy=state!=IDLE;
  assign start_ready=state==IDLE&&!reset&&!clear&&!protocol_error;
  assign release_valid=state==RELEASE&&!reset&&!clear;
  assign request_valid=state==REQUEST&&!reset&&!clear;
  assign request=descriptor;
  assign last_slot=descriptor.final_group||index[10];
  assign beat_legal=data.token==descriptor.token&&data.last==(last_slot&&index[9:0]==HIDDEN-1);
  assign data_ready=state==DATA&&load_ready&&!reset&&!clear;
  assign load_valid=state==DATA&&data_valid&&beat_legal&&!reset&&!clear;
  always_comb begin
    load='0;load.context_id=descriptor.context_id;load.generation=descriptor.generation;
    load.param_id=index[10]?descriptor.param1:descriptor.param0;
    load.slot=index[10];load.index=index[9:0];load.value=data.value;load.last=index[9:0]==HIDDEN-1;
  end
  assign loaded_ready=state==WAIT_SLOT||state==DATA;
  assign done_valid=state==FINISH;
  always_ff @(posedge clk)begin
    if(reset||clear)begin state<=IDLE;descriptor<='0;index<=0;status<=GC_OK;protocol_error<=0;end
    else begin
      if(start_valid&&start_ready)begin descriptor<=start;index<=0;status<=GC_OK;state<=RELEASE;end
      if(release_valid&&release_ready)state<=REQUEST;
      if(request_valid&&request_ready)state<=DATA;
      if(data_valid&&data_ready)begin
        if(!beat_legal)begin status<=GC_SOURCE_PROTOCOL;protocol_error<=1;state<=FINISH;end
        else if(load.last)state<=WAIT_SLOT;
        else index<=index+1'b1;
      end
      if(loaded_valid&&loaded_ready)begin
        if(state!=WAIT_SLOT||loaded_status!=GC_OK||loaded_id!=load.param_id)begin
          status<=loaded_status==GC_OK?GC_SOURCE_PROTOCOL:loaded_status;protocol_error<=1;state<=FINISH;
        end else if(last_slot)state<=FINISH;
        else begin index<=index+1'b1;state<=DATA;end
      end
      if(done_valid&&done_ready)state<=IDLE;
    end
  end
endmodule
