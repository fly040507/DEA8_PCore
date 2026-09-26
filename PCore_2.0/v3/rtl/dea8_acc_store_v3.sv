import pcore3_pkg::*;

// Parity-split accumulator storage.  The data arrays intentionally have no
// reset branch: only the small valid maps are reset, so BRAM/LUTRAM inference
// is not defeated by a full-memory reset loop.
module dea8_acc_store_v3 (
  input logic clk,reset,clear,
  input logic rd_valid,
  input acc_sel_e rd_sel,
  input logic [9:0] rd_addr,
  output logic rd_data_valid,
  output logic [15:0][31:0] rd_even_data,
  output logic [15:0][31:0] rd_odd_data,
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
  logic [31:0] facc_a_even[0:25][0:15],facc_a_odd[0:24][0:15];
  logic [31:0] facc_b_even[0:25][0:15],facc_b_odd[0:24][0:15];
  logic [31:0] oacc_even[0:415][0:15],oacc_odd[0:399][0:15];
  logic facc_a_even_v[0:25][0:15],facc_a_odd_v[0:24][0:15];
  logic facc_b_even_v[0:25][0:15],facc_b_odd_v[0:24][0:15];
  logic oacc_even_v[0:415][0:15],oacc_odd_v[0:399][0:15];
  logic [9:0] rd_addr_q;
  acc_sel_e rd_sel_q;
  logic rd_valid_q;

  function automatic logic [31:0] read_even(input acc_sel_e sel,input logic [9:0] addr,input int lane);
    read_even=0;
    if(lane<16) begin
      case(sel)
        ACC_FACC_A: if(addr<26 && facc_a_even_v[addr][lane]) read_even=facc_a_even[addr][lane];
        ACC_FACC_B: if(addr<26 && facc_b_even_v[addr][lane]) read_even=facc_b_even[addr][lane];
        ACC_OACC: if(addr<416 && oacc_even_v[addr][lane]) read_even=oacc_even[addr][lane];
        default: ;
      endcase
    end
  endfunction
  function automatic logic [31:0] read_odd(input acc_sel_e sel,input logic [9:0] addr,input int lane);
    read_odd=0;
    if(lane<16) begin
      case(sel)
        ACC_FACC_A: if(addr<25 && facc_a_odd_v[addr][lane]) read_odd=facc_a_odd[addr][lane];
        ACC_FACC_B: if(addr<25 && facc_b_odd_v[addr][lane]) read_odd=facc_b_odd[addr][lane];
        ACC_OACC: if(addr<400 && oacc_odd_v[addr][lane]) read_odd=oacc_odd[addr][lane];
        default: ;
      endcase
    end
  endfunction

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      rd_valid_q<=0;rd_addr_q<='0;rd_sel_q<=ACC_FACC_A;
      for(int a=0;a<26;a++) for(int n=0;n<16;n++) begin
        facc_a_even_v[a][n]<=0;facc_b_even_v[a][n]<=0;
      end
      for(int a=0;a<25;a++) for(int n=0;n<16;n++) begin
        facc_a_odd_v[a][n]<=0;facc_b_odd_v[a][n]<=0;
      end
      for(int a=0;a<416;a++) for(int n=0;n<16;n++) oacc_even_v[a][n]<=0;
      for(int a=0;a<400;a++) for(int n=0;n<16;n++) oacc_odd_v[a][n]<=0;
    end else begin
      rd_valid_q<=rd_valid;rd_addr_q<=rd_addr;rd_sel_q<=rd_sel;
      if(wr_valid) begin
        for(int n=0;n<16;n++) begin
          if(wr_even_valid) case(wr_sel)
            ACC_FACC_A: if(wr_addr<26) begin facc_a_even[wr_addr][n]<=wr_even_data;facc_a_even_v[wr_addr][n]<=1;end
            ACC_FACC_B: if(wr_addr<26) begin facc_b_even[wr_addr][n]<=wr_even_data;facc_b_even_v[wr_addr][n]<=1;end
            ACC_OACC: if(wr_addr<416) begin oacc_even[wr_addr][n]<=wr_even_data;oacc_even_v[wr_addr][n]<=1;end
            default: ;
          endcase
          if(wr_odd_valid) case(wr_sel)
            ACC_FACC_A: if(wr_addr<25) begin facc_a_odd[wr_addr][n]<=wr_odd_data;facc_a_odd_v[wr_addr][n]<=1;end
            ACC_FACC_B: if(wr_addr<25) begin facc_b_odd[wr_addr][n]<=wr_odd_data;facc_b_odd_v[wr_addr][n]<=1;end
            ACC_OACC: if(wr_addr<400) begin oacc_odd[wr_addr][n]<=wr_odd_data;oacc_odd_v[wr_addr][n]<=1;end
            default: ;
          endcase
        end
      end
    end
  end

  // One-cycle synchronous read response from the registered request.
  assign rd_data_valid=rd_valid_q;
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
