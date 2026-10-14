import pcore_pkg::*;

// The next NTile may compute k0..62 while the previous Pair is post-processing.
// Its last G/U tiles wait for an actual Pair reservation at the compute boundary.
module dea8_gu_scheduler (
  input logic clk,reset,clear,start_valid,output logic start_ready,
  input pcore_job_t context_job,input job_token_t context_token,
  input logic [ROW_COUNT_BITS-1:0] context_rows,
  output logic matrix_valid,input logic matrix_ready,output compute_job_t matrix_job,
  input logic matrix_done,output logic matrix_done_ready,
  output logic reserve_valid,output capture_desc_t reserve_desc,
  output logic done,protocol_error
);
  logic active,matrix_active;
  logic [TILE_BITS:0] issued,retired;
  logic [TILE_BITS-1:0] active_nt;
  assign start_ready=!active&&!reset&&!clear&&!protocol_error;
  assign matrix_valid=active&&!matrix_active&&issued<QOZ_Z_TILES&&!protocol_error;
  assign matrix_done_ready=active&&matrix_active&&!protocol_error;
  assign reserve_valid=active&&matrix_active&&!protocol_error;
  assign done=retired==QOZ_Z_TILES&&!matrix_active&&!protocol_error;
  always_comb begin
    matrix_job='0;matrix_job.token=context_token;matrix_job.work_seq=SEQ_BITS'(issued);
    matrix_job.m_rows=context_rows;matrix_job.tiles=MATRIX_TILE_COUNT_BITS'(128);
    matrix_job.mode=MAT_GU;matrix_job.role=ROLE_GATE;matrix_job.epoch=context_job.epoch;
    matrix_job.head=context_job.head;matrix_job.nt=TILE_BITS'(issued);matrix_job.gu_n=6'(issued);
    matrix_job.acc_sel=ACC_FACC_A;
    reserve_desc='0;reserve_desc.token=context_token;reserve_desc.work_seq=SEQ_BITS'(active_nt);
    reserve_desc.sel=ACC_FACC_A;reserve_desc.rows=context_rows;reserve_desc.nt=active_nt;
    reserve_desc.pair_seq=active_nt;
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin active<=0;matrix_active<=0;issued<=0;retired<=0;active_nt<=0;protocol_error<=0;end
    else begin
      if(start_valid&&start_ready)begin active<=1;issued<=0;retired<=0;end
      if(matrix_valid&&matrix_ready)begin matrix_active<=1;active_nt<=TILE_BITS'(issued);issued<=issued+1'b1;end
      if(matrix_done&&matrix_done_ready)begin matrix_active<=0;retired<=retired+1'b1;end
      if(done&&!(start_valid&&start_ready))active<=0;
    end
  end
endmodule
