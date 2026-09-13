param(
  [string]$VivadoRoot = "D:\Xilinx\Vivado\2022.2",
  [string]$PythonExecutable = "python",
  [ValidateSet("all", "mxu", "attention", "deqacc", "qk", "r6", "matrix", "state", "frontend")]
  [string]$Test = "all"
)
$ErrorActionPreference = "Stop"
$xvlog = Join-Path $VivadoRoot "bin\xvlog.bat"
$xelab = Join-Path $VivadoRoot "bin\xelab.bat"
$xsim = Join-Path $VivadoRoot "bin\xsim.bat"
if (!(Test-Path $xvlog)) { throw "Vivado xvlog not found under $VivadoRoot" }
$tests = @()
if ($Test -in @("all", "r6", "frontend")) { $tests += "tb_dea8_kvb_adapter", "tb_dea8_xbc_adapter" }
if ($Test -in @("all", "mxu")) { $tests += "tb_dea8_mxu" }
if ($Test -in @("all", "attention")) { $tests += "tb_dea8_attention_ctrl" }
if ($Test -in @("all", "deqacc")) { $tests += "tb_dea8_deqacc" }
if ($Test -in @("all", "qk")) { $tests += "tb_dea8_qk_engine" }
if ($Test -in @("all", "r6", "matrix")) { $tests += "tb_dea8_matrix_engine", "tb_dea8_attention_core" }
if ($Test -in @("all", "r6", "matrix")) {
  Push-Location (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
  try {
    & $PythonExecutable -m pcore.tests.generate_matrix_vectors
    if ($LASTEXITCODE -ne 0) { throw "Matrix vector generation failed" }
  } finally { Pop-Location }
}
if ($Test -in @("all", "r6")) { $tests += "tb_dea8_accumulator_fabric", "tb_dea8_attention_scheduler", "tb_dea8_attention_buffers" }
if ($Test -in @("all", "r6", "state")) { $tests += "tb_dea8_attention_state", "tb_dea8_p_result_link", "tb_dea8_external_stubs" }
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
  $testbenchFiles = @(
    "..\tb\stubs\dea8_vpu_stub.sv",
    "..\tb\stubs\dea8_sfu_stub.sv",
    "..\tb\stubs\dea8_gcore_stub.sv",
    "..\tb\stubs\dea8_hbm_stub.sv",
    "..\tb\tb_dea8_mxu.sv",
    "..\tb\tb_dea8_attention_ctrl.sv",
    "..\tb\tb_dea8_deqacc.sv",
    "..\tb\tb_dea8_qk_engine.sv",
    "..\tb\tb_dea8_accumulator_fabric.sv",
    "..\tb\tb_dea8_attention_scheduler.sv",
    "..\tb\tb_dea8_attention_buffers.sv",
    "..\tb\tb_dea8_matrix_engine.sv",
    "..\tb\tb_dea8_attention_core.sv",
    "..\tb\tb_dea8_attention_state.sv",
    "..\tb\tb_dea8_p_result_link.sv",
    "..\tb\tb_dea8_external_stubs.sv",
    "..\tb\tb_dea8_kvb_adapter.sv",
    "..\tb\tb_dea8_xbc_adapter.sv"
  )
  & $xvlog -sv -f dea8_pcore.f @testbenchFiles
  if ($LASTEXITCODE -ne 0) { throw "xvlog failed" }
  foreach ($top in $tests) {
    & $xelab $top -s "${top}_sim" -timescale 1ns/1ps
    if ($LASTEXITCODE -ne 0) { throw "xelab failed for $top" }
    Invoke-Simulation $top "default" ""
    if ($top -eq "tb_dea8_kvb_adapter") {
      foreach ($mode in @("BAD_KIND", "BAD_BLOCK", "BAD_EPOCH", "BAD_COLUMN", "BAD_TILE", "EARLY_LAST", "LATE_LAST", "PADDING", "MASK_CHANGE", "V_COLUMN")) {
        Invoke-Simulation $top $mode "Fatal: KVB protocol/context/order/mask mismatch"
      }
    }
    if ($top -eq "tb_dea8_external_stubs") {
      Invoke-Simulation $top "V_UNCONFIRMED" "Fatal: KVB V packing is not confirmed"
    }
    if ($top -eq "tb_dea8_attention_state") {
      Invoke-Simulation $top "EARLY_ALPHA" "Fatal: Alpha completed before 51 writes"
      Invoke-Simulation $top "OVERWRITE" "Fatal: Alpha generation overwrite"
      Invoke-Simulation $top "BAD_MASK" "Fatal: Scalar pair base/mask invalid"
    }
    if ($top -eq "tb_dea8_p_result_link") {
      Invoke-Simulation $top "EARLY_DONE" "Fatal: VPU P done before final pair accepted"
      Invoke-Simulation $top "WRONG_EPOCH" "Fatal: P stream context/order mismatch"
    }
    if ($top -eq "tb_dea8_matrix_engine") {
      Invoke-Simulation $top "KVB" ""
      Invoke-Simulation $top "STARVE" ""
      Invoke-Simulation $top "RESET_JOB" ""
    }
    if ($top -eq "tb_dea8_accumulator_fabric") {
      Invoke-Simulation $top "NO_RESERVATION" "Fatal: DEQACC write without bank reservation"
    }
    if ($top -eq "tb_dea8_attention_scheduler") {
      Invoke-Simulation $top "BAD_CONTEXT" "Fatal: Matrix completion context mismatch"
    }
    if ($top -eq "tb_dea8_attention_buffers") {
      Invoke-Simulation $top "BANK_CONFLICT" "Fatal: PBUF bank has simultaneous producer and consumer"
    }
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
