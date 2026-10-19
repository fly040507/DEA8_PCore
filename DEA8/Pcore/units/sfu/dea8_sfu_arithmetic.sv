// One arithmetic island: exp4, two interleaved GELU chains and ONE reciprocal.
// mode: 0=alpha, 1=P, 2=GELU, 3=reciprocal. Mode stays fixed until drained.
module dea8_sfu_arithmetic(
  input logic clk,active,input logic [1:0] mode,
  input logic in_valid,input logic [3:0][31:0] a,b,
  input logic gelu_lane,
  output logic out_valid,output logic [3:0][31:0] y
);
  import dea8_compute_config_pkg::*;
  localparam int M=FP_MUL_LATENCY,A=FP_ADD_LATENCY,E=FP_EXP_LATENCY,R=FP_RECIP_LATENCY;
  localparam int GPRE=4*M+A,GDEN=GPRE+E+A,GFINAL=GDEN+R;
  logic [3:0][31:0] sub_y,exp_a,exp_y;
  logic [3:0] sub_v,exp_v,exp_in_v;
  logic [1:0][31:0] g0,g1,g2,ga,g3,gd,gf;
  logic [1:0] v0,v1,v2,va,v3,vd,vf;
  logic [31:0] gx0,gx1,gx2,gxf,recip_a,recip_y;
  logic recip_in_v,recip_v;
  logic [R-1:0] lane_q;
  logic [A+E-1:0][3:0] p_zero_q;
  wire ce=active;
  wire [31:0] input_x=a[0];
  dea8_delay_ram #(.DELAY(M)) x0(.clk,.advance(ce),.in_data(input_x),.out_data(gx0));
  dea8_delay_ram #(.DELAY(2*M)) x1(.clk,.advance(ce),.in_data(input_x),.out_data(gx1));
  dea8_delay_ram #(.DELAY(3*M)) x2(.clk,.advance(ce),.in_data(input_x),.out_data(gx2));
  dea8_delay_ram #(.DELAY(GFINAL)) xf(.clk,.advance(ce),.in_data(input_x),.out_data(gxf));
  always_ff @(posedge clk)begin
    if(!active)begin lane_q<=0;p_zero_q<=0;end
    else begin
      lane_q<={lane_q[R-2:0],vd[1]};
      for(int j=0;j<4;j++)p_zero_q[0][j]<=mode==1&&a[j]==32'hff800000;
      for(int i=1;i<A+E;i++)p_zero_q[i]<=p_zero_q[i-1];
    end
  end
  for(genvar j=0;j<4;j++)begin: exp_lanes
    wire masked=a[j]==32'hff800000;
    dea8_fpadd_ip sub(.aclk(clk),.aclken(ce),.aresetn(active),
      .s_axis_a_tvalid(in_valid&&mode==1),.s_axis_a_tdata(masked?32'b0:a[j]),
      .s_axis_b_tvalid(in_valid&&mode==1),.s_axis_b_tdata(masked?32'b0:{~b[j][31],b[j][30:0]}),
      .m_axis_result_tvalid(sub_v[j]),.m_axis_result_tdata(sub_y[j]));
    always_comb begin
      exp_a[j]=mode==0?a[j]:sub_y[j];
      exp_in_v[j]=mode==0?in_valid:sub_v[j];
      if(mode==2)begin
        exp_a[j]=j<2?g3[j%2]:32'b0;
        exp_in_v[j]=j<2?v3[j%2]:1'b0;
      end
      if(mode==3)exp_in_v[j]=0;
    end
    dea8_fpexp_ip exponential(.aclk(clk),.aclken(ce),.aresetn(active),
      .s_axis_a_tvalid(exp_in_v[j]),.s_axis_a_tdata(exp_a[j]),
      .m_axis_result_tvalid(exp_v[j]),.m_axis_result_tdata(exp_y[j]));
  end
  for(genvar j=0;j<2;j++)begin: gelu_lanes
    wire iv=in_valid&&mode==2&&(gelu_lane==j);
    dea8_fpmul_ip m0(.aclk(clk),.aclken(ce),.aresetn(active),
      .s_axis_a_tvalid(iv),.s_axis_a_tdata(32'h3d372713),
      .s_axis_b_tvalid(iv),.s_axis_b_tdata(input_x),.m_axis_result_tvalid(v0[j]),.m_axis_result_tdata(g0[j]));
    dea8_fpmul_ip m1(.aclk(clk),.aclken(ce),.aresetn(active),
      .s_axis_a_tvalid(v0[j]),.s_axis_a_tdata(g0[j]),
      .s_axis_b_tvalid(v0[j]),.s_axis_b_tdata(gx0),.m_axis_result_tvalid(v1[j]),.m_axis_result_tdata(g1[j]));
    dea8_fpmul_ip m2(.aclk(clk),.aclken(ce),.aresetn(active),
      .s_axis_a_tvalid(v1[j]),.s_axis_a_tdata(g1[j]),
      .s_axis_b_tvalid(v1[j]),.s_axis_b_tdata(gx1),.m_axis_result_tvalid(v2[j]),.m_axis_result_tdata(g2[j]));
    dea8_fpadd_ip add_x(.aclk(clk),.aclken(ce),.aresetn(active),
      .s_axis_a_tvalid(v2[j]),.s_axis_a_tdata(g2[j]),
      .s_axis_b_tvalid(v2[j]),.s_axis_b_tdata(gx2),.m_axis_result_tvalid(va[j]),.m_axis_result_tdata(ga[j]));
    dea8_fpmul_ip m3(.aclk(clk),.aclken(ce),.aresetn(active),
      .s_axis_a_tvalid(va[j]),.s_axis_a_tdata(ga[j]),
      .s_axis_b_tvalid(va[j]),.s_axis_b_tdata(32'hbfcc422a),.m_axis_result_tvalid(v3[j]),.m_axis_result_tdata(g3[j]));
    dea8_fpadd_ip add_one(.aclk(clk),.aclken(ce),.aresetn(active),
      .s_axis_a_tvalid(exp_v[j]&&mode==2),.s_axis_a_tdata(exp_y[j]),
      .s_axis_b_tvalid(exp_v[j]&&mode==2),.s_axis_b_tdata(32'h3f800000),.m_axis_result_tvalid(vd[j]),.m_axis_result_tdata(gd[j]));
    dea8_fpmul_ip m4(.aclk(clk),.aclken(ce),.aresetn(active),
      .s_axis_a_tvalid(recip_v&&mode==2&&lane_q[R-1]==j),.s_axis_a_tdata(recip_y),
      .s_axis_b_tvalid(recip_v&&mode==2&&lane_q[R-1]==j),.s_axis_b_tdata(gxf),
      .m_axis_result_tvalid(vf[j]),.m_axis_result_tdata(gf[j]));
  end
  assign recip_in_v=mode==3?in_valid:(mode==2&&(|vd));
  assign recip_a=mode==3?a[0]:(vd[1]?gd[1]:gd[0]);
  dea8_fprecip_ip reciprocal(.aclk(clk),.aclken(ce),.aresetn(active),
    .s_axis_a_tvalid(recip_in_v),.s_axis_a_tdata(recip_a),
    .m_axis_result_tvalid(recip_v),.m_axis_result_tdata(recip_y));
  always_comb begin
    out_valid=0;y='0;
    case(mode)
      0:begin out_valid=exp_v[0];y=exp_y;end
      1:begin
        out_valid=exp_v[0];y=exp_y;
        for(int j=0;j<4;j++)if(p_zero_q[A+E-1][j])y[j]=0;
      end
      2:begin out_valid=|vf;y[0]=vf[1]?gf[1]:gf[0];end
      3:begin out_valid=recip_v;y[0]=recip_y;end
    endcase
    out_valid&=active;
  end
  // synthesis translate_off
  always @(posedge clk)if(active&&mode==2)begin
    assert($onehot0(vd))else $fatal(1,"GELU shared reciprocal collision");
    assert($onehot0(vf))else $fatal(1,"GELU result order collision");
  end
  // synthesis translate_on
endmodule
