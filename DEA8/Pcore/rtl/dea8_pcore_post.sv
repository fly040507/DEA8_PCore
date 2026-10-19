import pcore_pkg::*;
import pcore_control_pkg::*;

// The units own arithmetic. This service owns capture, pairing and retirement.
module dea8_pcore_post #(parameter bit EXTERNAL_VECTOR=0)(
  input logic clk,reset,clear,input control_job_t job,
  output vector_ram_port_t ram_a,ram_b,
  input logic [TILE-1:0][FP_BITS-1:0] ram_a_data,ram_b_data,
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
  logic [TILE-1:0][FP_BITS-1:0] a_data,b_data,normal_first_q,normal_second_q;
  logic [TILE-1:0] normal_mask_q;
  logic [5:0] fetch_index_q,ram_index_q,normal_index_q;
  logic ram_valid_q,normal_valid_q,fetch_fire,advance_normal,capture_legal;
  logic first_half_q,vector_finished_q,function_finished_q;
  logic [5:0] capture_q,index_q,result_index_q;
  logic result_half_q;
  logic [6:0] result_count_q;
  logic gu_ready,gu_gate_valid,gu_gelu_ready,gu_product_valid,gu_error;
  control_fp_data_t gu_gate,gu_product;
  logic [5:0] gu_accepted,gu_paired;
  logic rope,gu,vquant;
  logic [5:0] expected_result_tile;
  logic [6:0] expected_results;
  logic result_match;

  assign rope=job.header.op==OP_Q_PROJ||job.header.op==OP_K_PROJ;
  assign gu=job.header.op==OP_GU;
  assign vquant=job.header.op==OP_V_PROJ;
  assign capture_legal=in_data.header==command_q.header&&in_data.n==command_q.n&&
    in_data.row==capture_q&&in_data.row_valid==row_mask(capture_q)&&in_data.last==(capture_q==PAIRS-1);
  assign advance_normal=!normal_valid_q||vector_data_ready;
  assign fetch_fire=state_q==SEND&&!gu&&!error&&fetch_index_q<(vquant?V_PACKETS_PER_TILE:ROWS)&&
    (!ram_valid_q||advance_normal);
  if(EXTERNAL_VECTOR)begin assign a_data=ram_a_data;assign b_data=ram_b_data;end
  else begin: private_store
    dea8_vector_ram memory(.clk,.a(ram_a),.b(ram_b),.a_data,.b_data);
  end
  always_comb begin
    ram_a='0;ram_b='0;
    if(state_q==CAPTURE&&in_valid&&in_ready&&capture_legal)begin
      ram_a.data=in_data.first;ram_b.data=in_data.second;
      ram_a.rotate=$clog2(TILE)'(capture_q*2);
      ram_b.rotate=ram_a.rotate+1'b1;
      for(int b=0;b<TILE;b++)begin
        logic [$clog2(TILE)-1:0] fa,fb;
        fa=$clog2(TILE)'(b)-ram_a.rotate;fb=$clog2(TILE)'(b)-ram_b.rotate;
        ram_a.en[b]=1;ram_a.we[b]=1;
        ram_a.addr[b]=8'((rope&&command_q.n[0]?64:0)+(capture_q/(TILE/2))*TILE+fa);
        ram_b.en[b]=in_data.row_valid[1];ram_b.we[b]=in_data.row_valid[1];
        ram_b.addr[b]=8'((rope&&command_q.n[0]?64:0)+(capture_q/(TILE/2))*TILE+fb);
      end
    end else if(fetch_fire)begin
      if(vquant)begin
        ram_a.rotate=$clog2(TILE)'((fetch_index_q%(TILE/ROW_LANES))*ROW_LANES);
        ram_b.rotate=ram_a.rotate+1'b1;
        for(int b=0;b<TILE;b++)begin
          logic [$clog2(TILE)-1:0] ia,ib;
          ia=$clog2(TILE)'(b)-ram_a.rotate;ib=$clog2(TILE)'(b)-ram_b.rotate;
          ram_a.en[b]=(fetch_index_q/(TILE/ROW_LANES))*TILE+ia<ROWS;
          ram_b.en[b]=(fetch_index_q/(TILE/ROW_LANES))*TILE+ib<ROWS;
          ram_a.addr[b]=8'((fetch_index_q/(TILE/ROW_LANES))*TILE+ram_a.rotate);
          ram_b.addr[b]=8'((fetch_index_q/(TILE/ROW_LANES))*TILE+ram_b.rotate);
        end
      end else begin
        ram_a.rotate=$clog2(TILE)'(fetch_index_q);ram_b.rotate=ram_a.rotate;
        for(int b=0;b<TILE;b++)begin
          logic [$clog2(TILE)-1:0] feature;
          feature=$clog2(TILE)'(b)-ram_a.rotate;
          ram_a.en[b]=1;ram_b.en[b]=1;
          ram_a.addr[b]=8'((fetch_index_q/TILE)*TILE+feature);
          ram_b.addr[b]=8'(64+(fetch_index_q/TILE)*TILE+feature);
        end
      end
    end
  end
  assign idle=state_q==IDLE;
  assign in_cmd_ready=state_q==IDLE&&!error&&!reset&&!clear;
  assign in_ready=state_q==CAPTURE||(state_q==SEND&&gu&&gu_ready);
  dea8_gu_post_window gu_window(.clk,.reset,.clear(clear||state_q!=SEND),
    .enable(state_q==SEND&&gu&&!error),.job,.tile(command_q.n),
    .in_valid(in_valid&&state_q==SEND&&gu),.in_ready(gu_ready),.in_data,
    .gate_valid(gu_gate_valid),.gate_ready(function_data_ready),.gate_data(gu_gate),
    .gelu_valid(function_result_valid),.gelu_ready(gu_gelu_ready),.gelu_data(function_result),
    .product_valid(gu_product_valid),.product_ready(vector_data_ready),.product_data(gu_product),
    .error(gu_error),.accepted(gu_accepted),.paired(gu_paired),.occupancy()
  );
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
    vector_data.index=gu?index_q:normal_index_q;vector_data.vector_valid=gu?2'b01:2'b11;
    vector_data.token_mask='1;
    vector_data.last=(gu?index_q:normal_index_q)==(vquant?V_PACKETS_PER_TILE-1:ROWS-1);
    vector_data_valid=state_q==SEND&&!error&&!gu&&normal_valid_q;
    if(!gu)begin
      vector_data.first=normal_first_q;vector_data.second=normal_second_q;
      vector_data.token_mask=normal_mask_q;
    end else begin
      vector_data_valid=state_q==SEND&&gu_product_valid&&!error;
      vector_data=gu_product;
    end
    function_data=gu_gate;
    function_data_valid=state_q==SEND&&gu&&gu_gate_valid&&!error;
    function_result_ready=state_q==SEND&&gu&&gu_gelu_ready&&!error;
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
      error<=0;
      fetch_index_q<=0;ram_index_q<=0;normal_index_q<=0;ram_valid_q<=0;normal_valid_q<=0;
    end else begin
      if(!ram_valid_q||advance_normal)ram_valid_q<=fetch_fire;
      if(fetch_fire)begin ram_index_q<=fetch_index_q;fetch_index_q<=fetch_index_q+1'b1;end
      if(advance_normal)begin
        normal_valid_q<=ram_valid_q;
        if(ram_valid_q)begin
          normal_index_q<=ram_index_q;normal_mask_q<='1;
          for(int i=0;i<TILE;i++)begin
            if(vquant)begin
              normal_first_q[i]<=a_data[i];normal_second_q[i]<=b_data[i];
              if((ram_index_q/(TILE/ROW_LANES))*TILE+i>=ROWS)begin
                normal_mask_q[i]<=0;normal_first_q[i]<=0;normal_second_q[i]<=0;
              end
            end else begin
              normal_first_q[i]<=a_data[i];normal_second_q[i]<=b_data[i];
            end
          end
        end
      end
      if(in_cmd_valid&&in_cmd_ready)begin
        command_q<=in_cmd;capture_q<=0;index_q<=0;
        result_index_q<=0;result_half_q<=0;result_count_q<=0;
        vector_finished_q<=0;function_finished_q<=!gu;
        fetch_index_q<=0;ram_valid_q<=0;normal_valid_q<=0;
        if(in_cmd.header!=job.header||in_cmd.n>=output_tiles(job.header.op)||
           (rope&&in_cmd.n[0]!=first_half_q))error<=1;
        state_q<=gu?VCMD:CAPTURE;
      end
      if(state_q==CAPTURE&&in_valid&&in_ready)begin
        if(in_data.header!=command_q.header||in_data.n!=command_q.n||
           in_data.row!=capture_q||in_data.row_valid!=row_mask(capture_q)||
           in_data.last!=(capture_q==PAIRS-1))error<=1;
        else begin
          if(capture_q==PAIRS-1)begin
            if(rope&&!command_q.n[0])begin first_half_q<=1;state_q<=RETIRE;end
            else state_q<=VCMD;
          end else capture_q<=capture_q+1'b1;
        end
      end
      if(vector_valid&&vector_ready)state_q<=gu?FCMD:SEND;
      if(function_valid&&function_ready)state_q<=SEND;
      if(gu_error)error<=1;
      if(function_result_valid&&function_result_ready&&
         (function_result.tile!=command_q.n||function_result.index!=index_q))error<=1;
      if(vector_data_valid&&vector_data_ready)begin
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
