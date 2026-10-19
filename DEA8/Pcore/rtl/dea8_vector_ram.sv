import pcore_pkg::*;

// One physical 16-bank TDP store shared by Post/GU and Attention. The owner
// routes two legal bank operations; this module has no data reset or mux RAM.
module dea8_vector_ram(
  input logic clk,
  input vector_ram_port_t a,b,
  output logic [TILE-1:0][FP_BITS-1:0] a_data,b_data
);
  fp_vector_t a_raw,b_raw,a_write,b_write;
  logic [$clog2(TILE)-1:0] a_rotate_q,b_rotate_q;
  assign a_write=vector_rotate_left(a.data,a.rotate);
  assign b_write=vector_rotate_left(b.data,b.rotate);
  assign a_data=vector_rotate_right(a_raw,a_rotate_q);
  assign b_data=vector_rotate_right(b_raw,b_rotate_q);
  always_ff @(posedge clk)begin
    if((|a.en)&&!(|(a.en&a.we)))a_rotate_q<=a.rotate;
    if((|b.en)&&!(|(b.en&b.we)))b_rotate_q<=b.rotate;
  end
  for(genvar i=0;i<TILE;i++) begin: banks
    xpm_memory_tdpram #(
      .ADDR_WIDTH_A(8),.ADDR_WIDTH_B(8),.AUTO_SLEEP_TIME(0),
      .BYTE_WRITE_WIDTH_A(FP_BITS),.BYTE_WRITE_WIDTH_B(FP_BITS),
      .CLOCKING_MODE("common_clock"),.MEMORY_PRIMITIVE("block"),
      .MEMORY_SIZE(FP_BITS*256),.READ_DATA_WIDTH_A(FP_BITS),
      .READ_DATA_WIDTH_B(FP_BITS),.WRITE_DATA_WIDTH_A(FP_BITS),
      .WRITE_DATA_WIDTH_B(FP_BITS),.READ_LATENCY_A(1),.READ_LATENCY_B(1),
      .WRITE_MODE_A("read_first"),.WRITE_MODE_B("read_first"),
      .USE_MEM_INIT(0),.SIM_ASSERT_CHK(1)
    ) memory(
      .clka(clk),.clkb(clk),.ena(a.en[i]),.enb(b.en[i]),
      .wea(a.we[i]),.web(b.we[i]),.addra(a.addr[i]),.addrb(b.addr[i]),
      .dina(a_write[i]),.dinb(b_write[i]),.douta(a_raw[i]),.doutb(b_raw[i]),
      .rsta(1'b0),.rstb(1'b0),.regcea(1'b1),.regceb(1'b1),.sleep(1'b0),
      .injectsbiterra(1'b0),.injectdbiterra(1'b0),.injectsbiterrb(1'b0),
      .injectdbiterrb(1'b0),.sbiterra(),.dbiterra(),.sbiterrb(),.dbiterrb()
    );
    // synthesis translate_off
    always @(posedge clk) if(a.en[i]&&b.en[i]&&a.addr[i]==b.addr[i]&&(a.we[i]||b.we[i]))
      $fatal(1,"Shared vector RAM same-address port collision bank=%0d",i);
    // synthesis translate_on
  end
endmodule
