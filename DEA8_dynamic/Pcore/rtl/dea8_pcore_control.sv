import pcore_pkg::*;

// Only this block owns the external job and its completion lifetime.
module dea8_pcore_control #(parameter logic [2:0] CORE_ID=3'd0) (
  input logic clk,reset,clear,
  input logic job_valid,output logic job_ready,input pcore_job_t job,
  input logic profile_valid,input logic [ROW_COUNT_BITS-1:0] profile_rows,
  input logic [15:0] profile_id,profile_version,
  input logic precondition_ok,input logic [6:0] implemented_ops,
  output pcore_job_t context_job,output job_token_t context_token,
  output logic [ROW_COUNT_BITS-1:0] context_rows,
  output logic [2:0] start_valid,input logic [2:0] start_ready,
  input logic engine_done,input job_token_t engine_token,input logic fault,
  output logic busy,flush_request,input logic [2:0] flush_ack,
  output logic completion_valid,input logic completion_ready,output pcore_completion_t completion
);
  typedef enum logic [2:0] {IDLE,VALIDATE,START,ACTIVE,COMPLETE,FAULT,FLUSH_WAIT} state_e;
  state_e state;
  logic [15:0] generation;
  logic clear_seen,cancel_pending,fault_reported;
  logic [ROW_COUNT_BITS-1:0] rows_q;
  operation_profile_t contract;
  logic legal,profile_ok,empty_job;
  assign contract=operation_profile(context_job.op);
  assign busy=state!=IDLE;
  assign flush_request=state==FLUSH_WAIT;
  assign job_ready=!reset&&!clear&&state==IDLE&&!fault;
  assign context_rows=rows_q;
  assign empty_job=context_rows==0;
  assign profile_ok=context_job.op==OP_K_PROJ||context_job.op==OP_V_PROJ||
    (profile_valid&&profile_id==context_job.profile_id&&profile_version==context_job.profile_version);
  assign legal=context_job.op<=OP_DOWN_PROJ&&context_job.core_id==CORE_ID&&profile_rows<=ROWS&&
    (!(context_job.op==OP_Q_PROJ||context_job.op==OP_K_PROJ)||
      int'(context_job.position_base)+ROWS-1<65536);
  logic layout_ok;
  assign layout_ok=context_job.op==OP_K_PROJ?
    (context_job.kv_column_base0%TILE==0&&context_job.kv_column_base0<128&&
     int'(context_job.kv_column_base1)==int'(context_job.kv_column_base0)+128):
    context_job.op==OP_V_PROJ?
    (context_job.kv_column_base0%TILE==0&&context_job.kv_column_base0<256-TILE&&
     int'(context_job.kv_column_base1)==int'(context_job.kv_column_base0)+TILE):1'b1;
  always_comb begin
    start_valid=0;
    if(state==START&&!fault&&!clear)start_valid[contract.mode]=1;
  end
  task automatic finish(input pcore_status_e status,input bit is_empty);
    pcore_completion_t c;
    c='0;c.token=context_token;c.job_id=context_job.job_id;c.user_tag=context_job.user_tag;
    c.op=context_job.op;c.status=status;c.empty=is_empty;c.rows=context_rows;
    completion<=c;completion_valid<=1;state<=COMPLETE;
  endtask
  always_ff @(posedge clk)begin
    if(reset)begin
      state<=IDLE;context_job<='0;context_token<=0;generation<=1;
      clear_seen<=0;cancel_pending<=0;completion_valid<=0;completion<='0;
      rows_q<=0;fault_reported<=0;
    end else begin
      clear_seen<=clear;
      if(completion_valid&&completion_ready)completion_valid<=0;
      if(clear&&!clear_seen)begin
        cancel_pending<=state==VALIDATE||state==START||state==ACTIVE||(state==FAULT&&!fault_reported);
        state<=FLUSH_WAIT;
      end else case(state)
        IDLE:begin
          if(fault)begin state<=FAULT;fault_reported<=1;end
          else if(job_valid&&job_ready)begin
            context_job<=job;context_token<={generation,job.job_id};state<=VALIDATE;
            rows_q<=ROW_COUNT_BITS'(effective_rows(job.op,profile_rows));fault_reported<=0;
          end
        end
        VALIDATE:begin
          if(!legal||!layout_ok)finish(PCORE_INVALID,0);
          else if(!profile_ok)finish(PCORE_PRECONDITION,0);
          else if(generation==16'hffff)finish(PCORE_TOKEN_LIMIT,0);
          else if(empty_job)finish(PCORE_OK,1);
          else if(!implemented_ops[context_job.op])finish(PCORE_UNSUPPORTED,0);
          else if(!precondition_ok)finish(PCORE_PRECONDITION,0);
          else state<=START;
        end
        START:begin
          if(fault)state<=FAULT;
          else if(|(start_valid&start_ready))state<=ACTIVE;
        end
        ACTIVE:begin
          if(fault||(engine_done&&engine_token!=context_token))state<=FAULT;
          else if(engine_done)finish(PCORE_OK,0);
        end
        COMPLETE:begin
          // A late fault cannot create a second completion for a retired job.
          if(fault)fault_reported<=1;
          if(completion_valid&&completion_ready)begin
            if(generation!=16'hffff)generation<=generation+1'b1;
            state<=fault||fault_reported?FAULT:IDLE;
          end
        end
        FAULT:if(!completion_valid&&!fault_reported)begin finish(PCORE_FAULT,0);fault_reported<=1;end
        FLUSH_WAIT:if(&flush_ack&&!clear)begin
          generation<=generation==16'hffff ? 16'd1 : generation+1'b1;
          if(cancel_pending&&!completion_valid)finish(PCORE_CANCELLED,0);
          else state<=completion_valid?COMPLETE:IDLE;
          cancel_pending<=0;
          fault_reported<=0;
        end
        default:state<=FAULT;
      endcase
    end
  end
endmodule
