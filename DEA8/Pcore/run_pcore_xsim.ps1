param([string]$VivadoRoot="D:\Xilinx\Vivado\2022.2")
$ErrorActionPreference="Stop"
$here=$PSScriptRoot;$rtl=Join-Path $here "rtl";$xvlog=Join-Path $VivadoRoot "bin\xvlog.bat";$xelab=Join-Path $VivadoRoot "bin\xelab.bat";$xsim=Join-Path $VivadoRoot "bin\xsim.bat";$report=Join-Path $here "reports"
$tops=@("tb_ingress","tb_bpath","tb_bfifo_stream","tb_pair_store","tb_pair_store_regions","tb_acc_overlap","tb_local_a_protocol","tb_deqacc32","tb_matrix","tb_projection","tb_projection_local_o","tb_projection_local_down","tb_attention_scheduler","tb_attention_matrix","tb_attention_system","tb_attention_55")
$tops=@("tb_fp32_equiv")+$tops
$tops=@("tb_fp32_acc_lane_v5","tb_deqacc32_v5_stream")+$tops
$tops=@("tb_gu_scheduler","tb_gu_scheduler_stress","tb_gu_matrix","tb_gu_32_system","tb_qoz_shared","tb_attention_gu_chain")+$tops
$tops=@("tb_pcore_ctrl")+$tops
$tops=@("tb_pcore_job_dispatch","tb_qoz_manager","tb_pcore_three_job_chain")+$tops
$tops=@("tb_qoz_stale_write_after_release","tb_qoz_double_release")+$tops
$tops=@("tb_gu_xbc_restart")+$tops
$tops=@("tb_pcore_control")+$tops
New-Item -ItemType Directory -Force -Path $report | Out-Null
"RUNNING at $(Get-Date -Format o)" | Set-Content (Join-Path $report "DEA8_simulation_summary.txt") -Encoding UTF8
Push-Location $here
try {
  & $xvlog -sv -f pcore_all.f (Join-Path $VivadoRoot "data\verilog\src\glbl.v")
  if($LASTEXITCODE){throw "DEA8 xvlog failed"}
  & $xvlog -sv -f legacy/regression.f
  if($LASTEXITCODE){throw "legacy xvlog failed"}
  foreach($top in $tops){
    & $xelab $top glbl -s "${top}_sim" -timescale 1ns/1ps -L unisims_ver
    if($LASTEXITCODE){throw "DEA8 xelab failed: $top"}
    $out=& $xsim "${top}_sim" -runall 2>&1;$code=$LASTEXITCODE;$out|Write-Output
    $out|Set-Content (Join-Path $report "$top.txt") -Encoding UTF8
    $text=$out -join "`n"
    if($code -ne 0 -or $text -match '(?im)^\s*(Fatal|Error):' -or $text -notmatch [regex]::Escape("$top PASS")){throw "DEA8 simulation failed: $top"}
  }
  # Same execution top, GU-only slow POST: G0..U62 must continue and only the
  # final Gate reservation may stall on the single result slot.
  $out=& $xsim tb_pcore_three_job_chain_sim -runall -testplusarg GU_ONLY -testplusarg SLOW_POST 2>&1
  $code=$LASTEXITCODE;$out|Write-Output
  $out|Set-Content (Join-Path $report "tb_gu_prefetch_slow.txt") -Encoding UTF8
  $text=$out -join "`n"
  if($code -ne 0 -or $text -match '(?im)^\s*(Fatal|Error):' -or $text -notmatch 'tb_pcore_three_job_chain PASS.*slow=1'){throw "GU slow-post prefetch failed"}
  # A separate 55-block run restores real OACC reads/writes and overlap checks.
  # It uses the SAME numerical golden, but does not assert scheduling latency.
  $out=& $xsim tb_attention_55_sim -runall -testplusarg PORT_STRESS 2>&1
  $code=$LASTEXITCODE;$out|Write-Output
  $out|Set-Content (Join-Path $report "tb_attention_55_port_stress.txt") -Encoding UTF8
  $text=$out -join "`n"
  if($code -ne 0 -or $text -match '(?im)^\s*(Fatal|Error):' -or $text -notmatch 'tb_attention_55 PASS mode=port_stress'){throw "Attention port-stress failed"}
  # Expected failures only pass on the precise DUT context assertion. An
  # unrelated error, watchdog, or simulator startup failure is NOT success.
  foreach($unit in @("MATRIX","VPU","SFU")){
    $out=& $xsim tb_attention_scheduler_sim -runall -testplusarg "BAD_$unit" 2>&1
    $out|Write-Output
    $out|Set-Content (Join-Path $report "tb_attention_scheduler_bad_$unit.txt") -Encoding UTF8
    $text=$out -join "`n"
    $label=if($unit -eq "MATRIX"){"Matrix"}else{$unit}
    $expected="Fatal: Attention $label completion context mismatch"
    $fatals=[regex]::Matches($text,'(?im)^\s*Fatal:.*$')
    if($fatals.Count -ne 1 -or $text -notmatch [regex]::Escape($expected) -or $text -match '(?im)^\s*Error:' -or $text -match 'tb_attention_scheduler PASS'){throw "Context rejection did not match: $unit"}
  }
  foreach($fault in @("WRITE","RELEASE")){
    $out=& $xsim tb_pcore_three_job_chain_sim -runall -testplusarg "FAULT_$fault" 2>&1
    $code=$LASTEXITCODE;$out|Write-Output
    $out|Set-Content (Join-Path $report "tb_pcore_fabric_$fault.txt") -Encoding UTF8
    $text=$out -join "`n"
    if($code -ne 0 -or $text -match '(?im)^\s*(Fatal|Error):' -or $text -notmatch 'PASS fabric_fault=1 clear_recovery=1'){throw "Fabric FAULT failed: $fault"}
  }
  # Same shared execution top, but all seven PCore operations are issued in
  # one reset.  The non-matrix QOZ/VPU/SFU traffic is supplied by the TB.
  $out=& $xsim tb_pcore_three_job_chain_sim -runall -testplusarg SEVEN_JOBS 2>&1
  $code=$LASTEXITCODE;$out|Write-Output
  $out|Set-Content (Join-Path $report "tb_pcore_seven_jobs.txt") -Encoding UTF8
  $text=$out -join "`n"
  if($code -ne 0 -or $text -match '(?im)^\s*(Fatal|Error):' -or $text -notmatch 'tb_pcore_three_job_chain PASS seven_jobs=7'){throw "Seven-job matrix chain failed"}
  if($text -notmatch 'SEVEN_TOTAL issues=265408 order=K,V,Q,ATTENTION,O,GU,DOWN') {throw "Final seven-job order/workload failed"}
  $perf=@($out | Where-Object { "$_" -match '^PROJ_PERF ' })
  if($perf.Count -ne 5) {throw "Missing measured Projection performance"}
  $perf | Set-Content (Join-Path $report "DEA8_projection_performance.txt") -Encoding UTF8
  Get-ChildItem (Join-Path $here "rtl"),(Join-Path $here "tb"),(Join-Path $here "legacy") -File -Filter *.sv |
    Sort-Object FullName |
    Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash),$($_.Path.Substring($here.Length+1))" } |
    Set-Content (Join-Path $report "DEA8_sources_sha256.csv") -Encoding UTF8
  "All $($tops.Count) testbenches (mainline + legacy compatibility), PCore DEA8 PCore Matrix Stage Final Functional Freeze: K,V,Q,Attention,O,GU,Down; total issues=265408; Seven PCore Matrix Jobs functional PASS, GU slow-post, Attention55 port-stress, 2 fabric FAULT/clear cases and 3 expected context rejections passed at $(Get-Date -Format o). Simulation only; no synthesis/P&R." | Set-Content (Join-Path $report "DEA8_simulation_summary.txt") -Encoding UTF8
} catch {
  "FAILED at $(Get-Date -Format o): $_" | Set-Content (Join-Path $report "DEA8_simulation_summary.txt") -Encoding UTF8
  throw
} finally { Pop-Location }
