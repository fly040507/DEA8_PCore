param(
  [string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',
  [ValidateRange(1,64)][int]$StressSeeds=16,
  [ValidateRange(1,16)][int]$Workers=4,
  [switch]$ProtocolOnly
)
& (Join-Path $PSScriptRoot 'run_control_signoff.ps1') @PSBoundParameters
