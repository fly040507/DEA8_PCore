// Explicit synchronous RAM. Validity and elastic response storage belong to
// the caller; data bits are never reset or asynchronously read.
module dea8_sdp_ram #(
  parameter int WIDTH=32, DEPTH=64, LATENCY=1,
  parameter PRIMITIVE="block",
  parameter int AW=(DEPTH>1?$clog2(DEPTH):1)
)(
  input logic clk,rd_en,wr_en,
  input logic [AW-1:0] rd_addr,wr_addr,
  input logic [WIDTH-1:0] wr_data,
  output logic [WIDTH-1:0] rd_data,
  input logic [AW-1:0] dbg_addr,
  output logic [WIDTH-1:0] dbg_data
);
  // synthesis translate_off
  logic [WIDTH-1:0] shadow[0:DEPTH-1];
  // synthesis translate_on
  xpm_memory_sdpram #(
    .ADDR_WIDTH_A(AW),.ADDR_WIDTH_B(AW),.AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(WIDTH),.CLOCKING_MODE("common_clock"),
    .MEMORY_PRIMITIVE(PRIMITIVE),.MEMORY_SIZE(WIDTH*DEPTH),
    .READ_DATA_WIDTH_B(WIDTH),.READ_LATENCY_B(LATENCY),
    .WRITE_DATA_WIDTH_A(WIDTH),.WRITE_MODE_B("read_first"),
    .USE_MEM_INIT(0),.SIM_ASSERT_CHK(1)
  ) memory(
    .clka(clk),.clkb(clk),.ena(wr_en),.enb(rd_en),.wea(wr_en),
    .addra(wr_addr),.addrb(rd_addr),.dina(wr_data),.doutb(rd_data),
    .rstb(1'b0),.regceb(1'b1),.sleep(1'b0),
    .injectsbiterra(1'b0),.injectdbiterra(1'b0),.sbiterrb(),.dbiterrb()
  );
  always_comb begin
    dbg_data='0;
    // synthesis translate_off
    if(dbg_addr<DEPTH) dbg_data=shadow[dbg_addr];
    // synthesis translate_on
  end
  // synthesis translate_off
  always @(posedge clk) if(wr_en) shadow[wr_addr]<=wr_data;
  // synthesis translate_on
endmodule
