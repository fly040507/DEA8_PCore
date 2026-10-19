import pcore_pkg::*;
import dea8_fp32_pkg::*;

// Four dequant/ACC-read stages, native FPADD IP, one atomic commit. II=1.
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
  localparam int LAST=DEQACC_PIPE_STAGES-2;
  localparam int LEAD_BITS=$clog2(PSUM_BITS);
  typedef struct packed {logic valid;pair_meta_t meta;logic [1:0] rows;} context_t;
  typedef struct packed {
    logic sign_bit,is_zero,bad;
    logic [PSUM_BITS-1:0] mag;
    logic [LEAD_BITS-1:0] lead;
    logic signed [10:0] base;
  } magnitude_t;
  typedef struct packed {
    logic sign_bit,is_zero,bad;
    logic [PSUM_BITS-1:0] norm;
    logic signed [10:0] exponent;
  } normalized_t;
  magnitude_t mag_q[0:1][0:TILE-1];
  normalized_t norm_q[0:1][0:TILE-1];
  logic [31:0] partial_q[0:1][0:TILE-1],operand_q[0:1][0:TILE-1];
  logic [31:0] old_q[0:1][0:TILE-1];
  context_t context_q[0:LAST];
  logic signed [10:0] row_base[0:1];
  logic [1:0] word_valid;
  logic rd_valid,rd_data_valid;
  logic [9:0] rd_addr,wr_addr;
  logic [15:0][31:0] rd_even,rd_odd,wr_even,wr_odd;
  logic lane_valid[0:1][0:TILE-1];
  logic [31:0] lane_value[0:1][0:TILE-1];

  function automatic magnitude_t magnitude(input logic [PSUM_BITS-1:0] value,
    input logic [7:0] a,b,input logic signed [10:0] base);
    magnitude_t t;
    t='0;t.sign_bit=value[PSUM_BITS-1];
    t.mag=t.sign_bit?(~value+PSUM_BITS'(1)):value;
    for(int i=0;i<PSUM_BITS;i++)if(t.mag[i])t.lead=LEAD_BITS'(i);
    t.is_zero=t.mag==0;t.bad=(&a)||(&b);t.base=base+$signed({3'b0,b});return t;
  endfunction
  function automatic logic [31:0] pack_partial(input normalized_t p);
    logic [23:0] rounded,significand;
    logic [25:0] shift_stage[0:5];
    logic [4:0] shift_amount;
    logic [7:0] encoded;
    logic signed [11:0] distance;
    significand={p.norm,{(24-PSUM_BITS){1'b0}}};
    if(p.bad)return FP_QNAN;
    if(p.is_zero)return 0;
    if(p.exponent>127)return {p.sign_bit,8'hff,23'b0};
    if(p.exponent>=-126)begin
      encoded=8'(p.exponent+127);
      return {p.sign_bit,encoded,significand[22:0]};
    end
    distance=-12'sd126-$signed({p.exponent[10],p.exponent});
    shift_amount=distance>=26?5'd31:distance[4:0];
    shift_stage[0]={significand,2'b00};
    for(int s=0;s<5;s++)begin
      shift_stage[s+1]=shift_stage[s];
      if(shift_amount[s])begin
        shift_stage[s+1]=shift_stage[s]>>(1<<s);
        for(int j=0;j<=(1<<s);j++)shift_stage[s+1][0]|=shift_stage[s][j];
      end
    end
    rounded=shift_stage[5][25:2]+24'(shift_stage[5][1]&&(shift_stage[5][0]||shift_stage[5][2]));
    return {p.sign_bit,7'b0,rounded};
  endfunction
  function automatic logic [9:0] address(input pair_meta_t meta);
    return meta.acc_sel==ACC_OACC?{1'b0,meta.pair_idx,meta.nt[3:0]}:10'(meta.pair_idx);
  endfunction
  for(genvar r=0;r<2;r++)begin: rows
    assign row_base[r]=$signed({3'b0,rsp.e_stream[r]})-11'(DOT_EXP_OFFSET)+$signed(rsp.meta.exp_fold);
    for(genvar n=0;n<TILE;n++)begin: lanes
      DEQACC_3_3ns_lane lane(.clk,.reset,.clear,.in_valid(context_q[3].valid),
        .add_old(context_q[3].meta.add_old),.old_value(old_q[r][n]),.partial_value(operand_q[r][n]),
        .out_valid(lane_valid[r][n]),.result_value(lane_value[r][n]));
      if(r==0)assign wr_even[n]=lane_value[r][n];
      else assign wr_odd[n]=lane_value[r][n];
    end
  end
  assign rd_valid=rsp_valid&&rsp.meta.add_old&&!reset&&!clear;
  assign rd_addr=address(rsp.meta);
  assign wr_addr=address(context_q[LAST].meta);
  dea8_acc_store acc_store(
    .clk,.reset,.clear,.rd_valid,.rd_sel(rsp.meta.acc_sel),.rd_addr,.rd_data_valid,
    .rd_even_data(),.rd_odd_data(),.rd_even_raw(rd_even),.rd_odd_raw(rd_odd),.rd_word_valid(word_valid),
    .result_rd_owner,.result_rd_valid,.result_rd_ready,.result_rd_sel,.result_rd_addr,
    .result_rd_data_valid,.result_even_data,.result_odd_data,.vpu_wr_valid,.vpu_wr_ready,.vpu_wr,
    .wr_valid(context_q[LAST].valid),.wr_sel(context_q[LAST].meta.acc_sel),
    .wr_even_valid(context_q[LAST].rows[0]),.wr_odd_valid(context_q[LAST].rows[1]),
    .wr_addr,.wr_even_data(wr_even),.wr_odd_data(wr_odd),
    .dbg_valid,.dbg_sel,.dbg_parity,.dbg_addr,.dbg_lane,.dbg_data);
  always_ff @(posedge clk)begin
    context_q[0].meta<=rsp.meta;context_q[0].rows<=rsp.row_valid;
    for(int s=1;s<=LAST;s++)context_q[s]<=context_q[s-1];
    commit_meta<=context_q[LAST].meta;
    commit_write.sel<=context_q[LAST].meta.acc_sel;commit_write.addr<=wr_addr;
    commit_write.row_valid<=context_q[LAST].rows;
    commit_write.data[0]<=wr_even;commit_write.data[1]<=wr_odd;
    for(int r=0;r<2;r++)for(int n=0;n<TILE;n++)begin
      mag_q[r][n]<=magnitude(rsp.psum[r][n],rsp.e_stream[r],rsp.e_stat[n],row_base[r]);
      norm_q[r][n].norm<=mag_q[r][n].mag<<(LEAD_BITS'(PSUM_BITS-1)-mag_q[r][n].lead);
      norm_q[r][n].exponent<=mag_q[r][n].base+$signed({6'b0,mag_q[r][n].lead});
      norm_q[r][n].sign_bit<=mag_q[r][n].sign_bit;
      norm_q[r][n].is_zero<=mag_q[r][n].is_zero;norm_q[r][n].bad<=mag_q[r][n].bad;
      partial_q[r][n]<=pack_partial(norm_q[r][n]);
      operand_q[r][n]<=partial_q[r][n];
      old_q[r][n]<=context_q[2].meta.add_old&&word_valid[r]?(r==0?rd_even[n]:rd_odd[n]):32'b0;
    end
    if(reset||clear)begin
      for(int s=0;s<=LAST;s++)context_q[s].valid<=0;
      commit_valid<=0;done<=0;commit_write_valid<=0;
    end else begin
      context_q[0].valid<=rsp_valid;
      commit_valid<=context_q[LAST].valid;
      commit_write_valid<=context_q[LAST].valid;
      done<=context_q[LAST].valid&&context_q[LAST].meta.last;
    end
  end
  initial if(PSUM_BITS>24||DEQUANT_STAGES!=4||ACC_READ_LATENCY!=3)$fatal(1,"DEQACC configuration");
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)begin
    if(rd_data_valid!==(context_q[2].valid&&context_q[2].meta.add_old))$fatal(1,"DEQACC ACC response context mismatch");
    for(int r=0;r<2;r++)for(int n=0;n<TILE;n++)
      if(lane_valid[r][n]!==context_q[LAST].valid)$fatal(1,"DEQACC lane/context latency mismatch");
    if(rd_valid)for(int s=0;s<=LAST;s++)if(context_q[s].valid&&
      context_q[s].meta.acc_sel==rsp.meta.acc_sel&&address(context_q[s].meta)==rd_addr)
      $fatal(1,"DEQACC accumulator RAW hazard");
  end
  // synthesis translate_on
endmodule
