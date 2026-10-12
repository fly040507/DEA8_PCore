import pcore_pkg::*;
module dea8_gu_job_adapter(
  input logic clk,reset,clear,
  input logic op_valid,output logic op_ready,input pcore_job_t op_job,
  output logic done_valid,input logic done_ready,output pcore_completion_t done,output logic error,
  output matrix_service_req_t matrix_req,input matrix_service_rsp_t matrix_rsp,
  output logic region_valid,input logic region_ready,output qoz_region_req_t region,input logic region_complete,
  output logic post_valid,input logic post_ready,output pcore_post_job_t post_job,
  input logic post_done_valid,output logic post_done_ready,input pcore_post_job_t post_done,
  output logic data_valid,input logic data_ready,output post_data_t data_out,
  input logic z_commit,input logic [5:0] z_n,
  input logic a_valid,output logic a_ready,input a2_t a_entry,
  output logic prefetch_valid,input logic prefetch_ready,output logic [5:0] prefetch_n
);
  typedef enum logic [2:0] {IDLE,ACQUIRE,START,RUN,COMPLETE} state_t;
  state_t state_q;job_header_t header_q;
  logic [5:0] n_q,post_n_q;logic matrix_active_q,post_active_q,z_seen_q;
  logic [5:0] retired_q;
  logic gu_ready,gu_done,pair_ready,pair_accept,gu_busy,ae,be,ge;
  logic [5:0] out_row,out_n;logic [EPOCH_BITS-1:0] out_epoch;logic [2:0] out_head;
  logic [15:0][31:0] gate_data,up_data;logic [1:0] row_valid;logic last,consumed;
  logic tile_start,next_launch;
  logic prefetch_sent_q;
  // A one-ahead grant is held until the loader accepts it. It authorizes only
  // n+1; FIFO/replay credits bound actual storage, transport remains modulo64.
  assign op_ready=state_q==IDLE&&!reset&&!clear;
  assign done_valid=state_q==COMPLETE;assign done='{header:header_q,status:JOB_OK};
  assign region_valid=state_q==ACQUIRE;assign region='{header:header_q,owner:QOZ_Z,tiles:6'd32};
  // Current descriptor launches at the previous final commit. A/B producers
  // run ahead through bounded replay/FIFO credits, never fork per launch.
  assign next_launch=state_q==RUN&&matrix_active_q&&gu_done&&n_q<31;
  assign tile_start=(state_q==START)||next_launch;
  assign prefetch_valid=state_q==RUN&&matrix_active_q&&n_q<31&&!prefetch_sent_q;
  assign prefetch_n=n_q+1'b1;
  assign post_valid=state_q==RUN&&pair_ready&&!post_active_q;
  assign post_job='{header:header_q,op:POST_GU,n:post_active_q?post_n_q:out_n};
  assign pair_accept=post_valid&&post_ready;
  assign post_done_ready=post_active_q;
  assign data_out='{header:header_q,n:out_n,row:out_row,row_valid:row_valid,last:last,first:gate_data,second:up_data};
  dea8_gu_matrix #(.EXTERNAL_MATRIX(1)) gu(
    .clk,.reset,.clear,.service_req(matrix_req),.service_rsp(matrix_rsp),
    .start(tile_start),.start_ready(gu_ready),.job_epoch(header_q.epoch),.job_head(header_q.head),.job_n(next_launch?n_q+1'b1:n_q),
    .local_a_valid(a_valid),.local_a_ready(a_ready),.local_a_entry(a_entry),.hbm_valid(1'b0),.hbm_ready(),.hbm_entry('0),
    .gu_busy,.gu_matrix_done(gu_done),.gu_pair_ready(pair_ready),.gu_pair_ready_accept(pair_accept),
    .gu_out_valid(data_valid),.gu_out_ready(data_ready&&post_active_q),.gu_out_row(out_row),
    .gu_out_epoch(out_epoch),.gu_out_head(out_head),.gu_out_n(out_n),.gu_gate(gate_data),.gu_up(up_data),
    .gu_out_row_valid(row_valid),.gu_out_last(last),.gu_out_consumed(consumed),
    .vpu_z_valid(1'b0),.vpu_z_ready(),.vpu_z_tile('0),.vpu_z_pair('0),.vpu_z_row_valid('0),
    .vpu_z_even('0),.vpu_z_odd('0),.vpu_z_epoch('0),.vpu_z_head('0),.vpu_z_n('0),.vpu_z_last(1'b0),
    .qoz_z_wr_valid(),.qoz_z_wr_ready(1'b0),.qoz_z_wr_tile(),.qoz_z_wr_pair(),.qoz_z_wr_row_valid(),
    .qoz_z_wr_even(),.qoz_z_wr_odd(),.qoz_z_wr_epoch(),.qoz_z_wr_head(),.qoz_z_wr_n(),.qoz_z_wr_last(),
    .a_protocol_error(ae),.b_protocol_error(be),.gu_protocol_error(ge));
  always_ff @(posedge clk)begin
    if(reset||clear)begin state_q<=IDLE;header_q<='0;n_q<=0;post_n_q<=0;retired_q<=0;post_active_q<=0;matrix_active_q<=0;z_seen_q<=0;error<=0;prefetch_sent_q<=0;end
    else begin
      if(op_valid&&op_ready)begin header_q<=op_job.header;state_q<=ACQUIRE;end
      if(region_valid&&region_ready)state_q<=START;
      if(prefetch_valid&&prefetch_ready)prefetch_sent_q<=1;
      if(tile_start&&gu_ready)begin state_q<=RUN;matrix_active_q<=1;prefetch_sent_q<=0;if(next_launch)n_q<=n_q+1'b1;end
      if(gu_done&&n_q==31)matrix_active_q<=0;
      if(pair_accept)begin post_active_q<=1;post_n_q<=out_n;z_seen_q<=0;if(out_n!=retired_q)error<=1;end
      if(z_commit)begin if(!post_active_q||z_n!=post_n_q)error<=1;else z_seen_q<=1;end
      if(post_done_valid&&post_done_ready)begin
        if(post_done!=post_job||!(z_seen_q||(z_commit&&z_n==post_n_q)))error<=1;
        else begin post_active_q<=0;retired_q<=retired_q+1'b1;end
      end
      if(post_done_valid&&!post_done_ready)error<=1;
      if(state_q==RUN&&n_q==31&&!matrix_active_q&&retired_q==32&&region_complete&&!error)state_q<=COMPLETE;
      if(done_valid&&done_ready)state_q<=IDLE;
      if(ae||be||ge)error<=1;
    end
  end
endmodule
