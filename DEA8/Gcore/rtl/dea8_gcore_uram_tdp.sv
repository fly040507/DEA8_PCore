// Two independent read-or-write ports. A paired read consumes both ports;
// callers arbitrate writes before asserting either enable.
module dea8_gcore_uram_tdp #(
  parameter int AW=12, DW=gcore_pkg::STORE_WORD_BITS,
  parameter int RL=gcore_pkg::STORE_READ_LATENCY
) (
  input logic clk,enable_a,enable_b,write_a,write_b,
  input logic [AW-1:0] address_a,address_b,
  input logic [DW-1:0] data_a,data_b,
  output logic [DW-1:0] result_a,result_b
);
  xpm_memory_tdpram #(
    .ADDR_WIDTH_A(AW),.ADDR_WIDTH_B(AW),.MEMORY_SIZE((1<<AW)*DW),
    .WRITE_DATA_WIDTH_A(DW),.WRITE_DATA_WIDTH_B(DW),
    .READ_DATA_WIDTH_A(DW),.READ_DATA_WIDTH_B(DW),
    .BYTE_WRITE_WIDTH_A(DW),.BYTE_WRITE_WIDTH_B(DW),
    .READ_LATENCY_A(RL),.READ_LATENCY_B(RL),
    .CLOCKING_MODE("common_clock"),.MEMORY_PRIMITIVE("ultra"),
    .WRITE_MODE_A("no_change"),.WRITE_MODE_B("no_change"),
    .ECC_MODE("no_ecc"),.AUTO_SLEEP_TIME(0),
    .USE_MEM_INIT(0),.SIM_ASSERT_CHK(1)
  ) memory (
    .clka(clk),.clkb(clk),.ena(enable_a),.enb(enable_b),
    .wea(write_a),.web(write_b),.addra(address_a),.addrb(address_b),
    .dina(data_a),.dinb(data_b),.douta(result_a),.doutb(result_b),
    .regcea(1'b1),.regceb(1'b1),.rsta(1'b0),.rstb(1'b0),.sleep(1'b0),
    .injectsbiterra(1'b0),.injectdbiterra(1'b0),
    .injectsbiterrb(1'b0),.injectdbiterrb(1'b0),
    .sbiterra(),.dbiterra(),.sbiterrb(),.dbiterrb()
  );

  // The declared prefix preload exception is TB-only, not a hardware DMA.
  // A delta delay lets XPM's time-zero initialization finish first.
  // synthesis translate_off
  task automatic preload(input logic [AW-1:0] address,input logic [DW-1:0] data);
    #0;
    memory.xpm_memory_base_inst.mem[address]=data;
  endtask
  // synthesis translate_on
endmodule
