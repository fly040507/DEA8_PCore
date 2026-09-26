param([string]$VivadoRoot="D:\Xilinx\Vivado\2022.2")
$ErrorActionPreference="Stop"
$here=$PSScriptRoot;$rtl=Join-Path $here "rtl";$xvlog=Join-Path $VivadoRoot "bin\xvlog.bat";$xelab=Join-Path $VivadoRoot "bin\xelab.bat";$xsim=Join-Path $VivadoRoot "bin\xsim.bat";$report=Join-Path $here "reports"
$tops=@("tb_v3_ingress","tb_v3_bpath","tb_v3_bfifo_stream","tb_v3_pair_store","tb_v3_pair_store_regions","tb_v3_deqacc32","tb_v3_matrix")
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
  Get-ChildItem (Join-Path $here "rtl"),(Join-Path $here "tb") -File -Filter *.sv |
    Sort-Object FullName |
    Get-FileHash -Algorithm SHA256 |
    ForEach-Object { "$($_.Hash),$($_.Path.Substring($here.Length+1))" } |
    Set-Content (Join-Path $report "v3_sources_sha256.csv") -Encoding UTF8
  "All $($tops.Count) v3 testbenches passed at $(Get-Date -Format o)" | Set-Content (Join-Path $report "v3_simulation_summary.txt") -Encoding UTF8
} finally { Pop-Location }
