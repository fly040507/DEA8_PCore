module dea8_ram_fifo #(
  parameter int WIDTH=288,DEPTH=8,AW=$clog2(DEPTH)
)(
  input logic clk,reset,clear,in_valid,
  output logic in_ready,input logic [WIDTH-1:0] in_data,
  output logic out_valid,input logic out_ready,output logic [WIDTH-1:0] out_data,
  output logic [$clog2(DEPTH+1)-1:0] count
);
  logic [AW-1:0] head,tail,read_head;
  logic [WIDTH-1:0] ram_data,bypass_q;
  logic bypass_valid;
  wire pop=out_valid&&out_ready;
  wire push=in_valid&&in_ready;
  assign out_valid=count!=0&&!reset&&!clear;
  assign in_ready=!reset&&!clear&&(count<DEPTH||pop);
  assign read_head=head+AW'(pop);
  assign out_data=bypass_valid?bypass_q:ram_data;
  dea8_sdp_ram #(.WIDTH(WIDTH),.DEPTH(DEPTH)) storage(
    .clk,.rd_en(!reset&&!clear),.rd_addr(read_head),.wr_en(push),.wr_addr(tail),
    .wr_data(in_data),.rd_data(ram_data),.dbg_addr('0),.dbg_data());
  always_ff @(posedge clk)begin
    bypass_valid<=push&&tail==read_head;
    if(push&&tail==read_head)bypass_q<=in_data;
    if(reset||clear)begin head<=0;tail<=0;count<=0;bypass_valid<=0;end
    else begin
      if(push)tail<=tail+1'b1;
      if(pop)head<=head+1'b1;
      case({push,pop})
        2'b10:count<=count+1'b1;
        2'b01:count<=count-1'b1;
        default:;
      endcase
    end
  end
  initial if(DEPTH<2||(DEPTH&(DEPTH-1))!=0)$fatal(1,"RAM FIFO geometry");
endmodule
