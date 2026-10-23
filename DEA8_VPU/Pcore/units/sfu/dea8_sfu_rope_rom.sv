import pcore_pkg::*;
import pcore_control_pkg::*;

// Four real URAMs. Preload writes four 64-bit slices; inference uses BOTH
// ports for reads, producing sixteen FP32 coefficients per cycle. No BRAM ROM
// or synthesizable initialization copy is retained behind the preload port.
module dea8_sfu_rope_rom #(
 parameter int POSITION_BASE=816,POSITION_COUNT=51,
 parameter ROM_FILE="units/rom/rope_wide.mem",RAM_STYLE="ultra"
)(
 input logic clk,reset,flush,output logic flush_ack,
 input logic req_valid,output logic req_ready,input logic [$bits(control_rope_req_t)-1:0] req,
 output logic rsp_valid,input logic rsp_ready,output logic [$bits(control_rope_rsp_t)-1:0] rsp,
 output logic protocol_error,
 input logic load_valid,output logic load_ready,input logic [10:0] load_address,
 input logic [255:0] load_data,input logic load_last,output logic loaded
);
 control_rope_req_t request,request_q;
 control_rope_rsp_t answer;
 logic pending_sin,held;
 logic [2:0] read_valid,read_sin;
 logic [11:0] vector_address_q;
 logic [3:0][63:0] low,high;
 logic [10:0] load_count;
 assign request=req;
 wire legal=request.position>=POSITION_BASE&&int'(request.position)<POSITION_BASE+POSITION_COUNT&&
   request.frequency_base<=112&&request.frequency_base[3:0]==0&&request.row<ROWS;
 wire inference_idle=!pending_sin&&!(|read_valid)&&!held;
 assign req_ready=loaded&&!reset&&!flush&&!protocol_error&&inference_idle&&legal;
 wire take=req_valid&&req_ready;
 wire read_enable=take||pending_sin;
 wire [11:0] vector_address=take?12'((int'(request.position)-POSITION_BASE)*16+request.frequency_base/8):vector_address_q+12'd1;
 assign load_ready=!reset&&!loaded&&inference_idle;
 wire load_take=load_valid&&load_ready;
 wire good_load=load_address==load_count&&load_address<POSITION_COUNT*32&&load_last==(load_address==POSITION_COUNT*32-1);
 for(genvar bank=0;bank<4;bank++)begin: coefficient_banks
   xpm_memory_tdpram #(.ADDR_WIDTH_A(12),.ADDR_WIDTH_B(12),.AUTO_SLEEP_TIME(0),
     .BYTE_WRITE_WIDTH_A(64),.BYTE_WRITE_WIDTH_B(64),.CLOCKING_MODE("common_clock"),
     .MEMORY_PRIMITIVE("ultra"),.MEMORY_SIZE(4096*64),.READ_DATA_WIDTH_A(64),.READ_DATA_WIDTH_B(64),
     .WRITE_DATA_WIDTH_A(64),.WRITE_DATA_WIDTH_B(64),.READ_LATENCY_A(3),.READ_LATENCY_B(3),
     .WRITE_MODE_A("no_change"),.WRITE_MODE_B("no_change"),.USE_MEM_INIT(0),.SIM_ASSERT_CHK(1)) memory(
     .clka(clk),.clkb(clk),.ena(load_take||read_enable),.enb(read_enable),
     .wea(load_take&&good_load),.web(1'b0),.addra(load_take?{1'b0,load_address}:12'(vector_address*2)),
     .addrb(12'(vector_address*2+1)),.dina(load_data[64*bank+:64]),.dinb(64'b0),.douta(low[bank]),.doutb(high[bank]),
     .rsta(1'b0),.rstb(1'b0),.regcea(1'b1),.regceb(1'b1),.sleep(1'b0),
     .injectsbiterra(1'b0),.injectdbiterra(1'b0),.injectsbiterrb(1'b0),.injectdbiterrb(1'b0),
     .sbiterra(),.dbiterra(),.sbiterrb(),.dbiterrb());
 end
 assign rsp_valid=held&&!reset&&!flush;assign rsp=answer;assign flush_ack=flush&&!reset;
 always_ff @(posedge clk)begin
   if(reset)begin loaded<=0;load_count<=0;end
   else if(load_take&&good_load)begin
     load_count<=load_count+1'b1;
     if(load_last)loaded<=1;
   end
   if(reset||flush)begin pending_sin<=0;held<=0;read_valid<=0;read_sin<=0;protocol_error<=0;end
   else begin
     pending_sin<=take;read_valid<={read_valid[1:0],read_enable};read_sin<={read_sin[1:0],pending_sin};
     if(take)begin request_q<=request;vector_address_q<=vector_address;end
     if(rsp_valid&&rsp_ready)held<=0;
     if(read_valid[2])begin
       for(int bank=0;bank<4;bank++)begin
         if(read_sin[2])begin
           answer.sine[2*bank+:2]<=low[bank];answer.sine[8+2*bank+:2]<=high[bank];
         end else begin
           answer.cosine[2*bank+:2]<=low[bank];answer.cosine[8+2*bank+:2]<=high[bank];
         end
       end
       if(read_sin[2])begin held<=1;answer.request<=request_q;end
     end
     if((req_valid&&!legal)||(load_take&&!good_load))protocol_error<=1;
   end
 end
endmodule
