module dea8_gcore_norm (
  input logic clk,reset,clear,invalidate_stats,
  input logic cmd_valid,
  output logic cmd_ready,
  input gcore_pkg::gcore_cmd_t cmd,
  output logic ram_rd_valid,
  input logic ram_rd_ready,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] ram_rd_addr,
  input logic ram_rsp_valid,
  output logic ram_rsp_ready,
  input logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] ram_rsp_addr,
  input logic [255:0] ram_rsp_data,
  output logic ram_wr_valid,
  input logic ram_wr_ready,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] ram_wr_addr,
  output logic [255:0] ram_wr_data,
  output logic activation_valid,
  input logic activation_ready,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] activation_index,
  output logic [135:0] activation_word,
  input logic work_valid,
  output logic work_ready,
  input gcore_pkg::residual_work_t work,
  output logic written_valid,
  input logic written_ready,
  output gcore_pkg::residual_commit_t written,
  output logic rsqrt_valid,
  input logic rsqrt_ready,
  output gcore_pkg::rsqrt_packet_t rsqrt_request,
  input logic rsqrt_out_valid,
  output logic rsqrt_out_ready,
  input gcore_pkg::rsqrt_packet_t rsqrt_response,
  output logic done_valid,
  input logic done_ready,
  output gcore_pkg::gcore_done_t done,
  output logic busy,stats_valid,protocol_error
);
  import gcore_pkg::*;
  import gcore_fp_pkg::*;
  typedef enum logic [3:0] {IDLE,INIT,SCAN,SCAN_DRAIN,RSQRT,APPLY,APPLY_DRAIN,
    RESIDUAL,RESIDUAL_DRAIN,FINISH} state_e;
  state_e state_q;
  gcore_cmd_t command_q;
  logic [15:0] stats_object,stats_version;
  logic [VECTOR_ADDR_BITS:0] issued_q,committed_q;
  logic tag_valid,read_fire,response_fire,tag_space;
  vector_meta_t read_meta;
  logic [511:0] read_delta;
  logic vector_in_valid,vector_in_ready,vector_out_valid,vector_out_ready,vector_empty;
  vector_request_t vector_request;
  vector_result_t vector_result;
  logic clear_vector,clear_sq_q,abort_q,active_reads,work_good,response_good;
  logic [5:0] sq_row0,sq_row1,rsqrt_pair_q;
  logic [31:0] sq_value0,sq_value1,u0,u1;
  localparam int U_ADD_LATENCY=4, HIDDEN_LOG2=$clog2(HIDDEN);
  logic [U_ADD_LATENCY:0] u_valid_q;
  rsqrt_packet_t u_meta_q[U_ADD_LATENCY+1];
  logic [31:0] scaled_sq0,scaled_sq1;
  logic u_advance;
  logic [5:0] rsqrt_issue_pair_q;
  logic [31:0] inverse_read_q;
  logic inverse_write;
  logic sq_fetch_valid;
  rsqrt_packet_t sq_fetch_meta;
  logic [ROWS-1:0] inverse_valid,pending_rows;
  logic rsqrt_request_good,rsqrt_response_good,vector_metadata_good;
  logic fault_event;
  gcore_status_e fault_status;

  assign busy=state_q!=IDLE;
  assign cmd_ready=state_q==IDLE&&!reset&&!clear&&!ram_rsp_valid&&!protocol_error&&
    vector_empty&&!rsqrt_out_valid;
  assign done_valid=state_q==FINISH&&!reset&&!clear;
  assign clear_vector=clear||abort_q;
  assign active_reads=state_q==SCAN||state_q==APPLY||state_q==RESIDUAL;
  assign tag_space=!tag_valid||response_fire;
  assign work_good=work.token==command_token(command_q)&&work.index==issued_q;
  assign ram_rd_addr=VECTOR_ADDR_BITS'(issued_q);
  assign ram_rd_valid=active_reads&&tag_space&&issued_q<VECTOR_WORDS&&!reset&&!clear&&
    (state_q!=RESIDUAL||(work_valid&&work_good));
  assign read_fire=ram_rd_valid&&ram_rd_ready;
  assign work_ready=state_q==RESIDUAL&&!reset&&!clear&&
    (!work_good||(tag_space&&ram_rd_ready&&issued_q<VECTOR_WORDS));
  assign response_good=tag_valid&&ram_rsp_addr==read_meta.index;
  assign vector_in_valid=ram_rsp_valid&&response_good&&!reset&&!clear&&state_q!=FINISH&&state_q!=IDLE;
  assign ram_rsp_ready=!reset&&!clear&&((state_q==IDLE||state_q==FINISH)?1'b1:
    (response_good?vector_in_ready:1'b1));
  assign response_fire=ram_rsp_valid&&ram_rsp_ready;
  always_comb begin
    vector_request='0; vector_request.meta=read_meta;
    vector_request.residual=ram_rsp_data; vector_request.delta=read_delta;
    vector_request.inverse=inverse_read_q;
    ram_wr_addr=vector_result.meta.index; ram_wr_data=vector_result.residual;
    activation_index=vector_result.meta.index; activation_word=vector_result.quantized;
    written='0; written.token=vector_result.meta.token; written.index=vector_result.meta.index;
    vector_metadata_good=vector_result.meta.token==command_token(command_q)&&
      vector_result.meta.index==committed_q;
    ram_wr_valid=0; activation_valid=0; written_valid=0; vector_out_ready=0;
    if(!reset&&!clear&&!fault_event) begin
      case(state_q)
        SCAN,SCAN_DRAIN:vector_out_ready=1;
        RESIDUAL,RESIDUAL_DRAIN: begin
          ram_wr_valid=vector_out_valid&&written_ready;
          written_valid=vector_out_valid&&ram_wr_ready;
          vector_out_ready=ram_wr_ready&&written_ready;
        end
        APPLY,APPLY_DRAIN: begin
          activation_valid=vector_out_valid; vector_out_ready=activation_ready;
        end
        FINISH:vector_out_ready=1;
        default:;
      endcase
    end
  end
  dea8_gcore_vector vector_engine (
    .clk,.reset,.clear(clear_vector),.clear_sq(clear_sq_q),
    .in_valid(vector_in_valid),.in_ready(vector_in_ready),.request(vector_request),
    .out_valid(vector_out_valid),.out_ready(vector_out_ready),.result(vector_result),
    .sq_row0,.sq_row1,.stats_read(state_q==RSQRT),.stats_advance(u_advance),
    .sq_value0,.sq_value1,.empty(vector_empty)
  );

  assign sq_row0=6'(rsqrt_issue_pair_q*2);
  assign sq_row1=sq_row0+1'b1;
  assign u_advance=!u_valid_q[U_ADD_LATENCY]||rsqrt_ready;
  dea8_gcore_fp_add epsilon_add0(.clk,.advance(u_advance),.a(scaled_sq0),
    .b(command_q.epsilon_fp32),.result(u0));
  dea8_gcore_fp_add epsilon_add1(.clk,.advance(u_advance),.a(scaled_sq1),
    .b(command_q.epsilon_fp32),.result(u1));
  always_comb begin
    rsqrt_request=u_meta_q[U_ADD_LATENCY];
    rsqrt_request.data={rsqrt_request.mask[1]?u1:32'b0,u0};
    rsqrt_request_good=finite32(u0)&&!u0[31]&&u0[30:0]!=0 &&
      (!rsqrt_request.mask[1]||(finite32(u1)&&!u1[31]&&u1[30:0]!=0));
    rsqrt_response_good=rsqrt_response.token==command_token(command_q) &&
      rsqrt_response.row0<ROWS&&!rsqrt_response.row0[0] &&
      rsqrt_response.row1==rsqrt_response.row0+1 &&
      rsqrt_response.mask==((rsqrt_response.row0==ROWS-1)?2'b01:2'b11);
    if(rsqrt_response.row0<ROWS) begin
      if(!pending_rows[rsqrt_response.row0]||inverse_valid[rsqrt_response.row0]||
          !finite32(rsqrt_response.data[31:0])||rsqrt_response.data[31]||rsqrt_response.data[30:0]==0)
        rsqrt_response_good=0;
    end
    if(rsqrt_response.mask[1]) begin
      if(rsqrt_response.row1>=ROWS) rsqrt_response_good=0;
      else if(!pending_rows[rsqrt_response.row1]||inverse_valid[rsqrt_response.row1]||
          !finite32(rsqrt_response.data[63:32])||rsqrt_response.data[63]||rsqrt_response.data[62:32]==0)
        rsqrt_response_good=0;
    end
  end
  assign rsqrt_valid=state_q==RSQRT&&u_valid_q[U_ADD_LATENCY]&&rsqrt_request_good&&!reset&&!clear;
  // Consume and report unsolicited responses, including after a command has
  // already retired. Such a late fault must not produce a second completion.
  assign rsqrt_out_ready=!reset&&!clear;
  always_comb begin
    fault_event=0; fault_status=GC_SOURCE_PROTOCOL;
    if(state_q!=IDLE&&state_q!=FINISH) begin
      if(invalidate_stats) fault_event=1;
      if(ram_rsp_valid&&!response_good) fault_event=1;
      if(state_q==RESIDUAL&&work_valid&&!work_good) fault_event=1;
      if(vector_out_valid&&!vector_metadata_good) fault_event=1;
      if(vector_out_valid&&vector_result.numeric_fault) begin fault_event=1; fault_status=GC_NUMERIC_FAULT; end
      if(state_q==RSQRT) begin
        if(u_valid_q[U_ADD_LATENCY]&&!rsqrt_request_good) begin fault_event=1; fault_status=GC_NUMERIC_FAULT; end
        if(rsqrt_out_valid&&rsqrt_out_ready&&!rsqrt_response_good) fault_event=1;
      end else if(rsqrt_out_valid) fault_event=1;
    end
  end

  always_ff @(posedge clk) begin
    if(reset||clear||abort_q||state_q!=RSQRT) begin
      u_valid_q<=0; rsqrt_issue_pair_q<=0; scaled_sq0<=0; scaled_sq1<=0;
      sq_fetch_valid<=0;sq_fetch_meta<='0;
      for(int s=0;s<=U_ADD_LATENCY;s++) u_meta_q[s]<='0;
    end else if(u_advance) begin
      u_valid_q[0]<=sq_fetch_valid;
      sq_fetch_valid<=rsqrt_issue_pair_q<(ROWS+1)/2;
      u_meta_q[0]<=sq_fetch_meta;
      scaled_sq0<=scale_power_two(sq_value0,-HIDDEN_LOG2);scaled_sq1<=scale_power_two(sq_value1,-HIDDEN_LOG2);
      if(rsqrt_issue_pair_q<(ROWS+1)/2) begin
        rsqrt_issue_pair_q<=rsqrt_issue_pair_q+1'b1;
        sq_fetch_meta.token<=command_token(command_q);sq_fetch_meta.row0<=sq_row0;
        sq_fetch_meta.row1<=sq_row1;sq_fetch_meta.mask<=sq_row0==ROWS-1?2'b01:2'b11;
      end
      for(int s=1;s<=U_ADD_LATENCY;s++) begin
        u_valid_q[s]<=u_valid_q[s-1]; u_meta_q[s]<=u_meta_q[s-1];
      end
    end
  end

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      state_q<=IDLE; command_q<='0; issued_q<=0; committed_q<=0; done<='0;
      tag_valid<=0; read_meta<='0; read_delta<=0; clear_sq_q<=0; abort_q<=0;
      stats_valid<=0; stats_object<=0; stats_version<=0;
      rsqrt_pair_q<=0; inverse_valid<=0; pending_rows<=0; protocol_error<=0;
    end else begin
      clear_sq_q<=0; abort_q<=0;
      if(rsqrt_out_valid&&rsqrt_out_ready &&
          (state_q!=RSQRT||!rsqrt_response_good)) protocol_error<=1;
      if(invalidate_stats) stats_valid<=0;
      if(cmd_valid&&cmd_ready) begin
        command_q<=cmd; issued_q<=0; committed_q<=0; tag_valid<=0;
        inverse_valid<=0; pending_rows<=0; rsqrt_pair_q<=0;
        if((cmd.opcode!=GC_NORM&&cmd.opcode!=GC_RESIDUAL_APPLY) ||
            (cmd.opcode==GC_NORM&&(cmd.epsilon_fp32[31]||cmd.epsilon_fp32[30:0]==0||!finite32(cmd.epsilon_fp32)))) begin
          done<=make_done(cmd,GC_INVALID_CMD,0); state_q<=FINISH;
        end else begin
          state_q<=INIT;
          if(cmd.opcode==GC_RESIDUAL_APPLY || !stats_valid ||
              stats_object!=cmd.src_object || stats_version!=cmd.src_version) begin
            clear_sq_q<=1; stats_valid<=0;
          end
        end
      end
      if(state_q==INIT) begin
        if(command_q.opcode==GC_RESIDUAL_APPLY) state_q<=RESIDUAL;
        else if(stats_valid&&stats_object==command_q.src_object&&stats_version==command_q.src_version) state_q<=RSQRT;
        else state_q<=SCAN;
      end
      if(response_fire) tag_valid<=0;
      if(read_fire) begin
        tag_valid<=1; read_meta.token<=command_token(command_q); read_meta.index<=VECTOR_ADDR_BITS'(issued_q);
        read_meta.row<=6'(issued_q%ROWS); read_meta.nt<=6'(issued_q/ROWS);
        read_meta.mode<=state_q==SCAN?VECTOR_SCAN:(state_q==APPLY?VECTOR_APPLY:VECTOR_RESIDUAL);
        read_delta<=state_q==RESIDUAL?work.data:512'b0;
        issued_q<=issued_q+1'b1;
        if(issued_q==VECTOR_WORDS-1) begin
          case(state_q)
            SCAN:state_q<=SCAN_DRAIN;
            APPLY:state_q<=APPLY_DRAIN;
            RESIDUAL:state_q<=RESIDUAL_DRAIN;
            default:;
          endcase
        end
      end
      if(vector_out_valid&&vector_out_ready&&state_q!=FINISH) begin
        committed_q<=committed_q+1'b1;
        if(committed_q==VECTOR_WORDS-1) begin
          if(command_q.opcode==GC_RESIDUAL_APPLY) begin
            stats_valid<=1; stats_object<=command_q.dst_object; stats_version<=command_q.dst_version;
            done<=make_done(command_q,GC_OK,16'(VECTOR_WORDS)); state_q<=FINISH;
          end else if(state_q==SCAN||state_q==SCAN_DRAIN) begin
            stats_valid<=1; stats_object<=command_q.src_object; stats_version<=command_q.src_version;
            rsqrt_pair_q<=0; state_q<=RSQRT;
          end else begin done<=make_done(command_q,GC_OK,16'(VECTOR_WORDS)); state_q<=FINISH; end
        end
      end
      if(rsqrt_valid&&rsqrt_ready) begin
        rsqrt_pair_q<=rsqrt_pair_q+1'b1; pending_rows[rsqrt_request.row0]<=1;
        if(rsqrt_request.mask[1]) pending_rows[rsqrt_request.row1]<=1;
      end
      if(state_q==RSQRT&&rsqrt_out_valid&&rsqrt_out_ready&&rsqrt_response_good) begin
        inverse_valid[rsqrt_response.row0]<=1; pending_rows[rsqrt_response.row0]<=0;
        if(rsqrt_response.mask[1]) begin
          inverse_valid[rsqrt_response.row1]<=1; pending_rows[rsqrt_response.row1]<=0;
        end
      end
      if(state_q==RSQRT&&(&inverse_valid)&&rsqrt_pair_q==(ROWS+1)/2) begin
        issued_q<=0; committed_q<=0; state_q<=APPLY;
      end
      if(done_valid&&done_ready) state_q<=IDLE;
      if(fault_event) begin
        done<=make_done(command_q,fault_status,16'(committed_q)); state_q<=FINISH;
        stats_valid<=0; abort_q<=1; tag_valid<=0;
      end
    end
  end
  assign inverse_write=!reset&&!clear&&state_q==RSQRT&&rsqrt_out_valid&&rsqrt_out_ready&&rsqrt_response_good;
  dea8_gcore_stat_ram inverse_ram (
    .clk,.enable_a(inverse_write||(read_fire&&state_q==APPLY)),
    .enable_b(inverse_write&&rsqrt_response.mask[1]),
    .write_a(inverse_write),.write_b(inverse_write&&rsqrt_response.mask[1]),
    .address_a(inverse_write?rsqrt_response.row0:6'(issued_q%ROWS)),.address_b(rsqrt_response.row1),
    .data_a(rsqrt_response.data[31:0]),.data_b(rsqrt_response.data[63:32]),
    .result_a(inverse_read_q),.result_b()
  );
endmodule
