import pcore_pkg::*;
import pcore_control_pkg::*;
import dea8_tile_link_pkg::*;

// The production boundary: no VPU/SFU/result/ACC/workspace ports leave PCore.
module dea8_pcore_top #(
  parameter logic [2:0] PCORE_ID=0,
  parameter int ROPE_POSITION_BASE=816,
  parameter logic [15:0] ROPE_VERSION=1,MASK_VERSION=1,
  parameter MASK_FILE="units/rom/mask.mem",ROPE_FILE="units/rom/rope_wide.mem"
)(
  input logic clk,reset,clear,
  input logic config_valid,output logic config_ready,configured,
  input logic [15:0] config_context,config_mask_version,config_rope_version,config_position,
  input logic job_valid,output logic job_ready,input control_job_t job,
  output logic done_valid,input logic done_ready,output control_completion_t done,
  output logic busy,protocol_error,flush_done,
  input logic xbc_valid,output logic xbc_ready,input xbc4_t xbc_entry,
  input logic hbm_valid,output logic hbm_ready,input b2_t hbm_entry,
  input logic kv_valid,output logic kv_ready,input b2_t kv_entry,
  output logic tx_valid,input logic tx_ready,output logic [255:0] tx_data,output logic tx_last,
  input logic kv_commit_valid,output logic kv_commit_ready,input tile_commit_t kv_commit,
  output logic gu_prefetch_valid,input logic gu_prefetch_ready,output logic [5:0] gu_prefetch_n,
  input logic rope_load_valid,output logic rope_load_ready,input logic [10:0] rope_load_address,
  input logic [255:0] rope_load_data,input logic rope_load_last,output logic rope_loaded
);
  logic vector_valid,vector_ready,vector_done_valid,vector_done_ready;
  logic function_valid,function_ready,function_done_valid,function_done_ready;
  control_command_t vector_cmd,function_cmd;
  control_unit_done_t vector_done,function_done,function_done_to_control;
  logic vector_data_valid,vector_data_ready,function_data_valid,function_data_ready;
  control_fp_data_t vector_data,function_data,function_result;
  logic function_result_valid,function_result_ready,vector_result_valid,vector_result_ready;
  control_quant_result_t vector_result;
  logic vector_mem_valid,vector_mem_ready,vector_mem_out_valid,vector_mem_out_ready;
  logic function_mem_valid,function_mem_ready,function_mem_out_valid,function_mem_out_ready;
  control_memory_req_t vector_mem_req,function_mem_req;
  control_memory_rsp_t vector_mem_out,function_mem_out;
  logic acc_rd_valid,acc_rd_ready,acc_data_valid,acc_data_ready,acc_wr_valid,acc_wr_ready;
  acc_sel_e acc_rd_sel;logic [9:0] acc_rd_addr;control_token_t acc_token;acc_write_t acc_wr;
  logic [15:0][31:0] acc_even,acc_odd;
  logic rope_req_valid,rope_req_ready,rope_sfu_valid,rope_sfu_ready;
  logic rope_sfu_out_valid,rope_sfu_out_ready,rope_out_valid,rope_out_ready;
  control_rope_req_t rope_req,rope_sfu_req;control_rope_rsp_t rope_sfu_out,rope_out;
  logic flush_valid,vpu_flush_ack,sfu_flush_ack,sfu_error;
  logic [1:0] active_adapter;
  logic qoz_complete;qoz_region_req_t qoz_region;
  logic mask_configured,mask_config_error,mask_error,mask_query_ready,mask_result_valid,mask_config_ready;
  logic [15:0] mask_context,mask_version,mask_position,state_mask,action_mask;
  logic vpu_vector_valid,vpu_vector_ready,mask_query_valid;
  logic inner_ready,inner_done_valid,inner_busy,inner_error,rejected;
  control_completion_t inner_done,reject_done;
  logic config_identity;
  logic [2:0] flush_guard;
  logic guest_mode,guest_add_ready;
  logic [3:0] guest_add_valid,guest_add_out_valid;
  logic [3:0][31:0] guest_add_a,guest_add_b,guest_add_y;
  logic [4:0] guest_mul_valid,guest_mul_out_valid;
  logic [4:0][31:0] guest_mul_a,guest_mul_b,guest_mul_y;
  vector_ram_port_t vpu_ram_a,vpu_ram_b;logic [511:0] vpu_ram_data;
  wire qk_command=vector_cmd.function_id==VECTOR_QK_POST;
  wire job_context_good=configured&&job.data_context==mask_context&&job.position_base==mask_position;
  assign configured=mask_configured&&config_identity&&!mask_config_error&&rope_loaded;
  assign config_ready=mask_config_ready&&!busy;
  assign job_ready=!rejected&&(job_context_good?inner_ready:(!inner_busy&&!reset&&!clear));
  assign done_valid=rejected||inner_done_valid;
  assign done=rejected?reject_done:inner_done;
  assign busy=inner_busy||rejected;
  assign protocol_error=inner_error||mask_error||sfu_error;
  assign flush_done=&flush_guard&&!flush_valid&&!clear&&!busy&&!reset;
  always_ff @(posedge clk)begin
    if(reset||clear)flush_guard<=0;else flush_guard<={flush_guard[1:0],1'b1};
  end
  always_ff @(posedge clk)begin
    if(reset)begin rejected<=0;config_identity<=0;reject_done<='0;end
    else begin
      if(clear)rejected<=0;
      if(config_valid&&config_ready)config_identity<=
        config_position==ROPE_POSITION_BASE&&config_rope_version==ROPE_VERSION&&config_mask_version==MASK_VERSION;
      if(job_valid&&job_ready&&!job_context_good)begin
        rejected<=1;reject_done<='{job:job,status:CONTROL_CONTEXT_ERROR};
      end
      if(rejected&&done_ready)rejected<=0;
    end
  end
  dea8_mask_context #(.MASK_FILE(MASK_FILE)) mask_context_store(.clk,.reset,.flush(flush_valid||clear),
    .config_valid(config_valid&&!busy),.config_ready(mask_config_ready),.config_context,.config_version(config_mask_version),
    .config_position,.configured(mask_configured),.config_error(mask_config_error),
    .context_id(mask_context),.version(mask_version),.position_base(mask_position),
    .query_valid(mask_query_valid),.query_ready(mask_query_ready),.block_id(vector_cmd.tile),
    .result_valid(mask_result_valid),.result_ready(vector_valid&&vector_ready&&qk_command),
    .state_mask,.action_mask,.protocol_error(mask_error));
  assign mask_query_valid=vector_valid&&qk_command&&!mask_result_valid;
  assign vector_ready=vpu_vector_ready&&(!qk_command||mask_result_valid);
  assign vpu_vector_valid=vector_valid&&(!qk_command||mask_result_valid);
  always_comb begin function_done_to_control=function_done;
    function_done_to_control.error|=sfu_error||mask_error;end
  dea8_pcore_control #(.PCORE_ID(PCORE_ID)) control(
    .vpu_ram_a,.vpu_ram_b,.vpu_ram_data,
    .clk,.reset,.clear,.job_valid(job_valid&&job_context_good&&!rejected),.job_ready(inner_ready),.job,
    .done_valid(inner_done_valid),.done_ready(done_ready&&!rejected),.done(inner_done),
    .busy(inner_busy),.protocol_error(inner_error),.active_adapter,
    .flush_valid,.vpu_flush_ack,.sfu_flush_ack,
    .xbc_valid,.xbc_ready,.xbc_entry,.hbm_valid,.hbm_ready,.hbm_entry,.kv_valid,.kv_ready,.kv_entry,
    .vector_valid,.vector_ready,.vector_cmd,.vector_done_valid,.vector_done_ready,.vector_done,
    .function_valid,.function_ready,.function_cmd,.function_done_valid(function_done_valid||sfu_error||mask_error),
    .function_done_ready,.function_done(function_done_to_control),
    .vector_data_valid,.vector_data_ready,.vector_data,.function_data_valid,.function_data_ready,.function_data,
    .function_result_valid,.function_result_ready,.function_result,.vector_result_valid,.vector_result_ready,.vector_result,
    .vector_mem_valid,.vector_mem_ready,.vector_mem_req,.vector_mem_out_valid,.vector_mem_out_ready,.vector_mem_out,
    .function_mem_valid,.function_mem_ready,.function_mem_req,.function_mem_out_valid,.function_mem_out_ready,.function_mem_out,
    .rope_req_valid,.rope_req_ready,.rope_req,.rope_sfu_valid,.rope_sfu_ready,.rope_sfu_req,
    .rope_sfu_out_valid,.rope_sfu_out_ready,.rope_sfu_out,.rope_out_valid,.rope_out_ready,.rope_out,
    .tx_valid,.tx_ready,.tx_data,.tx_last,.kv_commit_valid,.kv_commit_ready,.kv_commit,
    .acc_rd_valid,.acc_rd_ready,.acc_rd_sel,.acc_rd_addr,.acc_token,
    .acc_data_valid,.acc_data_ready,.acc_even,.acc_odd,.acc_wr_valid,.acc_wr_ready,.acc_wr,
    .qoz_complete,.qoz_region,.ext_qoz_region_valid(1'b0),.ext_qoz_region_ready(),.ext_qoz_region('0),
    .ext_qoz_context('0),.ext_qoz_wr_valid(1'b0),.ext_qoz_wr_ready(),.ext_qoz_wr('0),
    .gu_prefetch_valid,.gu_prefetch_ready,.gu_prefetch_n);
  dea8_vpu_top vpu(.clk,.reset,.clear,.flush_valid,.vpu_flush_ack,
    .ram_a(vpu_ram_a),.ram_b(vpu_ram_b),.ram_data(vpu_ram_data),
    .vector_valid(vpu_vector_valid),.vector_ready(vpu_vector_ready),.vector_cmd,
    .vector_done_valid,.vector_done_ready,.vector_done,.vector_data_valid,.vector_data_ready,.vector_data,
    .vector_result_valid,.vector_result_ready,.vector_result,.vector_mem_valid,.vector_mem_ready,.vector_mem_req,
    .vector_mem_out_valid,.vector_mem_out_ready,.vector_mem_out,
    .acc_rd_valid,.acc_rd_ready,.acc_rd_sel,.acc_rd_addr,.acc_token,.acc_data_valid,.acc_data_ready,.acc_even,.acc_odd,
    .acc_wr_valid,.acc_wr_ready,.acc_wr,.rope_req_valid,.rope_req_ready,.rope_req,.rope_out_valid,.rope_out_ready,.rope_out,
    .mask_config_valid(mask_result_valid),.mask_state(state_mask),.mask_action(action_mask),
    .guest_mode,.guest_add_valid,.guest_add_a,.guest_add_b,.guest_add_ready,.guest_add_out_valid,.guest_add_y,
    .guest_mul_valid,.guest_mul_a,.guest_mul_b,.guest_mul_out_valid,.guest_mul_y);
  dea8_sfu_top #(.EXTERNAL_ARITHMETIC(1),.ROPE_POSITION_BASE(ROPE_POSITION_BASE),.ROPE_FILE(ROPE_FILE)) sfu(
    .rope_load_valid,.rope_load_ready,.rope_load_address,.rope_load_data,.rope_load_last,.rope_loaded,
    .clk,.reset,.flush(flush_valid||clear),.flush_ack(sfu_flush_ack),
    .function_valid,.function_ready,.function_cmd,.function_done_valid,.function_done_ready,.function_done,
    .function_data_valid,.function_data_ready,.function_data,.function_result_valid,.function_result_ready,.function_result,
    .function_mem_valid,.function_mem_ready,.function_mem_req,.function_mem_out_valid,.function_mem_out_ready,.function_mem_out,
    .rope_valid(rope_sfu_valid),.rope_ready(rope_sfu_ready),.rope_req(rope_sfu_req),
    .rope_out_valid(rope_sfu_out_valid),.rope_out_ready(rope_sfu_out_ready),.rope_out(rope_sfu_out),.protocol_error(sfu_error),
    .guest_mode,.add_valid(guest_add_valid),.add_a(guest_add_a),.add_b(guest_add_b),.add_ready(guest_add_ready),
    .add_out_valid(guest_add_out_valid),.add_y(guest_add_y),
    .mul_valid(guest_mul_valid),.mul_a(guest_mul_a),.mul_b(guest_mul_b),.mul_out_valid(guest_mul_out_valid),.mul_y(guest_mul_y));
endmodule
