[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$OutputZip
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Utility" -ErrorAction Stop
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Management" -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$exe = (Resolve-Path -LiteralPath $Path).Path
$reportPath = $exe + '.capabilities.json'
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
if ($report.pe_architecture -ne 'x86' -or
    [Version]$report.pe_subsystem_version -ne [Version]'6.1' -or
    $report.compiled_capabilities.hwcodec_min_windows_major -ne 10 -or
    $report.executable_sha256 -ne $hash) {
    throw 'A current, verified Win7-compatible x86 capability report is required before packaging.'
}
$zipPath = [IO.Path]::GetFullPath($OutputZip)
$tempPath = $zipPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
try {
    $archive = [IO.Compression.ZipFile]::Open($tempPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in @($exe, $reportPath)) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $file, [IO.Path]::GetFileName($file),
                [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $archive.Dispose() }
    $archive = [IO.Compression.ZipFile]::OpenRead($tempPath)
    try {
        if ($archive.Entries.Count -ne 2) { throw 'Unexpected ZIP entries.' }
        foreach ($file in @($exe, $reportPath)) {
            $entry = $archive.GetEntry([IO.Path]::GetFileName($file))
            if (!$entry) { throw "Missing ZIP entry: $file" }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $entryHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '')
                if ($entryHash -ne (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash) {
                    throw "ZIP content differs from verified source: $file"
                }
            } finally { $stream.Dispose(); $sha.Dispose() }
        }
    } finally { $archive.Dispose() }
    Move-Item -LiteralPath $tempPath -Destination $zipPath -Force
    Write-Host "[OK] ZIP contents match the verified EXE and capability report: $zipPath"
} finally {
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
}
