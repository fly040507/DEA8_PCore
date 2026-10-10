param([string]$VivadoRoot="D:\Xilinx\Vivado\2022.2")
$ErrorActionPreference="Stop"
$here=$PSScriptRoot;$xvlog=Join-Path $VivadoRoot "bin\xvlog.bat";$xelab=Join-Path $VivadoRoot "bin\xelab.bat";$xsim=Join-Path $VivadoRoot "bin\xsim.bat"
$report=Join-Path $here "reports\single_core_chain.txt"
Push-Location $here
try {
  & $xvlog -sv -f pcore_all.f (Join-Path $VivadoRoot "data\verilog\src\glbl.v")
  if($LASTEXITCODE){throw "xvlog failed"}
  $results=@()
  foreach($top in @("tb_attention_55","tb_gu_32_system","tb_attention_gu_chain")) {
    & $xelab $top glbl -s "${top}_single_core" -timescale 1ns/1ps -L unisims_ver
    if($LASTEXITCODE){throw "xelab failed: $top"}
    $out=& $xsim "${top}_single_core" -runall 2>&1
    $text=$out -join "`n";$out|Write-Output
    if($LASTEXITCODE -or $text -match '(?im)^\s*(Fatal|Error):' -or $text -notmatch "$top PASS") { throw "simulation failed: $top" }
    $results+=$text
  }
  $header="Single-core serialized Attention -> G-U regression`r`nAttention phase completes before G-U phase.`r`n"
  ($header+($results -join "`r`n"))|Set-Content $report -Encoding UTF8
  "Single-core Attention -> G-U chain PASS; report: $report"|Write-Output
} finally { Pop-Location }
