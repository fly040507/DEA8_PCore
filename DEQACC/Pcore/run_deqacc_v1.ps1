param(
  [string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',
  [switch]$SevenJobs
)
$ErrorActionPreference='Stop'
$here=$PSScriptRoot
$report=Join-Path $here 'reports'
if (!(Test-Path -LiteralPath $report)) {throw 'Expected project reports directory'}
if (!(Test-Path -LiteralPath (Join-Path $VivadoRoot 'settings64.bat'))) {throw 'Vivado settings64.bat is missing'}
# Every tool uses settings64.bat and its supported launcher in the same cmd.
# Do not override PATH/RDI/Tcl variables or invoke unwrapped executables.
function Invoke-Vivado([string]$Tool,[string]$Arguments,[switch]$AllowFailure) {
  $command='call "{0}\settings64.bat" && call "{0}\bin\{1}.bat" {2}' -f $VivadoRoot,$Tool,$Arguments
  $output=& $env:ComSpec /d /c $command 2>&1
  $code=$LASTEXITCODE
  $text=$output -join "`n"
  if (!$AllowFailure -and ($code -ne 0 -or $text -match '(?im)^\s*(ERROR|Error):')) {
    throw "$Tool failed (exit=$code). See reports/v2_* logs."
  }
  return $text
}
Push-Location $here
try {
  Invoke-Vivado xvlog '-sv -work v2_suite -f pcore_v1_sim.f -log reports/v2_suite_compile.log' | Out-Null
  Invoke-Vivado xvlog ('-work v2_suite "{0}\data\verilog\src\glbl.v"' -f $VivadoRoot) | Out-Null
  $results=[Collections.Generic.List[string]]::new()
  $tops=@('tb_deqacc_v1_arithmetic','tb_deqacc_v1_stream','tb_deqacc_v1_dynamic_matrix','tb_matrix')
  if ($SevenJobs) {$tops+='tb_pcore_control'}
  foreach ($top in $tops) {
    $snapshot="v2_suite_$top"
    $optimization='--O2'
    Invoke-Vivado xelab "v2_suite.$top v2_suite.glbl -s $snapshot $optimization --debug typical --mt off -timescale 1ns/1ps -L unisims_ver -log reports/v2_${top}_elab.log" | Out-Null
    $text=Invoke-Vivado xsim "$snapshot -runall -log reports/v2_${top}.log"
    if ($text -match '(?im)^\s*(Fatal|Error|ERROR):' -or $text -notmatch [regex]::Escape("$top PASS")) {
      throw "Verification failed: $top (check reports/v2_${top}.log)"
    }
    $line=([regex]::Match($text,"(?m)^$top PASS.*$")).Value
    $results.Add($line);$line
    if($top -eq 'tb_deqacc_v1_arithmetic' -or $top -eq 'tb_deqacc_v1_stream') {
      $extra=if($top -eq 'tb_deqacc_v1_arithmetic'){'tb_deqacc_v2_dual_path'}else{'tb_deqacc_v2_ingress'}
      $detail=([regex]::Match($text,"(?m)^$extra PASS.*$")).Value
      if(!$detail){throw "Missing V2 structural/algorithm coverage: $extra"}
      $results.Add($detail);$detail
    }
  }
  foreach ($test in @('BAD_RAW','BAD_RAW_2','BAD_RAW_3')) {
    $text=Invoke-Vivado xsim "v2_suite_tb_deqacc_v1_stream -runall -testplusarg $test -log reports/v2_${test}.log" -AllowFailure
    $fatals=[regex]::Matches($text,'(?im)^\s*Fatal:.*$')
    if ($fatals.Count -ne 1 -or $text -notmatch 'Fatal: V1 accumulator RAW: dependent input interval below four cycles' -or
        $text -match '(?im)^\s*(ERROR|Error):' -or $text -match 'tb_deqacc_v1_stream PASS') {
      throw "RAW negative case failed: $test"
    }
    $line="$test PASS expected RAW rejection";$results.Add($line);$line
  }
  # Keep the published V1 reference test-only. Its unchanged shared arithmetic
  # dependencies are hash-pinned; changed modules use test-only renamed copies.
  $pins=Import-Csv (Join-Path $here 'tb/reference/v1_shared_sha256.csv')
  foreach($pin in $pins) {
    if((Get-FileHash -LiteralPath (Join-Path $here $pin.file) -Algorithm SHA256).Hash -ne $pin.sha256) {
      throw "Published V1 reference dependency changed: $($pin.file)"
    }
  }
  Invoke-Vivado xvlog '-sv -work v2_lockstep_final -d V2_LOCKSTEP -f deqacc_v1.f -f v2_lockstep.f -log reports/v2_lockstep_compile.log' | Out-Null
  Invoke-Vivado xvlog ('-work v2_lockstep_final "{0}\data\verilog\src\glbl.v"' -f $VivadoRoot) | Out-Null
  foreach($top in @('tb_deqacc_v1_arithmetic','tb_deqacc_v1_stream')) {
    $snapshot="v2_lockstep_final_$top"
    Invoke-Vivado xelab "v2_lockstep_final.$top v2_lockstep_final.glbl -s $snapshot --O2 --debug typical --mt off -timescale 1ns/1ps -L unisims_ver -log reports/v2_lockstep_${top}_elab.log" | Out-Null
    $text=Invoke-Vivado xsim "$snapshot -runall -log reports/v2_lockstep_${top}.log"
    $marker=if($top -eq 'tb_deqacc_v1_arithmetic'){'tb_deqacc_v2_dequant_lockstep PASS'}else{'tb_deqacc_v2_lockstep PASS'}
    if($text -match '(?im)^\s*(Fatal|Error|ERROR):' -or $text -notmatch [regex]::Escape($marker)) {
      throw "Published V1/V2 lockstep failed: $top"
    }
    $line=([regex]::Match($text,"(?m)^$marker.*$")).Value
    $results.Add($line);$line
  }
  $results.Add('V2 simulation only. No synthesis/placement/routing. 250 MHz physical timing is unverified.')
  [IO.File]::WriteAllLines((Join-Path $report 'v2_simulation_summary.txt'),$results,[Text.Encoding]::UTF8)
  $hashes=@('file,sha256')
  $sources=@('rtl/pcore_pkg.sv','rtl/deqacc_v1_pkg.sv','rtl/dequant_lane_v1.sv','rtl/fp32_add_lane_v1.sv',
    'rtl/acc_slice_v1.sv','rtl/deqacc_v1_control.sv','rtl/deqacc_v2_scale_ingress.sv',
    'rtl/deqacc_v2_cluster.sv','rtl/DEQACC_V1.sv',
    'rtl/dea8_acc_store.sv','rtl/dea8_matrix.sv','rtl/dea8_fp32_pkg.sv',
    'tb/fp32_legacy_ref_pkg.sv','tb/tb_deqacc_v1_arithmetic.sv','tb/tb_deqacc_v1_stream.sv',
    'tb/tb_deqacc_v1_dynamic_matrix.sv','tb/tb_pcore_control.sv','run_deqacc_v1.ps1',
    'tb/reference/published_v1_dequant.sv','tb/reference/published_v1_acc.sv',
    'tb/reference/published_v1_group.sv','tb/reference/published_v1_top.sv',
    'tb/reference/published_v1_fpadd.sv','tb/reference/published_v1_control.sv',
    'tb/reference/v1_shared_sha256.csv','pcore_v1_sim.f','deqacc_v1.f','v2_lockstep.f')
  foreach($source in $sources) {
    $digest=(Get-FileHash -LiteralPath (Join-Path $here $source) -Algorithm SHA256).Hash
    $hashes+="$source,$digest"
  }
  [IO.File]::WriteAllLines((Join-Path $report 'v2_sources_sha256.csv'),$hashes,[Text.Encoding]::UTF8)
} finally {Pop-Location}
