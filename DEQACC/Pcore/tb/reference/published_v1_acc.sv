import pcore_pkg::*;

// Four columns, three banks, two parity planes. One local bitmap per parity
// bank is shared by its two 64-bit RAMs. RAM read/write remain read-first.
module published_v1_acc(
  input logic clk,reset,clear,
  input logic rd_valid,input acc_sel_e rd_sel,input logic [9:0] rd_addr,
  output logic [1:0][3:0][31:0] old_data,
  input logic wr_valid,input acc_sel_e wr_sel,input logic [9:0] wr_addr,
  input logic [1:0] wr_rows,input logic [1:0][3:0][31:0] wr_data,
  input logic external_rd_fire,input acc_sel_e external_rd_sel,input logic [9:0] external_rd_addr,
  output logic [1:0][3:0][31:0] external_data,
  input logic external_wr_fire,input acc_sel_e external_wr_sel,input logic [9:0] external_wr_addr,
  input logic [1:0] external_wr_rows,input logic [1:0][3:0][31:0] external_wr_data,
  input acc_sel_e dbg_sel,input logic dbg_parity,input logic [9:0] dbg_addr,
  input logic [1:0] dbg_column,output logic [31:0] dbg_data
);
  logic [127:0] data_by_bank[0:2][0:1];
  logic [31:0] debug_by_bank[0:2][0:1][0:1];
  acc_sel_e read_sel_q,external_sel_q;
  for(genvar b=0;b<3;b++)begin: banks
    for(genvar p=0;p<2;p++)begin: parity
      localparam int DEPTH=(p==0?(ROWS+1)/2:ROWS/2)*(b==2?TILE:1);
      localparam int AW=$clog2(DEPTH);
      logic [DEPTH-1:0] valid_map;
      wire mr=rd_valid&&rd_sel==b;
      wire er=external_rd_fire&&external_rd_sel==b;
      wire mw=wr_valid&&wr_sel==b;
      wire ew=external_wr_fire&&external_wr_sel==b;
      wire [9:0] ra=mr?rd_addr:external_rd_addr;
      wire [9:0] wa=mw?wr_addr:external_wr_addr;
      wire we=mw?wr_rows[p]:(ew&&external_wr_rows[p]);
      wire initialized=ra<DEPTH?valid_map[ra[AW-1:0]]:1'b0;
      always_ff @(posedge clk)begin
        if(reset||clear)valid_map<=0;
        else if(we&&wa<DEPTH)valid_map[wa[AW-1:0]]<=1;
      end
      for(genvar micro=0;micro<2;micro++)begin: halves
        wire [63:0] wd=mw?wr_data[p][micro*2+:2]:external_wr_data[p][micro*2+:2];
        dea8_acc_bank #(.DEPTH(DEPTH),.WIDTH(64),.SHARED_VALIDITY(1),
          .STYLE(b==2?"block":"distributed")) ram(
          .clk,.reset,.clear,.rd_en(mr||er),.wr_en(we),.rd_initialized(initialized),
          .rd_addr(ra),.wr_addr(wa),.wr_data(wd),.rd_data(data_by_bank[b][p][micro*64+:64]),
          .rd_data_raw(),.rd_word_valid(),.dbg_addr,.dbg_lane({3'b0,dbg_column[0]}),
          .dbg_data(debug_by_bank[b][p][micro]));
      end
    end
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin read_sel_q<=ACC_FACC_A;external_sel_q<=ACC_FACC_A;end
    else begin
      if(rd_valid)read_sel_q<=rd_sel;
      if(external_rd_fire)external_sel_q<=external_rd_sel;
    end
  end
  for(genvar p=0;p<2;p++)begin: output_parity
    assign old_data[p]=data_by_bank[read_sel_q][p];
    assign external_data[p]=data_by_bank[external_sel_q][p];
  end
  always_comb begin
    dbg_data=0;
    // synthesis translate_off
    case(dbg_sel)
      ACC_FACC_A: if(dbg_addr<(dbg_parity?ROWS/2:(ROWS+1)/2))
        dbg_data=dbg_parity?(banks[0].parity[1].valid_map[dbg_addr]?debug_by_bank[0][1][dbg_column[1]]:0):
          (banks[0].parity[0].valid_map[dbg_addr]?debug_by_bank[0][0][dbg_column[1]]:0);
      ACC_FACC_B: if(dbg_addr<(dbg_parity?ROWS/2:(ROWS+1)/2))
        dbg_data=dbg_parity?(banks[1].parity[1].valid_map[dbg_addr]?debug_by_bank[1][1][dbg_column[1]]:0):
          (banks[1].parity[0].valid_map[dbg_addr]?debug_by_bank[1][0][dbg_column[1]]:0);
      ACC_OACC: if(dbg_addr<(dbg_parity?ROWS/2:(ROWS+1)/2)*TILE)
        dbg_data=dbg_parity?(banks[2].parity[1].valid_map[dbg_addr]?debug_by_bank[2][1][dbg_column[1]]:0):
          (banks[2].parity[0].valid_map[dbg_addr]?debug_by_bank[2][0][dbg_column[1]]:0);
      default: dbg_data=0;
    endcase
    // synthesis translate_on
  end
endmodule
