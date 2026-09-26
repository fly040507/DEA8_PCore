import pcore3_pkg::*;

// A4 is only an external ingestion format.  Internally every beat becomes two
// ordered A2 entries, so the MXU still consumes one A2 per cycle.
module dea8_xbc4_adapter_v3 (
  input logic clk,reset,clear,
  input logic in_valid,
  output logic in_ready,
  input xbc4_t in_entry,
  output logic [1:0] out_valid,
  input logic [1:0] out_ready,
  output a2_t out_entry[0:1]
);
  logic [PAIR_BITS-1:0] pair_base;
  assign pair_base=PAIR_BITS'(in_entry.group_idx<<1);
  assign in_ready=!reset&&!clear&&out_ready[0]&&out_ready[1];
  assign out_valid={2{in_valid&&in_ready}};
  always_comb begin
    for(int p=0;p<2;p++) begin
      out_entry[p].row[0]='0;out_entry[p].row[1]='0;
      out_entry[p].row_valid='0;out_entry[p].pair_idx='0;out_entry[p].tile_idx='0;
      out_entry[p].slot=0;out_entry[p].reserved='0;
      out_entry[p].pair_idx=pair_base+p;
      out_entry[p].tile_idx=in_entry.tile_idx;
      out_entry[p].slot=in_entry.slot;
      out_entry[p].row_valid=in_entry.row_valid[p*2 +: 2];
      out_entry[p].row[0]=in_entry.row[p*2];
      out_entry[p].row[1]=in_entry.row[p*2+1];
    end
  end
endmodule
