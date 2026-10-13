import pcore_pkg::*;
import deqacc_v1_pkg::*;

module DEQACC_V1(
  input logic clk,reset,clear,rsp_valid,input mxu_rsp_t rsp,
  input acc_read_owner_e result_rd_owner,
  input logic result_rd_valid,output logic result_rd_ready,
  input logic vpu_wr_valid,output logic vpu_wr_ready,input acc_write_t vpu_wr,
  input acc_sel_e result_rd_sel,input logic [9:0] result_rd_addr,
  output logic result_rd_data_valid,output logic [15:0][31:0] result_even_data,result_odd_data,
  output logic commit_valid,done,output pair_meta_t commit_meta,
  output logic commit_write_valid,output acc_write_t commit_write,
  input logic dbg_valid,input acc_sel_e dbg_sel,input logic dbg_parity,
  input logic [9:0] dbg_addr,input logic [3:0] dbg_lane,output logic [31:0] dbg_data
);
  logic generation;
  logic [5:0] valid_pipe;
  pair_meta_t meta_pipe[0:5];
  logic [5:0][1:0] rows_pipe;
  v1_key_t input_key;
  logic [3:0] group_commit;
  logic [31:0] group_debug[0:3];
  logic [3:0] group_wr_valid;
  acc_sel_e group_wr_sel[0:3];
  logic [9:0] group_wr_addr[0:3];
  logic [1:0] group_wr_rows[0:3];
  logic [1:0][3:0][31:0] group_wr_data[0:3];
  logic [1:0][15:0][31:0] acc_old_data,acc_external_data,acc_wr_data;
  logic acc_wr_valid;
  acc_sel_e acc_wr_sel;
  logic [9:0] acc_wr_addr;
  logic [1:0] acc_wr_rows;
  logic [31:0] acc_dbg_data;
  logic result_free,vpu_free;
  logic [ROW_COUNT_BITS-1:0] active_rows[0:2];
  logic [ROW_LANES-1:0] external_mask_q;
  logic result_in_range,vpu_in_range;
  function automatic int unsigned compact_pair(input acc_sel_e sel,input logic [9:0] addr);
    return sel==ACC_OACC?int'(addr)/TILE:int'(addr);
  endfunction
  always_comb begin
    input_key='0;input_key.valid=rsp_valid;input_key.generation=generation;
    input_key.add_old=rsp.meta.add_old;input_key.sel=rsp.meta.acc_sel;
    input_key.addr=v1_address(rsp.meta);input_key.rows=rsp.row_valid;
    result_free=!(rsp_valid&&rsp.meta.acc_sel==result_rd_sel);
    vpu_free=!(rsp_valid&&rsp.meta.acc_sel==vpu_wr.sel);
    for(int s=0;s<6;s++)begin
      if(valid_pipe[s]&&meta_pipe[s].acc_sel==result_rd_sel)result_free=0;
      if(valid_pipe[s]&&meta_pipe[s].acc_sel==vpu_wr.sel)vpu_free=0;
    end
    result_in_range=0;vpu_in_range=0;
    if(result_rd_sel<=ACC_OACC)
      result_in_range=compact_pair(result_rd_sel,result_rd_addr)<pairs_for_rows(active_rows[result_rd_sel]);
    if(vpu_wr.sel<=ACC_OACC)
      vpu_in_range=compact_pair(vpu_wr.sel,vpu_wr.addr)<pairs_for_rows(active_rows[vpu_wr.sel])&&
        vpu_wr.row_valid!=0&&
        (vpu_wr.row_valid&~row_mask_for_rows(active_rows[vpu_wr.sel],compact_pair(vpu_wr.sel,vpu_wr.addr)))==0;
  end
  assign result_rd_ready=!reset&&!clear&&result_rd_owner==ACC_READ_RESULT&&result_in_range&&result_free;
  assign vpu_wr_ready=!reset&&!clear&&vpu_in_range&&vpu_free;
  deqacc_v1_control control(.clk,.reset,.clear,.in_valid(rsp_valid),.rsp,.generation,.valid_pipe,.meta_pipe,.rows_pipe,
    .commit_valid,.done,.commit_meta);
  assign commit_write_valid=commit_valid;
  always_comb begin
    acc_wr_data='0;
    for(int g=0;g<4;g++) begin
      for(int r=0;r<2;r++)
        for(int n=0;n<4;n++)
          acc_wr_data[r][g*4+n]=group_wr_data[g][r][n];
    end
    acc_wr_valid=group_wr_valid[0];
    acc_wr_sel=group_wr_sel[0];
    acc_wr_addr=group_wr_addr[0];
    acc_wr_rows=group_wr_rows[0];
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      result_rd_data_valid<=0;commit_write.sel<=ACC_FACC_A;commit_write.addr<=0;commit_write.row_valid<=0;
      external_mask_q<=0;
      for(int b=0;b<3;b++)active_rows[b]<=0;
    end else begin
      if(rsp_valid)active_rows[rsp.meta.acc_sel]<=rsp.meta.m_rows;
      if(result_rd_valid&&result_rd_ready)
        external_mask_q<=row_mask_for_rows(active_rows[result_rd_sel],compact_pair(result_rd_sel,result_rd_addr));
      result_rd_data_valid<=result_rd_valid&&result_rd_ready;
      commit_write.sel<=meta_pipe[5].acc_sel;commit_write.addr<=v1_address(meta_pipe[5]);
      // Rows are saved separately; do not reconstruct a live input row mask.
      commit_write.row_valid<=rows_pipe[5];
    end
  end
  acc_slice_v1 memory(
    .clk,.reset,.clear,
    // Execute the synchronous read from Q0's registered key. Its response
    // aligns with Q1 at the A0 boundary; an input-edge read can be stale at
    // Delta=6 (read-first collision with the producer's C write).
    .rd_valid(valid_pipe[0]&&meta_pipe[0].add_old),.rd_sel(meta_pipe[0].acc_sel),
    .rd_addr(v1_address(meta_pipe[0])),
    .old_data(acc_old_data),
    .wr_valid(acc_wr_valid),.wr_sel(acc_wr_sel),.wr_addr(acc_wr_addr),
    .wr_rows(acc_wr_rows),.wr_data(acc_wr_data),
    .external_rd_fire(result_rd_valid&&result_rd_ready),.external_rd_sel(result_rd_sel),
    .external_rd_addr(result_rd_addr),.external_data(acc_external_data),
    .external_wr_fire(vpu_wr_valid&&vpu_wr_ready),.external_wr_sel(vpu_wr.sel),
    .external_wr_addr(vpu_wr.addr),.external_wr_rows(vpu_wr.row_valid),
    .external_wr_data(vpu_wr.data),
    .dbg_sel,.dbg_parity,.dbg_addr,.dbg_column(dbg_lane),.dbg_data(acc_dbg_data));
  assign result_even_data=external_mask_q[0]?acc_external_data[0]:'0;
  assign result_odd_data=external_mask_q[1]?acc_external_data[1]:'0;
  assign dbg_data=dbg_valid?acc_dbg_data:0;
  for(genvar g=0;g<4;g++)begin: groups
    logic signed [1:0][3:0][31:0] sums;
    logic [1:0][3:0][31:0] cdata,old_data;
    for(genvar r=0;r<2;r++)for(genvar n=0;n<4;n++)begin: columns
      assign sums[r][n]=rsp.psum[r][g*4+n];
      assign commit_write.data[r][g*4+n]=cdata[r][n];
      assign old_data[r][n]=acc_old_data[r][g*4+n];
    end
    deqacc_v1_group8 compute(.clk,.reset,.clear,.input_key,.psum(sums),.ea(rsp.e_stream),
      .eb(rsp.e_stat[g*4+:4]),.fold(rsp.meta.exp_fold),.acc_old_data(old_data),
      .commit_valid(group_commit[g]),.commit_data(cdata),
      .acc_wr_valid(group_wr_valid[g]),.acc_wr_sel(group_wr_sel[g]),.acc_wr_addr(group_wr_addr[g]),
      .acc_wr_rows(group_wr_rows[g]),.acc_wr_data(group_wr_data[g]),
      .dbg_sel,.dbg_parity,.dbg_addr,.dbg_column(dbg_lane[1:0]),.dbg_data(group_debug[g]));
  end
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)begin
    if(group_commit!=={4{commit_valid}})$fatal(1,"V1 group commit alignment mismatch");
    if(group_wr_valid!=={4{group_wr_valid[0]}})$fatal(1,"V2 ACC write bundle valid mismatch");
    for(int g=1;g<4;g++)begin
      if(group_wr_valid[g]&&group_wr_sel[g]!==group_wr_sel[0])
        $fatal(1,"V2 ACC write bundle select mismatch");
      if(group_wr_valid[g]&&group_wr_addr[g]!==group_wr_addr[0])
        $fatal(1,"V2 ACC write bundle address mismatch");
      if(group_wr_valid[g]&&group_wr_rows[g]!==group_wr_rows[0])
        $fatal(1,"V2 ACC write bundle row mask mismatch");
    end
    if(rsp_valid&&(rsp.meta.acc_sel>ACC_OACC||rsp.meta.m_rows==0||rsp.meta.m_rows>ROWS||
       rsp.meta.pair_idx>=pairs_for_rows(rsp.meta.m_rows)||rsp.row_valid==0||
       (rsp.meta.acc_sel==ACC_OACC&&rsp.meta.nt>=TILE)||
       ((rsp.row_valid&~row_mask_for_rows(rsp.meta.m_rows,rsp.meta.pair_idx))!=0)))$fatal(1,"V1 illegal accumulator input");
  end
  // synthesis translate_on
endmodule
