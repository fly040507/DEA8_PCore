param(
  [string]$SevenJobRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$V3Root = Split-Path -Parent $SevenJobRoot
$srcPath = Join-Path $V3Root 'tb\tb_v3_pcore_control_v3.sv'
$dstPath = Join-Path $SevenJobRoot 'tb_v3_pcore_control_perf.sv'

if (!(Test-Path -LiteralPath $srcPath)) {
  throw "找不到原始 TB: $srcPath。请确认脚本位于 V3\7JOB。"
}

$src = Get-Content -LiteralPath $srcPath -Raw

# 新 TB 保留原始七 Job 驱动、真实 Matrix/DEQACC/QOZ/Control，只替换外部 VPU/SFU 时间模型。
$src = $src.Replace('tb_v3_pcore_control_v3','tb_v3_pcore_control_perf')

# 增加性能统计变量。
$oldDecl = '  int matrix_jobs=0,allowed_n=0;'
$newDecl = @'
  int matrix_jobs=0,allowed_n=0;
  int first_issue[7],last_issue[7],job_cycles_rec[7];
  int attn_start_last=-1,attn_interval_max=0,attn_interval_count=0;
  longint attn_interval_sum=0;
  int rope_quant_max=0,v_quant_max=0,gu_post_max=0,gelu_max=0;
  int qk_post_max=0,p_post_max=0,alpha_max=0,pexp_max=0,scale_max=0,recip_max=0,afin_max=0;
'@
if (!$src.Contains($oldDecl)) { throw '找不到性能变量插入点，仓库 TB 版本可能已变化。' }
$src = $src.Replace($oldDecl,$newDecl.TrimEnd())

$vectorTask = @'
  // PERFORMANCE model:
  // VPU=32 lanes. Arithmetic is still evaluated by TB golden functions, but
  // memory/ACC traffic is not serialized into the timing model. The model
  // preserves all control/result handshakes and streams quantized results at
  // the target hardware throughput.
  task automatic vector_agent;
    control_command_t c;
    control_fp_data_t d;
    logic [15:0][31:0] a,b,x;
    logic [31:0] v,old_m,new_m;
    real angle,cs,sn;
    int tile,cmd_start,elapsed;
    logic [15:0][31:0] vb_a[32],vb_b[32];
    bit vb_ready[32];
    bit rope_row_ready[ROWS];
    bit gu_row_ready[ROWS];
    bit p_row_ready[PAIRS];

    wait(!reset);
    forever begin
      @(posedge clk);
      if(vector_valid&&vector_ready)begin
        c=vector_cmd;
        commands[c.job.header.op]++;
        cmd_start=cycle;
        @(negedge clk);

        if(c.function_id==VECTOR_OACC_SCALE||c.function_id==VECTOR_AFIN_QUANT)begin
          if(c.elements!=ROWS*TILE*QOZ_O_TILES||c.tiles!=QOZ_O_TILES||c.source!=WORK_OACC)
            $fatal(1,"PERF OACC command descriptor");
        end else if(c.elements!=ROWS*TILE*(c.function_id==VECTOR_ROPE_QUANT?2:1))
          $fatal(1,"PERF vector command element count");

        case(c.function_id)
          // K/Q RoPE + quant:
          // 32 FP32 lanes = one token row/cycle. Input rows and quant-result
          // output overlap. Result order remains the real interface order:
          // all 26 pairs of the first RoPE half, then all 26 of the second.
          VECTOR_ROPE_QUANT:begin
            for(int r=0;r<ROWS;r++)rope_row_ready[r]=0;
            fork
              begin : rope_input_pipe
                @(negedge clk); vector_data_ready=1;
                for(int r=0;r<ROWS;r++)begin
                  do @(posedge clk);while(!vector_data_valid);
                  d=vector_data;
                  if(d.index!=r||d.token!=c.token||d.job!=c.job||!d.vector_valid[0])
                    $fatal(1,"PERF RoPE stream identity");
                  @(negedge clk);
                  for(int i=0;i<TILE;i++)begin
                    if(d.first[i]!==projection_golden(c.job.header.op,r,c.tile-1,i)||
                       d.second[i]!==projection_golden(c.job.header.op,r,c.tile,i))
                      $fatal(1,"PERF RoPE matrix golden");
                    // Coefficient service is modeled as fully pipelined II=1.
                    // The fixed coefficient latency is absorbed into the first
                    // output wait; throughput is one row/cycle.
                    angle=(c.job.position_base+r)*
                          (10000.0**(-2.0*(c.rope_frequency_base+i)/256.0));
                    cs=real32(bits($cos(angle)));
                    sn=real32(bits($sin(angle)));
                    scratch0[r][i]=bits(real32(d.first[i])*cs-real32(d.second[i])*sn);
                    scratch1[r][i]=bits(real32(d.second[i])*cs+real32(d.first[i])*sn);
                  end
                  rope_row_ready[r]=1;
                end
                vector_data_ready=0;
              end
              begin : rope_output_pipe
                // Fixed coefficient/VPU pipe fill. II remains one row/cycle.
                repeat(8) @(posedge clk);
                for(int h=0;h<2;h++)begin
                  tile=c.job.header.op==OP_Q_PROJ?c.tile/2+h*8:h;
                  for(int p=0;p<PAIRS;p++)begin
                    wait(rope_row_ready[2*p] && ((2*p+1>=ROWS)||rope_row_ready[2*p+1]));
                    if(c.job.header.op==OP_Q_PROJ)begin
                      qgold[tile][2*p]=quant(h?scratch1[2*p]:scratch0[2*p]);
                      if(2*p+1<ROWS)qgold[tile][2*p+1]=quant(h?scratch1[2*p+1]:scratch0[2*p+1]);
                      result_pair(c,tile,p,qgold[tile][2*p],
                        p<25?qgold[tile][2*p+1]:'0,0,'1);
                    end else begin
                      kgold[tile][2*p]=quant(h?scratch1[2*p]:scratch0[2*p]);
                      if(2*p+1<ROWS)kgold[tile][2*p+1]=quant(h?scratch1[2*p+1]:scratch0[2*p+1]);
                      result_pair(c,tile,p,kgold[tile][2*p],
                        p<25?kgold[tile][2*p+1]:'0,0,'1);
                    end
                  end
                end
              end
            join
          end

          // V token-axis quant/reorder: input and result are independently
          // pipelined so steady throughput is one packet/cycle.
          VECTOR_V_QUANT:begin
            for(int j=0;j<32;j++)vb_ready[j]=0;
            fork
              begin : v_input_pipe
                @(negedge clk);vector_data_ready=1;
                for(int j=0;j<32;j++)begin
                  do @(posedge clk);while(!vector_data_valid);
                  d=vector_data;
                  vb_a[j]=d.first;vb_b[j]=d.second;
                  for(int i=0;i<TILE;i++)begin
                    int row,col;
                    row=(j/8)*16+i;col=(j%8)*2;
                    if(row<ROWS&&(d.first[i]!==projection_golden(OP_V_PROJ,row,c.tile,col)||
                                 d.second[i]!==projection_golden(OP_V_PROJ,row,c.tile,col+1)))
                      $fatal(1,"PERF V token packing golden");
                  end
                  @(negedge clk);vb_ready[j]=1;
                end
                vector_data_ready=0;
              end
              begin : v_output_pipe
                repeat(4) @(posedge clk);
                for(int j=0;j<32;j++)begin
                  wait(vb_ready[j]);
                  vgold[c.tile][j]=quant(vb_a[j]);
                  result_pair(c,c.tile,j,quant(vb_a[j]),quant(vb_b[j]),1,
                              j>=24?16'h0007:16'hffff);
                end
              end
            join
          end

          // G-U VPU half: GELU result arrives from SFU stream in first[],
          // Up is carried in second[]. VPU32 consumes one row whenever the
          // SFU producer makes it available and quant output is streamed.
          VECTOR_GU_POST:begin
            for(int r=0;r<ROWS;r++)gu_row_ready[r]=0;
            fork
              begin : gu_input_pipe
                @(negedge clk);vector_data_ready=1;
                for(int r=0;r<ROWS;r++)begin
                  do @(posedge clk);while(!vector_data_valid);
                  d=vector_data;
                  if(d.index!=r||d.second[0]!==bits(2.0*aint(r)))
                    $fatal(1,"PERF GU Up pair");
                  for(int i=0;i<TILE;i++)scratch0[r][i]=mul32(d.first[i],d.second[i]);
                  zgold[c.tile][r]=quant(scratch0[r]);
                  @(negedge clk);gu_row_ready[r]=1;
                end
                vector_data_ready=0;
              end
              begin : gu_output_pipe
                for(int p=0;p<PAIRS;p++)begin
                  wait(gu_row_ready[2*p]&&((p==25)||gu_row_ready[2*p+1]));
                  result_pair(c,c.tile,p,zgold[c.tile][2*p],
                              p<25?zgold[c.tile][2*p+1]:'0,0,'1);
                end
              end
            join
          end

          // QK post is modeled as a 32-lane VPU pipeline. Numerical reference
          // state is updated immediately; timing is 65 cycles, matching the
          // planned ~60-70 cycle implementation window.
          VECTOR_QK_POST:begin
            for(int r=0;r<ROWS;r++)begin
              v=0;
              for(int k=0;k<16;k++)
                v=fp32_legacy_ref_pkg::fp32_add(
                    v,dot_part(qgold[k][r],1+c.tile%3,128,-4));
              for(int i=0;i<TILE;i++)
                score[c.tile][r][i]=(r==0||(c.tile==54&&i==15))?32'hff800000:v;
              old_m=m[r];
              new_m=(r==0)?32'hff800000:
                    (c.tile==0?v:(real32(v)>real32(old_m)?v:old_m));
              alpha[c.tile][r]='0;
              alpha[c.tile][r][0]=(c.tile==0||r==0)?32'h3f800000:
                                   bits($exp(real32(old_m)-real32(new_m)));
              m[r]=new_m;
            end
            repeat(65)@(posedge clk);
          end

          // P_POST streams behind SFU4 P_EXP. Each pair is consumed as soon as
          // it arrives; VPU32 row-reduction/l update/quant is hidden by SFU.
          VECTOR_P_POST:begin
            for(int p=0;p<PAIRS;p++)p_row_ready[p]=0;
            @(negedge clk);vector_data_ready=1;
            for(int p=0;p<PAIRS;p++)begin
              do @(posedge clk);while(!vector_data_valid);
              d=vector_data;
              if(d.index!=p||d.tile!=c.tile||d.token!=c.token)
                $fatal(1,"PERF P stream identity");
              for(int r=0;r<2;r++)if(2*p+r<ROWS)begin
                x=r?d.second:d.first;
                v=0;
                for(int i=0;i<TILE;i++)v=fp32_legacy_ref_pkg::fp32_add(v,x[i]);
                lsum[2*p+r]=fp32_legacy_ref_pkg::fp32_add(
                    mul32(alpha[c.tile][2*p+r][0],lsum[2*p+r]),v);
                pgold[c.tile][2*p+r]=quant(x);
              end
              @(negedge clk);
              result_pair(c,c.tile,p,pgold[c.tile][2*p],
                          p<25?pgold[c.tile][2*p+1]:'0,0,'1);
            end
            vector_data_ready=0;
          end

          // 51x256 FP32 scale. Physical OACC packetization is 16 tiles x 26
          // row-pairs = 416 beats. This is the critical hidden VPU window.
          VECTOR_OACC_SCALE:begin
            repeat(416)@(posedge clk);
          end

          // Final A_FIN cannot be hidden. Produce one 32-value packet/cycle:
          // 16 tiles x 26 pairs = 416 cycles.
          VECTOR_AFIN_QUANT:begin
            for(int r=0;r<ROWS;r++)begin
              v=0;
              for(int block=0;block<KV_BLOCKS;block++)begin
                if(block>0)v=mul32(v,alpha[block][r][0]);
                v=fp32_legacy_ref_pkg::fp32_add(
                    v,dot_part(pgold[block][r],1,128,0));
              end
              attention_gold[r]=v;
            end
            for(int t=0;t<16;t++)for(int p=0;p<PAIRS;p++)begin
              for(int i=0;i<TILE;i++)begin
                a[i]=mul32(attention_gold[2*p],recip[2*p]);
                if(p<25)b[i]=mul32(attention_gold[2*p+1],recip[2*p+1]);
                else b[i]=0;
              end
              ogold[t][2*p]=quant(a);
              if(p<25)ogold[t][2*p+1]=quant(b);
              result_pair(c,t,p,ogold[t][2*p],
                          p<25?ogold[t][2*p+1]:'0,0,'1);
            end
          end

          default:$fatal(1,"PERF unexpected vector function");
        endcase

        elapsed=cycle-cmd_start;
        case(c.function_id)
          VECTOR_ROPE_QUANT: if(elapsed>rope_quant_max)rope_quant_max=elapsed;
          VECTOR_V_QUANT:    if(elapsed>v_quant_max)v_quant_max=elapsed;
          VECTOR_GU_POST:    if(elapsed>gu_post_max)gu_post_max=elapsed;
          VECTOR_QK_POST:    if(elapsed>qk_post_max)qk_post_max=elapsed;
          VECTOR_P_POST:     if(elapsed>p_post_max)p_post_max=elapsed;
          VECTOR_OACC_SCALE: if(elapsed>scale_max)scale_max=elapsed;
          VECTOR_AFIN_QUANT: if(elapsed>afin_max)afin_max=elapsed;
          default:;
        endcase

        @(negedge clk);
        vector_done='{command:c,error:0};
        vector_done_valid=1;
        do @(posedge clk);while(!vector_done_ready);
        @(negedge clk);vector_done_valid=0;
      end
    end
  endtask
'@

$functionTask = @'
  // PERFORMANCE SFU model: four scalar lanes.
  // GELU: 16 values/row -> 4 cycles/row.
  // P_EXP: 32 values/full pair -> 8 cycles/pair; tail pair 16 values -> 4.
  // ALPHA/RECIP: 51 scalars -> 13 compute cycles plus small control allowance.
  task automatic function_agent;
    control_command_t c;
    control_fp_data_t d;
    real x,t;
    int cmd_start,elapsed;

    wait(!reset);
    forever begin
      @(posedge clk);
      if(function_valid&&function_ready)begin
        c=function_cmd;
        function_commands++;
        cmd_start=cycle;
        @(negedge clk);

        if(c.elements!=((c.function_id==FUNCTION_GELU||c.function_id==FUNCTION_P_EXP)?
                       ROWS*TILE:ROWS))
          $fatal(1,"PERF SFU command element count");

        case(c.function_id)
          FUNCTION_GELU:begin
            for(int r=0;r<ROWS;r++)begin
              function_data_ready=1;
              do @(posedge clk);while(!function_data_valid);
              d=function_data;
              if(d.index!=r||d.token!=c.token)$fatal(1,"PERF GELU input token");
              function_result=d;
              for(int i=0;i<TILE;i++)begin
                x=real32(d.first[i]);
                t=$sqrt(2.0/3.141592653589793)*(x+0.044715*x*x*x);
                function_result.first[i]=bits(0.5*x*(2.0/(1.0+$exp(-2.0*t))));
              end
              @(negedge clk);function_data_ready=0;
              // Four SFU lanes process the 16-value row in four cycles.
              repeat(3)@(posedge clk);
              @(negedge clk);function_result_valid=1;
              do @(posedge clk);while(!function_result_ready);
              @(negedge clk);function_result_valid=0;
            end
          end

          FUNCTION_P_EXP:begin
            for(int p=0;p<PAIRS;p++)begin
              function_result='0;
              function_result.job=c.job;
              function_result.token=c.token;
              function_result.tile=c.tile;
              function_result.index=6'(p);
              function_result.last=p==PAIRS-1;
              function_result.vector_valid=row_mask(p);
              for(int lane=0;lane<2;lane++)if(2*p+lane<ROWS)begin
                for(int i=0;i<TILE;i++)begin
                  if(lane==0)
                    function_result.first[i]=(score[c.tile][2*p+lane][i]==32'hff800000)?
                      0:bits($exp(real32(score[c.tile][2*p+lane][i])-real32(m[2*p+lane])));
                  else
                    function_result.second[i]=(score[c.tile][2*p+lane][i]==32'hff800000)?
                      0:bits($exp(real32(score[c.tile][2*p+lane][i])-real32(m[2*p+lane])));
                end
              end
              // Include result handshake in the 8-cycle/4-cycle packet interval.
              repeat(p==PAIRS-1?3:7)@(posedge clk);
              @(negedge clk);function_result_valid=1;
              do @(posedge clk);while(!function_result_ready);
              @(negedge clk);function_result_valid=0;
            end
          end

          FUNCTION_RECIP:begin
            for(int r=0;r<ROWS;r++)
              recip[r]=lsum[r]==0?0:bits(1.0/real32(lsum[r]));
            repeat(18)@(posedge clk);
          end

          FUNCTION_ALPHA_EXP:begin
            // alpha[] golden values were produced by QK_POST. The SFU4
            // throughput is 13 cycles; 18 includes interface/control margin.
            repeat(18)@(posedge clk);
          end

          default:$fatal(1,"PERF unexpected SFU function");
        endcase

        elapsed=cycle-cmd_start;
        case(c.function_id)
          FUNCTION_GELU:      if(elapsed>gelu_max)gelu_max=elapsed;
          FUNCTION_P_EXP:     if(elapsed>pexp_max)pexp_max=elapsed;
          FUNCTION_RECIP:     if(elapsed>recip_max)recip_max=elapsed;
          FUNCTION_ALPHA_EXP: if(elapsed>alpha_max)alpha_max=elapsed;
          default:;
        endcase

        @(negedge clk);
        function_done='{command:c,error:0};
        function_done_valid=1;
        do @(posedge clk);while(!function_done_ready);
        @(negedge clk);function_done_valid=0;
      end
    end
  endtask
'@

$rxVec = [regex]::new('(?ms)^  task automatic vector_agent;.*?^  endtask\r?\n')
if ($rxVec.Matches($src).Count -ne 1) { throw 'vector_agent 匹配失败或不唯一。' }
$src = $rxVec.Replace($src,$vectorTask.TrimEnd()+"`r`n",1)

$rxFun = [regex]::new('(?ms)^  task automatic function_agent;.*?^  endtask\r?\n')
if ($rxFun.Matches($src).Count -ne 1) { throw 'function_agent 匹配失败或不唯一。' }
$src = $rxFun.Replace($src,$functionTask.TrimEnd()+"`r`n",1)

# PERF 模式去掉旧 TB 人工周期性 backpressure；STRESS plusarg 仍保留随机 ready。
# PERF 模式：不依赖旧 TB 中具体的 cycle%N 写法。
# 直接按 ready 信号名替换其整行赋值；即使本地 TB 已经改过，也能继续。
$readyPatterns = @(
  @('(?m)^\s*kv_out_ready\s*=.*?;\s*$',       '    kv_out_ready=stress?random_limit(13,4)!=0:1;'),
  @('(?m)^\s*reduce_out_ready\s*=.*?;\s*$',   '    reduce_out_ready=stress?random_limit(14,4)!=0:1;'),
  @('(?m)^\s*vector_ready\s*=.*?;\s*$',       '    vector_ready=stress?random_limit(3,4)!=0:1;'),
  @('(?m)^\s*function_ready\s*=.*?;\s*$',     '    function_ready=stress?random_limit(4,4)!=0:1;')
)
foreach($item in $readyPatterns) {
  $rx=[regex]::new($item[0])
  if($rx.Matches($src).Count -lt 1) {
    throw "找不到 ready 信号赋值: $($item[0])"
  }
  $src=$rx.Replace($src,$item[1],1)
}

$issueRx=[regex]::new('(?m)^\s*if\s*\([^\r\n]*matrix\.req_valid[^\r\n]*\)\s*issues\[[^\r\n]*\]\+\+;\s*$')
if($issueRx.Matches($src).Count -lt 1){
  # 兼容本地版本把计数拆成 begin/end 的写法。
  $issueRx=[regex]::new('(?ms)^\s*if\s*\([^\r\n]*matrix\.req_valid[^\r\n]*\)\s*begin.*?issues\[[^\r\n]*\]\+\+;.*?^\s*end\s*$')
}
if($issueRx.Matches($src).Count -lt 1){
  throw '找不到 Matrix issue 统计点。请把 Select-String matrix.req_valid 的输出发给我。'
}
$newIssue = @'
    if(dut.exec.dispatch.matrix.req_valid)begin
      if(issues[job.header.op]==0)first_issue[job.header.op]=cycle;
      last_issue[job.header.op]=cycle;
      issues[job.header.op]++;
    end
'@
$src=$issueRx.Replace($src,$newIssue.TrimEnd(),1)

$startRx=[regex]::new('(?m)^\s*if\s*\([^\r\n]*dispatch\.req\.start[^\r\n]*\)\s*matrix_jobs\+\+;\s*$')
if($startRx.Matches($src).Count -lt 1){
  $startRx=[regex]::new('(?ms)^\s*if\s*\([^\r\n]*dispatch\.req\.start[^\r\n]*\)\s*begin.*?matrix_jobs\+\+;.*?^\s*end\s*$')
}
if($startRx.Matches($src).Count -lt 1){
  throw '找不到 Attention Matrix start 统计点。'
}
$newStart = @'
    if(dut.exec.dispatch.req.start&&active_adapter==1)begin
      matrix_jobs++;
      if(attn_start_last>=0)begin
        int iv;
        iv=cycle-attn_start_last;
        attn_interval_sum+=iv;
        attn_interval_count++;
        if(iv>attn_interval_max)attn_interval_max=iv;
      end
      attn_start_last=cycle;
    end
'@
$src=$startRx.Replace($src,$newStart.TrimEnd(),1)

# run_job 增加统一性能输出。
$runJobRx=[regex]::new('(?m)^\s*task\s+automatic\s+run_job\s*\([^\r\n]*\);\s*$')
if($runJobRx.Matches($src).Count -ne 1){
  throw "run_job 签名匹配数量异常: $($runJobRx.Matches($src).Count)"
}
$newSig = @'
  task automatic run_job(input pcore_op_e op,input int id,expected_issues);
    int span,jcycles;
    real mutil,jocc;
'@
$src=$runJobRx.Replace($src,$newSig.TrimEnd(),1)

$dispRx=[regex]::new('(?m)^\s*\$display\("CONTROL_JOB op=%0d cycles=%0d issues=%0d sent=%0d commands=%0d"[^\r\n]*\);\s*$')
if($dispRx.Matches($src).Count -lt 1){
  throw '找不到 CONTROL_JOB 输出点。'
}
$newDisp = @'
        jcycles=cycle-job_start;
        job_cycles_rec[op]=jcycles;
        span=(last_issue[op]>=first_issue[op])?(last_issue[op]-first_issue[op]+1):0;
        mutil=span?100.0*real'(issues[op])/real'(span):0.0;
        jocc=jcycles?100.0*real'(issues[op])/real'(jcycles):0.0;
        $display("CONTROL_JOB op=%0d cycles=%0d issues=%0d sent=%0d commands=%0d",
                 op,jcycles,issues[op],sent[op],commands[op]);
        $display("JOB_PERF op=%0d cycles=%0d issues=%0d first_issue=%0d last_issue=%0d matrix_span=%0d matrix_util=%0.3f job_occupancy=%0.3f",
                 op,jcycles,issues[op],first_issue[op],last_issue[op],span,mutil,jocc);
'@
$src=$dispRx.Replace($src,$newDisp.TrimEnd(),1)

# 不再修改原 TB 的初始化代码：first/last/job_cycles 均在运行时覆盖。

# 在最终 PASS 前输出 Attention / post 性能摘要。
$finalRx=[regex]::new('(?m)^\s*\$display\("tb_v3_pcore_control_perf PASS jobs=7[^\r\n]*\);\$finish;\s*$')
if($finalRx.Matches($src).Count -lt 1){
  $finalRx=[regex]::new('(?m)^\s*\$display\("tb_v3_pcore_control_v3 PASS jobs=7[^\r\n]*\);\$finish;\s*$')
}
if($finalRx.Matches($src).Count -lt 1){
  throw '找不到最终七 Job PASS 输出点。'
}
$newFinal = @'
    $display("ATTN_PERF matrix_body=416 matrix_jobs=%0d steady_interval_avg=%0.3f steady_interval_max=%0d qk_post_max=%0d alpha_max=%0d pexp_max=%0d ppost_max=%0d scale_max=%0d scale_margin=%0d recip_max=%0d afin_max=%0d tail_est=%0d total_cycles=%0d",
      matrix_jobs,
      attn_interval_count?real'(attn_interval_sum)/real'(attn_interval_count):0.0,
      attn_interval_max,qk_post_max,alpha_max,pexp_max,p_post_max,
      scale_max,434-scale_max,recip_max,afin_max,recip_max+afin_max,
      job_cycles_rec[OP_ATTENTION]);
    $display("POST_PERF rope_quant_max=%0d v_quant_max=%0d gelu_max=%0d gu_post_max=%0d",
      rope_quant_max,v_quant_max,gelu_max,gu_post_max);
    $display("tb_v3_pcore_control_perf PASS jobs=7 issues=265408 perf_vpu_lanes=32 perf_sfu_lanes=4 no_artificial_egress_stall=1");
    $finish;
'@
$src=$finalRx.Replace($src,$newFinal.TrimEnd(),1)

# Attention-only 也补一行性能输出，方便先单跑 Attention。
$attnPass='$display("tb_v3_pcore_control_perf PASS attention_only=1 attention_jobs=110 real_softmax=1 workspace=1 O_commit=1");$finish;'
$attnNew=@'
      $display("ATTN_PERF matrix_body=416 matrix_jobs=%0d steady_interval_avg=%0.3f steady_interval_max=%0d qk_post_max=%0d alpha_max=%0d pexp_max=%0d ppost_max=%0d scale_max=%0d scale_margin=%0d recip_max=%0d afin_max=%0d tail_est=%0d total_cycles=%0d",
        matrix_jobs,
        attn_interval_count?real'(attn_interval_sum)/real'(attn_interval_count):0.0,
        attn_interval_max,qk_post_max,alpha_max,pexp_max,p_post_max,
        scale_max,434-scale_max,recip_max,afin_max,recip_max+afin_max,
        job_cycles_rec[OP_ATTENTION]);
      $display("tb_v3_pcore_control_perf PASS attention_only=1 attention_jobs=110 perf_vpu_lanes=32 perf_sfu_lanes=4");
      $finish;
'@
if($src.Contains($attnPass)){$src=$src.Replace($attnPass,$attnNew.TrimEnd())}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($dstPath, $src, $utf8NoBom)
Write-Host "已生成: $dstPath"
Write-Host "原始功能 TB 未修改: $srcPath"
