import pcore3_pkg::*;

// A total GU job is N ordered matrix jobs. Matrix completion and Z commit
// completion are deliberately separate; done includes the post-process tail.
module dea8_gu_scheduler_v3 #(parameter int N_TILES=32)(
  input logic clk,reset,clear,
  input logic start,output logic start_ready,
  input logic [EPOCH_BITS-1:0] job_epoch,input logic [2:0] job_head,
  output logic tile_valid,input logic tile_ready,
  output logic [5:0] tile_n,
  output logic [EPOCH_BITS-1:0] tile_epoch,output logic [2:0] tile_head,
  output logic prefetch_valid,output logic [5:0] prefetch_n,
  output logic [EPOCH_BITS-1:0] prefetch_epoch,output logic [2:0] prefetch_head,
  input logic tile_matrix_done,
  input logic z_tile_commit,
  input logic [5:0] z_n,
  input logic [EPOCH_BITS-1:0] z_epoch,input logic [2:0] z_head,
  output logic busy,matrix_all_done,done,protocol_error
);
  typedef enum logic [1:0] {IDLE,SEND,WAIT_MATRIX,DRAIN} state_t;
  state_t state_q;
  logic [5:0] n_q;
  logic [6:0] z_count_q;
  logic [EPOCH_BITS-1:0] epoch_q;
  logic [2:0] head_q;
  logic prefetch_sent_q;
  assign start_ready=state_q==IDLE&&!reset&&!clear;
  assign busy=state_q!=IDLE;
  assign tile_valid=state_q==SEND&&!reset&&!clear&&!protocol_error;
  assign tile_n=n_q;assign tile_epoch=epoch_q;assign tile_head=head_q;
  assign prefetch_valid=state_q==WAIT_MATRIX&&!prefetch_sent_q&&n_q<N_TILES-1&&
                         !reset&&!clear&&!protocol_error;
  assign prefetch_n=n_q+1'b1;assign prefetch_epoch=epoch_q;assign prefetch_head=head_q;
  always_ff @(posedge clk) begin
    if(reset||clear) begin
      state_q<=IDLE;n_q<=0;z_count_q<=0;epoch_q<=0;head_q<=0;prefetch_sent_q<=0;
      done<=0;matrix_all_done<=0;protocol_error<=0;
    end else begin
      done<=0;
      if(start&&start_ready) begin
        state_q<=SEND;n_q<=0;z_count_q<=0;epoch_q<=job_epoch;head_q<=job_head;
        matrix_all_done<=0;protocol_error<=0;prefetch_sent_q<=0;
      end
      if(tile_valid&&tile_ready) begin state_q<=WAIT_MATRIX;prefetch_sent_q<=0;end
      if(prefetch_valid) prefetch_sent_q<=1;
      if(tile_matrix_done) begin
        if(state_q!=WAIT_MATRIX) protocol_error<=1;
        else if(n_q==N_TILES-1) begin state_q<=DRAIN;matrix_all_done<=1;end
        else begin n_q<=n_q+1'b1;state_q<=SEND;prefetch_sent_q<=0;end
      end
      if(z_tile_commit) begin
        if(state_q==IDLE||z_count_q>=N_TILES||z_n!=z_count_q||
           z_epoch!=epoch_q||z_head!=head_q) protocol_error<=1;
        else z_count_q<=z_count_q+1'b1;
      end
      if(state_q==DRAIN&&z_count_q==N_TILES&&!protocol_error) begin
        state_q<=IDLE;done<=1;
      end
    end
  end
  initial if(N_TILES<1||N_TILES>64) $fatal(1,"GU scheduler geometry");
endmodule
