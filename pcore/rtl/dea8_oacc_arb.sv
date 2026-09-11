import dea8_pcore_pkg::*;

// Arbitrates the single logical OACC 1R1W memory between PV update,
// OACC_SCALE and A_FIN. A synchronous read response is returned one cycle
// later to the client that issued the request.
module dea8_oacc_arb (
  input logic clk,
  input logic rst_n,

  input logic pv_rd_valid,
  output logic pv_rd_ready,
  input logic [ACC_ADDR_BITS-1:0] pv_rd_addr,
  output logic pv_rsp_valid,
  output logic [DW_VEC-1:0] pv_rsp_data,
  input logic pv_wr_valid,
  input logic [ACC_ADDR_BITS-1:0] pv_wr_addr,
  input logic [DW_VEC-1:0] pv_wr_data,

  input logic scale_rd_valid,
  output logic scale_rd_ready,
  input logic [ACC_ADDR_BITS-1:0] scale_rd_addr,
  output logic scale_rsp_valid,
  output logic [DW_VEC-1:0] scale_rsp_data,
  input logic scale_wr_valid,
  input logic [ACC_ADDR_BITS-1:0] scale_wr_addr,
  input logic [DW_VEC-1:0] scale_wr_data,

  input logic afin_rd_valid,
  output logic afin_rd_ready,
  input logic [ACC_ADDR_BITS-1:0] afin_rd_addr,
  output logic afin_rsp_valid,
  output logic [DW_VEC-1:0] afin_rsp_data,

  output logic mem_rd_en,
  output logic [ACC_ADDR_BITS-1:0] mem_rd_addr,
  input logic [DW_VEC-1:0] mem_rd_data,
  output logic mem_wr_en,
  output logic [ACC_ADDR_BITS-1:0] mem_wr_addr,
  output logic [DW_VEC-1:0] mem_wr_data
);
  oacc_owner_e rd_owner_q;
  logic rd_valid_q;
  logic [1:0] read_request_count;
  logic [1:0] write_request_count;

  always_comb begin
    pv_rd_ready    = 1'b0;
    scale_rd_ready = 1'b0;
    afin_rd_ready  = 1'b0;
    mem_rd_en      = 1'b0;
    mem_rd_addr    = '0;

    // These clients occupy non-overlapping 816-cycle OACC phases. Priority is
    // only a defensive choice; assertions below flag an invalid overlap.
    if (pv_rd_valid) begin
      mem_rd_en   = 1'b1;
      mem_rd_addr = pv_rd_addr;
      pv_rd_ready = 1'b1;
    end else if (scale_rd_valid) begin
      mem_rd_en      = 1'b1;
      mem_rd_addr    = scale_rd_addr;
      scale_rd_ready = 1'b1;
    end else if (afin_rd_valid) begin
      mem_rd_en     = 1'b1;
      mem_rd_addr   = afin_rd_addr;
      afin_rd_ready = 1'b1;
    end

    mem_wr_en   = 1'b0;
    mem_wr_addr = '0;
    mem_wr_data = '0;
    if (pv_wr_valid) begin
      mem_wr_en   = 1'b1;
      mem_wr_addr = pv_wr_addr;
      mem_wr_data = pv_wr_data;
    end else if (scale_wr_valid) begin
      mem_wr_en   = 1'b1;
      mem_wr_addr = scale_wr_addr;
      mem_wr_data = scale_wr_data;
    end

    read_request_count = pv_rd_valid + scale_rd_valid + afin_rd_valid;
    write_request_count = pv_wr_valid + scale_wr_valid;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_valid_q <= 1'b0;
      rd_owner_q <= OACC_OWNER_NONE;
    end else begin
      rd_valid_q <= mem_rd_en;
      if (pv_rd_valid && pv_rd_ready) rd_owner_q <= OACC_OWNER_PV;
      else if (scale_rd_valid && scale_rd_ready) rd_owner_q <= OACC_OWNER_SCALE;
      else if (afin_rd_valid && afin_rd_ready) rd_owner_q <= OACC_OWNER_AFIN;
      else rd_owner_q <= OACC_OWNER_NONE;
    end
  end

  assign pv_rsp_valid    = rd_valid_q && (rd_owner_q == OACC_OWNER_PV);
  assign scale_rsp_valid = rd_valid_q && (rd_owner_q == OACC_OWNER_SCALE);
  assign afin_rsp_valid  = rd_valid_q && (rd_owner_q == OACC_OWNER_AFIN);
  assign pv_rsp_data     = mem_rd_data;
  assign scale_rsp_data  = mem_rd_data;
  assign afin_rsp_data   = mem_rd_data;

  ap_one_reader: assert property (@(posedge clk) disable iff (!rst_n)
    read_request_count <= 1);
  ap_one_writer: assert property (@(posedge clk) disable iff (!rst_n)
    write_request_count <= 1);

endmodule
