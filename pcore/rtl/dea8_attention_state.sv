import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// PCore-owned scalar RFs. 51 rows of m/aa/l/recip plus two alpha generations.
// All reads have one-clock latency and no response backpressure.
// SFU pair ports use an EVEN base row and adjacent row+1; mask 01 at row50.
// These small multi-read RFs are expressed as registers, not a single BRAM.
module dea8_attention_state (
  input logic clk,rst_n,init,
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
  input logic alpha_begin,alpha_begin_bank,
  input job_context_t alpha_begin_ctx,
  input logic alpha_end,
  input logic alpha_wr_en,
  input logic [ROW_BITS-1:0] alpha_wr_base,
  input logic [SFU_LANES-1:0] alpha_wr_mask,
  input logic [SFU_LANES*FP_BITS-1:0] alpha_wr_data,
  input logic vpu_alpha_rd_en,vpu_alpha_rd_bank,
  input logic [ROW_BITS-1:0] vpu_alpha_rd_row,
  input job_context_t vpu_alpha_rd_ctx,
  output logic vpu_alpha_rsp_valid,
  output fp_t vpu_alpha_rsp_data,
  input logic alpha_l_done,alpha_scale_done,alpha_done_bank,
  input job_context_t alpha_done_ctx,
  output logic [BANK_COUNT-1:0] alpha_ready,
  input logic recip_begin,recip_end,recip_wr_en,
  input logic [ROW_BITS-1:0] recip_wr_base,
  input logic [SFU_LANES-1:0] recip_wr_mask,
  input logic [SFU_LANES*FP_BITS-1:0] recip_wr_data,
  input logic vpu_recip_rd_en,
  input logic [ROW_BITS-1:0] vpu_recip_rd_row,
  output logic vpu_recip_rsp_valid,
  output fp_t vpu_recip_rsp_data
);
  fp_t m[0:SUFFIX_LEN-1],aa[0:SUFFIX_LEN-1],l[0:SUFFIX_LEN-1],recip_l[0:SUFFIX_LEN-1];
  fp_t alpha[0:BANK_COUNT-1][0:SUFFIX_LEN-1];
  job_context_t alpha_ctx[0:BANK_COUNT-1];
  logic initialized,alpha_writing,alpha_write_bank,recip_writing,recip_ready;
  logic [BANK_COUNT-1:0] alpha_owned,l_consumed,scale_consumed;
  logic [SUFFIX_LEN-1:0] aa_valid,alpha_written,recip_written;
  logic [SUFFIX_LEN-1:0] alpha_write_bits,recip_write_bits;

  always_comb begin
    alpha_write_bits='0; recip_write_bits='0;
    for(int n=0;n<SFU_LANES;n++) begin
      if(alpha_wr_en && alpha_wr_mask[n] && alpha_wr_base+n<SUFFIX_LEN)
        alpha_write_bits[alpha_wr_base+n]=1;
      if(recip_wr_en && recip_wr_mask[n] && recip_wr_base+n<SUFFIX_LEN)
        recip_write_bits[recip_wr_base+n]=1;
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      initialized<=0; alpha_writing<=0; alpha_write_bank<=0; recip_writing<=0; recip_ready<=0;
      alpha_ready<='0; alpha_owned<='0; l_consumed<='0; scale_consumed<='0;
      aa_valid<='0; alpha_written<='0; recip_written<='0;
      vpu_m_rsp_valid<=0;vpu_l_rsp_valid<=0;sfu_m_rsp_valid<=0;
      sfu_aa_rsp_valid<=0;sfu_l_rsp_valid<=0;vpu_alpha_rsp_valid<=0;vpu_recip_rsp_valid<=0;
    end else if(init) begin
      initialized<=1; alpha_writing<=0; recip_writing<=0; recip_ready<=0;
      alpha_ready<='0;alpha_owned<='0;l_consumed<='0;scale_consumed<='0;
      aa_valid<='0;alpha_written<='0;recip_written<='0;
      for(int r=0;r<SUFFIX_LEN;r++) begin m[r]<=32'hff800000;l[r]<='0;end
      vpu_m_rsp_valid<=0;vpu_l_rsp_valid<=0;sfu_m_rsp_valid<=0;
      sfu_aa_rsp_valid<=0;sfu_l_rsp_valid<=0;vpu_alpha_rsp_valid<=0;vpu_recip_rsp_valid<=0;
    end else begin
      vpu_m_rsp_valid<=vpu_m_rd_en;vpu_l_rsp_valid<=vpu_l_rd_en;sfu_m_rsp_valid<=sfu_m_rd_en;
      sfu_aa_rsp_valid<=sfu_aa_rd_en;sfu_l_rsp_valid<=sfu_l_rd_en;
      vpu_alpha_rsp_valid<=vpu_alpha_rd_en;vpu_recip_rsp_valid<=vpu_recip_rd_en;
      if(vpu_m_rd_en) vpu_m_rsp_data<=m[vpu_m_rd_row];
      if(vpu_l_rd_en) vpu_l_rsp_data<=l[vpu_l_rd_row];
      if(sfu_m_rd_en) sfu_m_rsp_data<=m[sfu_m_rd_row];
      if(vpu_m_aa_wr_en) begin
        m[vpu_m_aa_wr_row]<=vpu_m_wr_data;aa[vpu_m_aa_wr_row]<=vpu_aa_wr_data;
        aa_valid[vpu_m_aa_wr_row]<=1;
      end
      if(vpu_l_wr_en) l[vpu_l_wr_row]<=vpu_l_wr_data;
      for(int n=0;n<SFU_LANES;n++) begin
        if(sfu_aa_rd_en) sfu_aa_rsp_data[n*FP_BITS+:FP_BITS]<=
          sfu_aa_rd_mask[n] ? aa[sfu_aa_rd_base+n] : '0;
        if(sfu_l_rd_en) sfu_l_rsp_data[n*FP_BITS+:FP_BITS]<=
          sfu_l_rd_mask[n] ? l[sfu_l_rd_base+n] : '0;
        if(alpha_wr_en && alpha_wr_mask[n]) alpha[alpha_write_bank][alpha_wr_base+n]<=alpha_wr_data[n*FP_BITS+:FP_BITS];
        if(recip_wr_en && recip_wr_mask[n]) recip_l[recip_wr_base+n]<=recip_wr_data[n*FP_BITS+:FP_BITS];
      end
      if(alpha_begin) begin
        alpha_writing<=1;alpha_write_bank<=alpha_begin_bank;alpha_written<='0;
        alpha_owned[alpha_begin_bank]<=1;alpha_ready[alpha_begin_bank]<=0;
        alpha_ctx[alpha_begin_bank]<=alpha_begin_ctx;
        l_consumed[alpha_begin_bank]<=0;
        scale_consumed[alpha_begin_bank]<=alpha_begin_ctx.block_id==0;
      end
      if(alpha_wr_en) alpha_written<=alpha_written | alpha_write_bits;
      if(alpha_end) begin alpha_writing<=0;alpha_ready[alpha_write_bank]<=1;aa_valid<='0;end
      if(vpu_alpha_rd_en) vpu_alpha_rsp_data<=alpha[vpu_alpha_rd_bank][vpu_alpha_rd_row];
      if(alpha_l_done) l_consumed[alpha_done_bank]<=1;
      if(alpha_scale_done) scale_consumed[alpha_done_bank]<=1;
      for(int b=0;b<BANK_COUNT;b++) begin
        if(alpha_ready[b] && (l_consumed[b] || (alpha_l_done && alpha_done_bank==b)) &&
           (scale_consumed[b] || (alpha_scale_done && alpha_done_bank==b))) begin
          alpha_owned[b]<=0;alpha_ready[b]<=0;
        end
      end
      if(recip_begin) begin recip_writing<=1;recip_ready<=0;recip_written<='0;end
      if(recip_wr_en) recip_written<=recip_written | recip_write_bits;
      if(recip_end) begin recip_writing<=0;recip_ready<=1;end
      if(vpu_recip_rd_en) vpu_recip_rsp_data<=recip_l[vpu_recip_rd_row];
    end
  end
  // synthesis translate_off
  task automatic check_row(input logic en,input logic [ROW_BITS-1:0] row);
    if(en && row>=SUFFIX_LEN) $fatal(1,"Scalar RF row out of range");
  endtask
  task automatic check_pair(input logic en,input logic [ROW_BITS-1:0] base,
                            input logic [SFU_LANES-1:0] mask);
    if(en && (base>=SUFFIX_LEN || base[0] || mask!=(base==SUFFIX_LEN-1 ? 2'b01 : 2'b11)))
      $fatal(1,"Scalar pair base/mask invalid");
  endtask
  always @(posedge clk) if(rst_n && !init) begin
    if(!initialized && (vpu_m_rd_en || vpu_l_rd_en || sfu_m_rd_en || sfu_aa_rd_en ||
       sfu_l_rd_en || vpu_m_aa_wr_en || vpu_l_wr_en || alpha_begin || recip_begin))
      $fatal(1,"Scalar RF used before initialization");
    check_row(vpu_m_rd_en,vpu_m_rd_row);check_row(vpu_l_rd_en,vpu_l_rd_row);
    check_row(vpu_m_aa_wr_en,vpu_m_aa_wr_row);check_row(vpu_l_wr_en,vpu_l_wr_row);
    check_row(sfu_m_rd_en,sfu_m_rd_row);check_row(vpu_alpha_rd_en,vpu_alpha_rd_row);
    check_row(vpu_recip_rd_en,vpu_recip_rd_row);
    check_pair(sfu_aa_rd_en,sfu_aa_rd_base,sfu_aa_rd_mask);check_pair(sfu_l_rd_en,sfu_l_rd_base,sfu_l_rd_mask);
    check_pair(alpha_wr_en,alpha_wr_base,alpha_wr_mask);check_pair(recip_wr_en,recip_wr_base,recip_wr_mask);
    if(alpha_begin && (alpha_owned[alpha_begin_bank] || alpha_writing)) $fatal(1,"Alpha generation overwrite");
    if(alpha_wr_en && (!alpha_writing || |(alpha_written & alpha_write_bits))) $fatal(1,"Alpha write without lease or duplicate row");
    if(alpha_end && (!alpha_writing || !( &(alpha_written | alpha_write_bits)))) $fatal(1,"Alpha completed before 51 writes");
    if(vpu_alpha_rd_en && (!alpha_ready[vpu_alpha_rd_bank] || vpu_alpha_rd_ctx!==alpha_ctx[vpu_alpha_rd_bank]))
      $fatal(1,"Alpha read generation mismatch");
    if((alpha_l_done || alpha_scale_done) && (!alpha_ready[alpha_done_bank] || alpha_done_ctx!==alpha_ctx[alpha_done_bank]))
      $fatal(1,"Alpha release generation mismatch");
    if((alpha_l_done && l_consumed[alpha_done_bank]) || (alpha_scale_done && scale_consumed[alpha_done_bank]))
      $fatal(1,"Alpha consumer completed twice");
    if(recip_begin && recip_writing) $fatal(1,"Reciprocal job already active");
    if(recip_wr_en && (!recip_writing || |(recip_written & recip_write_bits))) $fatal(1,"Reciprocal write without lease or duplicate row");
    if(recip_end && (!recip_writing || !( &(recip_written | recip_write_bits)))) $fatal(1,"Reciprocal completed before 51 writes");
    if(vpu_recip_rd_en && !recip_ready) $fatal(1,"Reciprocal read before completion");
    if(vpu_m_aa_wr_en && alpha_writing) $fatal(1,"aa overwritten while SFU consumes it");
    if(vpu_l_wr_en && recip_writing) $fatal(1,"l overwritten while SFU consumes it");
    for(int n=0;n<SFU_LANES;n++) if(sfu_aa_rd_en && sfu_aa_rd_mask[n] && !aa_valid[sfu_aa_rd_base+n])
      $fatal(1,"aa read before row update");
  end
  initial if(SFU_LANES!=2 || SUFFIX_LEN%2!=1) $fatal(1,"Scalar pair profile requires two lanes and odd row count");
  // synthesis translate_on
endmodule
