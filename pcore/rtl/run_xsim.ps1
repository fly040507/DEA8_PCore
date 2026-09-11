param(
  [string]$VivadoRoot = "D:\Xilinx\Vivado\2022.2",
  [ValidateSet("all", "mxu", "attention")]
  [string]$Test = "all"
)
$ErrorActionPreference = "Stop"
$xvlog = Join-Path $VivadoRoot "bin\xvlog.bat"
$xelab = Join-Path $VivadoRoot "bin\xelab.bat"
$xsim = Join-Path $VivadoRoot "bin\xsim.bat"
if (!(Test-Path $xvlog)) { throw "Vivado xvlog not found under $VivadoRoot" }
$tests = @()
if ($Test -in @("all", "mxu")) { $tests += "tb_dea8_mxu" }
if ($Test -in @("all", "attention")) { $tests += "tb_dea8_attention_ctrl" }

function Invoke-Simulation([string]$Top, [string]$Mode, [string]$ExpectedFailure) {
  $simArgs = @("${Top}_sim", "-runall", "-log", "${Top}_${Mode}.log")
  if ($Mode -ne "default") { $simArgs += @("-testplusarg", $Mode) }
  $simOutput = & $xsim @simArgs 2>&1
  $code = $LASTEXITCODE
  $simOutput | Write-Output
  $joined = $simOutput -join "`n"
  if ($ExpectedFailure) {
    if ($joined -notmatch [regex]::Escape($ExpectedFailure)) {
      throw "Expected assertion did not fire for $Mode"
    }
    Write-Output "Expected-failure test PASS: $Mode"
  } elseif ($code -ne 0 -or $joined -match '(Fatal|ERROR|Error):' -or
            $joined -notmatch [regex]::Escape("$Top PASS")) {
    throw "xsim failed or did not finish for $Top $Mode"
  }
}
Push-Location $PSScriptRoot
try {
  & $xvlog -sv -f dea8_pcore.f ..\tb\tb_dea8_mxu.sv ..\tb\tb_dea8_attention_ctrl.sv
  if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }
  foreach ($top in $tests) {
    & $xelab $top -s "${top}_sim" -timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw "xelab failed for $top" }
    Invoke-Simulation $top "default" ""
    if ($top -eq "tb_dea8_mxu") {
      Invoke-Simulation $top "STREAMING" ""
      Invoke-Simulation $top "INJECT_BUBBLE" "Fatal: Local stall inside tile"
    }
  }
} finally {
  Pop-Location
}
