// Independent row frontend and background OACC producer. Both use the SAME
// sixteen multipliers. Tokens distinguish foreground and scale generations.
module dea8_vpu_top(
 input logic clk,reset,clear,flush_valid,output logic vpu_flush_ack,
 input logic vector_valid,output logic vector_ready,input pcore_control_pkg::control_command_t vector_cmd,
 output logic vector_done_valid,input logic vector_done_ready,output pcore_control_pkg::control_unit_done_t vector_done,
 input logic vector_data_valid,output logic vector_data_ready,input pcore_control_pkg::control_fp_data_t vector_data,
 output logic vector_result_valid,input logic vector_result_ready,output pcore_control_pkg::control_quant_result_t vector_result,
 output logic vector_mem_valid,input logic vector_mem_ready,output pcore_control_pkg::control_memory_req_t vector_mem_req,
 input logic vector_mem_out_valid,output logic vector_mem_out_ready,input pcore_control_pkg::control_memory_rsp_t vector_mem_out,
 output logic acc_rd_valid,input logic acc_rd_ready,output pcore_pkg::acc_sel_e acc_rd_sel,output logic [9:0] acc_rd_addr,
 output pcore_control_pkg::control_token_t acc_token,
 input logic acc_data_valid,output logic acc_data_ready,input logic [15:0][31:0] acc_even,acc_odd,
 output logic acc_wr_valid,input logic acc_wr_ready,output pcore_pkg::acc_write_t acc_wr,
 output logic rope_req_valid,input logic rope_req_ready,output pcore_control_pkg::control_rope_req_t rope_req,
 input logic rope_out_valid,output logic rope_out_ready,input pcore_control_pkg::control_rope_rsp_t rope_out,
 input logic mask_config_valid,input logic [15:0] mask_state,mask_action,
 input logic guest_mode,input logic [4:0] guest_mul_valid,input logic [4:0][31:0] guest_mul_a,guest_mul_b,
 output logic [4:0] guest_mul_out_valid,output logic [4:0][31:0] guest_mul_y,
 input logic [3:0] guest_add_valid,input logic [3:0][31:0] guest_add_a,guest_add_b,
 output logic guest_add_ready,output logic [3:0] guest_add_out_valid,output logic [3:0][31:0] guest_add_y,
 output pcore_pkg::vector_ram_port_t ram_a,ram_b,input logic [511:0] ram_data
);
 import pcore_pkg::*;import pcore_control_pkg::*;import dea8_vpu_math_pkg::*;
 localparam int ML=dea8_compute_config_pkg::FP_MUL_LATENCY+2;
 control_command_t scale_cmd;
 logic scale_busy,scale_done,scale_error;
 logic [2:0] stat_issued,stat_received;
 logic [31:0] alpha[51];
 logic [9:0] reads,mul_issued,writes;
 logic fg_ready,fg_done_valid,fg_done_ready,fg_mv,fg_mr,fg_mout_ready;
 control_unit_done_t fg_done;
 control_memory_req_t fg_mreq;
 logic fg_rd,fg_rr,fg_data_ready,fg_wr,fg_wr_ready;
 acc_sel_e fg_sel;logic [9:0] fg_addr;control_token_t fg_token;acc_write_t fg_write;
 logic fg_mul_valid,fg_mul_ready,mul_ready,mul_valid,mul_out;
 pair_fp_t fg_a,fg_b,mul_a,mul_b,mul_y;
 logic [1:0] mul_error;
 logic [ML-1:0] mul_bg;
 logic [9:0] mul_address[ML];
 logic [7:0] response_kind;
 logic [3:0] response_count;
 logic scale_write_valid;
 acc_write_t scale_write;
 wire is_scale=vector_cmd.function_id==VECTOR_OACC_SCALE;
 wire bg_mem=scale_busy&&stat_issued<4;
 wire mem_bg_response=vector_mem_out.token==scale_cmd.token&&scale_busy;
 wire bg_read=scale_busy&&stat_received==4&&reads<416&&reads-writes<12;
 wire response_bg=response_kind[0];
 wire bg_mul=acc_data_valid&&response_bg;
 wire take_bg=bg_mul&&mul_ready&&!fg_mul_valid;
 wire read_fire=acc_rd_valid&&acc_rd_ready;
 wire response_fire=acc_data_valid&&acc_data_ready;
 wire write_fire=acc_wr_valid&&acc_wr_ready;
 assign vector_ready=is_scale?!scale_busy&&!scale_done:fg_ready;
 assign vector_done_valid=fg_done_valid||scale_done;
 assign vector_done=fg_done_valid?fg_done:control_unit_done_t'('{command:scale_cmd,error:scale_error});
 assign fg_done_ready=vector_done_ready&&fg_done_valid;
 assign vector_mem_valid=fg_mv||bg_mem;
 always_comb begin
   vector_mem_req=fg_mreq;
   if(!fg_mv)begin
     vector_mem_req='0;vector_mem_req.token=scale_cmd.token;vector_mem_req.buffer_id=WORK_ALPHA;
     vector_mem_req.bank=scale_cmd.tile[0];vector_mem_req.index=6'(stat_issued*16);
   end
 end
 assign fg_mr=vector_mem_ready&&fg_mv;
 assign vector_mem_out_ready=mem_bg_response?1'b1:fg_mout_ready;
 assign acc_rd_valid=(fg_rd||bg_read)&&response_count<8&&!scale_write_valid;
 assign fg_rr=acc_rd_ready&&fg_rd&&response_count<8&&!scale_write_valid;
 assign acc_rd_sel=fg_rd?fg_sel:ACC_OACC;
 assign acc_rd_addr=fg_rd?fg_addr:reads;
 assign acc_token=scale_write_valid?scale_cmd.token:((fg_rd||fg_wr)?fg_token:scale_cmd.token);
 assign acc_data_ready=response_bg?mul_ready&&!fg_mul_valid:fg_data_ready;
 assign fg_mul_ready=mul_ready;
 assign mul_valid=fg_mul_valid||bg_mul;
 assign mul_a=fg_mul_valid?fg_a:{acc_odd,acc_even};
 always_comb begin
   mul_b=fg_b;
   if(!fg_mul_valid)for(int r=0;r<2;r++)for(int lane=0;lane<16;lane++)
     mul_b[r][lane]=(2*(mul_issued%26)+r<51)?alpha[2*(mul_issued%26)+r]:32'b0;
 end
 assign acc_wr_valid=fg_wr||scale_write_valid;
 assign acc_wr=fg_wr?fg_write:scale_write;
 assign fg_wr_ready=acc_wr_ready&&fg_wr;
 dea8_vpu_pair_mul16 #(.SHARED_GELU(1)) shared_mul(.clk,.reset,.clear(clear||flush_valid),
   .in_valid(mul_valid),.in_ready(mul_ready),.out_valid(mul_out),.a(mul_a),.b(mul_b),.y(mul_y),.error(mul_error),
   .guest_mode(foreground.cmd.function_id==VECTOR_GU_POST&&!scale_busy),.guest_valid(guest_mul_valid),.guest_a(guest_mul_a),.guest_b(guest_mul_b),
   .guest_out_valid(guest_mul_out_valid),.guest_y(guest_mul_y));
 // Foreground exports the old state only as passive TB diagnostics.
 control_command_t cmd;
 logic [5:0] state;
 assign cmd=foreground.cmd;assign state=foreground.state;
 dea8_vpu_foreground foreground(.clk,.reset,.clear,.flush_valid,.vpu_flush_ack,
   .ram_a,.ram_b,.ram_data,
   .vector_valid(vector_valid&&!is_scale),.vector_ready(fg_ready),.vector_cmd,
   .vector_done_valid(fg_done_valid),.vector_done_ready(fg_done_ready),.vector_done(fg_done),
   .vector_data_valid,.vector_data_ready,.vector_data,.vector_result_valid,.vector_result_ready,.vector_result,
   .vector_mem_valid(fg_mv),.vector_mem_ready(fg_mr),.vector_mem_req(fg_mreq),
   .vector_mem_out_valid(vector_mem_out_valid&&!mem_bg_response),.vector_mem_out_ready(fg_mout_ready),.vector_mem_out,
   .acc_rd_valid(fg_rd),.acc_rd_ready(fg_rr),.acc_rd_sel(fg_sel),.acc_rd_addr(fg_addr),.acc_token(fg_token),
   .acc_data_valid(acc_data_valid&&!response_bg),.acc_data_ready(fg_data_ready),.acc_even,.acc_odd,
   .acc_wr_valid(fg_wr),.acc_wr_ready(fg_wr_ready),.acc_wr(fg_write),
   .rope_req_valid,.rope_req_ready,.rope_req,.rope_out_valid,.rope_out_ready,.rope_out,
   .mask_config_valid,.mask_state,.mask_action,.guest_mode,.guest_mul_valid,.guest_mul_a,.guest_mul_b,
   .guest_mul_out_valid(),.guest_mul_y(),.guest_add_valid,.guest_add_a,.guest_add_b,.guest_add_ready,.guest_add_out_valid,.guest_add_y,
   .fabric_in_valid(fg_mul_valid),.fabric_ready(fg_mul_ready),.fabric_out_valid(mul_out&&!mul_bg[ML-1]),
   .fabric_a(fg_a),.fabric_b(fg_b),.fabric_y(mul_y),.fabric_error(mul_error));
 always_ff @(posedge clk)begin
   if(reset||clear||flush_valid)begin
     scale_busy<=0;scale_done<=0;stat_issued<=0;stat_received<=0;reads<=0;writes<=0;mul_issued<=0;
     mul_bg<=0;scale_write_valid<=0;response_count<=0;response_kind<=0;scale_error<=0;
   end else begin
     if(vector_valid&&vector_ready&&is_scale)begin
       scale_cmd<=vector_cmd;scale_busy<=1;scale_done<=0;stat_issued<=0;stat_received<=0;
       reads<=0;writes<=0;mul_issued<=0;scale_error<=0;
     end
     if(scale_done&&vector_done_ready&&!fg_done_valid)scale_done<=0;
     if(vector_mem_valid&&vector_mem_ready&&!fg_mv)stat_issued<=stat_issued+1'b1;
     if(vector_mem_out_valid&&vector_mem_out_ready&&mem_bg_response)begin
       for(int lane=0;lane<16;lane++)if(stat_received*16+lane<51)
         alpha[stat_received*16+lane]<=vector_mem_out.data[lane];
       stat_received<=stat_received+1'b1;
     end
     if(read_fire&&!fg_rd)reads<=reads+1'b1;
     case({read_fire,response_fire})
       2'b10:response_count<=response_count+1'b1;
       2'b01:response_count<=response_count-1'b1;
       default:;
     endcase
     if(response_fire)response_kind<=response_kind>>1;
     if(read_fire)response_kind[response_count-4'(response_fire)]<=!fg_rd;
     mul_bg<={mul_bg[ML-2:0],take_bg};
     mul_address[0]<=mul_issued;
     for(int i=1;i<ML;i++)mul_address[i]<=mul_address[i-1];
     if(take_bg)mul_issued<=mul_issued+1'b1;
     if(write_fire&&!fg_wr)begin
       scale_write_valid<=0;writes<=writes+1'b1;
       if(writes==415)begin scale_busy<=0;scale_done<=1;end
     end
     if(mul_out&&mul_bg[ML-1])begin
       scale_write_valid<=1;scale_write.sel<=ACC_OACC;scale_write.addr<=mul_address[ML-1];
       scale_write.row_valid<=row_mask(mul_address[ML-1]%26);scale_write.data<=mul_y;
       if(|mul_error)scale_error<=1;
     end
   end
 end
 // synthesis translate_off
 always @(posedge clk)if(!reset&&!clear&&!flush_valid)begin
   if(scale_write_valid&&!acc_wr_ready)$fatal(1,"OACC scale write unexpectedly blocked address=%0d writes=%0d tile=%0d token=%h",scale_write.addr,writes,scale_cmd.tile,acc_token);
   if(response_count>8)$fatal(1,"VPU ACC tag credit overflow");
 end
 // synthesis translate_on
endmodule
