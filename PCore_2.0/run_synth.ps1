param(
  [string]$VivadoRoot="D:\Xilinx\Vivado\2022.2",
  [string]$Top="dea8_mxu_2row"
)
$ErrorActionPreference="Stop"
$reportDir=Join-Path $PSScriptRoot "reports"
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
Push-Location $reportDir
try {
  & (Join-Path $VivadoRoot "bin\vivado.bat") -mode batch -source (Join-Path $PSScriptRoot "scripts\synth_u50.tcl") -tclargs $Top
  if($LASTEXITCODE){throw "U50 synthesis failed: $Top"}
} finally { Pop-Location }
