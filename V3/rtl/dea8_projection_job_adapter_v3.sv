import pcore3_pkg::*;
module dea8_projection_job_adapter_v3(
  input logic clk,reset,clear,
  input logic op_valid,output logic op_ready,input pcore_job_t op_job,
  output logic done_valid,input logic done_ready,output pcore_completion_t done,
  output logic error,
  output matrix_service_req_t matrix_req,input matrix_service_rsp_t matrix_rsp,
  output logic region_valid,input logic region_ready,output qoz_region_req_t region,
  input logic region_complete,
  output logic post_valid,input logic post_ready,output pcore_post_job_t post_job,
  input logic post_done_valid,output logic post_done_ready,input pcore_post_job_t post_done,
  output logic data_valid,input logic data_ready,output post_data_t data_out,
  input logic z_commit,input logic [5:0] z_n
);
  typedef enum logic [2:0] {IDLE,ACQUIRE,START,RUN,COMPLETE} state_t;
  state_t state_q;job_header_t header_q;
  logic proj_done,proj_busy,qvalid,qready,ae,be;
  logic [3:0] qt;logic [PAIR_BITS-1:0] qp;logic [1:0] qr;
  logic [15:0][31:0] qe,qo;
  logic [4:0] post_n_q;logic post_sent_q,z_seen_q;
  assign op_ready=state_q==IDLE&&!reset&&!clear;
  assign done_valid=state_q==COMPLETE;assign done='{header:header_q,status:JOB_OK};
  assign region_valid=state_q==ACQUIRE;assign region='{header:header_q,owner:QOZ_Q,tiles:6'd16};
  assign post_valid=state_q==RUN&&qvalid&&!post_sent_q&&post_n_q<16;
  assign post_job='{header:header_q,op:POST_PROJ_QUANT,n:6'(post_n_q)};
  assign post_done_ready=state_q==RUN&&post_sent_q;
  assign data_valid=qvalid&&post_sent_q;assign qready=data_ready&&post_sent_q;
  assign data_out='{header:header_q,n:6'(qt),row:6'(qp),row_valid:qr,last:qp==PAIRS-1,first:qe,second:qo};
  dea8_projection_v3 #(.EXTERNAL_MATRIX(1)) projection(
    .clk,.reset,.clear,.service_req(matrix_req),.service_rsp(matrix_rsp),
    .start(state_q==START),.job_epoch(header_q.epoch),.job_head(header_q.head),.job_exp_fold('0),
    .busy(proj_busy),.done(proj_done),.xbc_valid(1'b0),.xbc_ready(),.xbc_entry('0),.hbm_valid(1'b0),.hbm_ready(),.hbm_entry('0),
    .qoz_wr_valid(qvalid),.qoz_wr_ready(qready),.qoz_wr_tile(qt),.qoz_wr_pair(qp),.qoz_wr_row_valid(qr),
    .qoz_wr_even_fp32(qe),.qoz_wr_odd_fp32(qo),.matrix_a_protocol_error(ae),.matrix_b_protocol_error(be));
  always_ff @(posedge clk)begin
    if(reset||clear)begin state_q<=IDLE;header_q<='0;post_n_q<=0;post_sent_q<=0;z_seen_q<=0;error<=0;end
    else begin
      if(op_valid&&op_ready)begin header_q<=op_job.header;state_q<=ACQUIRE;end
      if(region_valid&&region_ready)state_q<=START;
      if(state_q==START)state_q<=RUN;
      if(post_valid&&post_ready)begin post_sent_q<=1;z_seen_q<=0;end
      if(z_commit)begin if(z_n!=post_n_q||!post_sent_q)error<=1;else z_seen_q<=1;end
      if(post_done_valid&&post_done_ready)begin
        if(post_done!=post_job||!(z_seen_q||(z_commit&&z_n==post_n_q)))error<=1;
        else begin post_sent_q<=0;post_n_q<=post_n_q+1'b1;end
      end
      if(post_done_valid&&!post_done_ready)error<=1;
      if(state_q==RUN&&proj_done&&region_complete&&post_n_q==16&&!error)state_q<=COMPLETE;
      if(done_valid&&done_ready)state_q<=IDLE;
      if(ae||be)error<=1;
    end
  end
endmodule
