// 64x32 true dual-port statistics RAM. A 32-bit TDP needs one RAMB36,
// not one RAMB18; the row-valid bitmap is kept outside this unreset memory.
module dea8_gcore_stat_ram (
  input logic clk,enable_a,enable_b,write_a,write_b,
  input logic [5:0] address_a,address_b,
  input logic [31:0] data_a,data_b,
  output logic [31:0] result_a,result_b
);
  xpm_memory_tdpram #(
    .ADDR_WIDTH_A(6),.ADDR_WIDTH_B(6),.MEMORY_SIZE(64*32),
    .WRITE_DATA_WIDTH_A(32),.WRITE_DATA_WIDTH_B(32),
    .READ_DATA_WIDTH_A(32),.READ_DATA_WIDTH_B(32),
    .BYTE_WRITE_WIDTH_A(32),.BYTE_WRITE_WIDTH_B(32),
    .READ_LATENCY_A(1),.READ_LATENCY_B(1),
    .CLOCKING_MODE("common_clock"),.MEMORY_PRIMITIVE("block"),
    .WRITE_MODE_A("no_change"),.WRITE_MODE_B("no_change"),
    .USE_MEM_INIT(0),.SIM_ASSERT_CHK(1)
  ) ram (
    .clka(clk),.clkb(clk),.ena(enable_a),.enb(enable_b),
    .wea(write_a),.web(write_b),.addra(address_a),.addrb(address_b),
    .dina(data_a),.dinb(data_b),.douta(result_a),.doutb(result_b),
    .regcea(1'b1),.regceb(1'b1),.rsta(1'b0),.rstb(1'b0),.sleep(1'b0),
    .injectsbiterra(1'b0),.injectdbiterra(1'b0),
    .injectsbiterrb(1'b0),.injectdbiterrb(1'b0)
  );
endmodule
