param(
  [string]$VivadoRoot = "D:\Xilinx\Vivado\2022.2",
  [string]$PythonExecutable = "python",
  [ValidateSet("all", "mxu", "attention", "deqacc", "qk")]
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
if ($Test -in @("all", "deqacc")) { $tests += "tb_dea8_deqacc" }
if ($Test -in @("all", "qk")) { $tests += "tb_dea8_qk_engine" }
if ($Test -in @("all", "deqacc", "mxu", "qk")) {
  Push-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
  try {
    & $PythonExecutable -m pcore.tests.generate_deqacc_vectors
    if ($LASTEXITCODE -ne 0) { throw "DEQACC vector generation failed" }
  } finally { Pop-Location }
}

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
  & $xvlog -sv -f dea8_pcore.f ..\tb\tb_dea8_mxu.sv ..\tb\tb_dea8_attention_ctrl.sv ..\tb\tb_dea8_deqacc.sv ..\tb\tb_dea8_qk_engine.sv
  if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }
  foreach ($top in $tests) {
    & $xelab $top -s "${top}_sim" -timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw "xelab failed for $top" }
    Invoke-Simulation $top "default" ""
    if ($top -eq "tb_dea8_qk_engine") {
      Invoke-Simulation $top "STREAMING" ""
      Invoke-Simulation $top "STARVE" ""
      Invoke-Simulation $top "RESET_JOB" ""
      Invoke-Simulation $top "QOZ_CONFLICT" "Fatal: QOZ write during reserved QK job"
    }
    if ($top -eq "tb_dea8_mxu") {
      Invoke-Simulation $top "STREAMING" ""
      Invoke-Simulation $top "INJECT_BUBBLE" "Fatal: Local stall inside tile"
    }
    if ($top -eq "tb_dea8_deqacc") {
      Invoke-Simulation $top "BUBBLES" ""
      Invoke-Simulation $top "RAW_HAZARD" "Fatal: DEQACC accumulator RAW hazard"
      Invoke-Simulation $top "RAW_GAP3" "Fatal: DEQACC accumulator RAW hazard"
      Invoke-Simulation $top "BAD_DEST" "Fatal: Invalid DEQACC SBUF target"
      Invoke-Simulation $top "BAD_ADDR" "Fatal: DEQACC address out of range"
    }
  }
} finally {
  Pop-Location
}
