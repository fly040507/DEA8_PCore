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
  v1_key_t keys[0:6];
  logic [1:0] use_a3,use_c;
  localparam int CTRL_FLUSH=0,CTRL_Q_VALID=1,CTRL_A_VALID=2,CTRL_ADD_OLD=3;
  logic [2*TILE-1:0][3:0] control_leaf;
  logic [1:0][TILE-1:0][1:0] forward_leaf;
  logic signed [1:0][11:0] row_bias;
  logic signed [1:0][TILE-1:0][11:0] lane_base;
  logic [1:0][TILE-1:0] bad_scale,partial_valid,a3_valid;
  logic [1:0][TILE-1:0][31:0] partial_values,old_issue,a3_values,commit_data;
  logic [1:0][15:0][31:0] acc_old_data,acc_external_data,acc_wr_data;
  logic acc_wr_valid;
  acc_sel_e acc_wr_sel;
  logic [9:0] acc_wr_addr;
  logic [1:0] acc_wr_rows;
  logic [31:0] acc_dbg_data;
  logic result_free,vpu_free;
  always_comb begin
    result_free=!(rsp_valid&&rsp.meta.acc_sel==result_rd_sel);
    vpu_free=!(rsp_valid&&rsp.meta.acc_sel==vpu_wr.sel);
    for(int s=0;s<6;s++)begin
      if(valid_pipe[s]&&meta_pipe[s].acc_sel==result_rd_sel)result_free=0;
      if(valid_pipe[s]&&meta_pipe[s].acc_sel==vpu_wr.sel)vpu_free=0;
    end
  end
  assign result_rd_ready=!reset&&!clear&&result_rd_owner==ACC_READ_RESULT&&result_rd_sel<=ACC_OACC&&result_free;
  assign vpu_wr_ready=!reset&&!clear&&vpu_wr.sel<=ACC_OACC&&vpu_free;
  deqacc_v1_control control(.clk,.reset,.clear,.in_valid(rsp_valid),.rsp,.generation,.valid_pipe,.meta_pipe,.rows_pipe,
    .commit_valid,.done,.commit_meta,.keys,.use_a3,.use_c);
  deqacc_v2_fanout #(.WIDTH(4),.BRANCHES(4),.LEAVES_PER_BRANCH(TILE/2)) control_fanout(
    .root({keys[1].add_old,keys[1].valid,rsp_valid,reset||clear}),.leaf(control_leaf));
  for(genvar r=0;r<2;r++)begin: row_forward
    deqacc_v2_fanout #(.WIDTH(2),.BRANCHES(4),.LEAVES_PER_BRANCH(TILE/4)) fanout(
      .root({use_c[r],use_a3[r]}),.leaf(forward_leaf[r]));
  end
  deqacc_v2_scale_ingress scale_ingress(.ea(rsp.e_stream),.eb(rsp.e_stat),
    .fold(rsp.meta.exp_fold),.row_bias,.base(lane_base),.bad_scale);
  assign commit_write_valid=commit_valid;
  assign acc_wr_data=a3_values;
  assign acc_wr_valid=keys[5].valid;
  assign acc_wr_sel=keys[5].sel;
  assign acc_wr_addr=keys[5].addr;
  assign acc_wr_rows=keys[5].rows;
  assign commit_write.data=commit_data;
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
  assign result_even_data=acc_external_data[0];
  assign result_odd_data=acc_external_data[1];
  assign dbg_data=dbg_valid?acc_dbg_data:0;
  // Four same-row placement groups; the post-synthesis locality constraints
  // include these lanes and their local scale/control buffer endpoints.
  for(genvar g=0;g<4;g++)begin: physical_regions
    localparam int ROW=g/2;
    localparam int COLUMN_BASE=(g%2)*(TILE/2);
    for(genvar n=0;n<TILE/2;n++)begin: lanes
      localparam int COLUMN=COLUMN_BASE+n;
      localparam int CONTROL_LANE=ROW*TILE+COLUMN;
      logic [31:0] c_q;
      assign old_issue[ROW][COLUMN]=!control_leaf[CONTROL_LANE][CTRL_ADD_OLD]?32'b0:
        forward_leaf[ROW][COLUMN][0]?a3_values[ROW][COLUMN]:
        forward_leaf[ROW][COLUMN][1]?commit_data[ROW][COLUMN]:acc_old_data[ROW][COLUMN];
      (* keep_hierarchy="soft" *) dequant_lane_v1 quant(
        .clk,.reset(1'b0),.clear(control_leaf[CONTROL_LANE][CTRL_FLUSH]),
        .in_valid(control_leaf[CONTROL_LANE][CTRL_Q_VALID]),
        .psum(rsp.psum[ROW][COLUMN]),.base(lane_base[ROW][COLUMN]),
        .bad_scale(bad_scale[ROW][COLUMN]),.out_valid(partial_valid[ROW][COLUMN]),
        .partial_value(partial_values[ROW][COLUMN]));
      (* keep_hierarchy="soft" *) fp32_add_lane_v1 add(
        .clk,.reset(1'b0),.clear(control_leaf[CONTROL_LANE][CTRL_FLUSH]),
        .in_valid(control_leaf[CONTROL_LANE][CTRL_A_VALID]),
        .add_old(control_leaf[CONTROL_LANE][CTRL_ADD_OLD]),
        .old_value(old_issue[ROW][COLUMN]),.partial_value(partial_values[ROW][COLUMN]),
        .out_valid(a3_valid[ROW][COLUMN]),.result_value(a3_values[ROW][COLUMN]));
      always_ff @(posedge clk)c_q<=a3_values[ROW][COLUMN];
      assign commit_data[ROW][COLUMN]=c_q;
    end
  end
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)begin
    if(partial_valid!=={(2*TILE){keys[1].valid}})$fatal(1,"V2 partial/key mismatch");
    if(a3_valid!=={(2*TILE){keys[5].valid}})$fatal(1,"V2 A3/key mismatch");
    if(rsp_valid&&(rsp.meta.acc_sel>ACC_OACC||rsp.meta.pair_idx>=PAIRS||
       (rsp.meta.acc_sel==ACC_OACC&&rsp.meta.nt>=TILE)||
       ((rsp.row_valid&~row_mask(rsp.meta.pair_idx))!=0)))$fatal(1,"V1 illegal accumulator input");
  end
  // synthesis translate_on
endmodule
