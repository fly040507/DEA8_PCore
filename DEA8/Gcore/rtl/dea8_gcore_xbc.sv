module dea8_gcore_xbc (
  input logic clk,reset,clear,
  input logic cmd_valid,
  output logic cmd_ready,
  input gcore_pkg::gcore_cmd_t cmd,
  output logic rd_valid,
  input logic rd_ready,
  output logic [5:0] rd_tile,
  output logic [3:0] rd_group,
  input logic rsp_valid,
  output logic rsp_ready,
  input pcore_pkg::xbc4_t rsp,
  output logic [gcore_pkg::CORES-1:0] xbc_valid,
  input logic [gcore_pkg::CORES-1:0] xbc_ready,
  output pcore_pkg::xbc4_t xbc,
  input logic [gcore_pkg::CORES-1:0] gu_prefetch_valid,
  output logic [gcore_pkg::CORES-1:0] gu_prefetch_ready,
  input logic [gcore_pkg::CORES-1:0][5:0] gu_prefetch_n,
  output logic done_valid,
  input logic done_ready,
  output gcore_pkg::gcore_done_t done,
  output logic busy,protocol_error
);
  import gcore_pkg::*;
  import pcore_pkg::*;
  localparam int BEATS_PER_N=HIDDEN_TILES*ROW_GROUPS;
  gcore_cmd_t command_q;
  logic [5:0] issue_n,allowed_n,grant_n,retired_n;
  logic [5:0] n_tiles;
  logic [3:0] group_q;
  logic [5:0] tile_q;
  logic issued_all,read_pending,multicast_empty,retire;
  logic [15:0] retired_count;
  logic [$clog2(BEATS_PER_N)-1:0] retired_in_n;
  logic [CORES-1:0] granted_q,grant_next;
  logic [3:0] expected_group;
  logic [5:0] expected_tile;
  logic response_bad,grant_bad,failed;
  logic multicast_ready,multicast_valid;
  logic [STORE_CREDIT_BITS-1:0] read_credits;

  assign cmd_ready=!busy&&!done_valid&&!reset&&!clear;
  assign rd_valid=busy&&!failed&&!issued_all&&!reset&&!clear&&read_credits<STORE_RESPONSE_DEPTH&&
    (command_q.pcore_op!=OP_GU || issue_n<=allowed_n);
  assign rd_tile=tile_q;
  assign rd_group=group_q;
  assign response_bad=!read_pending || rsp.tile_idx!=expected_tile ||
    rsp.group_idx!=expected_group || rsp.slot!=0 || rsp.reserved!=0 ||
    rsp.row_valid!=((expected_group==ROW_GROUPS-1)?4'b0111:4'b1111) ||
    (expected_group==ROW_GROUPS-1&&rsp.row[3]!='0);
  // read_pending is a count, rather than a fixed latency assumption: the
  // synchronous store may hold a response while one broadcast is outstanding.
  assign read_pending=(read_credits!=0);
  assign rsp_ready=busy&&!reset&&!clear&&(failed||response_bad||multicast_ready);
  assign multicast_valid=rsp_valid&&busy&&!failed&&!response_bad;

  dea8_gcore_multicast #(.WIDTH($bits(xbc4_t)),.OUTPUTS(CORES)) fanout (
    .clk,.reset,.clear,
    .in_valid(multicast_valid),.in_ready(multicast_ready),.in_data(rsp),.in_mask(command_q.core_mask),
    .out_valid(xbc_valid),.out_ready(xbc_ready),.out_data(xbc),.retired(retire),.empty(multicast_empty)
  );
  always_comb begin
    gu_prefetch_ready='0; grant_next=granted_q; grant_bad=0;
    for(int c=0;c<CORES;c++) begin
      if(busy&&!failed&&command_q.pcore_op==OP_GU&&grant_n<n_tiles&&
          grant_n<=retired_n+1&&!granted_q[c]&&!reset&&!clear) begin
        gu_prefetch_ready[c]=1;
        if(gu_prefetch_valid[c]) begin
          if(gu_prefetch_n[c]!=grant_n) grant_bad=1;
          else grant_next[c]=1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      busy<=0; done_valid<=0; done<='0; protocol_error<=0; command_q<='0;
      issue_n<=0; allowed_n<=0; grant_n<=1; retired_n<=0; n_tiles<=0;
      group_q<=0; tile_q<=0; issued_all<=0; retired_count<=0; retired_in_n<=0;
      granted_q<=0; read_credits<=0; expected_group<=0; expected_tile<=0;
      failed<=0;
    end else begin
      if(done_valid&&done_ready) done_valid<=0;
      if(cmd_valid&&cmd_ready) begin
        command_q<=cmd; issue_n<=0; allowed_n<=0; grant_n<=1; retired_n<=0;
        group_q<=0; tile_q<=0; issued_all<=0; retired_count<=0; retired_in_n<=0;
        granted_q<=0; read_credits<=0; expected_group<=0; expected_tile<=0;
        failed<=0; n_tiles<=6'(xbc_tiles(cmd.pcore_op));
        if(cmd.opcode!=GC_XBC_RUN || xbc_tiles(cmd.pcore_op)==0 || cmd.core_mask!=8'hff) begin
          done<=make_done(cmd,GC_INVALID_CMD,0); done_valid<=1;
        end else busy<=1;
      end
      if(busy) begin
        case({rd_valid&&rd_ready,rsp_valid&&rsp_ready&&read_pending})
          2'b10:read_credits<=read_credits+1'b1;
          2'b01:if(read_credits!=0) read_credits<=read_credits-1'b1;
          default:;
        endcase
        if(rd_valid&&rd_ready) begin
          if(group_q==ROW_GROUPS-1) begin
            group_q<=0;
            if(tile_q==HIDDEN_TILES-1) begin
              tile_q<=0;
              if(issue_n==n_tiles-1) issued_all<=1;
              else issue_n<=issue_n+1'b1;
            end else tile_q<=tile_q+1'b1;
          end else group_q<=group_q+1'b1;
        end
        if(rsp_valid&&rsp_ready&&!failed) begin
          if(response_bad) begin protocol_error<=1; failed<=1; end
          else begin
            if(expected_group==ROW_GROUPS-1) begin expected_group<=0; expected_tile<=expected_tile+1'b1; end
            else expected_group<=expected_group+1'b1;
          end
        end
        if(grant_bad) begin protocol_error<=1; failed<=1; end
        else if(grant_next==command_q.core_mask && command_q.pcore_op==OP_GU) begin
          allowed_n<=grant_n; grant_n<=grant_n+1'b1; granted_q<=0;
        end else granted_q<=grant_next;
        if(retire&&!failed&&!grant_bad&&!(rsp_valid&&rsp_ready&&response_bad)) begin
          retired_count<=retired_count+1'b1;
          if(retired_in_n==BEATS_PER_N-1) begin retired_in_n<=0; retired_n<=retired_n+1'b1; end
          else retired_in_n<=retired_in_n+1'b1;
          if(retired_count==expected_items(command_q)-1) begin
            done<=make_done(command_q,GC_OK,expected_items(command_q)); done_valid<=1; busy<=0;
          end
        end
        if(failed&&read_credits==0&&multicast_empty) begin
          done<=make_done(command_q,GC_SOURCE_PROTOCOL,retired_count); done_valid<=1; busy<=0;
        end
      end
    end
  end
endmodule
