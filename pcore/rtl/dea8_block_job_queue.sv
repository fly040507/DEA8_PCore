import dea8_pcore_pkg::*;
import dea8_job_pkg::*;

// Two descriptors total: executing head and its successor. Pop only after
// completion acceptance, so lookahead never changes the executing context.
module dea8_block_job_queue (
  input logic clk, rst_n, start,
  input logic [HEAD_BITS-1:0] head,
  input logic [EPOCH_BITS-1:0] epoch,
  input logic pop,
  output logic current_valid, next_valid,
  output matrix_block_job_t current, next,
  output logic [1:0] count
);
  matrix_block_job_t slots[0:1];
  logic [MATRIX_JOB_INDEX_BITS-1:0] generated_q;
  logic [HEAD_BITS-1:0] head_q;
  logic [EPOCH_BITS-1:0] epoch_q;
  logic refill;
  assign current_valid=rst_n && count!=0;
  assign next_valid=rst_n && count==2;
  assign current=slots[0];
  assign next=slots[1];
  assign refill=generated_q<MATRIX_JOB_COUNT && (count<2 || pop);
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      count<=0; generated_q<=MATRIX_JOB_INDEX_BITS'(MATRIX_JOB_COUNT);
      head_q<='0; epoch_q<='0; slots[0]<='0; slots[1]<='0;
    end else if(start) begin
      slots[0]<=attention_block_job(0,head,epoch);
      slots[1]<=attention_block_job(1,head,epoch);
      count<=2; generated_q<=2; head_q<=head; epoch_q<=epoch;
    end else begin
      if(pop) slots[0]<=slots[1];
      if(refill) begin
        slots[int'(count)-(pop ? 1 : 0)]<=attention_block_job(int'(generated_q),head_q,epoch_q);
        generated_q<=generated_q+1'b1;
      end
      case({refill,pop})
        2'b10: count<=count+1'b1;
        2'b01: count<=count-1'b1;
        default: ;
      endcase
    end
  end
  // synthesis translate_off
  always @(posedge clk) if(rst_n && pop && !current_valid) $fatal(1,"Block queue underflow");
  // synthesis translate_on
endmodule
