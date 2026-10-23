// Native FP32 rsqrt. Normalize positive inputs to [1,4) so even
// subnormal inputs never reach the IP's denormal/FTZ boundary.
module dea8_gcore_rsqrt #(
  parameter int IP_LATENCY=32,CHANNELS=1
) (
  input logic clk,reset,clear,
  input logic in_valid,
  output logic in_ready,
  input gcore_pkg::rsqrt_packet_t request,
  output logic out_valid,
  input logic out_ready,
  output gcore_pkg::rsqrt_packet_t response,
  output logic empty,protocol_error
);
  import gcore_pkg::*;
  localparam int META_STAGES=IP_LATENCY;
  logic [1:0] reset_hold=2'b11;
  logic [1:0] warmup_q=0;
  logic ip_reset_n,running,advance,fire;
  logic [META_STAGES-1:0] valid_q,bad_q;
  rsqrt_packet_t meta_q[META_STAGES];
  logic signed [8:0] exponent_q[META_STAGES][2];
  logic [1:0][31:0] normalized,ip_result;
  logic signed [8:0] half_exponent[2];
  logic [1:0] ip_valid;
  logic request_bad;
  localparam int QUEUE_DEPTH=32, PTR_BITS=$clog2(QUEUE_DEPTH);
  logic [PTR_BITS:0] outstanding,count;
  logic [PTR_BITS-1:0] head,tail,read_head;
  (* ram_style="block" *) logic [$bits(rsqrt_packet_t)-1:0] queue_mem[QUEUE_DEPTH];
  rsqrt_packet_t computed,ram_q,bypass_q;
  logic bypass_valid,push,pop;

  assign ip_reset_n=!reset&&!clear&&reset_hold==0;
  // The vendor reset is internally pipelined. Do not accept operands in its
  // two-clock recovery window after ARESETn is released.
  assign running=ip_reset_n&&(&warmup_q);
  always_ff @(posedge clk)
    if(!ip_reset_n)warmup_q<=0;else warmup_q<={warmup_q[0],1'b1};
  assign out_valid=running&&count!=0;
  // Native NonBlocking IP runs freely. Credits reserve space for every
  // accepted pair, including the results still inside its 32-cycle pipeline.
  assign advance=running;
  assign in_ready=running&&(outstanding<QUEUE_DEPTH||pop);
  assign fire=in_valid&&in_ready;
  assign empty=outstanding==0;
  assign push=running&&valid_q[META_STAGES-1];
  assign pop=out_valid&&out_ready;
  assign read_head=head+PTR_BITS'(pop);
  assign response=bypass_valid?bypass_q:ram_q;
  always_ff @(posedge clk) begin
    ram_q<=queue_mem[read_head];
    if(push)queue_mem[tail]<=computed;
    bypass_valid<=push&&tail==read_head;
    if(push&&tail==read_head)bypass_q<=computed;
  end
  always_ff @(posedge clk) begin
    if(!running)begin head<=0;tail<=0;count<=0;outstanding<=0;end
    else begin
      if(push)tail<=tail+1'b1;
      if(pop)head<=head+1'b1;
      case({push,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:;endcase
      case({fire,pop})2'b10:outstanding<=outstanding+1'b1;2'b01:outstanding<=outstanding-1'b1;default:;endcase
    end
  end
  always_ff @(posedge clk) begin
    if(reset||clear) reset_hold<=2'b11;
    else reset_hold<={reset_hold[0],1'b0};
  end
  always_comb begin
    request_bad=request.mask[0]!=1'b1 || request.mask!=(CHANNELS==1?2'b01:(request.row0==ROWS-1?2'b01:2'b11)) ||
      request.row0>=ROWS || (CHANNELS==2&&request.row0[0]) || request.row1!=request.row0+1'b1;
    for(int lane=0;lane<2;lane++) begin
      logic [31:0] x;
      logic [23:0] significand;
      int lead,exponent;
      x=request.data[32*lane+:32];
      significand={(|x[30:23]),x[22:0]};
      lead=int'(dea8_fp32_pkg::lead32({8'b0,significand}));
      exponent=(x[30:23]==0?1:int'(x[30:23]))-150+lead;
      significand=significand<<(23-lead);
      normalized[lane]={1'b0,8'(127+(exponent&1)),significand[22:0]};
      half_exponent[lane]=9'(exponent>>>1);
      if(!request.mask[lane]) begin normalized[lane]=32'h3f800000;half_exponent[lane]=0;end
      else if(x[31]||x[30:0]==0||x[30:23]==8'hff) begin
        request_bad=1;normalized[lane]=32'h3f800000;half_exponent[lane]=0;
      end
    end
  end
  for(genvar lane=0;lane<CHANNELS;lane++) begin: channels
    gcore_rsqrt_ip ip (
      .aclk(clk),.aclken(1'b1),.aresetn(ip_reset_n),
      .s_axis_a_tvalid(fire),.s_axis_a_tdata(normalized[lane]),
      .m_axis_result_tvalid(ip_valid[lane]),.m_axis_result_tdata(ip_result[lane])
    );
  end
  if(CHANNELS==1)begin:unused_lane
    assign ip_result[1]=0;
    assign ip_valid[1]=0;
  end
  always_comb begin
    computed=meta_q[META_STAGES-1];computed.data=0;
    for(int lane=0;lane<2;lane++) if(computed.mask[lane]) begin
      computed.data[32*lane+:32]={1'b0,
        8'(int'(ip_result[lane][30:23])-$signed(exponent_q[META_STAGES-1][lane])),
        ip_result[lane][22:0]};
      if(bad_q[META_STAGES-1])computed.data[32*lane+:32]=32'h7fc00000;
    end
  end
  always_ff @(posedge clk) begin
    if(!running) begin
      valid_q<=0;bad_q<=0;protocol_error<=0;
    end else if(advance) begin
      valid_q[0]<=fire;bad_q[0]<=request_bad;
      if(fire) begin
        meta_q[0]<=request;
        for(int lane=0;lane<2;lane++)exponent_q[0][lane]<=half_exponent[lane];
        if(request_bad)protocol_error<=1;
      end
      for(int s=1;s<META_STAGES;s++) begin
        valid_q[s]<=valid_q[s-1];bad_q[s]<=bad_q[s-1];meta_q[s]<=meta_q[s-1];
        for(int lane=0;lane<2;lane++)exponent_q[s][lane]<=exponent_q[s-1][lane];
      end
    end
  end
`ifndef SYNTHESIS
  always @(posedge clk) if(advance)
    begin
      if(ip_valid!=(CHANNELS==1?{1'b0,valid_q[META_STAGES-1]}:{2{valid_q[META_STAGES-1]}}))
        $fatal(1,"GCore rsqrt IP/metadata latency mismatch ip=%b meta=%b",ip_valid,valid_q[META_STAGES-1]);
      if(push&&count==QUEUE_DEPTH&&!pop)$fatal(1,"GCore rsqrt credit/queue overflow");
    end
`endif
endmodule
