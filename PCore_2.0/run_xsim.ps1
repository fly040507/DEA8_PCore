param([string]$VivadoRoot="D:\Xilinx\Vivado\2022.2")
$ErrorActionPreference="Stop"
$here=$PSScriptRoot; $xvlog=Join-Path $VivadoRoot "bin\xvlog.bat"; $xelab=Join-Path $VivadoRoot "bin\xelab.bat"; $xsim=Join-Path $VivadoRoot "bin\xsim.bat"
$tops=@("tb_dea8_pe_2row","tb_dea8_mxu_2row","tb_dea8_a2_fifo","tb_dea8_w_tile_assembler_pp","tb_dea8_matrix_frontend_2row")
$testFiles=@($tops | ForEach-Object { "..\tb\$_.sv" })
$reportDir=Join-Path $here "reports"
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$summaryPath=Join-Path $reportDir "simulation_summary.txt"
"RUNNING at $(Get-Date -Format o); previous PASS is not current" |
  Set-Content $summaryPath -Encoding UTF8
trap {
  "FAILED at $(Get-Date -Format o): $_" | Set-Content $summaryPath -Encoding UTF8
  throw
}
$sourceHashes=@(Get-ChildItem (Join-Path $here "rtl\*.sv"),(Join-Path $here "tb\*.sv") |
  Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash)
if(!(Test-Path $xvlog)){throw "Vivado not found: $VivadoRoot"}
Push-Location (Join-Path $here "rtl")
try { & $xvlog -sv -f pcore2.f @testFiles (Join-Path $VivadoRoot "data\verilog\src\glbl.v"); if($LASTEXITCODE){throw "xvlog failed"} } finally { Pop-Location }
foreach($top in $tops) {
  Push-Location (Join-Path $here "rtl")
  try {
    & $xelab $top glbl -s "${top}_sim" -timescale 1ns/1ps -L unisims_ver
    if($LASTEXITCODE){throw "xelab failed: $top"}
    $output = & $xsim "${top}_sim" -runall 2>&1
    $exitCode = $LASTEXITCODE
    $output | Write-Output
    $output | Set-Content (Join-Path $reportDir "$top.txt") -Encoding UTF8
    $text = $output -join "`n"
    if($exitCode -ne 0 -or $text -match '(?im)^\s*(Fatal|Error):' -or
       $text -notmatch [regex]::Escape("$top PASS")) {
      throw "Simulation did not pass: $top"
    }
  } finally { Pop-Location }
}
 $endHashes=@(Get-ChildItem (Join-Path $here "rtl\*.sv"),(Join-Path $here "tb\*.sv") |
  Get-FileHash -Algorithm SHA256 |
  Select-Object Path,Hash)
if(Compare-Object $sourceHashes $endHashes -Property Path,Hash) {
  throw "RTL/TB files changed during regression; run again before recording PASS"
}
$sourceHashes |
  Export-Csv (Join-Path $reportDir "simulation_sources_sha256.csv") -NoTypeInformation -Encoding UTF8
"All $($tops.Count) testbenches passed at $(Get-Date -Format o)" |
  Set-Content (Join-Path $reportDir "simulation_summary.txt") -Encoding UTF8
