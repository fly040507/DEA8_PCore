param(
  [string]$Top="dea8_deqacc32_v4",
  [string]$VivadoRoot="D:\Xilinx\Vivado\2022.2"
)
$ErrorActionPreference="Stop"
$here=$PSScriptRoot
$report=Join-Path $here "reports\ooc_$Top"
New-Item -ItemType Directory -Force -Path $report | Out-Null
$inputs=@(Get-ChildItem (Join-Path $here "rtl") -Filter *.sv -File)
$inputs+=Get-Item (Join-Path $here "pcore_all.f"),(Join-Path $here "core_clock.xdc"),(Join-Path $here "synth_ooc.tcl")
$before=$inputs | Sort-Object FullName | Get-FileHash -Algorithm SHA256
$before | ForEach-Object { "$($_.Hash),$($_.Path.Substring($here.Length+1))" } |
  Set-Content (Join-Path $report "sources_sha256.csv") -Encoding UTF8
"RUNNING top=$Top time=$(Get-Date -Format o)" | Set-Content (Join-Path $report "status.txt") -Encoding UTF8
Push-Location $here
try {
  & (Join-Path $VivadoRoot "bin\vivado.bat") -mode batch -source synth_ooc.tcl -log "$report\run.log" -journal "$report\run.jou" -tclargs $Top ($here -replace '\\','/')
  if($LASTEXITCODE){throw "Vivado OOC failed: $Top"}
  $after=$inputs | Sort-Object FullName | Get-FileHash -Algorithm SHA256
  if(Compare-Object ($before | ForEach-Object Hash) ($after | ForEach-Object Hash)){throw "Inputs changed during OOC"}
  "COMPLETED top=$Top time=$(Get-Date -Format o); inspect run.log and timing.rpt: completion does not mean timing passed" |
    Set-Content (Join-Path $report "status.txt") -Encoding UTF8
} catch {
  "FAILED top=$Top time=$(Get-Date -Format o): $_" | Set-Content (Join-Path $report "status.txt") -Encoding UTF8
  throw
} finally {Pop-Location}
