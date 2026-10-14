import pcore_pkg::*;

// Normalizes local Q/O/Z/P reads to the same A slot protocol as XBC.
module dea8_local_job_loader (
  input logic clk,reset,clear,
  input logic work_valid,output logic work_ready,input compute_job_t work,
  input local_kind_e kind,input logic [15:0] content_version,
  output logic cmd_valid,input logic cmd_ready,output local_load_cmd_t cmd,
  output logic protocol_error
);
  compute_job_t owner;
  local_kind_e kind_q;
  logic [15:0] version_q;
  logic [SEQ_BITS-1:0] next_tile,occurrence;
  logic active;
  int uses;
  assign work_ready=!active&&!reset&&!clear&&!protocol_error;
  assign uses=owner.nt_per_tile?int'(owner.tiles):1;
  assign cmd_valid=active&&!reset&&!clear&&!protocol_error;
  always_comb begin
    cmd='0;cmd.destination.token=owner.token;cmd.destination.work_seq=owner.work_seq;
    cmd.destination.first_tile=next_tile;cmd.destination.occurrence_seq=occurrence;
    cmd.destination.m_rows=owner.m_rows;cmd.destination.uses=5'(uses);
    cmd.kind=kind_q;cmd.set_id=kind_q==LOCAL_P?owner.block_id[0]:1'b0;
    cmd.content_version=version_q;cmd.tile=owner.nt_per_tile?TILE_BITS'(0):TILE_BITS'(next_tile);
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin active<=0;owner<='0;kind_q<=LOCAL_NONE;version_q<=0;next_tile<=0;occurrence<=0;protocol_error<=0;end
    else begin
      if(work_valid&&work_ready)begin
        if(kind<LOCAL_Q||kind>LOCAL_P||work.m_rows==0||work.tiles==0)protocol_error<=1;
        else begin active<=1;owner<=work;kind_q<=kind;version_q<=content_version;next_tile<=0;occurrence<=0;end
      end
      if(cmd_valid&&cmd_ready)begin
        next_tile<=next_tile+SEQ_BITS'(uses);occurrence<=occurrence+1'b1;
        if(int'(next_tile)+uses==int'(owner.tiles))active<=0;
      end
    end
  end
endmodule
