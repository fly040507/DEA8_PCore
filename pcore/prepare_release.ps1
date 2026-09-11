param([ValidatePattern('^[0-9]{8}$')][string]$Version = '20260912')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$dest = Join-Path $root "output/release/DEA8_PCore_$Version"
if (Test-Path -LiteralPath $dest) { throw "Release exists; use a new version to avoid stale files: $dest" }
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$selected = Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File | Where-Object {
  $_.Extension -in @('.sv','.f','.py','.md','.ps1') -and
  $_.FullName -notmatch '[\\/](xsim.dir|__pycache__|\.Xil)[\\/]'
}
foreach ($file in $selected) {
  $relative = $file.FullName.Substring($root.Length + 1)
  $target = Join-Path $dest $relative
  New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
  Copy-Item -LiteralPath $file.FullName -Destination $target
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '.gitignore') -Destination (Join-Path $dest '.gitignore')
$refs = Join-Path $dest 'references'
New-Item -ItemType Directory -Force -Path $refs | Out-Null
$aiNotes = 'AI' + [char]0x5DE5 + [char]0x5177 + [char]0x610F + [char]0x89C1 + '.docx'
foreach ($name in @('README.docx',$aiNotes,'FlashAttention.pptx','MXU_9.6.pptx')) {
  Copy-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) $name) -Destination $refs
}
$pdf = Join-Path $root "output/pdf/VLA_PCore_Attention_v5_$Version.pdf"
if (Test-Path -LiteralPath $pdf) {
  $documents = Join-Path $dest 'documents'
  New-Item -ItemType Directory -Force -Path $documents | Out-Null
  Copy-Item -LiteralPath $pdf -Destination $documents
}
Get-ChildItem -LiteralPath $dest -Recurse -File | Where-Object Name -ne 'MANIFEST.csv' | ForEach-Object {
  [PSCustomObject]@{Path=$_.FullName.Substring($dest.Length+1);Bytes=$_.Length;SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
} | Export-Csv -LiteralPath (Join-Path $dest 'MANIFEST.csv') -NoTypeInformation -Encoding UTF8
Write-Output $dest
