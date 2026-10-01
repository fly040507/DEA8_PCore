param([string]$VivadoRoot="D:\Xilinx\Vivado\2022.2")
$ErrorActionPreference="Stop"
$here=$PSScriptRoot;$rtl=Join-Path $here "rtl";$xvlog=Join-Path $VivadoRoot "bin\xvlog.bat";$xelab=Join-Path $VivadoRoot "bin\xelab.bat";$xsim=Join-Path $VivadoRoot "bin\xsim.bat";$report=Join-Path $here "reports"
$tops=@("tb_v3_ingress","tb_v3_bpath","tb_v3_bfifo_stream","tb_v3_pair_store","tb_v3_pair_store_regions","tb_v3_acc_overlap","tb_v3_local_a_protocol","tb_v3_deqacc32","tb_v3_matrix","tb_v3_projection","tb_v3_attention_scheduler","tb_v3_attention_matrix","tb_v3_attention_system","tb_v3_attention_55")
$tops=@("tb_v3_fp32_equiv")+$tops
$tops=@("tb_fp32_acc_lane_v5","tb_deqacc32_v5_stream")+$tops
$tops=@("tb_v3_gu_scheduler","tb_v3_gu_matrix","tb_v3_gu_32_system")+$tops
New-Item -ItemType Directory -Force -Path $report | Out-Null
"RUNNING at $(Get-Date -Format o)" | Set-Content (Join-Path $report "v3_simulation_summary.txt") -Encoding UTF8
Push-Location $here
try {
  & $xvlog -sv -f v3_all.f (Join-Path $VivadoRoot "data\verilog\src\glbl.v")
  if($LASTEXITCODE){throw "v3 xvlog failed"}
  foreach($top in $tops){
    & $xelab $top glbl -s "${top}_sim" -timescale 1ns/1ps -L unisims_ver
    if($LASTEXITCODE){throw "v3 xelab failed: $top"}
    $out=& $xsim "${top}_sim" -runall 2>&1;$code=$LASTEXITCODE;$out|Write-Output
    $out|Set-Content (Join-Path $report "$top.txt") -Encoding UTF8
    $text=$out -join "`n"
    if($code -ne 0 -or $text -match '(?im)^\s*(Fatal|Error):' -or $text -notmatch [regex]::Escape("$top PASS")){throw "v3 simulation failed: $top"}
  }
  # A separate 55-block run restores real OACC reads/writes and overlap checks.
  # It uses the SAME numerical golden, but does not assert scheduling latency.
  $out=& $xsim tb_v3_attention_55_sim -runall -testplusarg PORT_STRESS 2>&1
  $code=$LASTEXITCODE;$out|Write-Output
  $out|Set-Content (Join-Path $report "tb_v3_attention_55_port_stress.txt") -Encoding UTF8
  $text=$out -join "`n"
  if($code -ne 0 -or $text -match '(?im)^\s*(Fatal|Error):' -or $text -notmatch 'tb_v3_attention_55 PASS mode=port_stress'){throw "Attention port-stress failed"}
  # Expected failures only pass on the precise DUT context assertion. An
  # unrelated error, watchdog, or simulator startup failure is NOT success.
  foreach($unit in @("MATRIX","VPU","SFU")){
    $out=& $xsim tb_v3_attention_scheduler_sim -runall -testplusarg "BAD_$unit" 2>&1
    $out|Write-Output
    $out|Set-Content (Join-Path $report "tb_v3_attention_scheduler_bad_$unit.txt") -Encoding UTF8
    $text=$out -join "`n"
    $label=if($unit -eq "MATRIX"){"Matrix"}else{$unit}
    $expected="Fatal: Attention $label completion context mismatch"
    $fatals=[regex]::Matches($text,'(?im)^\s*Fatal:.*$')
    if($fatals.Count -ne 1 -or $text -notmatch [regex]::Escape($expected) -or $text -match '(?im)^\s*Error:' -or $text -match 'tb_v3_attention_scheduler PASS'){throw "Context rejection did not match: $unit"}
  }
  Get-ChildItem (Join-Path $here "rtl"),(Join-Path $here "tb") -File -Filter *.sv |
    Sort-Object FullName |
    Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash),$($_.Path.Substring($here.Length+1))" } |
    Set-Content (Join-Path $report "v3_sources_sha256.csv") -Encoding UTF8
  "All $($tops.Count) v3 testbenches + Attention55 port-stress passed; G-U replay/golden/QOZ and 3 expected context rejections verified at $(Get-Date -Format o). Simulation only; no synthesis/P&R." | Set-Content (Join-Path $report "v3_simulation_summary.txt") -Encoding UTF8
} finally { Pop-Location }
