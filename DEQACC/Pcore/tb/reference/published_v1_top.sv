import pcore_pkg::*;
import deqacc_v1_pkg::*;

module published_v1_top(
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
  logic result_free,vpu_free;
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
  end
  assign result_rd_ready=!reset&&!clear&&result_rd_owner==ACC_READ_RESULT&&result_rd_sel<=ACC_OACC&&result_free;
  assign vpu_wr_ready=!reset&&!clear&&vpu_wr.sel<=ACC_OACC&&vpu_free;
  published_v1_control control(.clk,.reset,.clear,.in_valid(rsp_valid),.rsp,.generation,.valid_pipe,.meta_pipe,.rows_pipe,
    .commit_valid,.done,.commit_meta);
  assign commit_write_valid=commit_valid;
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      result_rd_data_valid<=0;commit_write.sel<=ACC_FACC_A;commit_write.addr<=0;commit_write.row_valid<=0;
    end else begin
      result_rd_data_valid<=result_rd_valid&&result_rd_ready;
      commit_write.sel<=meta_pipe[5].acc_sel;commit_write.addr<=v1_address(meta_pipe[5]);
      // Rows are saved separately; do not reconstruct a live input row mask.
      commit_write.row_valid<=rows_pipe[5];
    end
  end
  for(genvar g=0;g<4;g++)begin: groups
    logic signed [1:0][3:0][31:0] sums;
    logic [1:0][3:0][31:0] cdata,edata,wdata;
    for(genvar r=0;r<2;r++)for(genvar n=0;n<4;n++)begin: columns
      assign sums[r][n]=rsp.psum[r][g*4+n];
      assign wdata[r][n]=vpu_wr.data[r][g*4+n];
      assign commit_write.data[r][g*4+n]=cdata[r][n];
      if(r==0)assign result_even_data[g*4+n]=edata[r][n];
      else assign result_odd_data[g*4+n]=edata[r][n];
    end
    published_v1_group compute(.clk,.reset,.clear,.input_key,.psum(sums),.ea(rsp.e_stream),
      .eb(rsp.e_stat[g*4+:4]),.fold(rsp.meta.exp_fold),.commit_valid(group_commit[g]),.commit_data(cdata),
      .external_rd_fire(result_rd_valid&&result_rd_ready),.external_rd_sel(result_rd_sel),
      .external_rd_addr(result_rd_addr),.external_data(edata),
      .external_wr_fire(vpu_wr_valid&&vpu_wr_ready),.external_wr_sel(vpu_wr.sel),.external_wr_addr(vpu_wr.addr),
      .external_wr_rows(vpu_wr.row_valid),.external_wr_data(wdata),
      .dbg_sel,.dbg_parity,.dbg_addr,.dbg_column(dbg_lane[1:0]),.dbg_data(group_debug[g]));
  end
  assign dbg_data=dbg_valid?group_debug[dbg_lane[3:2]]:0;
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)begin
    if(group_commit!=={4{commit_valid}})$fatal(1,"V1 group commit alignment mismatch");
    if(rsp_valid&&(rsp.meta.acc_sel>ACC_OACC||rsp.meta.pair_idx>=PAIRS||
       (rsp.meta.acc_sel==ACC_OACC&&rsp.meta.nt>=TILE)||
       ((rsp.row_valid&~row_mask(rsp.meta.pair_idx))!=0)))$fatal(1,"V1 illegal accumulator input");
  end
  // synthesis translate_on
endmodule
