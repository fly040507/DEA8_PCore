import pcore_pkg::*;

module dea8_gu_pair_buffer #(
  parameter int ROWS_P=ROWS,PAIRS_P=PAIRS,
  parameter bit EXTERNAL_VECTOR=0
)(
  input logic clk,reset,clear,
  output vector_ram_port_t ram_a,ram_b,
  input logic [TILE-1:0][FP_BITS-1:0] ram_a_data,ram_b_data,
  input logic reserve_valid,output logic reserve_ready,
  input logic [EPOCH_BITS-1:0] reserve_epoch,input logic [2:0] reserve_head,input logic [5:0] reserve_n,
  input logic capture_valid,output logic capture_ready,input logic capture_branch,
  input logic [PAIR_BITS-1:0] capture_pair,input logic [1:0] capture_row_valid,
  input logic [15:0][31:0] capture_even,capture_odd,
  input logic [EPOCH_BITS-1:0] capture_epoch,input logic [2:0] capture_head,input logic [5:0] capture_n,
  input logic input_consumed,output logic out_valid,input logic out_ready,
  output logic [5:0] out_row,output logic [15:0][31:0] out_gate,out_up,
  output logic [1:0] out_row_valid,output logic [EPOCH_BITS-1:0] out_epoch,
  output logic [2:0] out_head,output logic [5:0] out_n,
  output logic out_last,complete,protocol_error
);
  logic [ROWS_P-1:0] gate_valid_q,up_valid_q;
  logic [6:0] gate_count_q,up_count_q;
  logic reserved_q;
  logic [EPOCH_BITS-1:0] epoch_q;
  logic [2:0] head_q;
  logic [5:0] n_q,issue_row_q,ram_row_q,held_row_q;
  logic ram_valid_q,held_valid_q;
  logic [TILE-1:0][FP_BITS-1:0] a_data,b_data;
  logic [TILE-1:0][FP_BITS-1:0] gate_q,up_q;
  logic odd_pending;
  logic [511:0] odd_data,gate_read;
  logic [7:0] odd_address;
  logic [1:0] read_phase;
  wire reserve_fire=reserve_valid&&reserve_ready;
  wire capture_fire=capture_valid&&capture_ready;
  wire capture_good=capture_epoch==epoch_q&&capture_head==head_q&&capture_n==n_q&&
    capture_pair<PAIRS_P&&capture_row_valid==row_mask(capture_pair)&&
    !(capture_branch?up_valid_q[2*capture_pair]:gate_valid_q[2*capture_pair]);
  wire advance=!held_valid_q||out_ready;
  wire read_fire=complete&&issue_row_q<ROWS_P&&read_phase==0&&advance&&!reset&&!clear&&!protocol_error;
  assign reserve_ready=!reset&&!clear&&!reserved_q&&!ram_valid_q&&!held_valid_q;
  assign capture_ready=!reset&&!clear&&reserved_q&&!complete&&!protocol_error&&!odd_pending;
  assign out_valid=held_valid_q&&!reset&&!clear&&!protocol_error;
  assign out_gate=gate_q;assign out_up=up_q;
  assign out_row_valid=out_valid?2'b01:2'b00;
  assign out_row=held_row_q;assign out_epoch=epoch_q;assign out_head=head_q;assign out_n=n_q;
  assign out_last=out_valid&&held_row_q==ROWS_P-1;
  if(EXTERNAL_VECTOR)begin
    assign a_data=ram_a_data;assign b_data=ram_b_data;
  end else begin: private_store
    dea8_vector_ram memory(.clk,.a(ram_a),.b(ram_b),.a_data,.b_data);
  end
  always_comb begin
    ram_a='0;ram_b='0;
    if(odd_pending)begin
      ram_a.en='1;ram_a.we='1;ram_a.data=odd_data;
      for(int lane=0;lane<16;lane++)ram_a.addr[lane]=odd_address;
    end else if(capture_fire&&capture_good)begin
      ram_a.en='1;ram_a.we='1;ram_a.data=capture_even;
      for(int lane=0;lane<16;lane++)ram_a.addr[lane]=8'(capture_branch*64+2*capture_pair);
    end
    if(read_fire||read_phase==1)begin
      ram_b.en='1;
      for(int lane=0;lane<16;lane++)ram_b.addr[lane]=read_phase==1?8'(64+ram_row_q):8'(issue_row_q);
    end
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      reserved_q<=0;complete<=0;protocol_error<=0;epoch_q<=0;head_q<=0;n_q<=0;
      gate_valid_q<='0;up_valid_q<='0;gate_count_q<=0;up_count_q<=0;
      issue_row_q<=0;ram_valid_q<=0;held_valid_q<=0;ram_row_q<=0;held_row_q<=0;
      odd_pending<=0;read_phase<=0;
    end else begin
      odd_pending<=0;
      if(capture_fire&&capture_good&&capture_row_valid[1])begin
        odd_pending<=1;odd_data<=capture_odd;odd_address<=8'(capture_branch*64+2*capture_pair+1);
      end
      if(held_valid_q&&out_ready)held_valid_q<=0;
      if(read_fire)begin read_phase<=1;ram_row_q<=issue_row_q;issue_row_q<=issue_row_q+1'b1;end
      if(read_phase==1)begin gate_read<=a_data;read_phase<=2;end
      if(read_phase==2)begin held_valid_q<=1;held_row_q<=ram_row_q;gate_q<=gate_read;up_q<=b_data;read_phase<=0;end
      if(reserve_fire)begin
        reserved_q<=1;complete<=0;epoch_q<=reserve_epoch;head_q<=reserve_head;n_q<=reserve_n;
        issue_row_q<=0;gate_valid_q<=0;up_valid_q<=0;gate_count_q<=0;up_count_q<=0;
      end
      if(capture_valid&&!capture_ready)protocol_error<=1;
      if(capture_fire)begin
        if(!capture_good)protocol_error<=1;
        else begin
          if(!capture_branch)begin
            gate_valid_q[2*capture_pair]<=1;
            if(capture_row_valid[1])gate_valid_q[2*capture_pair+1]<=1;
            gate_count_q<=gate_count_q+capture_row_valid[0]+capture_row_valid[1];
          end else begin
            up_valid_q[2*capture_pair]<=1;
            if(capture_row_valid[1])up_valid_q[2*capture_pair+1]<=1;
            up_count_q<=up_count_q+capture_row_valid[0]+capture_row_valid[1];
          end
          if(capture_pair==PAIRS_P-1&&capture_branch&&gate_count_q==ROWS_P&&up_count_q==ROWS_P-1)complete<=1;
        end
      end
      if(input_consumed||(out_valid&&out_ready&&out_last))begin
        reserved_q<=0;complete<=0;issue_row_q<=0;ram_valid_q<=0;held_valid_q<=0;
      end
    end
  end
endmodule
