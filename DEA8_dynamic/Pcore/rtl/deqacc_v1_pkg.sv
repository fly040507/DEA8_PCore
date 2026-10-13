package deqacc_v1_pkg;
  import pcore_pkg::*;
  parameter int V1_PIPE_STAGES=7;
  typedef struct packed {
    logic valid,generation,add_old;
    acc_sel_e sel;
    logic [9:0] addr;
    logic [1:0] rows;
  } v1_key_t;
  function automatic logic [9:0] v1_address(input pair_meta_t meta);
    return meta.acc_sel==ACC_OACC?10'(oacc_addr(meta.pair_idx,meta.nt)):10'(meta.pair_idx);
  endfunction
endpackage
