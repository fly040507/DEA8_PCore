import pcore3_pkg::*;

// Parity-split accumulator storage.  The data arrays intentionally have no
// reset branch: only the small valid maps are reset, so BRAM/LUTRAM inference
// is not defeated by a full-memory reset loop.
module dea8_acc_store_v3 #(
  parameter int ROWS_P=ROWS,
  parameter int OUT_TILES_P=TILE
) (
  input logic clk,reset,clear,
  input logic rd_valid,
  input acc_sel_e rd_sel,
  input logic [9:0] rd_addr,
  output logic rd_data_valid,
  output logic [15:0][31:0] rd_even_data,
  output logic [15:0][31:0] rd_odd_data,
  input acc_read_owner_e result_rd_owner,
  input logic result_rd_valid,
  input acc_sel_e result_rd_sel,
  input logic [9:0] result_rd_addr,
  output logic result_rd_data_valid,
  output logic [15:0][31:0] result_even_data,
  output logic [15:0][31:0] result_odd_data,
  input logic wr_valid,
  input acc_sel_e wr_sel,
  input logic wr_even_valid,wr_odd_valid,
  input logic [9:0] wr_addr,
  input logic [15:0][31:0] wr_even_data,wr_odd_data,
  input logic dbg_valid,
  input acc_sel_e dbg_sel,
  input logic dbg_parity,
  input logic [9:0] dbg_addr,
  input logic [3:0] dbg_lane,
  output logic [31:0] dbg_data
);
  localparam int PAIRS_P=(ROWS_P+1)/2;
  localparam int OACC_EVEN_DEPTH=PAIRS_P*OUT_TILES_P;
  localparam int OACC_ODD_DEPTH=PAIRS_P*OUT_TILES_P;
  logic [31:0] facc_a_even[0:PAIRS_P-1][0:OUT_TILES_P-1];
  logic [31:0] facc_a_odd [0:PAIRS_P-1][0:OUT_TILES_P-1];
  logic [31:0] facc_b_even[0:PAIRS_P-1][0:OUT_TILES_P-1];
  logic [31:0] facc_b_odd [0:PAIRS_P-1][0:OUT_TILES_P-1];
  logic [31:0] oacc_even[0:OACC_EVEN_DEPTH-1][0:OUT_TILES_P-1];
  logic [31:0] oacc_odd [0:OACC_ODD_DEPTH-1][0:OUT_TILES_P-1];
  logic facc_a_even_v[0:PAIRS_P-1],facc_a_odd_v[0:PAIRS_P-1];
  logic facc_b_even_v[0:PAIRS_P-1],facc_b_odd_v[0:PAIRS_P-1];
  logic oacc_even_v[0:OACC_EVEN_DEPTH-1],oacc_odd_v[0:OACC_ODD_DEPTH-1];
  logic [9:0] rd_addr_q;
  acc_sel_e rd_sel_q;
  logic rd_valid_q;
  logic [9:0] result_rd_addr_q;
  acc_sel_e result_rd_sel_q;
  logic result_rd_valid_q;

  function automatic logic [31:0] read_even(input acc_sel_e sel,input logic [9:0] addr,input int lane);
    read_even=0;
    if(lane<16) begin
      case(sel)
        ACC_FACC_A: if(addr<PAIRS_P && facc_a_even_v[addr]) read_even=facc_a_even[addr][lane];
        ACC_FACC_B: if(addr<PAIRS_P && facc_b_even_v[addr]) read_even=facc_b_even[addr][lane];
        ACC_OACC: if(addr<OACC_EVEN_DEPTH && oacc_even_v[addr]) read_even=oacc_even[addr][lane];
        default: ;
      endcase
    end
  endfunction
  function automatic logic [31:0] read_odd(input acc_sel_e sel,input logic [9:0] addr,input int lane);
    read_odd=0;
    if(lane<16) begin
      case(sel)
        ACC_FACC_A: if(addr<PAIRS_P && facc_a_odd_v[addr]) read_odd=facc_a_odd[addr][lane];
        ACC_FACC_B: if(addr<PAIRS_P && facc_b_odd_v[addr]) read_odd=facc_b_odd[addr][lane];
        ACC_OACC: if(addr<OACC_ODD_DEPTH && oacc_odd_v[addr]) read_odd=oacc_odd[addr][lane];
        default: ;
      endcase
    end
  endfunction

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      rd_valid_q<=0;rd_addr_q<='0;rd_sel_q<=ACC_FACC_A;
      for(int a=0;a<PAIRS_P;a++) begin facc_a_even_v[a]<=0;facc_b_even_v[a]<=0;facc_a_odd_v[a]<=0;facc_b_odd_v[a]<=0;end
      for(int a=0;a<OACC_EVEN_DEPTH;a++) oacc_even_v[a]<=0;
      for(int a=0;a<OACC_ODD_DEPTH;a++) oacc_odd_v[a]<=0;
    end else begin
      rd_valid_q<=rd_valid;rd_addr_q<=rd_addr;rd_sel_q<=rd_sel;
      if(wr_valid) begin
        for(int n=0;n<16;n++) begin
          if(wr_even_valid) case(wr_sel)
            ACC_FACC_A: if(wr_addr<PAIRS_P) begin facc_a_even[wr_addr][n]<=wr_even_data[n];facc_a_even_v[wr_addr]<=1;end
            ACC_FACC_B: if(wr_addr<PAIRS_P) begin facc_b_even[wr_addr][n]<=wr_even_data[n];facc_b_even_v[wr_addr]<=1;end
            ACC_OACC: if(wr_addr<OACC_EVEN_DEPTH) begin oacc_even[wr_addr][n]<=wr_even_data[n];oacc_even_v[wr_addr]<=1;end
            default: ;
          endcase
          if(wr_odd_valid) case(wr_sel)
            ACC_FACC_A: if(wr_addr<PAIRS_P) begin facc_a_odd[wr_addr][n]<=wr_odd_data[n];facc_a_odd_v[wr_addr]<=1;end
            ACC_FACC_B: if(wr_addr<PAIRS_P) begin facc_b_odd[wr_addr][n]<=wr_odd_data[n];facc_b_odd_v[wr_addr]<=1;end
            ACC_OACC: if(wr_addr<OACC_ODD_DEPTH) begin oacc_odd[wr_addr][n]<=wr_odd_data[n];oacc_odd_v[wr_addr]<=1;end
            default: ;
          endcase
        end
      end
    end
  end

  // One-cycle synchronous read response from the registered request.
  assign rd_data_valid=rd_valid_q;
  // Generic result reads use the same one-cycle registered request contract
  // as the internal DEQACC read port.  Keeping the data combinational after
  // the request register makes the valid pulse and the vector data refer to
  // exactly the same address.
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      result_rd_valid_q<=0;result_rd_addr_q<='0;result_rd_sel_q<=ACC_FACC_A;
    end else begin
      result_rd_valid_q<=result_rd_valid && result_rd_owner==ACC_READ_RESULT;
      if(result_rd_valid && result_rd_owner==ACC_READ_RESULT) begin
        result_rd_addr_q<=result_rd_addr;
        result_rd_sel_q<=result_rd_sel;
      end
    end
  end
  assign result_rd_data_valid=result_rd_valid_q;
  always_comb begin
    result_even_data='0;result_odd_data='0;
    if(result_rd_valid_q) begin
      for(int n=0;n<16;n++) begin
        result_even_data[n]=read_even(result_rd_sel_q,result_rd_addr_q,n);
        result_odd_data[n]=read_odd(result_rd_sel_q,result_rd_addr_q,n);
      end
    end
  end
  always_comb begin
    rd_even_data='0;rd_odd_data='0;
    for(int n=0;n<16;n++) begin
      rd_even_data[n]=read_even(rd_sel_q,rd_addr_q,n);
      rd_odd_data[n]=read_odd(rd_sel_q,rd_addr_q,n);
    end
  end

  always_comb begin
    dbg_data=0;
    if(dbg_valid) dbg_data=dbg_parity?read_odd(dbg_sel,dbg_addr,dbg_lane):read_even(dbg_sel,dbg_addr,dbg_lane);
  end
endmodule
