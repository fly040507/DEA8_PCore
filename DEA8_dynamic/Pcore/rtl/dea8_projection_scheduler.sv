import pcore_pkg::*;

// Five projection geometries. FACC lifetime is independent of Pair lifetime.
module dea8_projection_scheduler (
  input logic clk,reset,clear,start_valid,output logic start_ready,
  input pcore_job_t context_job,input job_token_t context_token,
  input logic [ROW_COUNT_BITS-1:0] context_rows,
  output logic matrix_valid,input logic matrix_ready,output compute_job_t matrix_job,
  input logic matrix_done,output logic matrix_done_ready,
  output logic capture_valid,input logic capture_ready,output capture_desc_t capture_desc,
  input logic capture_done,input capture_desc_t captured,
  output logic done,protocol_error
);
  operation_profile_t contract;
  logic active,matrix_active,active_bank;
  logic [1:0] held,committed,reading;
  capture_desc_t owners[0:1];
  logic [6:0] next_nt,copied;
  logic selected;
  logic [TILE_BITS-1:0] canonical;
  capture_desc_t next_owner;
  assign contract=operation_profile(context_job.op);
  assign start_ready=!reset&&!clear&&!active&&!protocol_error;
  assign canonical=context_job.op==OP_Q_PROJ?
    TILE_BITS'(int'(next_nt)/2+(next_nt[0]?QOZ_Q_TILES/2:0)):TILE_BITS'(next_nt);
  assign selected=committed[1]&&(!committed[0]||owners[1].work_seq<owners[0].work_seq);
  always_comb begin
    next_owner='0;next_owner.token=context_token;next_owner.work_seq=SEQ_BITS'(next_nt);
    next_owner.sel=next_nt[0]?ACC_FACC_B:ACC_FACC_A;next_owner.rows=context_rows;
    next_owner.nt=canonical;next_owner.pair_seq=6'(int'(next_nt)/2);next_owner.half=next_nt[0];
    if(context_job.op==OP_V_PROJ)begin next_owner.pair_seq=6'(next_nt);next_owner.half=0;end
    capture_desc='0;
    if(selected&&committed[1])capture_desc=owners[1];
    else if(!selected&&committed[0])capture_desc=owners[0];
    matrix_job='0;matrix_job.token=context_token;matrix_job.work_seq=SEQ_BITS'(next_nt);
    matrix_job.m_rows=context_rows;matrix_job.tiles=MATRIX_TILE_COUNT_BITS'(contract.k_tiles);
    matrix_job.mode=MAT_PROJECTION;matrix_job.role=ROLE_WEIGHT;matrix_job.epoch=context_job.epoch;
    matrix_job.head=context_job.head;matrix_job.nt=canonical;
    matrix_job.acc_sel=next_nt[0]?ACC_FACC_B:ACC_FACC_A;
  end
  assign matrix_valid=active&&next_nt<contract.n_tiles&&!held[next_nt[0]]&&!matrix_active&&!protocol_error;
  assign matrix_done_ready=active&&matrix_active&&!protocol_error;
  assign capture_valid=active&&|committed&&!protocol_error;
  assign done=next_nt==contract.n_tiles&&copied==contract.n_tiles&&copied!=0&&
    !matrix_active&&held==0&&!protocol_error;
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      active<=0;matrix_active<=0;held<=0;committed<=0;reading<=0;
      next_nt<=0;copied<=0;active_bank<=0;protocol_error<=0;
      owners[0]<='0;owners[1]<='0;
    end else begin
      if(start_valid&&start_ready)begin active<=1;next_nt<=0;copied<=0;end
      if(done&&!(start_valid&&start_ready))active<=0;
      if(matrix_valid&&matrix_ready)begin
        held[next_nt[0]]<=1;owners[next_nt[0]]<=next_owner;
        active_bank<=next_nt[0];matrix_active<=1;next_nt<=next_nt+1'b1;
      end
      if(matrix_done&&matrix_done_ready)begin committed[active_bank]<=1;matrix_active<=0;end
      if(capture_valid&&capture_ready)begin committed[selected]<=0;reading[selected]<=1;end
      if(capture_done)begin
        if(captured.sel>ACC_FACC_B)protocol_error<=1;
        else if(!reading[captured.sel]||captured!=owners[captured.sel])protocol_error<=1;
        else begin held[captured.sel]<=0;reading[captured.sel]<=0;copied<=copied+1'b1;end
      end
    end
  end
endmodule
