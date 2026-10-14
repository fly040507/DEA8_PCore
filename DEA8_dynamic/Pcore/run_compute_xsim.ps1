param(
    [string]$VivadoRoot = 'D:\Xilinx\Vivado\2022.2',
    [string[]]$Tests = @('tb_dynamic_pcore_control', 'tb_dynamic_projection_scheduler', 'tb_dynamic_projection_post', 'tb_dynamic_v_pair', 'tb_dynamic_kv_output', 'tb_dynamic_kv_projection', 'tb_dynamic_q_projection', 'tb_dynamic_profile', 'tb_dynamic_a_queue', 'tb_dynamic_local_memory', 'tb_dynamic_local_loader', 'tb_dynamic_local_compute', 'tb_dynamic_frontend', 'tb_dynamic_pe', 'tb_deqacc_v1_arithmetic', 'tb_dynamic_deqacc', 'tb_dynamic_compute'),
    [ValidateSet('O0','O2')][string]$Optimization = 'O2'
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$settings = Join-Path $VivadoRoot 'settings64.bat'
if (-not (Test-Path -LiteralPath $settings)) { throw "Missing $settings" }
$work = Join-Path $root 'sim_compute'
$reports = Join-Path $root 'reports'
New-Item -ItemType Directory -Path $work,$reports -Force | Out-Null
$sources = Get-Content -LiteralPath (Join-Path $root 'compute.f') |
    Where-Object { $_.Trim() -and -not $_.StartsWith('#') } |
    ForEach-Object { '"' + (Join-Path $root $_.Trim()) + '"' }
$library = 'dynamic_compute'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$results = [Collections.Generic.List[string]]::new()
$files = @(Get-Content -LiteralPath (Join-Path $root 'compute.f')) + @('compute.f', 'run_compute_xsim.ps1')
$pins = @($files | Where-Object { $_.Trim() } | ForEach-Object {
    [pscustomobject]@{ file = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $root $_) -Algorithm SHA256).Hash }
})

function Invoke-VivadoTool([string]$Tool, [string]$Arguments, [string]$LogName, [switch]$ExpectedRaw) {
    $command = 'call "' + $settings + '" && call "' +
        (Join-Path $VivadoRoot "bin\$Tool.bat") + '" ' + $Arguments
    $lines = @(& $env:ComSpec /d /c $command 2>&1)
    $code = $LASTEXITCODE
    $lines | Set-Content -LiteralPath (Join-Path $reports $LogName) -Encoding UTF8
    $text = $lines -join "`n"
    if ($ExpectedRaw) {
        $fatals = [regex]::Matches($text, '(?im)^\s*Fatal:.*$')
        if ($fatals.Count -ne 1 -or $text -notmatch 'Fatal: V1 accumulator RAW: dependent input interval below four cycles' -or
            $text -match '(?im)\bERROR:|^\s*Error:|\bFATAL_ERROR:|EXCEPTION_ACCESS_VIOLATION|Assertion failed:|\bPASS\b') {
            throw "Unexpected RAW-negative result; see reports/$LogName"
        }
        return $text
    }
    if ($code -ne 0 -or $text -match '(?im)\bFatal:|\bFATAL_ERROR:|\bERROR:|^\s*Error:|EXCEPTION_ACCESS_VIOLATION|Assertion failed:') {
        throw "$Tool failed; see reports/$LogName"
    }
    Write-Host "$Tool completed; reports/$LogName"
    return $text
}

Push-Location $work
try {
    $glbl = Join-Path $VivadoRoot 'data\verilog\src\glbl.v'
    $null = Invoke-VivadoTool 'xvlog' ('--sv --work ' + $library + ' ' + ($sources -join ' ') + ' "' + $glbl + '"') "compile_$stamp.log"
    foreach ($top in $Tests) {
        $snapshot = "${top}_$stamp"
        $null = Invoke-VivadoTool 'xelab' ("$library.$top $library.glbl -L unisims_ver --$Optimization --debug typical --mt off -timescale 1ns/1ps --snapshot $snapshot") "${top}_elaborate_$stamp.log"
        $output = Invoke-VivadoTool 'xsim' ("$snapshot -runall") "${top}_run_$stamp.log"
        if ($output -notmatch ([regex]::Escape($top) + ' PASS\b')) {
            throw "$top produced no PASS marker"
        }
        $line = [regex]::Match($output, "(?m)^$top PASS.*$").Value
        $results.Add($line)
        Write-Host $line
        if ($top -in @('tb_dynamic_compute','tb_dynamic_frontend','tb_dynamic_local_compute','tb_dynamic_q_projection','tb_dynamic_kv_projection')) {
            [regex]::Matches($output, '(?m)^CASE .*') | ForEach-Object { $results.Add($_.Value) }
        }
        if ($top -eq 'tb_dynamic_deqacc') {
            foreach ($gap in 1..3) {
                $null = Invoke-VivadoTool 'xsim' ("$snapshot -runall -testplusarg BAD_RAW_$gap") "raw_gap${gap}_run_$stamp.log" -ExpectedRaw
                $line = "RAW_GAP=$gap PASS (exact expected DUT rejection)"
                $results.Add($line)
                Write-Host $line
            }
        }
    }
    $results.Add('Simulation only: no synthesis, no placement/routing, no 250MHz timing signoff.')
    $results | Set-Content -LiteralPath (Join-Path $reports "simulation_summary_$stamp.txt") -Encoding UTF8
    foreach ($pin in $pins) {
        if ((Get-FileHash -LiteralPath (Join-Path $root $pin.file) -Algorithm SHA256).Hash -ne $pin.sha256) {
            throw "Source changed during regression: $($pin.file)"
        }
    }
    $pins | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath (Join-Path $reports "sources_sha256_$stamp.csv")
    Write-Host 'Dynamic compute regression PASS (fresh compile and snapshots, no synthesis).'
} finally { Pop-Location }
