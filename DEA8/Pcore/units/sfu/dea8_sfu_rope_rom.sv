import pcore_pkg::*;
import pcore_control_pkg::*;

// Sixteen coefficient pairs per synchronous ROM read. The CPU image packer
// converts the portable four-pair image before synthesis; Vivado cannot use
// an initial-block copy from another $readmemh-initialized array as ROM data.
module dea8_sfu_rope_rom #(
  parameter int POSITION_BASE=816,POSITION_COUNT=51,
  parameter ROM_FILE="units/rom/rope_wide.mem",RAM_STYLE="block"
)(
  input logic clk,reset,flush,output logic flush_ack,
  input logic req_valid,output logic req_ready,input logic [$bits(control_rope_req_t)-1:0] req,
  output logic rsp_valid,input logic rsp_ready,output logic [$bits(control_rope_rsp_t)-1:0] rsp,
  output logic protocol_error
);
  localparam int DEPTH=POSITION_COUNT*8,AW=$clog2(DEPTH);
  (* ram_style=RAM_STYLE *) logic [1023:0] coefficients[DEPTH];
  logic [1023:0] rom_data;
  logic pending,held;
  control_rope_req_t request,read_request;
  control_rope_rsp_t answer;
  wire legal=request.position>=POSITION_BASE&&int'(request.position)<POSITION_BASE+POSITION_COUNT&&
    request.frequency_base<=112&&request.frequency_base[3:0]==0&&request.row<ROWS;
  wire take=req_valid&&req_ready;
  assign request=req;
  assign req_ready=!reset&&!flush&&!protocol_error&&!pending&&(!held||rsp_ready)&&legal;
  assign rsp_valid=held&&!reset&&!flush;
  assign rsp=answer;
  assign flush_ack=flush&&!reset;
  initial $readmemh(ROM_FILE,coefficients);
  always_ff @(posedge clk)if(take)
    rom_data<=coefficients[AW'((int'(request.position)-POSITION_BASE)*8+request.frequency_base/16)];
  always_ff @(posedge clk)begin
    if(reset||flush)begin pending<=0;held<=0;protocol_error<=0;read_request<='0;answer<='0;end
    else begin
      pending<=take;
      if(take)read_request<=request;
      if(rsp_valid&&rsp_ready)held<=0;
      if(pending)begin
        held<=1;answer.request<=read_request;
        for(int j=0;j<16;j++)begin
          answer.cosine[j]<=rom_data[64*j+:32];answer.sine[j]<=rom_data[64*j+32+:32];
        end
      end
      if(req_valid&&!legal)protocol_error<=1;
    end
  end
endmodule
