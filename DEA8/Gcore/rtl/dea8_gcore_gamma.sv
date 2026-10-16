module dea8_gcore_gamma (
  input logic clk,reset,clear,allow_load,context_valid,
  input gcore_pkg::gcore_context_t context_data,
  input logic load_valid,output logic load_ready,input gcore_pkg::gamma_load_t load,
  output logic done_valid,input logic done_ready,
  output gcore_pkg::gcore_status_e status,output logic [15:0] loaded_id,
  input logic [15:0] lookup_id,output logic found,slot,
  input logic read_enable,read_slot,
  input logic [gcore_pkg::GAMMA_INDEX_BITS-1:0] read_index,
  output logic [31:0] read_data
);
  import gcore_pkg::*;
  (* ram_style="block" *) logic [31:0] memory[GAMMA_SLOTS*HIDDEN];
  logic [GAMMA_SLOTS-1:0] valid_q;
  logic [15:0] ids[GAMMA_SLOTS],contexts[GAMMA_SLOTS],generations[GAMMA_SLOTS];
  logic filling,fill_slot;
  logic [GAMMA_INDEX_BITS-1:0] next_index;
  logic [15:0] fill_id;
  logic legal,fire;
  assign load_ready=allow_load&&context_valid&&!done_valid&&!reset&&!clear;
  assign fire=load_valid&&load_ready;
  always_comb begin
    found=0;slot=0;
    for(int i=0;i<GAMMA_SLOTS;i++)if(valid_q[i]&&ids[i]==lookup_id&&
      contexts[i]==context_data.context_id&&generations[i]==context_data.generation)begin found=1;slot=1'(i);end
    legal=load.context_id==context_data.context_id&&load.generation==context_data.generation&&
      load.index==(filling?next_index:0)&&load.last==(load.index==HIDDEN-1)&&
      (!filling||(load.slot==fill_slot&&load.param_id==fill_id))&&gcore_fp_pkg::finite32(load.value);
    for(int i=0;i<GAMMA_SLOTS;i++)if(i!=load.slot&&valid_q[i]&&ids[i]==load.param_id&&
      contexts[i]==load.context_id&&generations[i]==load.generation)legal=0;
  end
  always_ff @(posedge clk)begin
    if(read_enable)read_data<=memory[{read_slot,read_index}];
    if(fire&&legal)memory[{load.slot,load.index}]<=load.value;
    if(reset||clear)begin
      valid_q<=0;filling<=0;fill_slot<=0;next_index<=0;fill_id<=0;
      done_valid<=0;status<=GC_OK;loaded_id<=0;
      for(int i=0;i<GAMMA_SLOTS;i++)begin ids[i]<=0;contexts[i]<=0;generations[i]<=0;end
    end else begin
      if(done_valid&&done_ready)done_valid<=0;
      if(fire)begin
        if(!legal)begin
          if(filling)valid_q[fill_slot]<=0;
          valid_q[load.slot]<=0;filling<=0;done_valid<=1;
          loaded_id<=load.param_id;status<=gcore_fp_pkg::finite32(load.value)?GC_SOURCE_PROTOCOL:GC_NUMERIC_FAULT;
        end else begin
          valid_q[load.slot]<=0;fill_slot<=load.slot;fill_id<=load.param_id;
          next_index<=load.index+1'b1;filling<=!load.last;
          if(load.last)begin
            ids[load.slot]<=load.param_id;contexts[load.slot]<=load.context_id;generations[load.slot]<=load.generation;
            valid_q[load.slot]<=1;done_valid<=1;status<=GC_OK;loaded_id<=load.param_id;
          end
        end
      end
    end
  end
endmodule
