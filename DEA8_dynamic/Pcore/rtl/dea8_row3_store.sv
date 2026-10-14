import pcore_pkg::*;

// Physical 1R1W row banks shared by A queue and future QOZ/PBUF managers.
// Requesters own completion/credit; the synchronous output holds without reads.
module dea8_row3_store #(
  parameter int TILES=A_SLOTS,
  parameter int ADDRESS_BITS=(TILES>1)?$clog2(TILES):1
) (
  input logic clk,reset,clear,
  input logic wr_valid,output logic wr_ready,
  input logic [ADDRESS_BITS-1:0] wr_tile,
  input logic [A_INPUT_ROWS-1:0][ROW_COUNT_BITS-1:0] wr_row,
  input logic [A_INPUT_ROWS-1:0] wr_mask,
  input qvec16_t [A_INPUT_ROWS-1:0] wr_entry,
  input logic rd_valid,output logic rd_ready,
  input logic [ADDRESS_BITS-1:0] rd_tile,
  input logic [A_INPUT_ROWS-1:0][ROW_COUNT_BITS-1:0] rd_row,
  input logic [A_INPUT_ROWS-1:0] rd_mask,
  output logic out_valid,output qvec16_t [A_INPUT_ROWS-1:0] out_entry,
  output logic protocol_error
);
  localparam int DEPTH=TILES*A_ROW_GROUPS;
  logic wr_legal,rd_legal,wr_fire,rd_fire;
  logic [A_INPUT_ROWS-1:0] mask_q;
  logic [$clog2(A_INPUT_ROWS)-1:0] bank_q[A_INPUT_ROWS];
  logic [ROW_BITS-1:0] bank_data[A_INPUT_ROWS];

  always_comb begin
    wr_legal=wr_tile<TILES&&wr_mask!=0;
    rd_legal=rd_tile<TILES&&rd_mask!=0;
    for(int i=0;i<A_INPUT_ROWS;i++)begin
      if(wr_mask[i]&&wr_row[i]>=ROWS)wr_legal=0;
      if(rd_mask[i]&&rd_row[i]>=ROWS)rd_legal=0;
      for(int j=0;j<i;j++)begin
        if(wr_mask[i]&&wr_mask[j]&&wr_row[i]%A_INPUT_ROWS==wr_row[j]%A_INPUT_ROWS)wr_legal=0;
        if(rd_mask[i]&&rd_mask[j]&&rd_row[i]%A_INPUT_ROWS==rd_row[j]%A_INPUT_ROWS)rd_legal=0;
      end
    end
  end
  assign wr_ready=!reset&&!clear&&!protocol_error&&wr_legal;
  assign rd_ready=!reset&&!clear&&!protocol_error&&rd_legal;
  assign wr_fire=wr_valid&&wr_ready;
  assign rd_fire=rd_valid&&rd_ready;

  for(genvar b=0;b<A_INPUT_ROWS;b++)begin: banks
    (* ram_style="block" *) logic [ROW_BITS-1:0] mem[0:DEPTH-1];
    always_ff @(posedge clk)begin
      for(int i=0;i<A_INPUT_ROWS;i++)begin
        if(wr_fire&&wr_mask[i]&&wr_row[i]%A_INPUT_ROWS==b)
          mem[int'(wr_tile)*A_ROW_GROUPS+int'(wr_row[i])/A_INPUT_ROWS]<=wr_entry[i];
        if(rd_fire&&rd_mask[i]&&rd_row[i]%A_INPUT_ROWS==b)
          bank_data[b]<=mem[int'(rd_tile)*A_ROW_GROUPS+int'(rd_row[i])/A_INPUT_ROWS];
      end
    end
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin out_valid<=0;mask_q<=0;protocol_error<=0;end
    else begin
      out_valid<=rd_fire;
      if((wr_valid&&!wr_legal)||(rd_valid&&!rd_legal))protocol_error<=1;
      if(rd_fire)begin
        mask_q<=rd_mask;
        for(int i=0;i<A_INPUT_ROWS;i++)bank_q[i]<=int'(rd_row[i])%A_INPUT_ROWS;
      end
    end
  end
  always_comb begin
    out_entry='0;
    for(int i=0;i<A_INPUT_ROWS;i++)if(mask_q[i])out_entry[i]=bank_data[bank_q[i]];
  end
  // synthesis translate_off
  always @(posedge clk)if(wr_fire&&rd_fire)
    for(int i=0;i<A_INPUT_ROWS;i++)for(int j=0;j<A_INPUT_ROWS;j++)
      if(wr_mask[i]&&rd_mask[j]&&wr_tile==rd_tile&&wr_row[i]==rd_row[j])
        $fatal(1,"row3 manager allowed a same-address read/write collision");
  initial if(TILES<1||A_INPUT_ROWS!=3)$fatal(1,"row3 geometry");
  // synthesis translate_on
endmodule
