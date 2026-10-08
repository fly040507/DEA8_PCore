param(
  [string]$VivadoRoot='D:\Xilinx\Vivado\2022.2',
  [string]$Python='C:\Users\fly04\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
)
$ErrorActionPreference='Stop'
Push-Location $PSScriptRoot
try {
  New-Item -ItemType Directory -Force reports | Out-Null
  'RUNNING' | Set-Content reports/simulation_summary.txt
  & $Python tb/make_vectors.py
  if($LASTEXITCODE){throw 'Vector generation failed'}
  $sources=Get-Content collective.f | Where-Object {$_ -and !$_.StartsWith('#')}
  $sources+=@('tb/make_vectors.py','tb/operands.hex','tb/expected.hex','run_sim.ps1','collective.f')
  $hashes=$sources | ForEach-Object { Get-FileHash -LiteralPath $_ -Algorithm SHA256 }
  $hashes | Select-Object Path,Hash | Export-Csv reports/sources_sha256.csv -NoTypeInformation
  & "$VivadoRoot\bin\xvlog.bat" -sv -f collective.f | Tee-Object reports/compile.log
  if($LASTEXITCODE){throw 'Compilation failed'}
  & "$VivadoRoot\bin\xelab.bat" tb_collective -s collective_checked --O2 --debug typical --mt off -timescale 1ns/1ps |
    Tee-Object reports/elaborate.log
  if($LASTEXITCODE){throw 'Elaboration failed'}
  $output=& "$VivadoRoot\bin\xsim.bat" collective_checked -runall --log reports/tb_collective.log 2>&1
  $code=$LASTEXITCODE
  $output | Write-Output
  $text=$output -join "`n"
  if($code -ne 0 -or $text -match '(?im)^\s*(Fatal|Error):' -or $text -notmatch 'tb_collective PASS') {
    throw 'Simulation failed or PASS missing'
  }
  foreach($entry in $hashes){
    if((Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash -ne $entry.Hash){throw "Source changed during run: $($entry.Path)"}
  }
  ($output | Select-String 'JOB PASS|tb_collective PASS').Line | Set-Content reports/simulation_summary.txt
} catch {
  "FAILED: $_" | Set-Content reports/simulation_summary.txt
  throw
} finally {Pop-Location}
