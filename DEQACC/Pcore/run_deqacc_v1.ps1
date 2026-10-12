param(
  [string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',
  [switch]$SevenJobs
)
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$report=Join-Path $here 'reports'
if (!(Test-Path -LiteralPath $report)) {throw 'Expected project reports directory'}
if (!(Test-Path -LiteralPath (Join-Path $VivadoRoot 'settings64.bat'))) {throw 'Vivado settings64.bat is missing'}
# Every tool gets an ordinary settings64 environment in its own cmd process.
# No manual PATH/RDI/Tcl changes, no direct unwrapped executable, no synth/P&R.
function Invoke-Vivado([string]$Tool,[string]$Arguments,[switch]$AllowFailure) {
  $command='call "{0}\settings64.bat" && call "{0}\bin\{1}.bat" {2}' -f $VivadoRoot,$Tool,$Arguments
  $output=& $env:ComSpec /d /c $command 2>&1
  $code=$LASTEXITCODE
  $text=$output -join "`n"
  if (!$AllowFailure -and ($code -ne 0 -or $text -match '(?im)^\s*(ERROR|Error):')) {
    throw "$Tool failed (exit=$code). See reports/v1_* logs."
  }
  return $text
}
Push-Location $here
try {
  Invoke-Vivado xvlog '-sv -work v1_suite -f pcore_v1_sim.f -log reports/v1_suite_compile.log' | Out-Null
  Invoke-Vivado xvlog ('-work v1_suite "{0}\data\verilog\src\glbl.v"' -f $VivadoRoot) | Out-Null
  $results=[Collections.Generic.List[string]]::new()
  $tops=@('tb_deqacc_v1_arithmetic','tb_deqacc_v1_stream','tb_deqacc_v1_dynamic_matrix','tb_matrix')
  if ($SevenJobs) {$tops+='tb_pcore_control'}
  foreach ($top in $tops) {
    $snapshot="v1_suite_$top"
    $optimization='--O2'
    Invoke-Vivado xelab "v1_suite.$top v1_suite.glbl -s $snapshot $optimization --debug typical --mt off -timescale 1ns/1ps -L unisims_ver -log reports/v1_${top}_elab.log" | Out-Null
    $text=Invoke-Vivado xsim "$snapshot -runall -log reports/v1_${top}.log"
    if ($text -match '(?im)^\s*(Fatal|Error|ERROR):' -or $text -notmatch [regex]::Escape("$top PASS")) {
      throw "Verification failed: $top (check reports/v1_${top}.log)"
    }
    $line=([regex]::Match($text,"(?m)^$top PASS.*$")).Value
    $results.Add($line);$line
  }
  foreach ($test in @('BAD_RAW','BAD_RAW_2','BAD_RAW_3')) {
    $text=Invoke-Vivado xsim "v1_suite_tb_deqacc_v1_stream -runall -testplusarg $test -log reports/v1_${test}.log" -AllowFailure
    $fatals=[regex]::Matches($text,'(?im)^\s*Fatal:.*$')
    if ($fatals.Count -ne 1 -or $text -notmatch 'Fatal: V1 accumulator RAW: dependent input interval below four cycles' -or
        $text -match '(?im)^\s*(ERROR|Error):' -or $text -match 'tb_deqacc_v1_stream PASS') {
      throw "RAW negative case failed: $test"
    }
    $line="$test PASS expected RAW rejection";$results.Add($line);$line
  }
  $results.Add('Simulation only. No synthesis/placement/routing. 250 MHz physical timing is unverified.')
  [IO.File]::WriteAllLines((Join-Path $report 'v1_simulation_summary.txt'),$results,[Text.Encoding]::UTF8)
  $hashes=@('file,sha256')
  $sources=@('rtl/pcore_pkg.sv','rtl/deqacc_v1_pkg.sv','rtl/dequant_lane_v1.sv','rtl/fp32_add_lane_v1.sv',
    'rtl/acc_slice_v1.sv','rtl/deqacc_v1_control.sv','rtl/deqacc_v1_group8.sv','rtl/DEQACC_V1.sv',
    'rtl/dea8_acc_store.sv','rtl/dea8_matrix.sv','tb/fp32_legacy_ref_pkg.sv')
  foreach($source in $sources) {
    $digest=(Get-FileHash -LiteralPath (Join-Path $here $source) -Algorithm SHA256).Hash
    $hashes+="$source,$digest"
  }
  [IO.File]::WriteAllLines((Join-Path $report 'v1_sources_sha256.csv'),$hashes,[Text.Encoding]::UTF8)
} finally {Pop-Location}
