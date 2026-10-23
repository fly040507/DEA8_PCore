// One arithmetic island: EXP4, ONE II=1 GELU chain, ONE reciprocal.
// GELU reuses P_EXP subtractors 0/1 for its two additions. No duplicated add IP.
// mode: 0=alpha, 1=P, 2=GELU, 3=reciprocal. Mode stays fixed until drained.
module dea8_sfu_arithmetic #(parameter bit EXTERNAL_ARITHMETIC=0)(
  input logic clk,active,input logic [1:0] mode,
  input logic in_valid,input logic [3:0][31:0] a,b,
  input logic gelu_lane,
  output logic out_valid,output logic [3:0][31:0] y,
  output logic [3:0] add_valid,output logic [3:0][31:0] add_a,add_b,
  input logic [3:0] add_out_valid,input logic [3:0][31:0] add_y,
  output logic [4:0] mul_valid,output logic [4:0][31:0] mul_a,mul_b,
  input logic [4:0] mul_out_valid,input logic [4:0][31:0] mul_y
);
  import dea8_compute_config_pkg::*;
  localparam int M=FP_MUL_LATENCY,A=FP_ADD_LATENCY,E=FP_EXP_LATENCY,R=FP_RECIP_LATENCY;
  localparam int GPRE=4*M+A,GDEN=GPRE+E+A,GFINAL=GDEN+R;
  logic [3:0][31:0] sub_y,exp_a,exp_y;
  logic [3:0] sub_v,exp_v,exp_in_v;
  logic [31:0] g0,g1,g2,ga,g3,gd,gf;
  logic v0,v1,v2,va,v3,vd,vf;
  logic [31:0] gx0,gx1,gx2,gxf,recip_a,recip_y;
  logic recip_in_v,recip_v;
  logic [A+E-1:0][3:0] p_zero_q;
  wire ce=active;
  wire [31:0] input_x=a[0];
  dea8_delay_ram #(.DELAY(M)) x0(.clk,.advance(ce),.in_data(input_x),.out_data(gx0));
  dea8_delay_ram #(.DELAY(2*M)) x1(.clk,.advance(ce),.in_data(input_x),.out_data(gx1));
  dea8_delay_ram #(.DELAY(3*M)) x2(.clk,.advance(ce),.in_data(input_x),.out_data(gx2));
  dea8_delay_ram #(.DELAY(GFINAL)) xf(.clk,.advance(ce),.in_data(input_x),.out_data(gxf));
  always_ff @(posedge clk)begin
    if(!active)begin p_zero_q<=0;end
    else begin
      for(int j=0;j<4;j++)p_zero_q[0][j]<=mode==1&&a[j]==32'hff800000;
      for(int i=1;i<A+E;i++)p_zero_q[i]<=p_zero_q[i-1];
    end
  end
  for(genvar j=0;j<4;j++)begin: exp_lanes
    wire masked=a[j]==32'hff800000;
    wire gelu_add=mode==2&&(j<2);
    assign add_a[j]=gelu_add?(j==0?g2:exp_y[0]):(masked?32'b0:a[j]);
    assign add_b[j]=gelu_add?(j==0?gx2:32'h3f800000):(masked?32'b0:{~b[j][31],b[j][30:0]});
    assign add_valid[j]=active&&(gelu_add?(j==0?v2:exp_v[0]):(in_valid&&mode==1));
    if(EXTERNAL_ARITHMETIC)begin
      assign sub_v[j]=add_out_valid[j];assign sub_y[j]=add_y[j];
    end else begin: private_add
    dea8_fpadd_ip sub(.aclk(clk),.aclken(ce),.aresetn(active),
      .s_axis_a_tvalid(add_valid[j]),.s_axis_a_tdata(add_a[j]),
      .s_axis_b_tvalid(add_valid[j]),.s_axis_b_tdata(add_b[j]),
      .m_axis_result_tvalid(sub_v[j]),.m_axis_result_tdata(sub_y[j]));
    end
    always_comb begin
      exp_a[j]=mode==0?a[j]:sub_y[j];
      exp_in_v[j]=mode==0?in_valid:sub_v[j];
      if(mode==2)begin
        exp_a[j]=j==0?g3:32'b0;
        exp_in_v[j]=j==0?v3:1'b0;
      end
      if(mode==3)exp_in_v[j]=0;
    end
    dea8_fpexp_ip exponential(.aclk(clk),.aclken(ce),.aresetn(active),
      .s_axis_a_tvalid(exp_in_v[j]),.s_axis_a_tdata(exp_a[j]),
      .m_axis_result_tvalid(exp_v[j]),.m_axis_result_tdata(exp_y[j]));
  end
  assign ga=sub_y[0];assign va=sub_v[0]&&mode==2;
  assign gd=sub_y[1];assign vd=sub_v[1]&&mode==2;
  logic [4:0] mv;
  logic [4:0][31:0] my;
  assign {vf,v3,v2,v1,v0}=mv;assign {gf,g3,g2,g1,g0}=my;
  assign mul_valid={recip_v&&mode==2,va,v1,v0,in_valid&&mode==2}&{5{active}};
  assign mul_a={recip_y,ga,g1,g0,32'h3d372713};
  assign mul_b={gxf,32'hbfcc422a,gx1,gx0,input_x};
  if(EXTERNAL_ARITHMETIC)begin assign mv=mul_out_valid;assign my=mul_y;end
  else for(genvar j=0;j<5;j++)begin: gelu_chain
    dea8_fpmul_ip mul(.aclk(clk),.aclken(ce),.aresetn(active),
      .s_axis_a_tvalid(mul_valid[j]),.s_axis_a_tdata(mul_a[j]),
      .s_axis_b_tvalid(mul_valid[j]),.s_axis_b_tdata(mul_b[j]),
      .m_axis_result_tvalid(mv[j]),.m_axis_result_tdata(my[j]));
  end
  assign recip_in_v=mode==3?in_valid:(mode==2&&vd);
  assign recip_a=mode==3?a[0]:gd;
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
      2:begin out_valid=vf;y[0]=gf;end
      3:begin out_valid=recip_v;y[0]=recip_y;end
    endcase
    out_valid&=active;
  end
endmodule
