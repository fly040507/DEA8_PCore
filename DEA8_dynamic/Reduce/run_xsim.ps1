param([string]$VivadoRoot='D:\Xilinx\Vivado\2022.2')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$work=Join-Path $root 'sim'
$reports=Join-Path $root 'reports'
New-Item -ItemType Directory -Force -Path $work,$reports | Out-Null
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$files=@(Get-Content (Join-Path $root 'reduce.f'))+@('reduce.f','run_xsim.ps1')
$pins=@($files | ForEach-Object { [pscustomobject]@{file=$_;sha256=(Get-FileHash (Join-Path $root $_) -Algorithm SHA256).Hash} })
function Invoke-Official([string]$tool,[string]$arguments) {
    $command='call "'+(Join-Path $VivadoRoot 'settings64.bat')+'" && call "'+(Join-Path $VivadoRoot "bin\$tool.bat")+'" '+$arguments
    $lines=@(& $env:ComSpec /d /c $command 2>&1)
    $code=$LASTEXITCODE
    $lines | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $reports "${tool}_$stamp.log")
    $output=$lines -join "`n"
    if($code -ne 0 -or $output -match '(?im)\bFatal:|\bERROR:|^\s*Error:|FATAL_ERROR|EXCEPTION_ACCESS_VIOLATION|Assertion failed:') {
        throw "Official $tool failed; see Reduce/reports/${tool}_$stamp.log"
    }
    return $output
}
Push-Location $work
try {
    $sources=@(Get-Content (Join-Path $root 'reduce.f') | ForEach-Object {'"'+(Join-Path $root $_)+'"'})
    $null=Invoke-Official 'xvlog' ('--sv --work dynamic_reduce '+($sources -join ' '))
    $snapshot="dynamic_reduce_$stamp"
    $null=Invoke-Official 'xelab' "dynamic_reduce.tb_dynamic_reduce --O2 --debug typical --mt off -timescale 1ns/1ps --snapshot $snapshot"
    $result=Invoke-Official 'xsim' "$snapshot -runall"
    if($result -notmatch 'tb_dynamic_reduce PASS\b'){throw 'No reduce PASS marker'}
    foreach($pin in $pins) {
        if((Get-FileHash (Join-Path $root $pin.file) -Algorithm SHA256).Hash -ne $pin.sha256){throw "Source changed during simulation: $($pin.file)"}
    }
    $pins | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath (Join-Path $reports "sources_sha256_$stamp.csv")
    $line=[regex]::Match($result,'(?m)^tb_dynamic_reduce PASS.*$').Value
    $line | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $reports "summary_$stamp.txt")
    Write-Host $line
} finally {Pop-Location}
