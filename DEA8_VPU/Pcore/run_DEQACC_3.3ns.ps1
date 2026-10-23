param([string]$VivadoRoot="D:\Xilinx\Vivado\2022.2")
$ErrorActionPreference="Stop"
$here=$PSScriptRoot
$report=Join-Path $here "reports\DEQACC_3.3ns"
New-Item -ItemType Directory -Force -Path $report | Out-Null
$files=@(Get-ChildItem (Join-Path $here "rtl") -Filter *.sv -File)
$files+=Get-Item (Join-Path $here "pcore_all.f"),(Join-Path $here "core_clock.xdc"),(Join-Path $here "DEQACC_3.3ns.tcl"),(Join-Path $here "DEQACC_3.3ns_refine.tcl")
$before=$files | Sort-Object FullName | Get-FileHash -Algorithm SHA256
$before | ForEach-Object {"$($_.Hash),$($_.Path.Substring($here.Length+1))"} | Set-Content (Join-Path $report "sources_sha256.csv") -Encoding UTF8
Push-Location $here
try {
  foreach($script in @("DEQACC_3.3ns.tcl","DEQACC_3.3ns_refine.tcl")) {
    & (Join-Path $VivadoRoot "bin\vivado.bat") -mode batch -source $script -log "$report\$script.log" -journal "$report\$script.jou" -tclargs ($here -replace '\\','/')
    if($LASTEXITCODE){throw "Vivado failed: $script"}
  }
  $after=$files | Sort-Object FullName | Get-FileHash -Algorithm SHA256
  if(Compare-Object ($before | ForEach-Object Hash) ($after | ForEach-Object Hash)){throw "Sources changed during run"}
} finally {Pop-Location}
