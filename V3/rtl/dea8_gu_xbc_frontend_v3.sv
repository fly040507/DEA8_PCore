import pcore3_pkg::*;

// GU-only XBC front end.  Projection uses the normal two-lane XBC adapter;
// GU replay consumes one A2 entry per cycle, so this wrapper serializes one
// accepted XBC4 beat into its two ordered A2 pairs without changing payload.
module dea8_gu_xbc_frontend_v3(
  input logic clk,reset,clear,restart,
  input logic in_valid,output logic in_ready,input xbc4_t in_entry,
  output logic out_valid,input logic out_ready,output a2_t out_entry,
  output logic protocol_error
);
  logic active_q,second_q;
  a2_t pair_q[0:1];
  logic [TILE_BITS-1:0] tile_q;
  logic [PAIR_BITS-1:0] base_pair_q;
  logic [1:0] pair_valid_q;
  assign in_ready=!reset&&!clear&&!restart&&!protocol_error&&!active_q;
  assign out_valid=active_q&&pair_valid_q[second_q];
  assign out_entry=pair_q[second_q];
  always_ff @(posedge clk) begin
    if(reset||clear||restart) begin
      active_q<=0;second_q<=0;pair_valid_q<=0;tile_q<=0;base_pair_q<=0;
      pair_q[0]<='0;pair_q[1]<='0;protocol_error<=0;
    end else begin
      if(in_valid&&in_ready) begin
        // Each GU n-slice starts a new 64-tile A stream.  The adapter keeps
        // the same job alive across n, so tile 0/group 0 is the legal
        // sequence restart after the previous slice's tile 63.
        logic slice_start;
        slice_start=!active_q && in_entry.tile_idx=='0 && in_entry.group_idx=='0;
        for(int p=0;p<2;p++) begin
          a2_t entry;
          entry='0;
          entry.tile_idx=in_entry.tile_idx;
          entry.pair_idx=PAIR_BITS'((in_entry.group_idx<<1)+p);
          entry.row_valid=in_entry.row_valid[p*2 +: 2];
          entry.slot=in_entry.slot;
          entry.row[0]=in_entry.row[p*2];
          entry.row[1]=in_entry.row[p*2+1];
          pair_q[p]<=entry;
        end
        pair_valid_q<={|in_entry.row_valid[3:2],|in_entry.row_valid[1:0]};
        second_q<=|in_entry.row_valid[1:0]?1'b0:1'b1;
        active_q<=|in_entry.row_valid;
        if(slice_start) begin
          tile_q<=0;
          base_pair_q<=0;
        end else if(in_entry.tile_idx!=tile_q || in_entry.group_idx!=base_pair_q[PAIR_BITS-1:1])
          protocol_error<=1;
      end
      if(out_valid&&out_ready) begin
        if(second_q||!pair_valid_q[1]) begin
          active_q<=0;second_q<=0;pair_valid_q<=0;
          if(out_entry.pair_idx==PAIRS-1) begin tile_q<=out_entry.tile_idx+1'b1;base_pair_q<=0;end
          else base_pair_q<=out_entry.pair_idx+1'b1;
        end else second_q<=1;
      end
    end
  end
endmodule
