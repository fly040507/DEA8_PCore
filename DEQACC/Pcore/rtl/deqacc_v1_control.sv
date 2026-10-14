import pcore_pkg::*;
import deqacc_v1_pkg::*;

module deqacc_v1_control(
  input logic clk,reset,clear,in_valid,input mxu_rsp_t rsp,
  output logic generation,
  output logic [5:0] valid_pipe,
  output pair_meta_t meta_pipe[0:5],
  output logic [5:0][1:0] rows_pipe,
  output logic commit_valid,done,output pair_meta_t commit_meta,
  output v1_key_t keys[0:6],
  output logic [1:0] use_a3,use_c
);
  logic [1:0] commit_rows;
  // Capture the physical address once. Forwarding compare no longer contains
  // a late bank-dependent metadata address mux at the A0 boundary.
  logic [5:0][9:0] address_pipe;
  logic [9:0] commit_address;
  v1_key_t input_key;
  logic [1:0] select_a3_next,select_c_next;
  function automatic bit key_match(input v1_key_t producer,consumer,input int parity);
    return producer.valid&&producer.rows[parity]&&producer.generation==consumer.generation&&
      producer.sel==consumer.sel&&producer.addr==consumer.addr;
  endfunction

  // Keys are views of the one metadata spine, not four replicated pipelines.
  always_comb begin
    input_key='0;
    input_key.valid=in_valid;input_key.generation=generation;
    input_key.add_old=rsp.meta.add_old;input_key.sel=rsp.meta.acc_sel;
    input_key.addr=v1_address(rsp.meta);input_key.rows=rsp.row_valid;
    for(int s=0;s<6;s++)begin
      keys[s]='0;keys[s].valid=valid_pipe[s];keys[s].generation=generation;
      keys[s].add_old=meta_pipe[s].add_old;keys[s].sel=meta_pipe[s].acc_sel;
      keys[s].addr=address_pipe[s];keys[s].rows=rows_pipe[s];
    end
    keys[6]='0;keys[6].valid=commit_valid;keys[6].generation=generation;
    keys[6].add_old=commit_meta.add_old;keys[6].sel=commit_meta.acc_sel;
    keys[6].addr=commit_address;keys[6].rows=commit_rows;
    for(int p=0;p<2;p++)begin
      // Predict which producers will occupy A3/C when Q1 reaches A0 next
      // cycle; data remains fully RNE-rounded at the point of consumption.
      select_a3_next[p]=key_match(keys[4],keys[0],p);
      select_c_next[p]=!select_a3_next[p]&&key_match(keys[5],keys[0],p);
    end
  end
  always_ff @(posedge clk)begin
    meta_pipe[0]<=rsp.meta;
    address_pipe[0]<=v1_address(rsp.meta);
    rows_pipe[0]<=rsp.row_valid;
    for(int s=1;s<6;s++)meta_pipe[s]<=meta_pipe[s-1];
    for(int s=1;s<6;s++)address_pipe[s]<=address_pipe[s-1];
    for(int s=1;s<6;s++)rows_pipe[s]<=rows_pipe[s-1];
    commit_meta<=meta_pipe[5];
    commit_rows<=rows_pipe[5];
    commit_address<=address_pipe[5];
    if(reset)generation<=0;
    else if(clear)generation<=!generation;
    if(reset||clear)begin valid_pipe<=0;commit_valid<=0;done<=0;use_a3<=0;use_c<=0;end
    else begin
      valid_pipe<={valid_pipe[4:0],in_valid};
      commit_valid<=valid_pipe[5];done<=valid_pipe[5]&&meta_pipe[5].last;
      use_a3<=select_a3_next;use_c<=select_c_next;
    end
  end
  // synthesis translate_off
  always @(posedge clk)if(!reset&&!clear)begin
    if(input_key.valid&&input_key.add_old)
      for(int p=0;p<2;p++)if(input_key.rows[p])
        for(int s=0;s<3;s++)if(key_match(keys[s],input_key,p))
          $fatal(1,"V1 accumulator RAW: dependent input interval below four cycles");
    if(keys[1].valid&&keys[1].add_old)
      for(int p=0;p<2;p++)if(keys[1].rows[p])
        for(int s=2;s<5;s++)if(key_match(keys[s],keys[1],p))
          $fatal(1,"V2 unresolved writer at A0");
  end
  // synthesis translate_on
endmodule
