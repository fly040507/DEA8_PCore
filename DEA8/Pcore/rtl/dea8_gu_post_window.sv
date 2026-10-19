import pcore_pkg::*;
import pcore_control_pkg::*;

// Four rows in flight; Gate and Up share a narrow, synchronous block RAM.
module dea8_gu_post_window #(
  parameter int CREDITS=dea8_compute_config_pkg::GU_CREDITS,
  parameter int WORD_BITS=64,
  parameter int WORDS=TILE*FP_BITS/WORD_BITS,
  parameter int DEPTH=CREDITS*2*WORDS,
  parameter int AW=$clog2(DEPTH)
)(
  input logic clk,reset,clear,enable,
  input control_job_t job,input logic [5:0] tile,
  input logic in_valid,output logic in_ready,input post_data_t in_data,
  output logic gate_valid,input logic gate_ready,output control_fp_data_t gate_data,
  input logic gelu_valid,output logic gelu_ready,input control_fp_data_t gelu_data,
  output logic product_valid,input logic product_ready,output control_fp_data_t product_data,
  output logic error,output logic [5:0] accepted,paired,
  output logic [$clog2(CREDITS+1)-1:0] occupancy
);
  logic [5:0] packed_rows,gate_rows;
  logic [TILE*FP_BITS-1:0] capture_gate,capture_up,gate_hold,up_hold;
  logic packing,reading,read_up,read_pending,gate_full,up_full;
  logic [$clog2(2*WORDS+1)-1:0] write_index;
  logic [$clog2(WORDS+1)-1:0] read_index,return_index;
  logic [AW-1:0] read_address,write_address;
  logic [WORD_BITS-1:0] write_word,read_word;
  logic read_enable,write_enable,input_take,product_take,gate_take;
  assign occupancy=$clog2(CREDITS+1)'(accepted-paired);
  assign in_ready=enable&&!error&&!packing&&(accepted-paired<CREDITS)&&accepted<ROWS;
  assign input_take=in_valid&&in_ready;
  assign gate_valid=enable&&!error&&gate_full;
  assign gate_take=gate_valid&&gate_ready;
  assign product_valid=enable&&!error&&up_full&&gelu_valid;
  assign product_take=product_valid&&product_ready;
  assign gelu_ready=enable&&!error&&up_full&&product_ready;
  assign write_enable=enable&&packing;
  assign write_address=AW'((int'(accepted)-1)%CREDITS*(2*WORDS)+write_index);
  assign write_word=write_index<WORDS?capture_gate[write_index*WORD_BITS+:WORD_BITS]:
    capture_up[(write_index-WORDS)*WORD_BITS+:WORD_BITS];
  assign read_enable=enable&&reading&&read_index<WORDS;
  assign read_address=AW'((read_up?int'(paired):int'(gate_rows))%CREDITS*(2*WORDS)+
    (read_up?WORDS:0)+read_index);
  dea8_sdp_ram #(.WIDTH(WORD_BITS),.DEPTH(DEPTH),.PRIMITIVE("block")) rows_ram(
    .clk,.rd_en(read_enable),.wr_en(write_enable),.rd_addr(read_address),.wr_addr(write_address),
    .wr_data(write_word),.rd_data(read_word),.dbg_addr('0),.dbg_data()
  );
  always_comb begin
    gate_data='0;gate_data.job=job;gate_data.tile=tile;gate_data.index=gate_rows;
    gate_data.vector_valid=2'b01;gate_data.token_mask='1;gate_data.first=gate_hold;
    gate_data.last=gate_rows==ROWS-1;
    product_data=gelu_data;product_data.second=up_hold;
  end
  always_ff @(posedge clk)begin
    if(reset||clear)begin
      accepted<=0;paired<=0;packed_rows<=0;gate_rows<=0;
      packing<=0;reading<=0;read_up<=0;read_pending<=0;
      write_index<=0;read_index<=0;return_index<=0;gate_full<=0;up_full<=0;error<=0;
    end else begin
      read_pending<=read_enable;
      if(input_take)begin
        if(in_data.header!=job.header||in_data.n!=tile||in_data.row!=accepted||
           in_data.row_valid!=2'b01||in_data.last!=(accepted==ROWS-1))error<=1;
        capture_gate<=in_data.first;capture_up<=in_data.second;
        accepted<=accepted+1;packing<=1;write_index<=0;
      end
      if(write_enable)begin
        if(write_index==2*WORDS-1)begin packing<=0;packed_rows<=packed_rows+1;end
        else write_index<=write_index+1;
      end
      if(!reading&&enable)begin
        if(gelu_valid&&!up_full&&paired<gate_rows)begin
          reading<=1;read_up<=1;read_index<=0;return_index<=0;
        end else if(!gate_full&&gate_rows<packed_rows)begin
          reading<=1;read_up<=0;read_index<=0;return_index<=0;
        end
      end
      if(read_enable)read_index<=read_index+1;
      if(read_pending)begin
        if(read_up)up_hold[return_index*WORD_BITS+:WORD_BITS]<=read_word;
        else gate_hold[return_index*WORD_BITS+:WORD_BITS]<=read_word;
        return_index<=return_index+1;
        if(return_index==WORDS-1)begin
          reading<=0;
          if(read_up)up_full<=1;else gate_full<=1;
        end
      end
      if(gate_take)begin gate_rows<=gate_rows+1;gate_full<=0;end
      if(product_take)begin
        if(gelu_data.job!=job||gelu_data.tile!=tile||gelu_data.index!=paired||
           gelu_data.vector_valid!=2'b01||gelu_data.last!=(paired==ROWS-1))error<=1;
        paired<=paired+1;up_full<=0;
      end
    end
  end
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)begin
    assert(paired<=gate_rows&&gate_rows<=packed_rows&&packed_rows<=accepted&&accepted-paired<=CREDITS)
      else $fatal(1,"GU credit ownership violation");
  end
  // synthesis translate_on
endmodule
