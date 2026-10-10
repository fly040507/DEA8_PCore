import pcore_pkg::*;
// Operation executor only. Algorithm state belongs to the selected adapter.
// Keep block/tile/post counters, prefetch and resource scheduling in adapters.
module dea8_pcore_ctrl(
  input logic clk,reset,clear,input logic fabric_error,
  input logic job_valid,output logic job_ready,input pcore_job_t job,
  output logic job_done_valid,input logic job_done_ready,output pcore_completion_t job_done,
  output logic busy,protocol_error,output logic [1:0] owner,
  output logic [2:0] adapter_valid,input logic [2:0] adapter_ready,
  output pcore_job_t adapter_job,
  input logic [2:0] adapter_done_valid,output logic [2:0] adapter_done_ready,
  input pcore_completion_t adapter_done[0:2],input logic [2:0] adapter_error,
  output logic operation_clear
);
  typedef enum logic [1:0] {IDLE,ACTIVE,COMPLETE,FAULT} state_t;
  state_t state_q;logic sent_q;pcore_job_t job_q;
  assign job_ready=state_q==IDLE&&!reset&&!clear;
  assign busy=state_q!=IDLE;assign job_done_valid=state_q==COMPLETE&&!reset&&!clear;
  assign adapter_job=job_q;
  assign operation_clear=job_valid&&job_ready;
  always_comb begin
    adapter_valid=0;adapter_done_ready=0;
    if(state_q==ACTIVE&&!reset&&!clear)begin
      adapter_valid[owner]=!sent_q;adapter_done_ready[owner]=sent_q;
    end
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin state_q<=IDLE;sent_q<=0;owner<=0;job_q<='0;job_done<='0;protocol_error<=0;end
    else begin
      if(job_valid&&job_ready)begin
        job_q<=job;job_done.header<=job.header;job_done.status<=JOB_OK;sent_q<=0;
        case(job.header.op)
          OP_Q_PROJ,OP_K_PROJ,OP_V_PROJ,OP_O_PROJ,OP_DOWN_PROJ:begin owner<=0;state_q<=ACTIVE;end
          OP_ATTENTION:begin owner<=1;state_q<=ACTIVE;end
          OP_GU:begin owner<=2;state_q<=ACTIVE;end
          default:begin job_done.status<=JOB_UNSUPPORTED;state_q<=COMPLETE;end
        endcase
      end
      if(state_q==ACTIVE)begin
        if(adapter_valid[owner]&&adapter_ready[owner])sent_q<=1;
        if(adapter_done_valid[owner]&&adapter_done_ready[owner])begin
          if(adapter_done[owner].header!=job_q.header)begin state_q<=FAULT;protocol_error<=1;end
          else begin job_done<=adapter_done[owner];state_q<=COMPLETE;end
        end
        if(adapter_error[owner]||fabric_error)begin state_q<=FAULT;protocol_error<=1;end
        for(int i=0;i<3;i++) if(adapter_done_valid[i]&&(owner!=i||!sent_q))begin
          state_q<=FAULT;protocol_error<=1;
        end
      end
      if(job_done_valid&&job_done_ready)state_q<=IDLE;
    end
  end
endmodule
