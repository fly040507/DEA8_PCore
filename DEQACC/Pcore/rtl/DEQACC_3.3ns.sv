import pcore_pkg::*;
import dea8_fp32_pkg::*;

// D0 abs/lead, D1 normalize/exponent, D2 pack preparation/ACC read,
// D3 pack finish/RAM response, D4..D9 lane arithmetic, D10 commit. II=1.
module DEQACC_3_3ns(
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
  typedef struct packed {logic valid;pair_meta_t meta;logic [1:0] rows;} context_t;
  typedef struct packed {
    logic sign_bit,is_zero,bad;
    logic [31:0] mag;
    logic [4:0] lead;
    logic [7:0] a,b;
    logic signed [EXP_FOLD_BITS-1:0] fold;
  } magnitude_t;
  typedef struct packed {
    logic sign_bit,is_zero,bad;
    logic [31:0] norm;
    logic signed [10:0] exponent;
  } normalized_t;
  typedef struct packed {
    logic sign_bit,is_zero,bad,subnormal;
    logic signed [10:0] exponent;
    logic [23:0] kept;
    logic increment;
  } pack_t;
  typedef struct packed {logic [31:0] partial,old_value;} operands_t;
  magnitude_t magnitude_q[0:1][0:15];
  normalized_t s0[0:1][0:15];
  pack_t s1[0:1][0:15];
  operands_t s2[0:1][0:15];
  pack_t pack_next[0:1][0:15];
  logic [31:0] partial_next[0:1][0:15];
  context_t context_q[0:9];
  logic [7:0] group_rd_valid,group_wr_valid;
  logic [7:0][1:0] group_rd_sel,group_wr_sel,group_wr_rows,group_word_valid;
  logic [7:0][9:0] group_rd_addr,group_wr_addr;
  // Copies sit on existing D0..D3 boundaries. Preserve only these small
  // arithmetic sidebands; global commit metadata remains a single pipeline.
  for(genvar g=0;g<8;g++)begin: local_control
    (* dont_touch="yes", shreg_extract="no" *) logic read_q,write_q;
    (* dont_touch="yes", shreg_extract="no" *) logic [1:0] read_sel_q,write_sel_q,write_rows_q;
    (* dont_touch="yes", shreg_extract="no" *) logic [9:0] read_addr_q,write_addr_q;
    assign group_rd_valid[g]=read_q;assign group_wr_valid[g]=write_q;
    assign group_rd_sel[g]=read_sel_q;assign group_wr_sel[g]=write_sel_q;
    assign group_rd_addr[g]=read_addr_q;assign group_wr_addr[g]=write_addr_q;
    assign group_wr_rows[g]=write_rows_q;
    always_ff @(posedge clk)begin
      read_sel_q<=context_q[0].meta.acc_sel;write_sel_q<=context_q[8].meta.acc_sel;
      read_addr_q<=context_q[0].meta.acc_sel==ACC_OACC?
        {1'b0,context_q[0].meta.pair_idx,context_q[0].meta.nt[3:0]}:10'(context_q[0].meta.pair_idx);
      write_addr_q<=context_q[8].meta.acc_sel==ACC_OACC?
        {1'b0,context_q[8].meta.pair_idx,context_q[8].meta.nt[3:0]}:10'(context_q[8].meta.pair_idx);
      write_rows_q<=context_q[8].rows;
      if(reset||clear)begin read_q<=0;write_q<=0;end
      else begin read_q<=context_q[0].valid&&context_q[0].meta.add_old;write_q<=context_q[8].valid;end
    end
  end
  logic [1:0] word_valid;
  logic rd_valid,rd_data_valid;
  logic [9:0] rd_addr,wr_addr;
  logic [15:0][31:0] rd_even,rd_odd,wr_even,wr_odd;
  logic lane_valid[0:1][0:15];
  logic [31:0] lane_value[0:1][0:15];
  function automatic magnitude_t magnitude(input logic signed [31:0] value,
    input logic [7:0] a,b,input logic signed [EXP_FOLD_BITS-1:0] fold);
    magnitude_t t;
    t.mag=value[31]?(~value+32'd1):value;t.lead=lead32(t.mag);
    t.sign_bit=value[31];t.is_zero=t.mag==0;t.bad=(&a)||(&b);
    t.a=a;t.b=b;t.fold=fold;return t;
  endfunction
  function automatic logic [31:0] finish_pack(input pack_t p);
    logic [24:0] rounded;logic [23:0] mant;logic signed [11:0] exponent;
    rounded={1'b0,p.kept}+25'(p.increment);
    mant=rounded[24]?rounded[24:1]:rounded[23:0];
    exponent=$signed({p.exponent[10],p.exponent})+$signed({11'b0,rounded[24]});
    if(p.bad) return FP_QNAN;
    if(p.is_zero) return 0;
    if(p.subnormal) return {p.sign_bit,7'b0,rounded[23:0]};
    if(exponent>127) return {p.sign_bit,FP_INF[30:0]};
    return {p.sign_bit,8'(exponent+127),mant[22:0]};
  endfunction
  assign rd_valid=context_q[1].valid&&context_q[1].meta.add_old;
  assign rd_addr=context_q[1].meta.acc_sel==ACC_OACC?
    {1'b0,context_q[1].meta.pair_idx,context_q[1].meta.nt[3:0]}:10'(context_q[1].meta.pair_idx);
  assign wr_addr=context_q[9].meta.acc_sel==ACC_OACC?
    {1'b0,context_q[9].meta.pair_idx,context_q[9].meta.nt[3:0]}:10'(context_q[9].meta.pair_idx);
  dea8_acc_store #(.LOCAL_MATRIX_CONTROL(1)) acc_store(
    .clk,.reset,.clear,.rd_valid,.rd_sel(context_q[1].meta.acc_sel),.rd_addr,
    .rd_data_valid,.rd_even_data(rd_even),.rd_odd_data(rd_odd),
    .rd_even_raw(),.rd_odd_raw(),.rd_word_valid(word_valid),
    .rd_group_word_valid(group_word_valid),.group_rd_valid,.group_wr_valid,
    .group_rd_sel,.group_wr_sel,.group_wr_rows,.group_rd_addr,.group_wr_addr,
    .result_rd_owner,.result_rd_valid,.result_rd_ready,.result_rd_sel,.result_rd_addr,
    .result_rd_data_valid,.result_even_data,.result_odd_data,.vpu_wr_valid,.vpu_wr_ready,.vpu_wr,
    .wr_valid(context_q[9].valid),.wr_sel(context_q[9].meta.acc_sel),
    .wr_even_valid(context_q[9].rows[0]),.wr_odd_valid(context_q[9].rows[1]),
    .wr_addr,.wr_even_data(wr_even),.wr_odd_data(wr_odd),
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);
  for(genvar g=0;g<8;g++)begin: groups
    logic [1:0][1:0][31:0] psum,old_data,values;
    logic [1:0][1:0] valids;
    for(genvar r=0;r<2;r++)for(genvar n=0;n<2;n++)begin: connect
      assign psum[r][n]=rsp.psum[r][g*2+n];
      assign old_data[r][n]=r==0?rd_even[g*2+n]:rd_odd[g*2+n];
      assign lane_value[r][g*2+n]=values[r][n];
      assign lane_valid[r][g*2+n]=valids[r][n];
      // synthesis translate_off
      assign s0[r][g*2+n]=arithmetic.s0[r][n];
      assign s1[r][g*2+n]=arithmetic.s1[r][n];
      assign s2[r][g*2+n]=arithmetic.s2[r][n];
      // synthesis translate_on
    end
    DEQACC_3_3ns_group2 arithmetic(.clk,.reset,.clear,.in_valid(rsp_valid),.add_old(rsp.meta.add_old),
      .fold(rsp.meta.exp_fold),.psum,.e_stream(rsp.e_stream),.e_stat(rsp.e_stat[g*2+:2]),
      .old_data,.word_valid(group_word_valid[g]),.out_valid(valids),.result_value(values));
    assign wr_even[g*2+:2]=values[0];assign wr_odd[g*2+:2]=values[1];
  end
  always_ff @(posedge clk) begin
    context_q[0].meta<=rsp.meta;context_q[0].rows<=rsp.row_valid;
    for(int i=1;i<10;i++)begin
      context_q[i].meta<=context_q[i-1].meta;
      context_q[i].rows<=context_q[i-1].rows;
    end
    commit_meta<=context_q[9].meta;
  end
  always_ff @(posedge clk)begin
    if(reset||clear) begin
      for(int i=0;i<10;i++)context_q[i].valid<=0;
      commit_valid<=0;done<=0;commit_write_valid<=0;commit_write<='0;
    end else begin
      context_q[0].valid<=rsp_valid;
      for(int i=1;i<10;i++)context_q[i].valid<=context_q[i-1].valid;
      commit_valid<=context_q[9].valid;done<=context_q[9].valid&&context_q[9].meta.last;
      // Keep the entire write bundle on one register boundary.  Pair Buffer
      // must never observe metadata from one pair with data from another.
      commit_write_valid<=context_q[9].valid;
      commit_write.sel<=context_q[9].meta.acc_sel;
      commit_write.addr<=wr_addr;
      commit_write.row_valid<=context_q[9].rows;
      commit_write.data[0]<=wr_even;
      commit_write.data[1]<=wr_odd;
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(!reset&&!clear) begin
    if(rd_data_valid!==(context_q[2].valid&&context_q[2].meta.add_old)) $fatal(1,"DEQACC ACC response context mismatch");
    for(int r=0;r<2;r++)for(int n=0;n<16;n++)
      if(lane_valid[r][n]!==context_q[9].valid) $fatal(1,"DEQACC lane/context latency mismatch");
    for(int i=2;i<10;i++) if(rd_valid&&context_q[i].valid&&
      context_q[i].meta.acc_sel==context_q[1].meta.acc_sel&&
      context_q[i].meta.pair_idx==context_q[1].meta.pair_idx&&
      (context_q[1].meta.acc_sel!=ACC_OACC||context_q[i].meta.nt==context_q[1].meta.nt))
      $fatal(1,"DEQACC accumulator RAW hazard");
  end
  // synthesis translate_on
endmodule
