import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// Attention integration boundary. VPU/SFU are external clients here so their
// implementation can be supplied by the owners without changing the matrix
// path. This is NOT yet the full PCore (XBC/CNET/private projections are absent).
module dea8_attention_core #(
  parameter bit USE_KVB = 0,
  parameter bit V_KEY_LANE_IS_COLUMN = 1,
  parameter int KVFIFO_DEPTH = dea8_pcore_pkg::KVFIFO_DEPTH
) (
  input logic clk,rst_n,
  input logic start_valid,resources_ready,
  output logic start_ready,busy,done_valid,
  input logic done_ready,
  input logic [HEAD_BITS-1:0] start_head,
  input logic [EPOCH_BITS-1:0] start_epoch,
  output logic matrix_busy,
  output matrix_job_t current_job,
  input logic b_valid,
  output logic b_ready,
  input logic [DW_ACT-1:0] b_data,
  input logic [SCALE_BITS-1:0] b_scale,
  input logic kvb_valid,
  output logic kvb_ready,
  input logic [DW_ACT-1:0] kvb_q,
  input logic [SCALE_BITS-1:0] kvb_e,
  input logic kvb_kind,
  input logic [BLOCK_BITS-1:0] kvb_blk_id,
  input logic [TILE_IDX_BITS-1:0] kvb_key_lane,kvb_feat_blk,
  input logic [TILE-1:0] kvb_valid_mask,
  input logic kvb_last,
  input logic [EPOCH_BITS-1:0] kvb_epoch,
  output logic vpu_key_mask_valid,
  output logic [TILE-1:0] vpu_key_mask,
  output logic kvb_protocol_error,
  input logic qoz_wr_en,
  input logic [QOZ_ADDR_BITS-1:0] qoz_wr_addr,
  input logic [DW_ACT-1:0] qoz_wr_data,
  input logic [SCALE_BITS-1:0] qoz_wr_scale,
  output logic vpu_valid,
  input logic vpu_ready,
  output vpu_job_t vpu_cmd,
  input logic vpu_done_valid,
  output logic vpu_done_ready,
  input vpu_job_t vpu_done,
  output logic sfu_valid,
  input logic sfu_ready,
  output sfu_job_t sfu_cmd,
  input logic sfu_done_valid,
  output logic sfu_done_ready,
  input sfu_job_t sfu_done,
  input logic vpu_rd_valid,
  output logic vpu_rd_ready,
  input acc_sel_e vpu_rd_sel,
  input logic [ACC_ADDR_BITS-1:0] vpu_rd_addr,
  output logic vpu_rsp_valid,
  output logic [DW_VEC-1:0] vpu_rsp_data,
  input logic vpu_wr_valid,
  output logic vpu_wr_ready,
  input acc_sel_e vpu_wr_sel,
  input logic [ACC_ADDR_BITS-1:0] vpu_wr_addr,
  input logic [TILE-1:0] vpu_wr_lane_en,
  input logic [DW_VEC-1:0] vpu_wr_data,
  input logic sbuf_wr_en,sbuf_wr_bank,
  input logic [ROW_BITS-1:0] sbuf_wr_row,
  input logic [DW_VEC-1:0] sbuf_wr_data,
  input logic sbuf_rd_en,sbuf_rd_bank,
  input logic [ROW_BITS-1:0] sbuf_rd_row,
  output logic sbuf_rsp_valid,
  output logic [DW_VEC-1:0] sbuf_rd_data,
  input logic pbuf_wr_en,pbuf_wr_bank,
  input logic [ROW_BITS-1:0] pbuf_wr_row,
  input logic [DW_ACT-1:0] pbuf_wr_data,
  input logic [SCALE_BITS-1:0] pbuf_wr_scale,
  input logic vpu_m_rd_en,
  input logic [ROW_BITS-1:0] vpu_m_rd_row,
  output logic vpu_m_rsp_valid,
  output fp_t vpu_m_rsp_data,
  input logic vpu_m_aa_wr_en,
  input logic [ROW_BITS-1:0] vpu_m_aa_wr_row,
  input fp_t vpu_m_wr_data,vpu_aa_wr_data,
  input logic vpu_l_rd_en,
  input logic [ROW_BITS-1:0] vpu_l_rd_row,
  output logic vpu_l_rsp_valid,
  output fp_t vpu_l_rsp_data,
  input logic vpu_l_wr_en,
  input logic [ROW_BITS-1:0] vpu_l_wr_row,
  input fp_t vpu_l_wr_data,
  input logic sfu_m_rd_en,
  input logic [ROW_BITS-1:0] sfu_m_rd_row,
  output logic sfu_m_rsp_valid,
  output fp_t sfu_m_rsp_data,
  input logic sfu_aa_rd_en,sfu_l_rd_en,
  input logic [ROW_BITS-1:0] sfu_aa_rd_base,sfu_l_rd_base,
  input logic [SFU_LANES-1:0] sfu_aa_rd_mask,sfu_l_rd_mask,
  output logic sfu_aa_rsp_valid,sfu_l_rsp_valid,
  output logic [SFU_LANES*FP_BITS-1:0] sfu_aa_rsp_data,sfu_l_rsp_data,
  input logic alpha_wr_en,
  input logic [ROW_BITS-1:0] alpha_wr_base,
  input logic [SFU_LANES-1:0] alpha_wr_mask,
  input logic [SFU_LANES*FP_BITS-1:0] alpha_wr_data,
  input logic vpu_alpha_rd_en,vpu_alpha_rd_bank,
  input logic [ROW_BITS-1:0] vpu_alpha_rd_row,
  output logic vpu_alpha_rsp_valid,
  output fp_t vpu_alpha_rsp_data,
  input logic recip_wr_en,
  input logic [ROW_BITS-1:0] recip_wr_base,
  input logic [SFU_LANES-1:0] recip_wr_mask,
  input logic [SFU_LANES*FP_BITS-1:0] recip_wr_data,
  input logic vpu_recip_rd_en,
  input logic [ROW_BITS-1:0] vpu_recip_rd_row,
  output logic vpu_recip_rsp_valid,
  output fp_t vpu_recip_rsp_data,
  input logic sfu_p_valid,
  output logic sfu_p_ready,
  input p_result_t sfu_p_data,
  output logic vpu_p_valid,
  input logic vpu_p_ready,
  output p_result_t vpu_p_data,
  output logic commit_valid,
  output pipe_tag_t commit_tag,
  output deq_dest_t commit_dest
);
  logic matrix_valid,matrix_ready,matrix_done_valid,matrix_done_ready;
  matrix_job_t matrix_cmd,matrix_done,a_read_job;
  logic a_rd_en;
  logic [QOZ_ADDR_BITS-1:0] a_rd_addr;
  logic [DW_ACT-1:0] a_data,q_data,pbuf_rd_data;
  logic [SCALE_BITS-1:0] a_scale,q_scale,pbuf_rd_scale;
  logic pbuf_rsp_valid;
  logic mem_rd_en,mem_wr_en;
  acc_sel_e mem_rd_sel,mem_wr_sel;
  logic [ACC_ADDR_BITS-1:0] mem_rd_addr,mem_wr_addr;
  logic [DW_VEC-1:0] mem_rd_data,mem_wr_data;
  logic [TILE-1:0] mem_wr_lane_en;
  logic [2:0] deq_reserved;
  logic [BANK_COUNT-1:0] p_ready_q,f_ready_q;
  logic [BLOCK_BITS-1:0] p_generation[0:BANK_COUNT-1],f_generation[0:BANK_COUNT-1];
  vpu_job_t vpu_active_job;
  sfu_job_t sfu_active_job;
  logic vpu_active,sfu_active;
  logic init,alpha_begin,alpha_begin_bank,alpha_end,alpha_l_done,alpha_scale_done,alpha_done_bank;
  logic recip_begin,recip_end;
  logic [BANK_COUNT-1:0] alpha_ready;
  job_context_t alpha_begin_ctx,alpha_done_ctx,vpu_alpha_rd_ctx;
  logic frontend_valid,frontend_ready;
  logic [DW_ACT-1:0] frontend_data;
  logic [SCALE_BITS-1:0] frontend_scale;
  if (USE_KVB) begin : g_kvb
    dea8_kvb_stream #(.FIFO_DEPTH(KVFIFO_DEPTH)) frontend (
      .start(init),.head(start_head),.epoch(start_epoch),
      .b_valid(frontend_valid),.b_ready(frontend_ready),
      .b_data(frontend_data),.b_scale(frontend_scale),
      .mask_block(vpu_cmd.ctx.block_id),.mask_epoch(vpu_cmd.ctx.epoch),
      .mask_valid(vpu_key_mask_valid),.mask_data(vpu_key_mask),
      .protocol_error(kvb_protocol_error),.*
    );
    assign b_ready=0;
  end else begin : g_normalized
    assign frontend_valid=b_valid;
    assign frontend_data=b_data;
    assign frontend_scale=b_scale;
    assign b_ready=frontend_ready;
    assign kvb_ready=0;
    assign kvb_protocol_error=0;
    // Legacy normalized test input does not supply a mask context.
    assign vpu_key_mask_valid=0;
    assign vpu_key_mask='0;
  end

  assign init=start_valid && start_ready;
  assign alpha_begin=sfu_valid && sfu_ready && sfu_cmd.op==SFU_ALPHA_EXP;
  assign alpha_begin_bank=sfu_cmd.alpha_bank;
  assign alpha_begin_ctx=sfu_cmd.ctx;
  assign alpha_end=sfu_done_valid && sfu_done_ready && sfu_done.op==SFU_ALPHA_EXP;
  assign alpha_l_done=vpu_done_valid && vpu_done_ready && vpu_done.op==VPU_P_POST;
  assign alpha_scale_done=vpu_done_valid && vpu_done_ready && vpu_done.op==VPU_OACC_SCALE;
  assign alpha_done_bank=vpu_done.alpha_bank;
  assign alpha_done_ctx=vpu_done.ctx;
  assign vpu_alpha_rd_ctx=vpu_active_job.ctx;
  assign recip_begin=sfu_valid && sfu_ready && sfu_cmd.op==SFU_RECIP;
  assign recip_end=sfu_done_valid && sfu_done_ready && sfu_done.op==SFU_RECIP;
  dea8_attention_state scalar_state (.*);
  dea8_p_result_link p_link (
    .job_start(vpu_valid && vpu_ready && vpu_cmd.op==VPU_P_POST),
    .job_end(alpha_l_done),.job_ctx(vpu_cmd.ctx),.*
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin vpu_active<=0;sfu_active<=0;vpu_active_job<='0;sfu_active_job<='0;end
    else begin
      if(vpu_valid && vpu_ready) begin vpu_active<=1;vpu_active_job<=vpu_cmd;end
      if(sfu_valid && sfu_ready) begin sfu_active<=1;sfu_active_job<=sfu_cmd;end
      if(vpu_done_valid && vpu_done_ready) vpu_active<=0;
      if(sfu_done_valid && sfu_done_ready) sfu_active<=0;
    end
  end

  dea8_attention_scheduler scheduler (.*);
  assign matrix_done=current_job;
  dea8_attention_matrix matrix (
    .start(init),.head(start_head),.epoch(start_epoch),.matrix_done(),
    .b_valid(frontend_valid),.b_ready(frontend_ready),
    .b_data(frontend_data),.b_scale(frontend_scale),
    .launch_valid(matrix_valid),.launch_ready(matrix_ready),.job_busy(matrix_busy),
    .job_done_valid(matrix_done_valid),.job_done_ready(matrix_done_ready),.launch_job(matrix_cmd),.*
  );
  dea8_qoz_buffer qoz (
    .clk,.wr_en(qoz_wr_en),.wr_addr(qoz_wr_addr),.wr_data(qoz_wr_data),.wr_scale(qoz_wr_scale),
    .rd_en(a_rd_en && a_read_job.op==MATRIX_QK),.rd_addr(a_rd_addr),.rd_data(q_data),.rd_scale(q_scale)
  );
  assign a_data=current_job.op==MATRIX_QK ? q_data : pbuf_rd_data;
  assign a_scale=current_job.op==MATRIX_QK ? q_scale : pbuf_rd_scale;
  dea8_attention_buffers buffers (
    .pbuf_rd_en(a_rd_en && a_read_job.op==MATRIX_PV),.pbuf_rd_bank(a_read_job.pbuf_bank),
    .pbuf_rd_row(ROW_BITS'(a_rd_addr)),.*
  );
  assign deq_reserved=matrix_busy ? (current_job.op==MATRIX_PV ? 3'b100 :
                           (current_job.facc_bank ? 3'b010 : 3'b001)) : 3'b000;
  dea8_accumulator_fabric accum (
    .deq_rd_en(mem_rd_en),.deq_rd_sel(mem_rd_sel),.deq_rd_addr(mem_rd_addr),.deq_rd_data(mem_rd_data),
    .deq_wr_en(mem_wr_en),.deq_wr_sel(mem_wr_sel),.deq_wr_addr(mem_wr_addr),
    .deq_wr_lane_en(mem_wr_lane_en),.deq_wr_data(mem_wr_data),.*
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin p_ready_q<='0; f_ready_q<='0; end
    else begin
      if(start_valid && start_ready) begin p_ready_q<='0; f_ready_q<='0; end
      if(matrix_done_valid && matrix_done_ready) begin
        if(current_job.op==MATRIX_QK) begin
          f_ready_q[current_job.facc_bank]<=1;
          f_generation[current_job.facc_bank]<=current_job.ctx.block_id;
        end else p_ready_q[current_job.pbuf_bank]<=0;
      end
      if(vpu_done_valid && vpu_done_ready) begin
        if(vpu_done.op==VPU_P_POST) begin
          p_ready_q[vpu_done.pbuf_bank]<=1;
          p_generation[vpu_done.pbuf_bank]<=vpu_done.ctx.block_id;
        end
        if(vpu_done.op==VPU_QK_POST) f_ready_q[vpu_done.facc_bank]<=0;
      end
    end
  end
  // synthesis translate_off
  initial if(USE_KVB && !V_KEY_LANE_IS_COLUMN)
    $fatal(1,"Continuous KVB requires B-column layout for both K and V");
  always @(posedge clk) if(rst_n) begin
    if(USE_KVB && vpu_valid && vpu_ready && vpu_cmd.op==VPU_QK_POST && !vpu_key_mask_valid)
      $fatal(1,"QK_POST missing KV mask context");
    if(vpu_alpha_rd_en && (!vpu_active ||
       (vpu_active_job.op!=VPU_P_POST && vpu_active_job.op!=VPU_OACC_SCALE) ||
       vpu_alpha_rd_bank!=vpu_active_job.alpha_bank)) $fatal(1,"Alpha read outside owning VPU job");
    if(vpu_recip_rd_en && (!vpu_active || vpu_active_job.op!=VPU_AFIN))
      $fatal(1,"Reciprocal read outside AFIN");
    if((sfu_m_rd_en || sbuf_rd_en) && (!sfu_active || sfu_active_job.op!=SFU_P_EXP))
      $fatal(1,"SBUF/m read outside P_EXP");
    if(vpu_m_aa_wr_en && (!vpu_active || vpu_active_job.op!=VPU_QK_POST))
      $fatal(1,"m/aa write outside QK_POST");
    if(vpu_l_wr_en && (!vpu_active || vpu_active_job.op!=VPU_P_POST))
      $fatal(1,"l write outside P_POST");
    if((alpha_wr_en || sfu_aa_rd_en) && (!sfu_active || sfu_active_job.op!=SFU_ALPHA_EXP))
      $fatal(1,"alpha/aa access outside ALPHA_EXP");
    if((recip_wr_en || sfu_l_rd_en) && (!sfu_active || sfu_active_job.op!=SFU_RECIP))
      $fatal(1,"reciprocal/l access outside RECIP");
    if(sfu_p_valid && (!sfu_active || sfu_active_job.op!=SFU_P_EXP))
      $fatal(1,"P output outside P_EXP");
    if(qoz_wr_en && matrix_busy && current_job.op==MATRIX_QK) $fatal(1,"Q modified during QK");
    if(matrix_valid && matrix_ready) begin
      if(matrix_cmd.op==MATRIX_PV && (!p_ready_q[matrix_cmd.pbuf_bank] ||
         p_generation[matrix_cmd.pbuf_bank]!=matrix_cmd.ctx.block_id)) $fatal(1,"PV PBUF generation not ready");
      if(matrix_cmd.op==MATRIX_QK && f_ready_q[matrix_cmd.facc_bank]) $fatal(1,"Unconsumed FACC overwrite");
    end
    if(vpu_valid && vpu_ready && vpu_cmd.op==VPU_QK_POST &&
       (!f_ready_q[vpu_cmd.facc_bank] || f_generation[vpu_cmd.facc_bank]!=vpu_cmd.ctx.block_id))
      $fatal(1,"VPU FACC generation not ready");
    if(pbuf_wr_en && matrix_busy && current_job.op==MATRIX_PV && pbuf_wr_bank==current_job.pbuf_bank)
      $fatal(1,"PBUF overwrite during PV");
  end
  // synthesis translate_on
endmodule
