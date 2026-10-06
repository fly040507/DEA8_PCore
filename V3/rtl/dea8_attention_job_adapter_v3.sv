import pcore3_pkg::*;
module dea8_attention_job_adapter_v3 (
  input logic clk,reset,clear,
  input logic op_valid,output logic op_ready,input pcore_job_t op_job,
  output logic done_valid,input logic done_ready,output pcore_completion_t done,output logic error,
  output matrix_service_req_t matrix_req,input matrix_service_rsp_t matrix_rsp,
  input logic q_complete,input qoz_region_req_t q_region,
  output logic q_release,input logic q_release_ready,
  output logic q_rd_valid,input logic q_rd_ready,output logic [5:0] q_rd_tile,
  output logic [PAIR_BITS-1:0] q_rd_pair,output logic [TILE_BITS-1:0] q_rd_transport,
  input logic q_out_valid,output logic q_out_ready,input a2_t q_entry,
  input logic p_valid,output logic p_ready,input a2_t p_entry,
  input logic [5:0] p_block,input logic [EPOCH_BITS-1:0] p_epoch,input logic [2:0] p_head,
  output logic vpu_valid,input logic vpu_ready,output vpu_cmd_t vpu_cmd,
  input logic vpu_done_valid,output logic vpu_done_ready,input vpu_cmd_t vpu_done,
  output logic sfu_valid,input logic sfu_ready,output sfu_cmd_t sfu_cmd,
  input logic sfu_done_valid,output logic sfu_done_ready,input sfu_cmd_t sfu_done,
  input logic rd_valid,output logic rd_ready,input acc_sel_e rd_sel,input logic [9:0] rd_addr,
  output logic rd_data_valid,output logic [15:0][31:0] even_data,odd_data,
  input logic wr_valid,output logic wr_ready,input acc_write_t wr
);
  typedef enum logic [2:0] {IDLE,WAIT_Q,START,RUN,RELEASE_Q,COMPLETE} state_t;
  state_t state_q;job_header_t header_q;
  logic start_ready,busy,attention_done;
  logic mv,mr,mdv,mdr,tail_ready;matrix_cmd_t mc,md;
  logic ae,be;logic [3:0] qt;
  assign op_ready=state_q==IDLE&&!reset&&!clear;
  assign done_valid=state_q==COMPLETE;assign done='{header:header_q,status:JOB_OK};
  assign q_release=state_q==RELEASE_Q;
  assign q_rd_tile={2'b0,qt};
  dea8_attention_scheduler_v4 scheduler(.clk,.reset,.clear,
    .start_valid(state_q==START),.start_ready,.busy,.start_head(header_q.head),.start_epoch(header_q.epoch),
    .done_valid(attention_done),.done_ready(1'b1),.matrix_valid(mv),.matrix_ready(mr),.matrix_cmd(mc),
    .tail_launch_ready(tail_ready),.matrix_done_valid(mdv),.matrix_done_ready(mdr),.matrix_done(md),
    .vpu_valid,.vpu_ready,.vpu_cmd,.vpu_done_valid,.vpu_done_ready,.vpu_done,
    .sfu_valid,.sfu_ready,.sfu_cmd,.sfu_done_valid,.sfu_done_ready,.sfu_done);
  dea8_attention_matrix_v3 #(.EXTERNAL_MATRIX(1),.EXTERNAL_QOZ(1)) frontend(
    .clk,.reset,.clear,.service_req(matrix_req),.service_rsp(matrix_rsp),
    .cmd_valid(mv),.cmd_ready(mr),.cmd(mc),.tail_launch_ready(tail_ready),.done_valid(mdv),.done_ready(mdr),.done_cmd(md),
    .qoz_load_valid(1'b0),.qoz_load_ready(),.qoz_load_entry('0),.qoz_load_epoch('0),.qoz_load_head('0),
    .replay_load_valid(p_valid),.replay_load_ready(p_ready),.replay_load_entry(p_entry),
    .replay_load_epoch(p_epoch),.replay_load_head(p_head),.replay_load_block(p_block),
    .qoz_ext_load_ready(1'b0),.qoz_ext_rd_valid(q_rd_valid),.qoz_ext_rd_ready(q_rd_ready),
    .qoz_ext_rd_tile(qt),.qoz_ext_rd_pair(q_rd_pair),.qoz_ext_rd_transport(q_rd_transport),
    .qoz_ext_out_valid(q_out_valid),.qoz_ext_out_ready(q_out_ready),.qoz_ext_out_entry(q_entry),
    .qoz_ext_complete(q_complete),.qoz_ext_epoch(q_region.header.epoch),.qoz_ext_head(q_region.header.head),.qoz_ext_owner(q_region.owner),
    .hbm_valid(1'b0),.hbm_ready(),.hbm_entry('0),.kv_valid(1'b0),.kv_ready(),.kv_entry('0),.b_source(B_KVB),
    .a_protocol_error(ae),.b_protocol_error(be),.result_rd_owner(ACC_READ_RESULT),
    .result_rd_valid(rd_valid),.result_rd_ready(rd_ready),.result_rd_sel(rd_sel),.result_rd_addr(rd_addr),
    .result_rd_data_valid(rd_data_valid),.result_even_data(even_data),.result_odd_data(odd_data),
    .vpu_wr_valid(wr_valid),.vpu_wr_ready(wr_ready),.vpu_wr(wr),
    .dbg_valid(1'b0),.dbg_sel(ACC_OACC),.dbg_parity(1'b0),.dbg_addr('0),.dbg_lane('0),.dbg_data());
  always_ff @(posedge clk)begin
    if(reset||clear)begin state_q<=IDLE;header_q<='0;error<=0;end
    else begin
      if(op_valid&&op_ready)begin header_q<=op_job.header;state_q<=WAIT_Q;end
      if(state_q==WAIT_Q&&q_complete)begin
        if(q_region.owner!=QOZ_Q||q_region.tiles!=16||q_region.header.epoch!=header_q.epoch||q_region.header.head!=header_q.head)error<=1;
        else state_q<=START;
      end
      if(state_q==START&&start_ready)state_q<=RUN;
      if(state_q==RUN&&attention_done)state_q<=RELEASE_Q;
      if(q_release&&q_release_ready)state_q<=COMPLETE;
      if(done_valid&&done_ready)state_q<=IDLE;
      if(ae||be)error<=1;
    end
  end
endmodule
