// Seven VOPs share official FP32 IPs and bounded RAM-backed response stores.
module dea8_vpu_foreground(
 input logic clk,reset,clear,flush_valid, output logic vpu_flush_ack,
 input logic vector_valid, output logic vector_ready,
 input pcore_control_pkg::control_command_t vector_cmd,
 output logic vector_done_valid,input logic vector_done_ready,
 output pcore_control_pkg::control_unit_done_t vector_done,
 input logic vector_data_valid,output logic vector_data_ready,
 input pcore_control_pkg::control_fp_data_t vector_data,
 output logic vector_result_valid,input logic vector_result_ready,
 output pcore_control_pkg::control_quant_result_t vector_result,
 output logic vector_mem_valid,input logic vector_mem_ready,
 output pcore_control_pkg::control_memory_req_t vector_mem_req,
 input logic vector_mem_out_valid,output logic vector_mem_out_ready,
 input pcore_control_pkg::control_memory_rsp_t vector_mem_out,
 output logic acc_rd_valid,input logic acc_rd_ready,
 output pcore_pkg::acc_sel_e acc_rd_sel,output logic [9:0] acc_rd_addr,
 output pcore_control_pkg::control_token_t acc_token,
 input logic acc_data_valid,output logic acc_data_ready,
 input logic [15:0][31:0] acc_even,acc_odd,
 output logic acc_wr_valid,input logic acc_wr_ready,output pcore_pkg::acc_write_t acc_wr,
 output logic rope_req_valid,input logic rope_req_ready,
 output pcore_control_pkg::control_rope_req_t rope_req,
 input logic rope_out_valid,output logic rope_out_ready,
 input pcore_control_pkg::control_rope_rsp_t rope_out,
  input logic mask_config_valid,input logic [15:0] mask_state,mask_action,
  input logic guest_mode,input logic [4:0] guest_mul_valid,
  input logic [4:0][31:0] guest_mul_a,guest_mul_b,
  output logic [4:0] guest_mul_out_valid,output logic [4:0][31:0] guest_mul_y,
  input logic [3:0] guest_add_valid,input logic [3:0][31:0] guest_add_a,guest_add_b,
   output logic guest_add_ready,output logic [3:0] guest_add_out_valid,output logic [3:0][31:0] guest_add_y,
   output logic fabric_in_valid,input logic fabric_ready,fabric_out_valid,
   output dea8_vpu_math_pkg::pair_fp_t fabric_a,fabric_b,
   input dea8_vpu_math_pkg::pair_fp_t fabric_y,input logic [1:0] fabric_error,
   output pcore_pkg::vector_ram_port_t ram_a,ram_b,input logic [511:0] ram_data
);
 import pcore_pkg::*;import pcore_control_pkg::*;import dea8_vpu_math_pkg::*;
 import dea8_compute_config_pkg::*;
  localparam int MUL_LAT=FP_MUL_LATENCY+2,ADD_LAT=FP_ADD_LATENCY+2;
 typedef enum logic [5:0] {IDLE,MREQ,MRSP,AREQ,ARSP,PDATA,QIN,QOUT,CALC,
 SCORE0,SCORE1,WM,WAA,WL,AW,RESULT,NEXT,DONE,STREAM,XDATA,RREQ,RRSP,RMUL0,RMUL1,RSAVE,XSAVE,XRESULT,SDRAIN,MW0,MW1,GWAIT,PSTREAM,PDRAIN,GSTREAM,GDRAIN,RADD,VQWAIT,XQDRAIN,QSTREAM,QDRAIN} state_t;
 (* extract_enable = "no" *) state_t state;control_command_t cmd;
 logic error_q,read_second;logic [4:0] pair_q;logic [5:0] tile_q,base_q;
 logic factor_valid;logic [5:0] factor_tile;control_job_t factor_job;
 localparam int STAT_WORDS=(ROWS+TILE-1)/TILE;
 logic [3:0] stat_requests,stat_responses,stat_total;
 logic stat_loading,stat_response;
 logic [1:0] flush_count;logic [2:0] warmup;
 logic [15:0] state_mask_q,action_mask_q;
 logic [31:0] hist[51],factor[51],updated_stat[51],aa[51];
 pair_fp_t data_q,scaled,norm;scalars_t factors,oldls,lvalue,rowsums;
 pair_int8_t pq,aq;logic [1:0][7:0] ps,as;logic [1:0] pe,ae,se;
 logic [1:0] rv;logic enabled;
 typedef struct packed {logic [9:0] ordinal,index;logic [5:0] tile;
  logic [1:0] rv;logic [15:0] token_mask;logic last,terminal;} quant_tag_t;
  quant_tag_t quant_tag_in,quant_tags[8];
  logic [3:0] quant_tag_count;
 logic [1:0] quant_ready,quant_valid;
  logic quant_launch,quant_take,quant_sink_ready,quant_direct,quant_eligible,v_meta_ok,quant_advance;
 logic [8:0] quant_launched,quant_finished,quant_limit;
 logic [4:0] x_issue_pair;logic x_issue_half;

 logic qi,qr,qo;pair_fp_t qs;scalars_t qm,qaa;logic [1:0] qe;
 logic qk_acc_valid,qk_acc_ready,qk_take,qk_mem_take,qk_score_half;
 pair_fp_t qk_acc_score;logic [1:0][15:0] qk_acc_mask;scalars_t qk_acc_hist;
 logic [4:0] qk_acc_pair,qk_out_pair;logic [1:0] qk_out_rv;
  logic [5:0] qk_launched,qk_finished;
  logic score_held_valid;
  logic [4:0] score_held_pair;
  pair_fp_t score_held_data;
  wire score_capture_ready=!score_held_valid||(qk_mem_take&&(qk_score_half||2*score_held_pair+1>=ROWS));
 assign enabled=!reset&&!clear&&!flush_valid&&(&warmup);
 always_ff @(posedge clk)begin
  if(reset||clear||flush_valid)warmup<=0;else warmup<={warmup[1:0],1'b1};
  if(reset||clear||!flush_valid)flush_count<=0;else if(flush_count!=3)flush_count<=flush_count+1;
 end
 assign vpu_flush_ack=flush_valid&&flush_count==3;
 assign stat_loading=state==MREQ||state==MRSP;
 assign stat_response=stat_loading&&vector_mem_out_valid&&vector_mem_out_ready;
 assign stat_total=4'(cmd.function_id==VECTOR_P_POST?2*STAT_WORDS:STAT_WORDS);
 // P_POST and its following OACC_SCALE consume the same alpha generation.
 // QK_POST only updates m/aa and must not invalidate this cached alpha.
 always_ff @(posedge clk)begin
  if(reset||clear||flush_valid)begin factor_valid<=0;factor_tile<=0;factor_job<='0;end
  else if(stat_response&&vector_mem_out.token==cmd.token&&stat_responses==stat_total-1&&
    (cmd.function_id==VECTOR_P_POST||cmd.function_id==VECTOR_OACC_SCALE))begin
    factor_valid<=1;factor_tile<=cmd.tile;factor_job<=cmd.job;
  end else if(state==IDLE&&vector_valid&&vector_ready&&vector_cmd.function_id==VECTOR_AFIN_QUANT)
    factor_valid<=0;
 end
 assign rv=row_mask(pair_q);

 // A single physical 2x16 multiplier expression bank, shared by all multiply VOPs.
 pair_fp_t mul_a,mul_b,mul_y,quant_x;
 logic [1:0][15:0] quant_mask;logic [1:0] mul_error,quant_error;
 logic [15:0][31:0] cosine_q,sine_q,rope_ac,rope_as;
 pair_fp_t saved_read_data;
 logic saved_read_valid,saved_read_request,saved_read_half;
 logic [4:0] saved_read_pair;
  logic [6:0] saved_reads_issued;
  logic saved_ram_ready,saved_reply_valid;
  logic [4:0] saved_pending_pair;
  logic saved_pending_half;
 wire [6:0] saved_read_total=cmd.function_id==VECTOR_ROPE_QUANT?7'(2*PAIRS):7'(PAIRS);
 assign saved_read_request=state==XRESULT&&enabled&&!error_q&&
  saved_reads_issued<saved_read_total&&(!saved_read_valid||quant_launch)&&
    !(quant_valid[0]&&(|quant_error))&&saved_ram_ready;
 always_ff @(posedge clk)begin
  if(reset||clear||flush_valid||(state==IDLE&&vector_valid&&vector_ready))begin
   saved_read_valid<=0;saved_reads_issued<=0;saved_read_pair<=0;saved_read_half<=0;
  end else begin
    if(saved_read_request)begin
     saved_pending_pair<=x_issue_pair;saved_pending_half<=x_issue_half;
     saved_reads_issued<=saved_reads_issued+1;
    end
    if(saved_reply_valid)begin saved_read_valid<=1;saved_read_pair<=saved_pending_pair;saved_read_half<=saved_pending_half;end
    else if(quant_launch&&state==XRESULT)saved_read_valid<=0;
  end
 end
 logic [5:0] input_idx;logic output_half;
 logic [15:0] token_mask_q;
  localparam int STREAM_DEPTH=8,STREAM_AW=$clog2(STREAM_DEPTH),STREAM_BEATS=QOZ_O_TILES*PAIRS;
 logic [$clog2(STREAM_BEATS+1)-1:0] issued,received,retired,completed,drain_results,mul_launched,mul_finished,p_limit;logic drain_request;
 logic stream_pop,stream_read,stream_rsp,stream_retire_available;
 pair_fp_t stream_head_data;
 pair_int8_t stream_head_quant;
 logic [1:0][7:0] stream_head_scale;
 logic [271:0] stream_head_word;
 logic result_head_valid,result_head_pop,result_head_read,result_fifo_active,quant_ram_we;
 logic [$clog2(STREAM_BEATS+1)-1:0] result_read_index,result_head_index;
 localparam int RESULT_RL=3;
 logic [RESULT_RL-1:0] result_read_valid;
 logic [$clog2(STREAM_BEATS+1)-1:0] result_issued,result_read_tag[RESULT_RL];
 logic result_advance;
  assign result_fifo_active=state==STREAM||state==SDRAIN||state==PSTREAM||state==PDRAIN;
 assign result_head_pop=stream_pop||
  ((state==QSTREAM||state==QDRAIN)&&qk_mem_take&&(qk_score_half||2*retired+1>=ROWS))||
  ((state==PSTREAM||state==PDRAIN)&&vector_result_valid&&vector_result_ready);
 assign result_head_valid=result_read_valid[RESULT_RL-1];
 assign result_head_index=result_read_tag[RESULT_RL-1];
 assign result_advance=!result_head_valid||result_head_pop;
 assign result_read_index=result_issued;
 assign result_head_read=enabled&&result_fifo_active&&result_advance&&result_issued<completed;
 always_ff @(posedge clk)begin
  if(reset||clear||flush_valid||!result_fifo_active)begin result_read_valid<=0;result_issued<=0;end
  else if(result_advance)begin
   result_read_valid<={result_read_valid[RESULT_RL-2:0],result_head_read};
   result_read_tag[0]<=result_issued;
   for(int i=1;i<RESULT_RL;i++)result_read_tag[i]<=result_read_tag[i-1];
   if(result_head_read)result_issued<=result_issued+1;
  end
 end
 assign stream_head_quant=stream_head_word[255:0];
 assign stream_head_scale=stream_head_word[271:256];

 logic [4:0] calc_pair,receive_pair,retire_pair;logic [5:0] retire_tile;
 // Each job uses one read address per scalar store. Select addresses before
 // the wide data mux, rather than synthesizing separate P/STREAM/QK read ports.
 logic [8:0] factor_read_index,hist_read_index;
 scalars_t factor_read,hist_read;
 assign factor_read_index=cmd.function_id==VECTOR_P_POST?issued:9'(receive_pair);
 assign hist_read_index=cmd.function_id==VECTOR_P_POST?issued:received;
 always_comb begin
  factor_read='0;hist_read='0;
  for(int r=0;r<2;r++)begin
   if(2*factor_read_index+r<ROWS)factor_read[r]=factor[2*5'(factor_read_index)+r];
   if(2*hist_read_index+r<ROWS)hist_read[r]=hist[2*5'(hist_read_index)+r];
  end
 end
  logic mul_in,mul_out,mul_ready,p_in,p_out,g_in;
 logic [$clog2(STREAM_BEATS+1)-1:0] mul_index[MUL_LAT];
 scalars_t p_lvalue;logic [1:0] p_error,p_input_error;
 pair_fp_t rope_add_a,rope_add_b,rope_add_y;
 logic rope_add_in,rope_add_out,rope_mul_bad;logic [MUL_LAT-1:0] rope_part;logic [5:0] rope_mul_row[MUL_LAT];
 logic [5:0] rope_tag[ADD_LAT],rope_launched,rope_finished;
 assign rope_mul_bad=enabled&&cmd.function_id==VECTOR_ROPE_QUANT&&mul_out&&(|mul_error);
 assign rope_add_in=enabled&&cmd.function_id==VECTOR_ROPE_QUANT&&mul_out&&rope_part[MUL_LAT-1]&&!error_q&&!(|mul_error);
 always_comb begin
  rope_add_a[0]=rope_ac;rope_add_a[1]=mul_y[0];rope_add_b[1]=mul_y[1];
  for(int j=0;j<16;j++)rope_add_b[0][j]={~rope_as[j][31],rope_as[j][30:0]};
 end
 always_ff @(posedge clk)begin
  rope_mul_row[0]<=input_idx;
  for(int i=1;i<MUL_LAT;i++)rope_mul_row[i]<=rope_mul_row[i-1];
   rope_part<={rope_part[MUL_LAT-2:0],state==RMUL1&&mul_in};
  rope_tag[0]<=rope_mul_row[MUL_LAT-1];
  for(int i=1;i<ADD_LAT;i++)rope_tag[i]<=rope_tag[i-1];
 end
 pair_fp_t p_x;
 assign p_in=state==PSTREAM&&vector_data_valid&&vector_data_ready;
 assign p_x={vector_data.second,vector_data.first};
 assign g_in=state==GSTREAM&&vector_data_valid&&vector_data_ready;
  assign mul_in=(stream_rsp||p_in||g_in||state==RMUL0||state==RMUL1||state==XSAVE)&&enabled&&mul_ready;
 always_ff @(posedge clk)begin
  mul_index[0]<=received;
  for(int i=1;i<MUL_LAT;i++)mul_index[i]<=mul_index[i-1];
 end
 always_comb begin
  p_input_error=0;
  for(int r=0;r<2;r++)begin
   if(2*issued+r>=ROWS)p_input_error[r]=0;
   else for(int j=0;j<16;j++)p_input_error[r]|=nonfinite(p_x[r][j])||(p_x[r][j][31]&&(|p_x[r][j][30:0]));
  end
 end
  dea8_vpu_p_pipe #(.SHARE_ADD(1)) p_pipe(.clk,.reset,.clear(clear||flush_valid),.in_valid(p_in),.x(p_x),
  .product({mul_y[1][0],mul_y[0][0]}),.product_error(mul_error),
  .input_error(p_input_error),.out_valid(p_out),.lvalue(p_lvalue),.error(p_error),
  .rope_mode(cmd.function_id==VECTOR_ROPE_QUANT),.rope_in_valid(rope_add_in),
   .rope_a(rope_add_a),.rope_b(rope_add_b),.rope_out_valid(rope_add_out),.rope_y(rope_add_y),
   .guest_valid(guest_add_valid),.guest_a(guest_add_a),.guest_b(guest_add_b),
   .guest_ready(guest_add_ready),.guest_out_valid(guest_add_out_valid),.guest_y(guest_add_y));
 always_comb begin
  mul_a='0;mul_b='0;
  calc_pair=state==STREAM?receive_pair:pair_q;
  if(state==STREAM)begin
   mul_a={acc_odd,acc_even};
   for(int r=0;r<2;r++)for(int j=0;j<16;j++)
    if(2*calc_pair+r<ROWS)mul_b[r][j]=factor_read[r];else mul_a[r][j]=0;
  end else if(cmd.function_id==VECTOR_P_POST)begin
   for(int r=0;r<2;r++)if(2*issued+r<ROWS)begin mul_a[r][0]=factor_read[r];mul_b[r][0]=hist_read[r];end
  end else if(cmd.function_id==VECTOR_GU_POST)begin
   mul_a[0]=state==GSTREAM?vector_data.first:data_q[0];mul_b[0]=state==GSTREAM?vector_data.second:data_q[1];
  end else if(cmd.function_id==VECTOR_ROPE_QUANT)begin
   mul_a[0]=data_q[0];mul_a[1]=data_q[1];
   mul_b[0]=(state==RMUL0||state==MW0)?cosine_q:sine_q;
   mul_b[1]=(state==RMUL0||state==MW0)?sine_q:cosine_q;
  end
 end
 always_comb begin
  quant_x=data_q;quant_mask={2{16'hffff}};
  if(state==STREAM)begin quant_x=mul_y;quant_mask={16'hffff,16'hffff};
// Tail second row is already +0 at both MUL inputs; Quant sees an all-zero group.
  end else if(cmd.function_id==VECTOR_V_QUANT)begin
   quant_x={vector_data.second,vector_data.first};quant_mask={2{vector_data.token_mask}};
  end
  else if(state==XRESULT)begin
   quant_x='0;quant_mask='0;
   for(int r=0;r<2;r++)if(2*saved_read_pair+r<ROWS)begin
    quant_x[r]=saved_read_data[r];quant_mask[r]='1;
   end
  end else if(cmd.function_id==VECTOR_P_POST)begin quant_x=p_x;quant_mask={ {16{2*issued+1<ROWS}},{16{2*issued<ROWS}} };end
 end
  assign fabric_in_valid=mul_in;assign mul_ready=fabric_ready;
  assign mul_out=fabric_out_valid;assign fabric_a=mul_a;assign fabric_b=mul_b;
  assign mul_y=fabric_y;assign mul_error=fabric_error;
  assign quant_ready[1]=quant_ready[0];assign quant_valid[1]=quant_valid[0];
  dea8_vpu_pair_quant16 shared_quant(.clk,.reset,.clear(clear||flush_valid),
    .in_valid(quant_launch),.in_ready(quant_ready[0]),.advance(quant_advance),
    .x(quant_x),.lane_valid(quant_mask),.out_valid(quant_valid[0]),.out_ready(quant_sink_ready),
    .q(aq),.scale(as),.error(quant_error));
 assign quant_direct=cmd.function_id==VECTOR_V_QUANT||state==XRESULT||state==XQDRAIN;
  assign quant_eligible=quant_tags[0].ordinal<quant_limit&&!(|quant_error);
 assign quant_sink_ready=!quant_direct||!quant_eligible||vector_result_ready;
 assign quant_take=quant_valid[0]&&quant_sink_ready&&enabled;
 assign v_meta_ok=vector_data.token==cmd.token&&vector_data.job==cmd.job&&vector_data.tile==cmd.tile&&
  vector_data.index==input_idx&&vector_data.last==(input_idx==V_PACKETS_PER_TILE-1)&&
  vector_data.vector_valid==2'b11&&vector_data.token_mask==(input_idx>=24?16'h0007:16'hffff);
 always_comb begin
  quant_launch=0;quant_tag_in='0;quant_tag_in.ordinal=10'(quant_launched);
  quant_tag_in.tile=cmd.tile;quant_tag_in.token_mask='1;
  if(state==STREAM&&cmd.function_id==VECTOR_AFIN_QUANT&&mul_out&&!(|mul_error)&&!error_q)begin
   quant_launch=1;quant_tag_in.index=10'(mul_index[MUL_LAT-1]);
  end else if(p_in)begin quant_launch=1;quant_tag_in.index=10'(issued);end
  else if(state==XDATA&&cmd.function_id==VECTOR_V_QUANT&&vector_data_valid&&v_meta_ok&&!error_q)begin
   quant_launch=1;quant_tag_in.index=10'(input_idx);quant_tag_in.rv=2'b11;
   quant_tag_in.token_mask=vector_data.token_mask;quant_tag_in.last=input_idx==V_PACKETS_PER_TILE-1;quant_tag_in.terminal=quant_tag_in.last;
  end else if(state==XRESULT&&saved_read_valid&&quant_launched<(cmd.function_id==VECTOR_ROPE_QUANT?2*PAIRS:PAIRS)&&
    !error_q&&!(quant_valid[0]&&(|quant_error)))begin
   quant_launch=1;quant_tag_in.index=10'(saved_read_pair);quant_tag_in.rv=row_mask(saved_read_pair);
   quant_tag_in.last=saved_read_pair==PAIRS-1;
   quant_tag_in.terminal=quant_tag_in.last&&(cmd.function_id!=VECTOR_ROPE_QUANT||saved_read_half);
   if(cmd.function_id==VECTOR_ROPE_QUANT)quant_tag_in.tile=
    cmd.job.header.op==OP_Q_PROJ?6'(cmd.tile/2+(saved_read_half?QOZ_Q_TILES/2:0)):6'(saved_read_half);
  end
   quant_launch&=quant_ready[0]&&enabled&&quant_tag_count<8;
 end
  always_ff @(posedge clk)begin
   if(reset||clear||flush_valid)quant_tag_count<=0;
   else begin
    case({quant_launch,quant_take})
     2'b10:quant_tag_count<=quant_tag_count+1'b1;
     2'b01:quant_tag_count<=quant_tag_count-1'b1;
     default:;
    endcase
    if(quant_take)for(int i=0;i<7;i++)quant_tags[i]<=quant_tags[i+1];
    if(quant_launch)quant_tags[quant_tag_count-4'(quant_take)]<=quant_tag_in;
   end
 end
 assign pq=stream_head_quant;assign ps=stream_head_scale;assign scaled=mul_y;assign norm=mul_y;
 assign se=mul_error;assign ae=mul_error|quant_error;
 assign stream_read=state==STREAM&&acc_rd_valid&&acc_rd_ready;
 assign stream_rsp=state==STREAM&&acc_data_valid&&acc_data_ready;
 // Compare both retirement bounds in parallel; no serial min selection.
 assign stream_retire_available=result_head_valid&&(retired<completed)&&((state!=SDRAIN)||(retired<drain_results));
 assign stream_pop=(state==STREAM||state==SDRAIN)&&((cmd.function_id==VECTOR_OACC_SCALE&&acc_wr_valid&&acc_wr_ready)||
  (cmd.function_id==VECTOR_AFIN_QUANT&&vector_result_valid&&vector_result_ready));
 // Decouple ordered ACC responses from QK and from score-memory writeback.
  assign qk_acc_ready=!qk_acc_valid||(qr&&score_capture_ready);
  assign qi=qk_acc_valid&&(state==QSTREAM||state==QDRAIN)&&enabled&&score_capture_ready;
 assign qk_take=qo&&(state==QSTREAM||state==QDRAIN)&&enabled;
 assign qk_mem_take=(state==QSTREAM||state==QDRAIN)&&vector_mem_valid&&vector_mem_ready;
 always_ff @(posedge clk)begin
  if(reset||clear||flush_valid)qk_acc_valid<=0;
  else if(qk_acc_ready)begin
   qk_acc_valid<=state==QSTREAM&&acc_data_valid&&acc_data_ready;
   if(state==QSTREAM&&acc_data_valid&&acc_data_ready)begin
    qk_acc_score<={acc_odd,acc_even};qk_acc_pair<=5'(received);
    for(int r=0;r<2;r++)begin
     qk_acc_mask[r]<=0;qk_acc_hist[r]<=0;
     if(2*received+r<ROWS)begin
      qk_acc_mask[r]<=((2*received+r)==0)?state_mask_q:action_mask_q;
      qk_acc_hist[r]<=hist_read[r];
     end
    end
   end
  end
 end
  dea8_vpu_qk_row16 qk(.clk,.reset,.clear(clear||flush_valid),.in_valid(qi),.in_ready(qr),
 .in_cmd(cmd.attention_vpu),.in_pair_idx(qk_acc_pair),.in_row_valid(row_mask(qk_acc_pair)),.in_score(qk_acc_score),
 .in_effective_mask(qk_acc_mask),.in_m_old(qk_acc_hist),.out_valid(qo),.out_ready((state==QSTREAM||state==QDRAIN)&&enabled),
 .out_cmd(),.out_pair_idx(qk_out_pair),.out_row_valid(qk_out_rv),.capture_masked_score(qs),.out_row_max(),
 .out_m_new(qm),.out_aa(qaa),.out_empty_row(),.out_initial_row(),.out_numeric_error(qe));
  assign stream_head_data=score_held_data;
  always_ff @(posedge clk)begin
    if(reset||clear||flush_valid)score_held_valid<=0;
    else begin
      if(qk_mem_take&&(qk_score_half||2*score_held_pair+1>=ROWS))score_held_valid<=0;
      if(qi&&qr)begin score_held_valid<=1;score_held_pair<=qk_acc_pair;score_held_data<=qs;end
    end
  end
 assign quant_ram_we=enabled&&quant_take&&
  (cmd.function_id==VECTOR_P_POST||
   (cmd.function_id==VECTOR_AFIN_QUANT&&(state==STREAM||state==SDRAIN)&&!(|quant_error)&&
     (state==STREAM||quant_tags[0].index<drain_results)));
  dea8_vpu_stream_ram #(.DW(272),.AW(STREAM_AW)) quant_ram(.clk,.advance(result_advance),.we(quant_ram_we),
    .wr_addr(STREAM_AW'(quant_tags[0].index)),.wr_data({as,aq}),.rd_en(result_head_read),
   .rd_addr(STREAM_AW'(result_read_index)),.rd_data(stream_head_word));
 always_comb begin
  vector_ready=state==IDLE&&enabled;
  vector_done_valid=state==DONE&&enabled;vector_done.command=cmd;vector_done.error=error_q;
   vector_data_ready=((state==XDATA&&(cmd.function_id!=VECTOR_V_QUANT||quant_ready[0]))||(state==GSTREAM&&issued<ROWS&&mul_ready)||(state==PSTREAM&&issued<PAIRS&&issued-retired<STREAM_DEPTH&&mul_ready))&&enabled;
   vector_mem_valid=((stat_loading&&stat_requests<stat_total)||state==SCORE0||state==SCORE1||state==WM||state==WAA||state==WL||((state==QSTREAM||state==QDRAIN)&&score_held_valid&&retired<(state==QDRAIN?drain_results:PAIRS)))&&enabled;
  vector_mem_out_ready=stat_loading&&enabled;
  acc_rd_valid=(state==AREQ||(state==QSTREAM&&issued<PAIRS)||(state==QDRAIN&&drain_request)||(state==STREAM&&issued<STREAM_BEATS&&issued-retired<STREAM_DEPTH)||(state==SDRAIN&&drain_request))&&enabled;
   acc_data_ready=(state==ARSP||(state==QSTREAM&&received<issued&&qk_acc_ready)||(state==QDRAIN&&received<issued)||((state==STREAM||state==SDRAIN)&&received<issued&&mul_ready))&&enabled;
  acc_rd_sel=cmd.function_id==VECTOR_QK_POST?(cmd.attention_vpu.facc_bank?ACC_FACC_B:ACC_FACC_A):ACC_OACC;
  acc_rd_addr=(state==STREAM||state==SDRAIN||state==QSTREAM||state==QDRAIN)?10'(issued):10'(tile_q*PAIRS+pair_q);acc_token=cmd.token;
  acc_wr_valid=(state==AW||((state==STREAM||state==SDRAIN)&&cmd.function_id==VECTOR_OACC_SCALE&&stream_retire_available))&&enabled;acc_wr='0;acc_wr.sel=ACC_OACC;
  acc_wr.addr=(state==STREAM||state==SDRAIN)?10'(retired):acc_rd_addr;acc_wr.row_valid=(state==STREAM||state==SDRAIN)?row_mask(retire_pair):rv;
  acc_wr.data=(state==STREAM||state==SDRAIN)?stream_head_data:scaled;
  vector_result_valid=(((state==PSTREAM||state==PDRAIN)&&result_head_valid&&retired<completed&&retired<p_limit)||state==RESULT||(quant_direct&&quant_valid[0]&&quant_eligible)||((state==STREAM||state==SDRAIN)&&cmd.function_id==VECTOR_AFIN_QUANT&&stream_retire_available))&&enabled;vector_result='0;
  vector_result.token=cmd.token;vector_result.quant_axis=QUANT_FEATURE_B16;
  vector_result.tile=cmd.function_id==VECTOR_P_POST?cmd.tile:6'(tile_q);
  vector_result.index=10'(pair_q);vector_result.vector_valid=rv;vector_result.token_mask='1;
  vector_result.last=pair_q==PAIRS-1;
  for(int r=0;r<2;r++)begin
   vector_result.vector_data[r].data=cmd.function_id==VECTOR_P_POST?pq[r]:aq[r];
   vector_result.vector_data[r].scale=cmd.function_id==VECTOR_P_POST?ps[r]:as[r];
  end
  if(state==PSTREAM||state==PDRAIN)begin
   vector_result.index=10'(retired);vector_result.vector_valid=row_mask(retired);
   vector_result.last=retired==PAIRS-1;
  end else if(state==STREAM||state==SDRAIN)begin
   vector_result.tile=retire_tile;vector_result.index=10'(retire_pair);
   vector_result.vector_valid=row_mask(retire_pair);vector_result.last=retire_pair==PAIRS-1;
   for(int r=0;r<2;r++)begin vector_result.vector_data[r].data=stream_head_quant[r];
    vector_result.vector_data[r].scale=stream_head_scale[r];end
  end else if(cmd.function_id==VECTOR_V_QUANT)begin
   vector_result.tile=cmd.tile;vector_result.index=10'(input_idx);vector_result.vector_valid=2'b11;
   vector_result.quant_axis=QUANT_TOKEN_B16;vector_result.token_mask=token_mask_q;
   vector_result.last=input_idx==V_PACKETS_PER_TILE-1;
  end else if(state==XRESULT)begin
   vector_result.tile=cmd.function_id==VECTOR_ROPE_QUANT?
    (cmd.job.header.op==OP_Q_PROJ?6'(cmd.tile/2+(output_half?QOZ_Q_TILES/2:0)):6'(output_half)):cmd.tile;
  end
  if(quant_direct)begin
    vector_result.tile=quant_tags[0].tile;vector_result.index=quant_tags[0].index;
    vector_result.vector_valid=quant_tags[0].rv;vector_result.token_mask=quant_tags[0].token_mask;
    vector_result.last=quant_tags[0].last;
   vector_result.quant_axis=cmd.function_id==VECTOR_V_QUANT?QUANT_TOKEN_B16:QUANT_FEATURE_B16;
   for(int r=0;r<2;r++)begin vector_result.vector_data[r].data=aq[r];vector_result.vector_data[r].scale=as[r];end
  end
  vector_mem_req='0;vector_mem_req.token=cmd.token;vector_mem_req.index=6'(base_q);
  if(stat_loading)begin
   vector_mem_req.index=6'((stat_requests%STAT_WORDS)*TILE);
   case(cmd.function_id)
    VECTOR_QK_POST:vector_mem_req.buffer_id=WORK_M;
    VECTOR_P_POST:vector_mem_req.buffer_id=stat_requests>=STAT_WORDS?WORK_ALPHA:WORK_L;
    VECTOR_OACC_SCALE:vector_mem_req.buffer_id=WORK_ALPHA;
    default:vector_mem_req.buffer_id=WORK_RECIP;
   endcase
  end else begin
   vector_mem_req.write=1;
   case(state)
    SCORE0,SCORE1:begin
     vector_mem_req.buffer_id=WORK_SCORE;vector_mem_req.index=6'(2*pair_q+(state==SCORE1));
     vector_mem_req.mask='1;vector_mem_req.data=qs[state==SCORE1];
    end
    WM:vector_mem_req.buffer_id=WORK_M;
    WAA:vector_mem_req.buffer_id=WORK_AA;
    default:vector_mem_req.buffer_id=WORK_L;
   endcase
   if(state!=SCORE0&&state!=SCORE1)case(base_q[5:4])
    2'd0:for(int i=0;i<TILE;i++)if(0+i<ROWS)begin
     vector_mem_req.mask[i]=1;
     vector_mem_req.data[i]=state==WM?updated_stat[0+i]:(state==WAA?aa[0+i]:updated_stat[0+i]);
    end
    2'd1:for(int i=0;i<TILE;i++)if(16+i<ROWS)begin
     vector_mem_req.mask[i]=1;
     vector_mem_req.data[i]=state==WM?updated_stat[16+i]:(state==WAA?aa[16+i]:updated_stat[16+i]);
    end
    2'd2:for(int i=0;i<TILE;i++)if(32+i<ROWS)begin
     vector_mem_req.mask[i]=1;
     vector_mem_req.data[i]=state==WM?updated_stat[32+i]:(state==WAA?aa[32+i]:updated_stat[32+i]);
    end
    2'd3:for(int i=0;i<TILE;i++)if(48+i<ROWS)begin
     vector_mem_req.mask[i]=1;
     vector_mem_req.data[i]=state==WM?updated_stat[48+i]:(state==WAA?aa[48+i]:updated_stat[48+i]);
    end
   endcase
  end
  if(state==QSTREAM||state==QDRAIN)begin
   vector_mem_req.write=1;vector_mem_req.buffer_id=WORK_SCORE;
    vector_mem_req.index=6'(2*score_held_pair+int'(qk_score_half));vector_mem_req.mask='1;
   vector_mem_req.data=stream_head_data[qk_score_half];
  end
  vector_mem_req.bank=(vector_mem_req.buffer_id==WORK_ALPHA||vector_mem_req.buffer_id==WORK_SCORE)?cmd.tile[0]:0;
  rope_req_valid=state==RREQ&&enabled;rope_req='0;rope_out_ready=state==RRSP&&enabled;
  rope_req.token=cmd.token;rope_req.row=input_idx;
  rope_req.position=cmd.job.position_base+input_idx;rope_req.frequency_base=cmd.rope_frequency_base;
 end
 // QK m_new and P l_new are never live in the same job. Share their store.
 // Both readers consume old history before the matching updated result exists.
 logic stat_write_valid,stat_write_qk,stat_write_p;
 logic [4:0] stat_write_pair;scalars_t stat_write_value;
 assign stat_write_qk=qk_take&&!(|qe)&&(state==QSTREAM||qk_out_pair<drain_results);
 assign stat_write_p=(state==PSTREAM||state==PDRAIN)&&p_out&&completed<p_limit&&!(|(p_error&row_mask(completed)));
 assign stat_write_valid=stat_write_qk||stat_write_p;
 assign stat_write_pair=stat_write_qk?qk_out_pair:5'(completed);
 assign stat_write_value=stat_write_qk?qm:p_lvalue;
 // Single writer per scalar row; no variable-address multiport memory inference.
 for(genvar row=0;row<ROWS;row++)begin: scalar_rows
  always_ff @(posedge clk)begin
   if(reset||clear||flush_valid)begin updated_stat[row]<=0;aa[row]<=0;hist[row]<=0;factor[row]<=0;end
   else begin
    if(stat_response&&vector_mem_out.token==cmd.token&&stat_responses%STAT_WORDS==row/TILE)begin
     if(cmd.function_id==VECTOR_QK_POST||(cmd.function_id==VECTOR_P_POST&&stat_responses<STAT_WORDS))hist[row]<=vector_mem_out.data[row%16];
     else factor[row]<=vector_mem_out.data[row%16];
    end
   if(stat_write_qk&&qk_out_pair==row/2)aa[row]<=qaa[row%2];
   if(stat_write_valid&&stat_write_pair==row/2)updated_stat[row]<=stat_write_value[row%2];
   end
  end
 end
 // Mutually exclusive write/read phases share one true-dual-port block RAM.
 logic save_lo_valid,save_gu_stream,save_gu_wait;
 logic [5:0] save_lo_row;logic [15:0][31:0] save_lo_data;
 assign save_gu_stream=(state==GSTREAM||state==GDRAIN)&&mul_out&&!(|mul_error)&&!error_q;
 assign save_gu_wait=state==GWAIT&&mul_out&&!(|mul_error);
 always_comb begin
  save_lo_valid=0;save_lo_row=0;save_lo_data='0;
  if(rope_add_out)begin save_lo_valid=1;save_lo_row=rope_tag[ADD_LAT-1];save_lo_data=rope_add_y[0];end
  if(save_gu_stream)begin save_lo_valid=1;save_lo_row=6'(completed);save_lo_data=mul_y[0];end
  if(save_gu_wait)begin save_lo_valid=1;save_lo_row=input_idx;save_lo_data=mul_y[0];end
 end
  dea8_vpu_saved_ram saved_ram(.clk,.reset,.clear(clear||flush_valid),.ram_a,.ram_b,.ram_data,
  .lo_we(enabled&&save_lo_valid),.lo_row(save_lo_row),.lo_data(save_lo_data),
  .hi_we(enabled&&rope_add_out),.hi_row(rope_tag[ADD_LAT-1]),.hi_data(rope_add_y[1]),
   .rd_en(saved_read_request),.rd_half(x_issue_half),.rd_pair(x_issue_pair),.rd_data(saved_read_data),
   .rd_ready(saved_ram_ready),.rd_valid(saved_reply_valid));
 // Simulation assertions do not change the external interface.
 // synthesis translate_off
 ap_scalar_chunk_aligned:assert property(@(posedge clk) disable iff(reset||clear||flush_valid)
  (state==MRSP||state==WM||state==WAA||state==WL) |-> base_q[3:0]==0);
 ap_stats_exclusive:assert property(@(posedge clk) disable iff(reset||clear||flush_valid)
  !(stat_write_qk&&stat_write_p));
 ap_result_head_tag:assert property(@(posedge clk) disable iff(reset||clear||flush_valid)
  result_fifo_active&&result_head_valid |-> result_head_index==retired);
 ap_stream_capacity: assert property (@(posedge clk) disable iff(reset||clear||flush_valid)
  state==STREAM |-> retired<=received&&received<=issued&&issued-retired<=STREAM_DEPTH);
 ap_acc_req_hold: assert property (@(posedge clk) disable iff(reset||clear||flush_valid)
  acc_rd_valid&&!acc_rd_ready |=> acc_rd_valid&&$stable({acc_rd_sel,acc_rd_addr,acc_token}));
 ap_acc_write_hold: assert property (@(posedge clk) disable iff(reset||clear||flush_valid)
  acc_wr_valid&&!acc_wr_ready |=> acc_wr_valid&&$stable(acc_wr));
 ap_result_hold: assert property (@(posedge clk) disable iff(reset||clear||flush_valid)
  vector_result_valid&&!vector_result_ready |=> vector_result_valid&&$stable(vector_result));
 ap_done_arithmetic_drained: assert property (@(posedge clk) disable iff(reset||clear||flush_valid)
  vector_done_valid |-> qk_launched==qk_finished&&!qo&&!qk_acc_valid&&quant_finished==quant_launched&&!quant_valid[0]&&mul_finished==mul_launched&&rope_finished==rope_launched&&!p_out&&!rope_add_out);
 ap_rope_req_hold: assert property (@(posedge clk) disable iff(reset||clear||flush_valid)
  rope_req_valid&&!rope_req_ready |=> rope_req_valid&&$stable(rope_req));
 ap_saved_write_exclusive: assert property (@(posedge clk) disable iff(reset||clear||flush_valid)
  $onehot0({rope_add_out,save_gu_stream,save_gu_wait}));
 ap_done_hold: assert property (@(posedge clk) disable iff(reset||clear||flush_valid)
  vector_done_valid&&!vector_done_ready |=> vector_done_valid&&$stable(vector_done));
  ap_qk_capacity:assert property(@(posedge clk) disable iff(reset||clear||flush_valid)
   (state==QSTREAM||state==QDRAIN) |-> retired<=qk_launched&&qk_launched<=received&&received<=issued&&issued<=PAIRS&&qk_finished<=qk_launched);
 ap_memory_hold:assert property(@(posedge clk) disable iff(reset||clear||flush_valid)
  vector_mem_valid&&!vector_mem_ready |=> vector_mem_valid&&$stable(vector_mem_req));
 ap_qk_tags:assert property(@(posedge clk) disable iff(reset||clear||flush_valid)
  qk_take |-> qk_out_pair==5'(qk_finished)&&qk_out_rv==row_mask(qk_out_pair));
 ap_quant_capacity:assert property(@(posedge clk) disable iff(reset||clear||flush_valid)
  quant_finished<=quant_launched&&quant_launched-quant_finished<=5);
 ap_quant_pair:assert property(@(posedge clk) disable iff(reset||clear||flush_valid)
  quant_valid[0]==quant_valid[1]&&quant_ready[0]==quant_ready[1]);
 // synthesis translate_on
 always_ff @(posedge clk)begin
  if(reset||clear||flush_valid)begin
   receive_pair<=0;retire_pair<=0;retire_tile<=0;
   quant_launched<=0;quant_finished<=0;quant_limit<=STREAM_BEATS;x_issue_pair<=0;x_issue_half<=0;
   qk_launched<=0;qk_finished<=0;qk_score_half<=0;
   rope_launched<=0;rope_finished<=0;
   state<=IDLE;cmd<='0;error_q<=0;pair_q<=0;tile_q<=0;base_q<=0;read_second<=0;stat_requests<=0;stat_responses<=0;
   data_q<='0;state_mask_q<=0;action_mask_q<=0;issued<=0;received<=0;retired<=0;completed<=0;mul_launched<=0;mul_finished<=0;p_limit<=PAIRS;drain_results<=0;drain_request<=0;input_idx<=0;output_half<=0;token_mask_q<='0;cosine_q<='0;sine_q<='0;rope_ac<='0;rope_as<='0;
   // Scalar payload reset is owned by scalar_rows.
  end else begin
   if(rope_add_in)rope_launched<=rope_launched+1;
   if(rope_add_out)begin
    rope_finished<=rope_finished+1;

   end
   if(stream_rsp)receive_pair<=(receive_pair==PAIRS-1)?0:receive_pair+1;
   if(stream_pop)begin
    if(retire_pair==PAIRS-1)begin retire_pair<=0;retire_tile<=retire_tile+1;end
    else retire_pair<=retire_pair+1;
   end
   if(qi&&qr)qk_launched<=qk_launched+1;
   if(qk_take)qk_finished<=qk_finished+1;
   if(quant_launch)quant_launched<=quant_launched+1;
   if(quant_take)quant_finished<=quant_finished+1;
   if(mul_in)mul_launched<=mul_launched+1;
   if(mul_out)mul_finished<=mul_finished+1;
   case(state)
    IDLE:if(vector_valid&&vector_ready)begin
     receive_pair<=0;retire_pair<=0;retire_tile<=0;
   quant_launched<=0;quant_finished<=0;quant_limit<=STREAM_BEATS;x_issue_pair<=0;x_issue_half<=0;
   qk_launched<=0;qk_finished<=0;qk_score_half<=0;
   rope_launched<=0;rope_finished<=0;
     cmd<=vector_cmd;error_q<=0;pair_q<=0;tile_q<=0;base_q<=0;read_second<=0;stat_requests<=0;stat_responses<=0;
     state_mask_q<=mask_state;action_mask_q<=mask_action;issued<=0;received<=0;retired<=0;completed<=0;mul_launched<=0;mul_finished<=0;p_limit<=PAIRS;drain_results<=0;drain_request<=0;input_idx<=0;output_half<=0;
     case(vector_cmd.function_id)
      VECTOR_QK_POST:if(!mask_config_valid)begin error_q<=1;state<=DONE;end else state<=MREQ;
      VECTOR_P_POST,VECTOR_AFIN_QUANT:state<=MREQ;
      VECTOR_OACC_SCALE:state<=factor_valid&&factor_job==vector_cmd.job&&factor_tile==vector_cmd.tile?STREAM:MREQ;
      VECTOR_ROPE_QUANT,VECTOR_V_QUANT:state<=XDATA;
      VECTOR_GU_POST:state<=GSTREAM;
      default:begin error_q<=1;state<=DONE;end
     endcase
    end
    MREQ,MRSP:begin
     if(vector_mem_valid&&vector_mem_ready)begin
      stat_requests<=stat_requests+1;
      if(stat_requests==stat_total-1)state<=MRSP;
     end
     if(stat_response)begin
      stat_responses<=stat_responses+1;
      if(stat_responses==STAT_WORDS-1)read_second<=1;
      if(vector_mem_out.token!=cmd.token)begin error_q<=1;state<=DONE;end
      else if(stat_responses==stat_total-1)begin base_q<=0;
       state<=cmd.function_id==VECTOR_P_POST?PSTREAM:(cmd.function_id==VECTOR_QK_POST?QSTREAM:STREAM);
      end
     end
    end
    STREAM:begin
     if(stream_read)issued<=issued+1;
     if(stream_rsp)received<=received+1;
     if(mul_out)begin
      if(cmd.function_id==VECTOR_OACC_SCALE)begin
       completed<=completed+1;

      end
      if(|mul_error)begin error_q<=1;drain_results<=mul_index[MUL_LAT-1];drain_request<=acc_rd_valid&&!acc_rd_ready;state<=SDRAIN;end
     end
     if(stream_pop)begin retired<=retired+1;if(retired==STREAM_BEATS-1)state<=DONE;end
    end
    SDRAIN:begin
     if(acc_rd_valid&&acc_rd_ready)begin issued<=issued+1;drain_request<=0;end
     if(acc_data_valid&&acc_data_ready)received<=received+1;
     if(stream_pop)retired<=retired+1;
     if(received==issued&&!drain_request&&retired==drain_results&&mul_finished==mul_launched&&quant_finished==quant_launched)state<=DONE;
    end
    QSTREAM,QDRAIN:begin
     if(acc_rd_valid&&acc_rd_ready)begin issued<=issued+1;if(state==QDRAIN)drain_request<=0;end
     if(acc_data_valid&&acc_data_ready)received<=received+1;
     if(qk_take)begin
      completed<=completed+1;
      if(|qe)begin
       error_q<=1;state<=QDRAIN;
       if(state==QSTREAM||qk_out_pair<drain_results)drain_results<=9'(qk_out_pair);
       if(state==QSTREAM)drain_request<=acc_rd_valid&&!acc_rd_ready;
      end
     end
     if(qk_mem_take)begin
      if(!qk_score_half&&2*retired+1<ROWS)qk_score_half<=1;
      else begin qk_score_half<=0;retired<=retired+1;end
     end
     if(state==QSTREAM&&retired==PAIRS&&issued==PAIRS&&received==issued&&
       qk_launched==qk_finished&&!qk_acc_valid&&!qo)begin base_q<=0;state<=WM;end
     if(state==QDRAIN&&received==issued&&!drain_request&&retired==drain_results&&
       qk_launched==qk_finished&&!qk_acc_valid&&!qo)state<=DONE;
    end
    GSTREAM,GDRAIN:begin
     if(g_in)begin
      issued<=issued+1;
      if(vector_data.token!=cmd.token||vector_data.job!=cmd.job||vector_data.tile!=cmd.tile||
         vector_data.index!=issued||vector_data.last!=(issued==ROWS-1)||vector_data.vector_valid!=2'b01||vector_data.token_mask!=16'hffff)begin
       error_q<=1;state<=GDRAIN;
      end
     end
     if(mul_out)begin
      completed<=completed+1;
      if(|mul_error)begin error_q<=1;state<=GDRAIN;end
      else if(!error_q)begin

       if(completed==ROWS-1)begin pair_q<=0;state<=XRESULT;end
      end
     end
     if(state==GDRAIN&&completed==issued)state<=DONE;
    end
    XDATA:if(vector_data_valid&&vector_data_ready)begin
     if(cmd.function_id==VECTOR_V_QUANT)begin
      if(!v_meta_ok)begin error_q<=1;quant_limit<=quant_launched;state<=VQWAIT;end
      else if(input_idx==V_PACKETS_PER_TILE-1)state<=VQWAIT;
      else input_idx<=input_idx+1;
     end else if(vector_data.token!=cmd.token||vector_data.job!=cmd.job||vector_data.tile!=cmd.tile||
        vector_data.index!=input_idx||vector_data.last!=(input_idx==(cmd.function_id==VECTOR_V_QUANT?V_PACKETS_PER_TILE-1:ROWS-1))||
        vector_data.vector_valid!=(cmd.function_id==VECTOR_GU_POST?2'b01:2'b11)||
        vector_data.token_mask!=(cmd.function_id==VECTOR_V_QUANT&&input_idx>=24?16'h0007:16'hffff))begin error_q<=1;state<=cmd.function_id==VECTOR_ROPE_QUANT?RADD:DONE;end
     else begin data_q<={vector_data.second,vector_data.first};token_mask_q<=vector_data.token_mask;
      state<=cmd.function_id==VECTOR_ROPE_QUANT?RREQ:(cmd.function_id==VECTOR_GU_POST?XSAVE:RSAVE);end
    end
    RREQ:if(rope_req_ready)state<=RRSP;
    RRSP:if(rope_out_valid)begin
     if(rope_out.request!=rope_req)begin error_q<=1;state<=RADD;end
     else if(error_q||rope_mul_bad)state<=RADD;
     else begin cosine_q<=rope_out.cosine;sine_q<=rope_out.sine;state<=RMUL0;end
    end
     RMUL0:if(mul_ready)state<=RMUL1;
     RMUL1:if(mul_ready)begin
     if(input_idx==ROWS-1)state<=RADD;
     else begin input_idx<=input_idx+1;state<=XDATA;end
    end
    RADD:if(mul_finished==mul_launched&&rope_finished==rope_launched)begin
     if(error_q)state<=DONE;
     else if(rope_finished==ROWS)begin pair_q<=0;state<=XRESULT;end
    end
    XSAVE:state<=GWAIT;
    GWAIT:if(mul_out)begin
     if(|mul_error)begin error_q<=1;state<=DONE;end
     else begin
      if(input_idx==ROWS-1)begin pair_q<=0;state<=XRESULT;end
      else begin input_idx<=input_idx+1;state<=XDATA;end
     end
    end
    RSAVE:begin if(|quant_error)begin error_q<=1;state<=DONE;end else state<=RESULT;end
    XRESULT:if(saved_read_request)begin
     if(x_issue_pair==PAIRS-1)begin x_issue_pair<=0;x_issue_half<=1;end
     else x_issue_pair<=x_issue_pair+1;
    end
    XQDRAIN,VQWAIT:if(error_q&&quant_finished==quant_launched)state<=DONE;
    AREQ:if(acc_rd_ready)state<=ARSP;
    ARSP:if(acc_data_valid)begin data_q[0]<=acc_even;data_q[1]<=acc_odd;state<=cmd.function_id==VECTOR_QK_POST?QIN:CALC;end
    PSTREAM,PDRAIN:begin
     if(p_in)begin
      // Validate accepted input before allowing its result to retire.
      if(vector_data.token!=cmd.token||vector_data.job!=cmd.job||vector_data.tile!=cmd.tile||
         vector_data.index!=issued||vector_data.vector_valid!=row_mask(issued)||vector_data.last!=(issued==PAIRS-1))begin
       error_q<=1;p_limit<=issued;issued<=issued+1;state<=PDRAIN;
      end else begin
       issued<=issued+1;
      end
     end
     if(p_out)begin
      completed<=completed+1;
      if(completed<p_limit)begin
       if(|(p_error&row_mask(completed)))begin error_q<=1;p_limit<=completed;state<=PDRAIN;end
       // Per-row write enables are decoded below.
      end
     end
     if(vector_result_valid&&vector_result_ready)begin
      retired<=retired+1;
      if(retired==PAIRS-1&&!error_q)begin base_q<=0;state<=WL;end
     end
     if(state==PDRAIN&&completed==issued&&retired==p_limit&&quant_finished==quant_launched)state<=DONE;
    end
    QIN:if(qr)state<=QOUT;
    QOUT:if(qo)begin
     if(|qe)begin error_q<=1;state<=DONE;end
     else begin
      // Per-row write enables are decoded below.
      state<=SCORE0;
     end
    end
    SCORE0:if(vector_mem_ready)state<=rv[1]?SCORE1:NEXT;
    SCORE1:if(vector_mem_ready)state<=NEXT;
    CALC:begin
     if(cmd.function_id==VECTOR_OACC_SCALE)begin
      if(|se)begin error_q<=1;state<=DONE;end else state<=AW;
     end else begin if(|ae)begin error_q<=1;state<=DONE;end else state<=RESULT;end
    end
    AW:if(acc_wr_ready)state<=NEXT;
    RESULT:if(vector_result_ready)begin
     if(cmd.function_id==VECTOR_V_QUANT)begin
      if(input_idx==V_PACKETS_PER_TILE-1)state<=DONE;
      else begin input_idx<=input_idx+1;state<=XDATA;end
     end else state<=NEXT;
    end
    NEXT:begin
     if(pair_q+1<PAIRS)begin pair_q<=pair_q+1;state<=cmd.function_id==VECTOR_P_POST?PSTREAM:AREQ;end
     else if((cmd.function_id==VECTOR_OACC_SCALE||cmd.function_id==VECTOR_AFIN_QUANT)&&tile_q+1<QOZ_O_TILES)begin tile_q<=tile_q+1;pair_q<=0;state<=AREQ;end
     else begin base_q<=0;state<=cmd.function_id==VECTOR_QK_POST?WM:(cmd.function_id==VECTOR_P_POST?WL:DONE);end
    end
    WM:if(vector_mem_ready)state<=WAA;
    WAA:if(vector_mem_ready)begin if(base_q+TILE<ROWS)begin base_q<=base_q+TILE;state<=WM;end else state<=DONE;end
    WL:if(vector_mem_ready)begin if(base_q+TILE<ROWS)base_q<=base_q+TILE;else state<=DONE;end
    DONE:if(vector_done_ready)state<=IDLE;
    default:state<=IDLE;
   endcase
   // Quant results retire with the tags that entered the same stalled pipeline.
   if(quant_take)begin
    if(cmd.function_id==VECTOR_P_POST)begin
     // Payload write is performed by the synchronous quant RAM above.
    end else if(cmd.function_id==VECTOR_AFIN_QUANT&&(state==STREAM||state==SDRAIN))begin
     completed<=completed+1;
     if(|quant_error)begin
      error_q<=1;state<=SDRAIN;
       if(state==STREAM||quant_tags[0].index<drain_results)drain_results<=9'(quant_tags[0].index);
      if(state==STREAM)drain_request<=acc_rd_valid&&!acc_rd_ready;
      end else if(state==STREAM||quant_tags[0].index<drain_results)begin
      // Payload write is performed by the synchronous quant RAM above.
     end
    end else if(quant_direct)begin
     if(|quant_error)begin
       error_q<=1;if(quant_tags[0].ordinal<quant_limit)quant_limit<=9'(quant_tags[0].ordinal);
      state<=cmd.function_id==VECTOR_V_QUANT?VQWAIT:XQDRAIN;
      end else if(quant_eligible&&quant_tags[0].terminal&&!error_q)state<=DONE;
    end
   end
   // Recover products independently of issuing subsequent rows. A held ROM
   // request/response is serviced even after an arithmetic error.
   if(cmd.function_id==VECTOR_ROPE_QUANT&&mul_out)begin
    if(|mul_error)begin
     error_q<=1;
     if(state!=RREQ&&state!=RRSP)state<=RADD;
    end else if(!error_q&&!rope_part[MUL_LAT-1])begin rope_ac<=mul_y[0];rope_as<=mul_y[1];end
   end
  end
 end
endmodule
