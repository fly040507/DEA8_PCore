import pcore_pkg::*;

// One G/U output tile buffer.  Capture is pair based because DEQACC commits
// two rows at once; the VPU-facing port is row based and takes 51 cycles.
// The two 512-bit outputs are intentionally kept separate: one row of Gate
// and the corresponding row of Up are available in the same cycle.
module dea8_gu_pair_buffer #(
  parameter int ROWS_P=ROWS,
  parameter int PAIRS_P=PAIRS
) (
  input logic clk,reset,clear,
  input logic reserve_valid,
  output logic reserve_ready,
  input logic [EPOCH_BITS-1:0] reserve_epoch,
  input logic [2:0] reserve_head,
  input logic [5:0] reserve_n,
  input logic capture_valid,
  output logic capture_ready,
  input logic capture_branch,
  input logic [PAIR_BITS-1:0] capture_pair,
  input logic [1:0] capture_row_valid,
  input logic [15:0][31:0] capture_even,
  input logic [15:0][31:0] capture_odd,
  input logic [EPOCH_BITS-1:0] capture_epoch,
  input logic [2:0] capture_head,
  input logic [5:0] capture_n,
  input logic input_consumed,
  output logic out_valid,
  input logic out_ready,
  output logic [5:0] out_row,
  output logic [15:0][31:0] out_gate,
  output logic [15:0][31:0] out_up,
  output logic [1:0] out_row_valid,
  output logic [EPOCH_BITS-1:0] out_epoch,
  output logic [2:0] out_head,
  output logic [5:0] out_n,
  output logic out_last,
  output logic complete,
  output logic protocol_error
);
  // Gate and Up are separate logical memories so each branch can be captured
  // independently, while the implementation is explicitly eligible for
  // block RAM inference instead of silently becoming LUTRAM.
  (* ram_style="block" *) logic [511:0] data_mem [0:1][0:ROWS_P-1];
  logic [ROWS_P-1:0] gate_valid_q,up_valid_q;
  logic [6:0] gate_count_q,up_count_q;
  logic reserved_q;
  logic [EPOCH_BITS-1:0] epoch_q;
  logic [2:0] head_q;
  logic [5:0] n_q;
  logic [5:0] row_q;

  logic capture_fire,reserve_fire,out_fire;
  assign reserve_ready=!reset&&!clear&&!reserved_q;
  assign reserve_fire=reserve_valid&&reserve_ready;
  assign capture_ready=!reset&&!clear&&reserved_q&&!complete&&!protocol_error;
  assign capture_fire=capture_valid&&capture_ready;
  assign out_valid=complete&&!protocol_error;
  assign out_fire=out_valid&&out_ready;

  always_comb begin
    out_gate='0;out_up='0;out_row_valid='0;
    if(out_valid) begin
      out_gate=data_mem[0][row_q];
      out_up=data_mem[1][row_q];
      // One row, not one pair, is delivered by this interface.
      out_row_valid=2'b01;
    end
  end
  assign out_row=row_q;
  assign out_epoch=epoch_q;
  assign out_head=head_q;
  assign out_n=n_q;
  assign out_last=out_valid&&(row_q==ROWS_P-1);

  always_ff @(posedge clk) begin
    if(reset||clear) begin
      reserved_q<=0;complete<=0;protocol_error<=0;row_q<=0;
      epoch_q<=0;head_q<=0;n_q<=0;gate_valid_q<='0;up_valid_q<='0;
      gate_count_q<=0;up_count_q<=0;
    end else begin
      if(reserve_fire) begin
        reserved_q<=1;complete<=0;row_q<=0;
        epoch_q<=reserve_epoch;head_q<=reserve_head;n_q<=reserve_n;
        gate_valid_q<='0;up_valid_q<='0;
        gate_count_q<=0;up_count_q<=0;
      end
      if(capture_valid && !capture_ready) protocol_error<=1;
      if(capture_fire) begin
        if(capture_epoch!=epoch_q||capture_head!=head_q||capture_n!=n_q||
           capture_pair>=PAIRS_P||capture_row_valid!=row_mask(capture_pair))
          protocol_error<=1;
        else begin
          if(capture_branch==0 && gate_valid_q[capture_pair*2]) protocol_error<=1;
          if(capture_branch==1 && up_valid_q[capture_pair*2]) protocol_error<=1;
          data_mem[capture_branch][capture_pair*2]<=capture_even;
          if(capture_row_valid[1]) data_mem[capture_branch][capture_pair*2+1]<=capture_odd;
          if(capture_branch==0) begin
            gate_valid_q[capture_pair*2]<=1;
            if(capture_row_valid[1]) gate_valid_q[capture_pair*2+1]<=1;
            gate_count_q<=gate_count_q+capture_row_valid[0]+capture_row_valid[1];
          end else begin
            up_valid_q[capture_pair*2]<=1;
            if(capture_row_valid[1]) up_valid_q[capture_pair*2+1]<=1;
            up_count_q<=up_count_q+capture_row_valid[0]+capture_row_valid[1];
          end
          if(capture_pair==PAIRS_P-1&&capture_branch==1&&capture_row_valid==2'b01&&
             gate_count_q==ROWS_P&&up_count_q==ROWS_P-1) complete<=1;
        end
      end
      if(out_fire) begin
        if(row_q==ROWS_P-1) begin
          complete<=0;reserved_q<=0;row_q<=0;
        end else row_q<=row_q+1'b1;
      end
      if(input_consumed) begin
        complete<=0;reserved_q<=0;row_q<=0;
      end
    end
  end
  initial if(ROWS_P<2||PAIRS_P<1) $fatal(1,"GU pair buffer geometry");
endmodule
