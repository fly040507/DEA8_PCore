import pcore_pkg::*;

// Two physical tile banks. Accept each A tile once, then issue Gate and Up
// copies in transport order 2*k, 2*k+1. No extra copy exists in the PE.
module dea8_gu_a_replay(
  input logic clk,reset,clear,
  input logic in_valid,output logic in_ready,input a2_t in_entry,
  output logic out_valid,input logic out_ready,output a2_t out_entry,
  output logic protocol_error
);
  localparam int DEPTH=2*PAIRS,AW=$clog2(DEPTH);
  logic [1:0] full_q;
  logic fill_bank_q,read_bank_q,up_q;
  logic [PAIR_BITS-1:0] fill_pair_q,read_pair_q;
  logic [TILE_BITS-1:0] expected_k_q,transport_q;
  a2_t data_q;
  logic read_en;
  logic [AW-1:0] read_address;
  always_comb begin
    read_en=0;read_address=AW'(read_bank_q*PAIRS+read_pair_q);
    if(!out_valid&&full_q[read_bank_q])read_en=1;
    else if(out_valid&&out_ready)begin
      if(read_pair_q!=PAIRS-1)begin read_en=1;read_address=AW'(read_bank_q*PAIRS+read_pair_q+1);end
      else if(!up_q)begin read_en=1;read_address=AW'(read_bank_q*PAIRS);end
      else if(full_q[!read_bank_q])begin read_en=1;read_address=AW'((!read_bank_q)*PAIRS);end
    end
  end
  dea8_sdp_ram #(.WIDTH($bits(a2_t)),.DEPTH(DEPTH)) memory(
    .clk,.rd_en(read_en),.rd_addr(read_address),.wr_en(in_valid&&in_ready),
    .wr_addr(AW'(fill_bank_q*PAIRS+fill_pair_q)),.wr_data(in_entry),.rd_data(data_q),.dbg_addr('0),.dbg_data());
  assign in_ready=!reset&&!clear&&!protocol_error&&!full_q[fill_bank_q];
  always_comb begin
    out_entry=data_q;
    out_entry.tile_idx=transport_q;
    out_entry.pair_idx=read_pair_q;
  end
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      full_q<=0;fill_bank_q<=0;read_bank_q<=0;up_q<=0;
      fill_pair_q<=0;read_pair_q<=0;expected_k_q<=0;transport_q<=0;
      out_valid<=0;protocol_error<=0;
    end else begin
      if(in_valid&&in_ready) begin
        if(in_entry.tile_idx!=expected_k_q||in_entry.pair_idx!=fill_pair_q||
           in_entry.row_valid!=row_mask(fill_pair_q)||in_entry.reserved!=0)
          protocol_error<=1;
        if(fill_pair_q==PAIRS-1) begin
          full_q[fill_bank_q]<=1;fill_bank_q<=!fill_bank_q;
          fill_pair_q<=0;expected_k_q<=expected_k_q+1'b1;
        end else fill_pair_q<=fill_pair_q+1'b1;
      end
      if(!out_valid&&full_q[read_bank_q]) begin
        out_valid<=1;
      end else if(out_valid&&out_ready) begin
        if(read_pair_q==PAIRS-1) begin
          read_pair_q<=0;transport_q<=transport_q+1'b1;
          if(!up_q) begin up_q<=1;end
          else begin
            up_q<=0;full_q[read_bank_q]<=0;read_bank_q<=!read_bank_q;
            // The next Gate tile can be exposed on the same edge as the
            // final Up pair when the alternate bank is already complete.
            // This removes the former one-cycle bubble at every k boundary;
            // if the bank is not ready, the normal elastic refill path keeps
            // out_valid low until it becomes complete.
            if(full_q[!read_bank_q]) begin
              out_valid<=1;
            end else out_valid<=0;
          end
        end else begin
          read_pair_q<=read_pair_q+1'b1;
        end
      end
    end
  end
endmodule
