import pcore_pkg::*;

// One immutable compact-to-original map. Owners supply the live reference fence.
module dea8_profile (
  input logic clk,reset,clear,in_use,
  input logic begin_valid,output logic begin_ready,
  input logic [ROW_COUNT_BITS-1:0] begin_rows,
  input logic [15:0] begin_id,begin_version,
  input logic wr_valid,output logic wr_ready,
  input logic [ROW_COUNT_BITS-1:0] wr_index,wr_original,
  input logic commit_valid,output logic commit_ready,
  output logic profile_valid,protocol_error,
  output logic [ROW_COUNT_BITS-1:0] m_rows,
  output logic [15:0] profile_id,profile_version,
  input logic rd_valid,output logic rd_ready,input logic [ROW_COUNT_BITS-1:0] rd_index,
  output logic out_valid,input logic out_ready,
  output logic [ROW_COUNT_BITS-1:0] out_index,out_original
);
  logic [ROW_COUNT_BITS-1:0] row_order[ROWS];
  logic [ROWS-1:0] written,original_seen;
  logic filling,write_legal;
  assign begin_ready=!reset&&!clear&&!in_use&&!filling&&!out_valid&&!protocol_error;
  assign write_legal=wr_index<m_rows&&wr_original<ROWS&&!written[wr_index]&&!original_seen[wr_original];
  assign wr_ready=!reset&&!clear&&!in_use&&filling&&!protocol_error&&write_legal;
  assign commit_ready=!reset&&!clear&&!in_use&&filling&&!protocol_error;
  assign rd_ready=!reset&&!clear&&!begin_valid&&!filling&&!protocol_error&&profile_valid&&rd_index<m_rows&&(!out_valid||out_ready);
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      filling<=0;profile_valid<=0;protocol_error<=0;out_valid<=0;
      written<=0;original_seen<=0;m_rows<=0;profile_id<=0;profile_version<=0;
    end else begin
      if(out_valid&&out_ready)out_valid<=0;
      if(begin_valid&&begin_ready)begin
        if(begin_rows>ROWS)protocol_error<=1;
        else begin
          filling<=1;profile_valid<=0;written<=0;original_seen<=0;
          m_rows<=begin_rows;profile_id<=begin_id;profile_version<=begin_version;
        end
      end
      if(wr_valid&&filling&&!in_use)begin
        if(!write_legal)protocol_error<=1;
        else if(wr_ready)begin
          row_order[wr_index]<=wr_original;written[wr_index]<=1;original_seen[wr_original]<=1;
        end
      end
      if(commit_valid&&commit_ready)begin
        if(written!=row_prefix(m_rows))protocol_error<=1;
        else begin filling<=0;profile_valid<=1;end
      end
      if(rd_valid&&rd_ready)begin
        out_valid<=1;out_index<=rd_index;out_original<=row_order[rd_index];
      end
    end
  end
endmodule
