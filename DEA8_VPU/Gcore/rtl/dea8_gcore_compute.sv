module dea8_gcore_compute (
  input logic clk,reset,clear,invalidate_stats,input_fault,
  input logic cmd_valid,output logic cmd_ready,input gcore_pkg::gcore_cmd_t cmd,
  input gcore_pkg::gcore_context_t context_data,
  input logic [7:0] header_valid,output logic [7:0] header_ready,
  input dea8_tile_link_pkg::tile_header_t header[8],
  input logic [7:0] data_valid,output logic [7:0] data_ready,
  input logic [7:0][255:0] data,output logic tile_retire,
  output logic ram_rd_valid,input logic ram_rd_ready,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] ram_rd_addr,
  input logic ram_rsp_valid,output logic ram_rsp_ready,
  input logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] ram_rsp_addr,input logic [255:0] ram_rsp_data,
  output logic ram_wr_valid,input logic ram_wr_ready,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] ram_wr_addr,output logic [255:0] ram_wr_data,
  output logic activation_valid,input logic activation_ready,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] activation_index,output logic [135:0] activation_word,
  output logic final_valid,input logic final_ready,
  output logic [511:0] final_values,
  output logic [gcore_pkg::VECTOR_ADDR_BITS-1:0] final_index,
  output logic gamma_in_use,
  output logic rsqrt_valid,input logic rsqrt_ready,output gcore_pkg::rsqrt_packet_t rsqrt_request,
  input logic rsqrt_out_valid,output logic rsqrt_out_ready,input gcore_pkg::rsqrt_packet_t rsqrt_response,
  output logic [15:0] gamma_lookup_id,input logic gamma_found,gamma_slot,
  output logic gamma_read_enable,gamma_read_slot,
  output logic [gcore_pkg::GAMMA_INDEX_BITS-1:0] gamma_read_index,input logic [31:0] gamma_read_data,
  output logic done_valid,input logic done_ready,output gcore_pkg::gcore_done_t done,
  output logic busy,stats_valid,protocol_error
);
  import gcore_pkg::*;
  import gcore_fp_pkg::*;
  import dea8_tile_link_pkg::*;
  localparam int TREE_LAT=3*ADD_LATENCY,READ_DEPTH=4;
  // Cover the native multiplier latency plus the synchronous FIFO head stages.
  localparam int WORK_DEPTH=1<<$clog2(MUL_LATENCY+4);
  typedef enum logic [3:0] {IDLE,INIT,HEADERS,REDUCING,REDUCE_DRAIN,
    SCAN,SCAN_DRAIN,INVERSE,APPLY,APPLY_DRAIN,FINISH} state_e;
  typedef enum logic [1:0] {M_SQUARE,M_FIRST,M_SECOND,M_MEAN} multiply_mode_e;
  typedef struct packed {logic [VECTOR_ADDR_BITS-1:0] index;logic [255:0] values;logic [31:0] inverse;} read_t;
  typedef struct packed {logic [VECTOR_ADDR_BITS-1:0] index;logic [511:0] values,gamma;} feedback_t;
  typedef struct packed {logic [VECTOR_ADDR_BITS-1:0] index;logic [511:0] values;} output_t;
  typedef struct packed {logic [5:0] row,nt;logic [1:0] quarter;logic [63:0] old_values;} tree_tag_t;
  state_e state;
  gcore_cmd_t command_q;
  tile_transfer_t transfer_q;
  logic residual_mode,reader_clear,read_pending,read_fire,response_fire;
  logic [VECTOR_ADDR_BITS-1:0] read_tag;
  logic [VECTOR_ADDR_BITS:0] reads_q,scan_retired,quant_retired;
  logic [10:0] acc_retired;
  logic [5:0] nt_q,written_q;
  logic [7:0] seen_q;
  logic [7:0] reduce_issued;
  logic [15:0] stats_object,stats_version,stats_context,stats_generation;
  logic source_stats_match;
  logic rd_fifo_valid,rd_fifo_ready,rd_push_ready;
  logic [$clog2(READ_DEPTH+1)-1:0] rd_count;
  read_t rd_input,rd_head;
  logic [31:0] inverse_read;
  logic gamma_slot_q;
  logic [1:0][15:0][31:0] gamma_cache;
  logic [1:0] gamma_cache_valid;
  logic [5:0] gamma_cache_nt[2];
  logic [6:0] gamma_load_nt;
  logic [3:0] gamma_load_lane,gamma_fetch_lane;
  logic gamma_fetch_valid,gamma_fetch_bank;
  logic [5:0] gamma_fetch_nt;
  logic gamma_available;
  logic [255:0] old_row_q,assembled_q;
  logic reduce_issue,arith_advance;
  tree_tag_t tree_tag[TREE_LAT],group_tag[TREE_LAT],res_tag[ADD_LATENCY];
  logic [TREE_LAT-1:0] tree_valid,group_valid;
  logic [ADD_LATENCY-1:0] res_valid,acc_valid,epsilon_valid;
  logic [3:0][7:0][31:0] tree_input;
  logic [3:0][31:0] tree_result,residual_sum;
  logic [63:0] rounded_four;
  logic [5:0] acc_rows[ADD_LATENCY],epsilon_rows[ADD_LATENCY];
  logic [MUL_LATENCY-1:0] multiply_valid;
  multiply_mode_e multiply_modes[MUL_LATENCY],multiply_mode;
  logic [VECTOR_ADDR_BITS-1:0] multiply_indices[MUL_LATENCY],multiply_index;
  logic [511:0] multiply_gammas[MUL_LATENCY],multiply_gamma;
  logic [15:0][31:0] multiply_a,multiply_b,multiply_result;
  logic multiply_issue,multiply_output,feedback_valid,feedback_ready,feedback_space,second_valid,second_ready,second_space;
  logic multiply_advance;
  logic [$clog2(WORK_DEPTH+1)-1:0] feedback_count,second_count;
  feedback_t feedback_input,feedback_head;
  output_t second_input,second_head;
  int first_inflight,second_inflight;
  logic [5:0] sq_read_address;
  logic sq_read_enable,sq_write;
  logic [31:0] sq_old,sq_result,epsilon_input,epsilon_result;
  logic [3:0][63:0] sum8_read;
  logic sum64_fetch;
  logic [63:0] sum8_current;
  tree_tag_t sum64_meta,acc_meta;
  logic acc_fetch;
  logic [31:0] sum64_current;
  logic [5:0] inverse_issue,inverse_fetch_row;
  logic inverse_fetch_valid,u_advance,inverse_write;
  logic [ROWS-1:0] inverse_valid,pending_rows;
  logic rsqrt_good,quant_fault,fault_event,numeric_fault;
  logic datapath_clear,ram_write_q,quant_valid,quant_ready,final_mode,result_fire;
  gcore_status_e fault_status;
  logic [5:0] response_row;

  assign busy=state!=IDLE;
  assign gamma_in_use=busy&&command_q.opcode==GC_NORM;
  assign final_mode=command_q.flags==NORM_FP32;
  assign final_valid=second_valid&&final_mode&&!protocol_error&&!reset&&!clear;
  assign final_values=second_head.values;
  assign final_index=second_head.index;
  assign second_ready=final_mode?final_ready&&!protocol_error:quant_ready;
  assign result_fire=(activation_valid&&activation_ready)||(final_valid&&final_ready);
  assign datapath_clear=clear||protocol_error;
  assign ram_wr_valid=ram_write_q&&!protocol_error&&!reset&&!clear;
  assign activation_valid=quant_valid&&!protocol_error&&!reset&&!clear;
  assign residual_mode=command_q.opcode==GC_RESIDUAL_APPLY;
  assign cmd_ready=state==IDLE&&!reset&&!clear&&!protocol_error&&!ram_rsp_valid&&!rsqrt_out_valid;
  assign done_valid=state==FINISH&&!reset&&!clear;
  assign source_stats_match=stats_valid&&stats_object==command_q.src_object&&stats_version==command_q.src_version&&
    stats_context==context_data.context_id&&stats_generation==context_data.generation;
  assign gamma_lookup_id=state==IDLE?cmd.norm_param_id:command_q.norm_param_id;
  assign gamma_read_slot=gamma_slot_q;
  assign gamma_read_index={gamma_load_nt[5:0],gamma_load_lane};
  assign gamma_read_enable=command_q.opcode==GC_NORM&&state!=IDLE&&state!=FINISH&&
    gamma_load_nt<HIDDEN_TILES&&!gamma_cache_valid[gamma_load_nt[0]]&&!reset&&!clear;
  assign gamma_available=gamma_cache_valid[(rd_head.index/ROWS)%2]&&
    gamma_cache_nt[(rd_head.index/ROWS)%2]==rd_head.index/ROWS;
  always_ff @(posedge clk)begin
    if(reset||clear||(cmd_valid&&cmd_ready))begin
      gamma_cache_valid<=0;gamma_load_nt<=0;gamma_load_lane<=0;gamma_fetch_valid<=0;
      gamma_fetch_lane<=0;gamma_fetch_bank<=0;gamma_fetch_nt<=0;
      for(int i=0;i<2;i++)gamma_cache_nt[i]<=0;
    end else begin
      gamma_fetch_valid<=gamma_read_enable;
      if(gamma_read_enable)begin
        gamma_fetch_lane<=gamma_load_lane;gamma_fetch_bank<=gamma_load_nt[0];gamma_fetch_nt<=gamma_load_nt[5:0];
        if(gamma_load_lane==TILE-1)begin gamma_load_lane<=0;gamma_load_nt<=gamma_load_nt+1'b1;end
        else gamma_load_lane<=gamma_load_lane+1'b1;
      end
      if(gamma_fetch_valid)begin
        gamma_cache[gamma_fetch_bank][gamma_fetch_lane]<=gamma_read_data;
        if(gamma_fetch_lane==TILE-1)begin gamma_cache_valid[gamma_fetch_bank]<=1;gamma_cache_nt[gamma_fetch_bank]<=gamma_fetch_nt;end
      end
      if(multiply_issue&&multiply_mode==M_FIRST&&multiply_index%ROWS==ROWS-1)
        gamma_cache_valid[(multiply_index/ROWS)%2]<=0;
    end
  end

  assign ram_rd_addr=VECTOR_ADDR_BITS'((state==REDUCING||(residual_mode&&(state==SCAN||state==SCAN_DRAIN)))?nt_q*ROWS+reads_q:reads_q);
  assign ram_rd_valid=(state==REDUCING||state==SCAN||state==APPLY)&&!reader_clear&&
    reads_q<((state==REDUCING||residual_mode)?ROWS:VECTOR_WORDS)&&
    (!read_pending||response_fire)&&(int'(rd_count)+int'(read_pending)<READ_DEPTH)&&!reset&&!datapath_clear;
  assign read_fire=ram_rd_valid&&ram_rd_ready;
  assign ram_rsp_ready=!reset&&!clear&&(state==IDLE||state==FINISH||reader_clear?1'b1:rd_push_ready);
  assign response_fire=ram_rsp_valid&&ram_rsp_ready;
  always_comb begin rd_input.index=read_tag;rd_input.values=ram_rsp_data;rd_input.inverse=inverse_read;end
  dea8_gcore_fifo #(.WIDTH($bits(read_t)),.DEPTH(READ_DEPTH)) read_fifo (
    .clk,.reset,.clear(datapath_clear||reader_clear),.in_valid(response_fire&&read_pending&&!reader_clear),.in_ready(rd_push_ready),
    .in_data(rd_input),.out_valid(rd_fifo_valid),.out_ready(rd_fifo_ready),.out_data(rd_head),.occupancy(rd_count)
  );
  always_ff @(posedge clk)begin
    if(reset||datapath_clear||reader_clear)begin reads_q<=0;read_pending<=0;read_tag<=0;end
    else begin
      if(response_fire)read_pending<=0;
      if(read_fire)begin reads_q<=reads_q+1'b1;read_pending<=1;read_tag<=ram_rd_addr;end
    end
  end

  always_comb begin
    header_ready=0;
    if(state==HEADERS&&!reset&&!clear&&!protocol_error)header_ready=~seen_q;
    arith_advance=!(state==REDUCING||state==REDUCE_DRAIN)||!ram_wr_valid||ram_wr_ready;
    reduce_issue=state==REDUCING&&reduce_issued<ROWS*(TILE/REDUCE_LANES)&&(&data_valid)&&arith_advance&&
      (reduce_issued%4!=0||rd_fifo_valid)&&!reset&&!clear;
    data_ready={CORES{reduce_issue&&reduce_issued[0]}};
    rd_fifo_ready=reduce_issue&&reduce_issued%4==0;
    multiply_issue=0;multiply_mode=M_SQUARE;multiply_a=0;multiply_b=0;multiply_index=rd_head.index;multiply_gamma=0;
    feedback_ready=0;
    first_inflight=0;second_inflight=0;
    for(int s=0;s<MUL_LATENCY;s++)if(multiply_valid[s])begin
      if(multiply_modes[s]==M_FIRST)first_inflight++;
      if(multiply_modes[s]==M_SECOND)second_inflight++;
    end
    if(state==SCAN||state==SCAN_DRAIN)begin
      multiply_issue=rd_fifo_valid;rd_fifo_ready=multiply_issue;
      for(int i=0;i<TILE;i++)begin multiply_a[i]={rd_head.values[16*i+:16],16'b0};multiply_b[i]=multiply_a[i];end
    end else if(state==INVERSE)begin
      // Reuse the otherwise idle first multiplier for mean(square), rather
      // than keeping a separate hand-written FP32 exponent adjustment.
      multiply_issue=inverse_fetch_valid&&u_advance;multiply_mode=M_MEAN;
      multiply_index=VECTOR_ADDR_BITS'(inverse_fetch_row);
      multiply_a[0]=sq_old;multiply_b[0]=32'h3a800000; // 1/1024
    end else if(state==APPLY||state==APPLY_DRAIN)begin
      if(feedback_valid&&int'(second_count)+second_inflight<WORK_DEPTH)begin
        multiply_issue=1;multiply_mode=M_SECOND;multiply_index=feedback_head.index;
        multiply_a=feedback_head.values;multiply_b=feedback_head.gamma;feedback_ready=1;
      end else if(rd_fifo_valid&&gamma_available&&int'(feedback_count)+first_inflight<WORK_DEPTH)begin
        multiply_issue=1;multiply_mode=M_FIRST;rd_fifo_ready=1;
        multiply_gamma=gamma_cache[(rd_head.index/ROWS)%2];
        for(int i=0;i<TILE;i++)begin multiply_a[i]={rd_head.values[16*i+:16],16'b0};multiply_b[i]=rd_head.inverse;end
      end
    end
    if(reset||datapath_clear)begin multiply_issue=0;feedback_ready=0;rd_fifo_ready=0;reduce_issue=0;data_ready=0;end
  end
  assign multiply_advance=state==INVERSE?u_advance:1'b1;
  for(genvar i=0;i<TILE;i++)begin:multipliers
    dea8_gcore_fp_mul multiply(.clk,.reset,.clear(datapath_clear),.advance(multiply_advance),.a(multiply_a[i]),.b(multiply_b[i]),.result(multiply_result[i]));
  end
  assign multiply_output=multiply_valid[MUL_LATENCY-1];
  always_ff @(posedge clk)begin
    if(reset||datapath_clear)begin
      multiply_valid<=0;
      for(int s=0;s<MUL_LATENCY;s++)begin multiply_modes[s]<=M_SQUARE;multiply_indices[s]<=0;multiply_gammas[s]<=0;end
    end else if(multiply_advance)begin
      multiply_valid[0]<=multiply_issue;multiply_modes[0]<=multiply_mode;
      multiply_indices[0]<=multiply_index;multiply_gammas[0]<=multiply_gamma;
      for(int s=1;s<MUL_LATENCY;s++)begin
        multiply_valid[s]<=multiply_valid[s-1];multiply_modes[s]<=multiply_modes[s-1];
        multiply_indices[s]<=multiply_indices[s-1];multiply_gammas[s]<=multiply_gammas[s-1];
      end
    end
  end
  always_comb begin
    feedback_input.index=multiply_indices[MUL_LATENCY-1];feedback_input.values=multiply_result;
    feedback_input.gamma=multiply_gammas[MUL_LATENCY-1];
    second_input.index=multiply_indices[MUL_LATENCY-1];second_input.values=multiply_result;
  end
  dea8_gcore_fifo #(.WIDTH($bits(feedback_t)),.DEPTH(WORK_DEPTH)) feedback_fifo (
    .clk,.reset,.clear(datapath_clear),.in_valid(multiply_output&&multiply_modes[MUL_LATENCY-1]==M_FIRST),
    .in_ready(feedback_space),.in_data(feedback_input),.out_valid(feedback_valid),.out_ready(feedback_ready),
    .out_data(feedback_head),.occupancy(feedback_count)
  );
  dea8_gcore_fifo #(.WIDTH($bits(output_t)),.DEPTH(WORK_DEPTH)) second_fifo (
    .clk,.reset,.clear(datapath_clear),.in_valid(multiply_output&&multiply_modes[MUL_LATENCY-1]==M_SECOND),
    .in_ready(second_space),.in_data(second_input),.out_valid(second_valid),.out_ready(second_ready),
    .out_data(second_head),.occupancy(second_count)
  );
  dea8_gcore_quant8 quantizer (
    .clk,.reset,.clear(datapath_clear),.in_valid(second_valid&&!final_mode),.in_ready(quant_ready),.values(second_head.values),.index(second_head.index),
    .out_valid(quant_valid),.out_ready(activation_ready&&!protocol_error),.result(activation_word),.out_index(activation_index),.numeric_fault(quant_fault)
  );

  always_comb begin
    tree_input=0;
    if(state==REDUCING||state==REDUCE_DRAIN)begin
      for(int lane=0;lane<REDUCE_LANES;lane++)for(int c=0;c<CORES;c++)
        tree_input[lane][c]=data[c][128*int'(reduce_issued[0])+32*lane+:32];
    end else begin
      for(int lane=0;lane<2;lane++)for(int j=0;j<8;j++)tree_input[lane][j]=multiply_result[8*lane+j];
      for(int j=0;j<3;j++)begin tree_input[2][2*j]=sum8_read[j][31:0];tree_input[2][2*j+1]=sum8_read[j][63:32];end
      tree_input[2][6]=sum8_current[31:0];tree_input[2][7]=sum8_current[63:32];
    end
    for(int lane=0;lane<REDUCE_LANES;lane++)rounded_four[16*lane+:16]=round_bf16(residual_sum[lane]);
  end
  for(genvar t=0;t<4;t++)begin:trees
    dea8_gcore_tree8 tree(.clk,.reset,.clear(datapath_clear),.advance(arith_advance),.data(tree_input[t]),.result(tree_result[t]));
  end
  for(genvar lane=0;lane<REDUCE_LANES;lane++)begin:residual_adders
    dea8_gcore_fp_add add(.clk,.reset,.clear(datapath_clear),.advance(arith_advance),.a(tree_result[lane]),
      .b({tree_tag[TREE_LAT-1].old_values[16*lane+:16],16'b0}),.result(residual_sum[lane]));
  end
  always_ff @(posedge clk)begin
    if(reset||datapath_clear)begin
      tree_valid<=0;group_valid<=0;res_valid<=0;old_row_q<=0;
      for(int s=0;s<TREE_LAT;s++)begin tree_tag[s]<='0;group_tag[s]<='0;end
      for(int s=0;s<ADD_LATENCY;s++)res_tag[s]<='0;
    end else if(arith_advance)begin
      tree_valid[0]<=reduce_issue||(multiply_output&&multiply_modes[MUL_LATENCY-1]==M_SQUARE);
      if(reduce_issue)begin
        tree_tag[0].row<=6'(reduce_issued/4);tree_tag[0].nt<=nt_q;tree_tag[0].quarter<=reduce_issued[1:0];
        tree_tag[0].old_values<=reduce_issued%4==0?rd_head.values[63:0]:old_row_q[64*int'(reduce_issued[1:0])+:64];
        if(reduce_issued%4==0)old_row_q<=rd_head.values;
      end else begin
        tree_tag[0].row<=6'(multiply_indices[MUL_LATENCY-1]%ROWS);
        tree_tag[0].nt<=6'(multiply_indices[MUL_LATENCY-1]/ROWS);tree_tag[0].quarter<=0;tree_tag[0].old_values<=0;
      end
      group_valid[0]<=sum64_fetch;group_tag[0]<=sum64_meta;
      for(int s=1;s<TREE_LAT;s++)begin
        tree_valid[s]<=tree_valid[s-1];tree_tag[s]<=tree_tag[s-1];
        group_valid[s]<=group_valid[s-1];group_tag[s]<=group_tag[s-1];
      end
      res_valid[0]<=tree_valid[TREE_LAT-1]&&(state==REDUCING||state==REDUCE_DRAIN);
      res_tag[0]<=tree_tag[TREE_LAT-1];
      for(int s=1;s<ADD_LATENCY;s++)begin res_valid[s]<=res_valid[s-1];res_tag[s]<=res_tag[s-1];end
    end
  end
  always_ff @(posedge clk)begin
    if(reset||datapath_clear)begin ram_write_q<=0;ram_wr_addr<=0;ram_wr_data<=0;assembled_q<=0;end
    else if(arith_advance)begin
      if(ram_wr_valid&&ram_wr_ready)ram_write_q<=0;
      if(res_valid[ADD_LATENCY-1])begin
        assembled_q[64*int'(res_tag[ADD_LATENCY-1].quarter)+:64]<=rounded_four;
        if(res_tag[ADD_LATENCY-1].quarter==3)begin
          ram_write_q<=1;ram_wr_addr<=VECTOR_ADDR_BITS'(res_tag[ADD_LATENCY-1].nt*ROWS+res_tag[ADD_LATENCY-1].row);
          ram_wr_data<={rounded_four,assembled_q[191:0]};
        end
      end
    end
  end

  for(genvar bank=0;bank<4;bank++)begin:sum8_banks
    (* ram_style="block" *) logic [63:0] memory[64];
    always_ff @(posedge clk)begin
      if(tree_valid[TREE_LAT-1]&&state!=REDUCING&&state!=REDUCE_DRAIN&&tree_tag[TREE_LAT-1].nt%4==bank)
        memory[tree_tag[TREE_LAT-1].row]<={tree_result[1],tree_result[0]};
      if(tree_valid[TREE_LAT-1]&&state!=REDUCING&&state!=REDUCE_DRAIN&&tree_tag[TREE_LAT-1].nt%4==3)
        sum8_read[bank]<=memory[tree_tag[TREE_LAT-1].row];
    end
  end
  always_ff @(posedge clk)begin
    if(reset||datapath_clear)begin sum64_fetch<=0;sum8_current<=0;sum64_meta<='0;acc_fetch<=0;sum64_current<=0;acc_meta<='0;end
    else begin
      sum64_fetch<=tree_valid[TREE_LAT-1]&&state!=REDUCING&&state!=REDUCE_DRAIN&&tree_tag[TREE_LAT-1].nt%4==3;
      sum8_current<={tree_result[1],tree_result[0]};sum64_meta<=tree_tag[TREE_LAT-1];
      acc_fetch<=group_valid[TREE_LAT-1];sum64_current<=tree_result[2];acc_meta<=group_tag[TREE_LAT-1];
    end
  end
  assign u_advance=!epsilon_valid[ADD_LATENCY-1]||rsqrt_ready;
  assign sq_read_enable=group_valid[TREE_LAT-1]||(state==INVERSE&&u_advance&&inverse_issue<ROWS);
  assign sq_read_address=group_valid[TREE_LAT-1]?group_tag[TREE_LAT-1].row:inverse_issue;
  assign sq_write=acc_valid[ADD_LATENCY-1]&&!protocol_error;
  dea8_gcore_stat_ram square_sum_ram (
    .clk,.enable_a(sq_write),.write_a(sq_write),.address_a(acc_rows[ADD_LATENCY-1]),.data_a(sq_result),.result_a(),
    .enable_b(sq_read_enable),.write_b(1'b0),.address_b(sq_read_address),.data_b(32'b0),.result_b(sq_old)
  );
  dea8_gcore_fp_add accumulator(.clk,.reset,.clear(datapath_clear),.advance(1'b1),.a(acc_meta.nt<4?32'b0:sq_old),.b(sum64_current),.result(sq_result));
  always_ff @(posedge clk)begin
    if(reset||datapath_clear)begin acc_valid<=0;for(int s=0;s<ADD_LATENCY;s++)acc_rows[s]<=0;end
    else begin
      acc_valid[0]<=acc_fetch;acc_rows[0]<=acc_meta.row;
      for(int s=1;s<ADD_LATENCY;s++)begin acc_valid[s]<=acc_valid[s-1];acc_rows[s]<=acc_rows[s-1];end
    end
  end
  assign epsilon_input=multiply_result[0];
  dea8_gcore_fp_add epsilon_add(.clk,.reset,.clear(datapath_clear),.advance(u_advance),.a(epsilon_input),.b(command_q.epsilon_fp32),.result(epsilon_result));
  always_ff @(posedge clk)begin
    if(reset||datapath_clear||state!=INVERSE)begin
      epsilon_valid<=0;inverse_issue<=0;inverse_fetch_valid<=0;inverse_fetch_row<=0;
      for(int s=0;s<ADD_LATENCY;s++)epsilon_rows[s]<=0;
    end else if(u_advance)begin
      inverse_fetch_valid<=inverse_issue<ROWS;
      if(inverse_issue<ROWS)begin inverse_fetch_row<=inverse_issue;inverse_issue<=inverse_issue+1'b1;end
      epsilon_valid[0]<=multiply_output&&multiply_modes[MUL_LATENCY-1]==M_MEAN;
      epsilon_rows[0]<=6'(multiply_indices[MUL_LATENCY-1]);
      for(int s=1;s<ADD_LATENCY;s++)begin epsilon_valid[s]<=epsilon_valid[s-1];epsilon_rows[s]<=epsilon_rows[s-1];end
    end
  end
  always_comb begin
    rsqrt_request='0;rsqrt_request.token=command_token(command_q);rsqrt_request.row0=epsilon_rows[ADD_LATENCY-1];
    rsqrt_request.row1=rsqrt_request.row0+1'b1;rsqrt_request.mask=2'b01;rsqrt_request.data={32'b0,epsilon_result};
    response_row=rsqrt_response.row0;
    rsqrt_good=state==INVERSE&&rsqrt_response.token==command_token(command_q)&&response_row<ROWS&&
      rsqrt_response.mask==1&&rsqrt_response.row1==response_row+1&&rsqrt_response.data[63:32]==0;
    if(response_row<ROWS)rsqrt_good=rsqrt_good&&pending_rows[response_row]&&!inverse_valid[response_row];
    rsqrt_good=rsqrt_good&&finite32(rsqrt_response.data[31:0])&&!rsqrt_response.data[31]&&rsqrt_response.data[30:0]!=0;
  end
  assign rsqrt_valid=state==INVERSE&&epsilon_valid[ADD_LATENCY-1]&&!reset&&!datapath_clear;
  assign rsqrt_out_ready=!reset&&!clear;
  assign inverse_write=rsqrt_out_valid&&rsqrt_out_ready&&rsqrt_good;
  dea8_gcore_stat_ram inverse_ram (
    .clk,.enable_a(inverse_write),.write_a(inverse_write),.address_a(response_row),.data_a(rsqrt_response.data[31:0]),.result_a(),
    .enable_b(read_fire&&state==APPLY),.write_b(1'b0),.address_b(6'(reads_q%ROWS)),.data_b(32'b0),.result_b(inverse_read)
  );

  always_comb begin
    numeric_fault=0;fault_event=0;fault_status=GC_SOURCE_PROTOCOL;
    if(multiply_output)for(int i=0;i<TILE;i++)if(!finite32(multiply_result[i]))numeric_fault=1;
    if(tree_valid[TREE_LAT-1])begin
      if(!finite32(tree_result[0])||!finite32(tree_result[1]))numeric_fault=1;
      if(state==REDUCING||state==REDUCE_DRAIN)
        if(!finite32(tree_result[2])||!finite32(tree_result[3]))numeric_fault=1;
    end
    if(group_valid[TREE_LAT-1]&&!finite32(tree_result[2]))numeric_fault=1;
    if(sq_write&&!finite32(sq_result))numeric_fault=1;
    if(res_valid[ADD_LATENCY-1])for(int i=0;i<REDUCE_LANES;i++)
      if(!finite32(residual_sum[i])||rounded_four[16*i+7+:8]==8'hff)numeric_fault=1;
    if(rsqrt_valid&&(!finite32(epsilon_result)||epsilon_result[31]||epsilon_result[30:0]==0))numeric_fault=1;
    if((state==APPLY||state==APPLY_DRAIN)&&quant_fault)numeric_fault=1;
    if(state!=IDLE&&state!=FINISH)begin
      fault_event=input_fault||invalidate_stats||numeric_fault;
      if(numeric_fault)fault_status=GC_NUMERIC_FAULT;
      if(response_fire&&(!read_pending||ram_rsp_addr!=read_tag)&&!reader_clear)fault_event=1;
      if(rsqrt_out_valid&&rsqrt_out_ready&&!rsqrt_good)fault_event=1;
      if(multiply_output&&multiply_modes[MUL_LATENCY-1]==M_FIRST&&!feedback_space)fault_event=1;
      if(multiply_output&&multiply_modes[MUL_LATENCY-1]==M_SECOND&&!second_space)fault_event=1;
      if(activation_valid&&activation_ready&&activation_index!=quant_retired)fault_event=1;
      if(final_valid&&final_ready&&final_index!=quant_retired)fault_event=1;
      for(int c=0;c<CORES;c++)if(header_valid[c]&&header_ready[c])begin
        if(header[c].source_id!=c||header[c].rows!=ROWS||header[c].columns!=TILE||header[c].reserved!=0||
          header[c].kind!=(command_q.pcore_op==pcore_pkg::OP_O_PROJ?TILE_O:TILE_DOWN)||header[c].layout!=LAYOUT_FP_ROWS||
          header[c].transfer_id!=transfer_q.transfer_id||header[c].transfer_epoch!=transfer_q.transfer_epoch||
          header[c].destination_id!=transfer_q.destination_id||header[c].token_origin!=transfer_q.token_origin||
          header[c].tile_seq!=nt_q||header[c].column_base!=nt_q*TILE)fault_event=1;
      end
    end
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      state<=IDLE;command_q<='0;transfer_q<='0;reader_clear<=0;nt_q<=0;written_q<=0;
      seen_q<=0;reduce_issued<=0;scan_retired<=0;acc_retired<=0;quant_retired<=0;
      stats_valid<=0;stats_object<=0;stats_version<=0;stats_context<=0;stats_generation<=0;
      inverse_valid<=0;pending_rows<=0;gamma_slot_q<=0;tile_retire<=0;done<='0;protocol_error<=0;
    end else begin
      reader_clear<=0;tile_retire<=0;
      if(invalidate_stats)stats_valid<=0;
      if(rsqrt_out_valid&&rsqrt_out_ready&&!rsqrt_good)protocol_error<=1;
      if(cmd_valid&&cmd_ready)begin
        command_q<=cmd;nt_q<=0;seen_q<=0;reduce_issued<=0;written_q<=0;reader_clear<=1;
        scan_retired<=0;acc_retired<=0;quant_retired<=0;inverse_valid<=0;pending_rows<=0;
        gamma_slot_q<=gamma_slot;
        transfer_q<=cmd.pcore_op==pcore_pkg::OP_O_PROJ?context_data.o_transfer:context_data.down_transfer;
        if((cmd.opcode!=GC_NORM&&cmd.opcode!=GC_RESIDUAL_APPLY)||
          (cmd.opcode==GC_RESIDUAL_APPLY&&cmd.pcore_op!=pcore_pkg::OP_O_PROJ&&cmd.pcore_op!=pcore_pkg::OP_DOWN_PROJ))begin
          done<=make_done(cmd,GC_INVALID_CMD,0);state<=FINISH;
        end else if(cmd.opcode==GC_NORM&&(!finite32(cmd.epsilon_fp32)||cmd.epsilon_fp32[31]||cmd.epsilon_fp32[30:0]==0))begin
          done<=make_done(cmd,GC_INVALID_CMD,0);state<=FINISH;
        end else if(cmd.opcode==GC_NORM&&!gamma_found)begin done<=make_done(cmd,GC_PRECONDITION,0);state<=FINISH;end
        else begin state<=INIT;if(cmd.opcode==GC_RESIDUAL_APPLY)stats_valid<=0;end
      end
      if(state==INIT)begin
        if(residual_mode)state<=HEADERS;
        else if(source_stats_match)state<=INVERSE;
        else begin stats_valid<=0;state<=SCAN;end
      end
      for(int c=0;c<CORES;c++)if(header_valid[c]&&header_ready[c])seen_q[c]<=1;
      if(state==HEADERS&&(&seen_q))begin state<=REDUCING;reader_clear<=1;end
      if(reduce_issue)begin reduce_issued<=reduce_issued+1'b1;if(reduce_issued==ROWS*4-1)state<=REDUCE_DRAIN;end
      if(ram_wr_valid&&ram_wr_ready)begin
        written_q<=written_q+1'b1;
        if(written_q==ROWS-1)begin state<=SCAN;reader_clear<=1;scan_retired<=0;acc_retired<=0;end
      end
      if(state==SCAN&&!reader_clear&&reads_q==(residual_mode?ROWS:VECTOR_WORDS))state<=SCAN_DRAIN;
      if(tree_valid[TREE_LAT-1]&&(state==SCAN||state==SCAN_DRAIN))scan_retired<=scan_retired+1'b1;
      if(sq_write)acc_retired<=acc_retired+1'b1;
      if((state==SCAN||state==SCAN_DRAIN)&&scan_retired==(residual_mode?ROWS:VECTOR_WORDS)&&
        (residual_mode?(nt_q%4!=3||acc_retired==ROWS):(acc_retired==ROWS*HIDDEN_TILES/4)))begin
        if(residual_mode)begin
          tile_retire<=1;
          if(nt_q==HIDDEN_TILES-1)begin
            stats_valid<=1;stats_object<=command_q.dst_object;stats_version<=command_q.dst_version;
            stats_context<=context_data.context_id;stats_generation<=context_data.generation;
            done<=make_done(command_q,GC_OK,16'(VECTOR_WORDS));state<=FINISH;
          end else begin
            nt_q<=nt_q+1'b1;seen_q<=0;reduce_issued<=0;written_q<=0;state<=HEADERS;
          end
        end else begin
          stats_valid<=1;stats_object<=command_q.src_object;stats_version<=command_q.src_version;
          stats_context<=context_data.context_id;stats_generation<=context_data.generation;state<=INVERSE;
        end
      end
      if(rsqrt_valid&&rsqrt_ready)pending_rows[rsqrt_request.row0]<=1;
      if(inverse_write)begin inverse_valid[response_row]<=1;pending_rows[response_row]<=0;end
      if(state==INVERSE&&(&inverse_valid))begin state<=APPLY;reader_clear<=1;end
      if(state==APPLY&&!reader_clear&&reads_q==VECTOR_WORDS)state<=APPLY_DRAIN;
      if(result_fire)begin
        quant_retired<=quant_retired+1'b1;
        if(quant_retired==VECTOR_WORDS-1)begin done<=make_done(command_q,GC_OK,16'(VECTOR_WORDS));state<=FINISH;end
      end
      if(done_valid&&done_ready)state<=IDLE;
      if(fault_event)begin
        done<=make_done(command_q,fault_status,16'(quant_retired));state<=FINISH;stats_valid<=0;protocol_error<=1;
      end
    end
  end
endmodule
