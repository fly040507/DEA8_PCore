package pcore3_legacy_pkg;
  import pcore3_pkg::*;
  typedef struct packed {
    job_header_t header;
    matrix_mode_e mode;
    logic [5:0] n;
    logic [7:0] k_tiles;
    logic [5:0] m_rows;
  } pcore_matrix_job_t;
  typedef pcore_post_op_e pcore_vpu_op_e;
  typedef enum logic {GELU_GU=0} pcore_sfu_op_e;
  typedef struct packed {job_header_t header;pcore_vpu_op_e op;logic [5:0] n;} pcore_vpu_job_t;
  typedef struct packed {job_header_t header;pcore_sfu_op_e op;logic [5:0] n;} pcore_sfu_job_t;
endpackage
