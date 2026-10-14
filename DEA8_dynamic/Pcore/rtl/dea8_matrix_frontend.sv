import pcore_pkg::*;

// Matrix-work boundary. Seven-job and cross-block schedulers will drive it;
// this stage binds real source queues to the verified arithmetic, not a job shell.
module dea8_matrix_frontend (
  input logic clk,reset,clear,
  input logic gu_capture_ready,launch_allow,
  input logic job_valid,output logic job_ready,input compute_job_t job,input b_source_e job_b_source,
  input a_source_e job_a_source,
  output logic busy,done_valid,input logic done_ready,output compute_job_t done_work,output logic protocol_error,
  input logic a_desc_valid,output logic a_desc_ready,input a_slot_desc_t a_desc,
  input logic a_in_valid,output logic a_in_ready,input a3_beat_t a_in,
  input logic local_cmd_valid,output logic local_cmd_ready,input local_load_cmd_t local_cmd,
  output logic local_rd_valid,input logic local_rd_ready,output local_read_t local_rd,
  input logic local_out_valid,output logic local_out_ready,input local_response_t local_out_response,
  output logic source_read_closed,
  input logic b_desc_valid,output logic b_desc_ready,input b_packet_desc_t b_desc,
  input logic [1:0] hbm_valid,output logic [1:0] hbm_ready,
  input logic [1:0][B_BEAT_BITS/2-1:0] hbm_data,input b_beat_tag_t hbm_tag[0:1],
  input logic kv_valid,output logic kv_ready,input logic [B_BEAT_BITS-1:0] kv_data,input b_beat_tag_t kv_tag,
  input logic result_rd_valid,output logic result_rd_ready,
  input acc_sel_e result_rd_sel,input logic [9:0] result_rd_addr,
  output logic result_rd_data_valid,output logic [15:0][31:0] result_even_data,result_odd_data,
  input logic vpu_wr_valid,output logic vpu_wr_ready,input acc_write_t vpu_wr,
  output logic issue_valid,output pair_meta_t issue_meta,
  output logic psum_valid,output mxu_rsp_t psum_rsp,
  output logic commit_valid,output pair_meta_t commit_meta,
  output logic commit_write_valid,output acc_write_t commit_write
);
  compute_job_t ctx;
  b_source_e source_q;
  a_source_e a_source_q;
  logic [SEQ_BITS-1:0] a_next,a_occ,b_next,b_packet;
  logic [SEQ_BITS-1:0] local_next,local_occ;
  logic a_desc_legal,b_desc_legal,error_q,active,all_empty,job_fire;
  logic core_job_ready,core_busy,core_done,core_error;
  logic aq_desc_ready,bq_desc_ready,aq_valid,aq_ready,aq_in_ready,aq_available,aq_empty,aq_error;
  logic core_a_ready,core_b_ready;
  logic bq_valid,bq_ready,bq_empty,bq_error;
  logic pair_valid,pair_ready,pair_empty,pair_error;
  logic [1:0] pair_in_ready;
  logic [B_BEAT_BITS-1:0] pair_data,rx_data;
  b_beat_tag_t pair_tag,rx_tag;
  logic rx_valid,rx_ready;
  a2_t aq_entry;b4_t bq_entry;
  int expected_uses,packet_tiles;
  logic ld_cmd_ready,ld_desc_valid,ld_desc_ready,ld_data_valid,ld_data_ready,ld_empty,ld_error;
  logic local_cmd_legal,selected_desc_valid,selected_data_valid;
  logic ld_rd_valid,ld_rd_ready;
  logic aq_input_closed,bq_input_closed,ingress_closed;
  compute_job_t core_done_work;
  a_slot_desc_t ld_desc,selected_desc;
  a3_beat_t ld_data,selected_data;

  assign protocol_error=error_q||aq_error||bq_error||pair_error||core_error||ld_error;
  assign all_empty=aq_empty&&bq_empty&&pair_empty&&ld_empty;
  assign ingress_closed=ctx.m_rows==0||
    (a_next==ctx.tiles&&aq_input_closed&&local_next==(a_source_q==A_LOCAL?ctx.tiles:0)&&
     ld_empty&&b_next==ctx.tiles&&bq_input_closed&&pair_empty);
  assign job_ready=core_job_ready&&(all_empty||ingress_closed)&&!protocol_error&&job_b_source<=B_KVB;
  assign job_fire=job_valid&&job_ready;
  assign active=core_busy&&(!core_done||ctx.token!=core_done_work.token||ctx.work_seq!=core_done_work.work_seq)&&!protocol_error;
  assign busy=core_busy||!all_empty;
  assign done_valid=core_done&&(all_empty||ctx.token!=core_done_work.token||ctx.work_seq!=core_done_work.work_seq);
  assign done_work=core_done_work;
  always_comb begin
    expected_uses=ctx.mode==MAT_GU?2:(ctx.nt_per_tile?int'(ctx.tiles):1);
    packet_tiles=b_packet_tiles(source_q);
    selected_desc=a_source_q==A_LOCAL?ld_desc:a_desc;
    selected_desc_valid=a_source_q==A_LOCAL?ld_desc_valid:a_desc_valid;
    selected_data=a_source_q==A_LOCAL?ld_data:a_in;
    selected_data_valid=a_source_q==A_LOCAL?ld_data_valid:a_in_valid;
    a_desc_legal=selected_desc.token==ctx.token&&selected_desc.work_seq==ctx.work_seq&&
      selected_desc.m_rows==ctx.m_rows&&selected_desc.first_tile==a_next&&selected_desc.occurrence_seq==a_occ&&
      int'(selected_desc.uses)==expected_uses&&int'(a_next)+expected_uses<=int'(ctx.tiles);
    local_cmd_legal=local_cmd.destination.token==ctx.token&&local_cmd.destination.work_seq==ctx.work_seq&&
      local_cmd.destination.m_rows==ctx.m_rows&&local_cmd.destination.first_tile==local_next&&
      local_cmd.destination.occurrence_seq==local_occ&&int'(local_cmd.destination.uses)==expected_uses&&
      int'(local_next)+expected_uses<=int'(ctx.tiles);
    b_desc_legal=b_desc.token==ctx.token&&b_desc.work_seq==ctx.work_seq&&
      b_desc.source==source_q&&b_desc.mode==ctx.mode&&b_desc.role==ctx.role&&
      b_desc.block_id==ctx.block_id&&b_desc.first_tile==b_next&&b_desc.packet_seq==b_packet&&
      int'(b_next)+packet_tiles<=int'(ctx.tiles);
    rx_valid=active&&(source_q==B_HBM?pair_valid:kv_valid);
    rx_data=source_q==B_HBM?pair_data:kv_data;
    rx_tag=source_q==B_HBM?pair_tag:kv_tag;
  end
  assign a_desc_ready=active&&a_source_q==A_XBC&&a_desc_legal&&aq_desc_ready;
  assign a_in_ready=active&&a_source_q==A_XBC&&aq_in_ready;
  assign ld_desc_ready=active&&a_source_q==A_LOCAL&&a_desc_legal&&aq_desc_ready;
  assign ld_data_ready=active&&a_source_q==A_LOCAL&&aq_in_ready;
  assign local_cmd_ready=active&&a_source_q==A_LOCAL&&local_cmd_legal&&ld_cmd_ready;
  assign local_rd_valid=active&&a_source_q==A_LOCAL&&ld_rd_valid;
  assign ld_rd_ready=active&&a_source_q==A_LOCAL&&local_rd_ready;
  assign source_read_closed=ctx.m_rows==0||(a_source_q==A_LOCAL?
    (local_next==ctx.tiles&&ld_empty):(a_next==ctx.tiles&&aq_input_closed));
  assign aq_ready=core_a_ready&&!protocol_error;
  assign bq_ready=core_b_ready&&!protocol_error;
  assign b_desc_ready=active&&b_desc_legal&&bq_desc_ready;
  assign pair_ready=active&&source_q==B_HBM&&rx_ready;
  assign hbm_ready=pair_in_ready&{2{active&&source_q==B_HBM}};
  assign kv_ready=active&&source_q==B_KVB&&rx_ready;

  always_ff @(posedge clk)begin
    if(reset||clear)begin
      ctx<='0;source_q<=B_HBM;a_source_q<=A_XBC;a_next<=0;a_occ<=0;b_next<=0;b_packet<=0;
      local_next<=0;local_occ<=0;error_q<=0;
    end
    else begin
      if(job_fire)begin
        ctx<=job;source_q<=job_b_source;a_source_q<=job_a_source;
        a_next<=0;a_occ<=0;b_next<=0;b_packet<=0;local_next<=0;local_occ<=0;
      end
      if(active)begin
        if(selected_desc_valid&&!a_desc_legal)error_q<=1;
        if(local_cmd_valid&&a_source_q==A_LOCAL&&!local_cmd_legal)error_q<=1;
        if(b_desc_valid&&!b_desc_legal)error_q<=1;
      end
      if(selected_desc_valid&&(a_source_q==A_LOCAL?ld_desc_ready:a_desc_ready))begin
        a_next<=a_next+SEQ_BITS'(expected_uses);a_occ<=a_occ+1'b1;
      end
      if(local_cmd_valid&&local_cmd_ready)begin
        local_next<=local_next+SEQ_BITS'(expected_uses);local_occ<=local_occ+1'b1;
      end
      if(b_desc_valid&&b_desc_ready)begin b_next<=b_next+SEQ_BITS'(packet_tiles);b_packet<=b_packet+1'b1;end
    end
  end
  dea8_a_queue aq(.clk,.reset,.clear,
    .desc_valid(selected_desc_valid&&active&&a_desc_legal),.desc_ready(aq_desc_ready),.desc(selected_desc),
    .in_valid(selected_data_valid&&active),.in_ready(aq_in_ready),.in_entry(selected_data),
    .out_valid(aq_valid),.out_ready(aq_ready),.out_entry(aq_entry),
    .tile_available(aq_available),.empty(aq_empty),.input_closed(aq_input_closed),.protocol_error(aq_error),.used_slots());
  dea8_local_a_loader loader(.clk,.reset,.clear,
    .cmd_valid(local_cmd_valid&&active&&a_source_q==A_LOCAL&&local_cmd_legal),.cmd_ready(ld_cmd_ready),.cmd(local_cmd),
    .desc_valid(ld_desc_valid),.desc_ready(ld_desc_ready),.desc(ld_desc),
    .data_valid(ld_data_valid),.data_ready(ld_data_ready),.data(ld_data),
    .rd_valid(ld_rd_valid),.rd_ready(ld_rd_ready),.rd(local_rd),
    .out_valid(local_out_valid),.out_ready(local_out_ready),.out_response(local_out_response),
    .empty(ld_empty),.protocol_error(ld_error),.consumed_valid(),.consumed());
  dea8_hbm_pair pc_pair(.clk,.reset,.clear,
    .in_valid(hbm_valid&{2{active&&source_q==B_HBM}}),.in_ready(pair_in_ready),.in_data(hbm_data),.in_tag(hbm_tag),
    .out_valid(pair_valid),.out_ready(pair_ready),.out_data(pair_data),.out_tag(pair_tag),
    .empty(pair_empty),.protocol_error(pair_error));
  dea8_b_queue bq(.clk,.reset,.clear,
    .desc_valid(b_desc_valid&&active&&b_desc_legal),.desc_ready(bq_desc_ready),.desc(b_desc),
    .in_valid(rx_valid),.in_ready(rx_ready),.in_data(rx_data),.in_tag(rx_tag),
    .out_valid(bq_valid),.out_ready(bq_ready),.out_entry(bq_entry),.empty(bq_empty),.input_closed(bq_input_closed),.protocol_error(bq_error),.used_slots());
  dea8_compute_core core(.clk,.reset,.clear,.gu_capture_ready,.launch_allow,.job_valid(job_fire),.job_ready(core_job_ready),.job,
    .busy(core_busy),.done_valid(core_done),.done_work(core_done_work),.done_ready(done_ready&&done_valid),.protocol_error(core_error),
    .a_valid(aq_valid&&!protocol_error),.a_bank(aq_entry.tile_idx[0]),.a_tile_available(aq_available),
    .a(aq_entry),.a_ready(core_a_ready),.a_tile_reserve(),
    .b_valid(bq_valid&&!protocol_error),.b(bq_entry),.b_ready(core_b_ready),
    .result_rd_valid,.result_rd_ready,.result_rd_sel,.result_rd_addr,.result_rd_data_valid,
    .result_even_data,.result_odd_data,.vpu_wr_valid,.vpu_wr_ready,.vpu_wr,
    .issue_valid,.issue_meta,.psum_valid,.psum_rsp,.commit_valid,.commit_meta,.commit_write_valid,.commit_write);
endmodule
