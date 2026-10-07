import pcore3_pkg::*;
import pcore_control_pkg::*;

// The units own arithmetic. This service owns capture, pairing and retirement.
module dea8_pcore_post_v3(
  input logic clk,reset,clear,input control_job_t job,
  input logic in_cmd_valid,output logic in_cmd_ready,input pcore_post_job_t in_cmd,
  input logic in_valid,output logic in_ready,input post_data_t in_data,
  output logic done_valid,input logic done_ready,output pcore_post_job_t done,
  output logic vector_valid,input logic vector_ready,output control_command_t vector_cmd,
  input logic vector_done,
  output logic function_valid,input logic function_ready,output control_command_t function_cmd,
  input logic function_done,
  output logic vector_data_valid,input logic vector_data_ready,output control_fp_data_t vector_data,
  output logic function_data_valid,input logic function_data_ready,output control_fp_data_t function_data,
  input logic function_result_valid,output logic function_result_ready,input control_fp_data_t function_result,
  input logic result_fire,input control_quant_result_t result,
  output logic result_legal,output logic error,output logic idle
);
  typedef enum logic [3:0] {IDLE,CAPTURE,VCMD,FCMD,SEND,WAIT_DONE,RETIRE} state_t;
  state_t state_q;
  pcore_post_job_t command_q;
  localparam int ROW_BANKS=TILE,ROWS_PER_BANK=(ROWS+ROW_BANKS-1)/ROW_BANKS;
  // One bank per token lane supports V's transposed reads. Both RoPE halves
  // share each bank's address space; only CAPTURE writes this store.
  (* ram_style="distributed" *) logic [TILE-1:0][FP_BITS-1:0] halves[0:ROW_BANKS-1][0:2*ROWS_PER_BANK-1];
  logic first_half_q,vector_finished_q,function_finished_q;
  logic [5:0] capture_q,index_q,result_index_q;
  logic result_half_q;
  logic [6:0] result_count_q;
  logic [TILE-1:0][FP_BITS-1:0] up_q;
  logic gu_row_q,gate_sent_q;
  control_fp_data_t gate_q;
  logic rope,gu,vquant;
  logic [5:0] expected_result_tile;
  logic [6:0] expected_results;
  logic result_match;

  assign rope=job.header.op==OP_Q_PROJ||job.header.op==OP_K_PROJ;
  assign gu=job.header.op==OP_GU;
  assign vquant=job.header.op==OP_V_PROJ;
  assign idle=state_q==IDLE;
  assign in_cmd_ready=state_q==IDLE&&!error&&!reset&&!clear;
  assign in_ready=state_q==CAPTURE||
    (state_q==SEND&&gu&&!gu_row_q);
  assign done_valid=state_q==RETIRE&&!error&&!reset&&!clear;
  assign done=command_q;
  assign vector_valid=state_q==VCMD&&!error;
  assign function_valid=state_q==FCMD&&!error;
  always_comb begin
    vector_cmd='0;vector_cmd.job=job;
    vector_cmd.tile=command_q.n;vector_cmd.tiles=rope?2:1;
    vector_cmd.elements=16'(ROWS*TILE*(rope?2:1));
    vector_cmd.source=WORK_PAIR;
    vector_cmd.destination=gu?WORK_Z:((job.header.op==OP_K_PROJ||vquant)?WORK_KV_OUT:WORK_QOZ);
    vector_cmd.quant_axis=vquant?QUANT_TOKEN_B16:QUANT_FEATURE_B16;
    vector_cmd.rope_frequency_base=job.header.op==OP_K_PROJ?
      job.rope_pair_base:8'((command_q.n/2)*TILE);
    vector_cmd.function_id=rope?VECTOR_ROPE_QUANT:(gu?VECTOR_GU_POST:VECTOR_V_QUANT);
    function_cmd=vector_cmd;function_cmd.function_id=FUNCTION_GELU;
    function_cmd.source=WORK_GATE;function_cmd.destination=WORK_PAIR;
    function_cmd.elements=16'(ROWS*TILE);
  end
  // RoPE and GU expose one row per transfer. V exposes two feature columns
  // across a token-B16 group, with explicit padding in the final group.
  always_comb begin
    vector_data='0;vector_data.job=job;vector_data.tile=command_q.n;
    vector_data.index=index_q;vector_data.vector_valid=gu?2'b01:2'b11;
    vector_data.token_mask='1;
    vector_data.last=index_q==(vquant?V_PACKETS_PER_TILE-1:ROWS-1);
    vector_data_valid=state_q==SEND&&!error&&!gu;
    if(vquant)begin
      for(int i=0;i<TILE;i++)begin
        if((index_q/(TILE/ROW_LANES))*TILE+i<ROWS)begin
          vector_data.first[i]=halves[i][index_q/(TILE/ROW_LANES)][(index_q%(TILE/ROW_LANES))*ROW_LANES];
          vector_data.second[i]=halves[i][index_q/(TILE/ROW_LANES)][(index_q%(TILE/ROW_LANES))*ROW_LANES+1];
        end else vector_data.token_mask[i]=0;
      end
    end else if(!gu)begin
      vector_data.first=halves[index_q%ROW_BANKS][index_q/ROW_BANKS];
      vector_data.second=halves[index_q%ROW_BANKS][ROWS_PER_BANK+index_q/ROW_BANKS];
    end else begin
      vector_data_valid=state_q==SEND&&gu_row_q&&gate_sent_q&&function_result_valid&&!error;
      vector_data.first=function_result.first;vector_data.second=up_q;
    end
    function_data=gate_q;
    function_data_valid=state_q==SEND&&gu_row_q&&!gate_sent_q&&!error;
    function_result_ready=state_q==SEND&&gu_row_q&&gate_sent_q&&vector_data_ready&&!error;
  end
  always_comb begin
    expected_results=vquant?V_PACKETS_PER_TILE:(rope?2*PAIRS:PAIRS);
    expected_result_tile=command_q.n;
    if(rope&&job.header.op==OP_Q_PROJ)
      expected_result_tile=6'(command_q.n/2+(result_half_q?QOZ_Q_TILES/2:0));
    else if(rope)expected_result_tile=6'(result_half_q);
    result_match=result.tile==expected_result_tile&&result.index==result_index_q&&
      result.quant_axis==(vquant?QUANT_TOKEN_B16:QUANT_FEATURE_B16)&&
      result.vector_valid==(vquant?2'b11:row_mask(result_index_q))&&
      result.last==(result_index_q==(vquant?V_PACKETS_PER_TILE-1:PAIRS-1));
  end
  assign result_legal=(state_q==SEND||state_q==WAIT_DONE)&&result_match&&result_count_q<expected_results;
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      state_q<=IDLE;command_q<='0;first_half_q<=0;capture_q<=0;index_q<=0;
      result_index_q<=0;result_half_q<=0;result_count_q<=0;
      vector_finished_q<=0;function_finished_q<=0;
      gu_row_q<=0;gate_sent_q<=0;gate_q<='0;up_q<='0;error<=0;
    end else begin
      if(in_cmd_valid&&in_cmd_ready)begin
        command_q<=in_cmd;capture_q<=0;index_q<=0;
        result_index_q<=0;result_half_q<=0;result_count_q<=0;
        vector_finished_q<=0;function_finished_q<=!gu;
        if(in_cmd.header!=job.header||in_cmd.n>=output_tiles(job.header.op)||
           (rope&&in_cmd.n[0]!=first_half_q))error<=1;
        state_q<=gu?VCMD:CAPTURE;
      end
      if(state_q==CAPTURE&&in_valid&&in_ready)begin
        if(in_data.header!=command_q.header||in_data.n!=command_q.n||
           in_data.row!=capture_q||in_data.row_valid!=row_mask(capture_q)||
           in_data.last!=(capture_q==PAIRS-1))error<=1;
        else begin
          halves[(capture_q*ROW_LANES)%ROW_BANKS][(rope&&command_q.n[0]?ROWS_PER_BANK:0)+(capture_q*ROW_LANES)/ROW_BANKS]<=in_data.first;
          if(in_data.row_valid[1])halves[(capture_q*ROW_LANES+1)%ROW_BANKS][(rope&&command_q.n[0]?ROWS_PER_BANK:0)+(capture_q*ROW_LANES+1)/ROW_BANKS]<=in_data.second;
          if(capture_q==PAIRS-1)begin
            if(rope&&!command_q.n[0])begin first_half_q<=1;state_q<=RETIRE;end
            else state_q<=VCMD;
          end else capture_q<=capture_q+1'b1;
        end
      end
      if(vector_valid&&vector_ready)state_q<=gu?FCMD:SEND;
      if(function_valid&&function_ready)state_q<=SEND;
      if(state_q==SEND&&gu&&in_valid&&in_ready)begin
        if(in_data.header!=command_q.header||in_data.n!=command_q.n||in_data.row!=index_q||
           in_data.row_valid!=2'b01||in_data.last!=(index_q==ROWS-1))error<=1;
        gate_q<='0;gate_q.job<=job;gate_q.tile<=command_q.n;gate_q.index<=index_q;
        gate_q.vector_valid<=2'b01;gate_q.token_mask<='1;gate_q.last<=index_q==ROWS-1;
        gate_q.first<=in_data.first;up_q<=in_data.second;gu_row_q<=1;gate_sent_q<=0;
      end
      if(function_data_valid&&function_data_ready)gate_sent_q<=1;
      if(function_result_valid&&function_result_ready&&
         (function_result.tile!=command_q.n||function_result.index!=index_q))error<=1;
      if(vector_data_valid&&vector_data_ready)begin
        gu_row_q<=0;
        if(vector_data.last)state_q<=WAIT_DONE;
        else index_q<=index_q+1'b1;
      end
      if(result_fire)begin
        if((state_q!=SEND&&state_q!=WAIT_DONE)||!result_match||result_count_q>=expected_results)error<=1;
        else begin
          result_count_q<=result_count_q+1'b1;
          if(result.last)begin result_index_q<=0;result_half_q<=1;end
          else result_index_q<=result_index_q+1'b1;
        end
      end
      if(vector_done)begin
        if(state_q!=WAIT_DONE||result_count_q!=expected_results)error<=1;
        else vector_finished_q<=1;
      end
      if(function_done)begin
        if(!gu||state_q!=WAIT_DONE)error<=1;
        else function_finished_q<=1;
      end
      if(state_q==WAIT_DONE&&vector_finished_q&&function_finished_q)begin
        first_half_q<=0;state_q<=RETIRE;
      end
      if(done_valid&&done_ready)state_q<=IDLE;
    end
  end
endmodule
