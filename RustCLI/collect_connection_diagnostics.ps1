# Collect only sanitized connection timelines. Does not copy application logs,
# credentials, configuration, screenshots or clipboard contents.
[CmdletBinding()]
param(
    [string]$LogDirectory = (Join-Path $env:LOCALAPPDATA 'MDesk\diagnostics'),
    [string]$OutputPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) ('MDesk-diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip'))
)
$ErrorActionPreference = 'Stop'
$sourceRoot = [IO.Path]::GetFullPath($LogDirectory)
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Diagnostic directory does not exist: $sourceRoot"
}
$files = @(Get-ChildItem -LiteralPath $sourceRoot -File | Where-Object {
    $_.Name -match '^mdesk-(ui-)?diag-[\d-]+(\.jsonl)?(\.[12])?\.jsonl$'
})
if ($files.Count -eq 0) { throw "No connection diagnostic files in $sourceRoot" }
$destination = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $destination) { throw "Output already exists: $destination" }
# Snapshot first, so ZIP compression never holds an active log open for long.
$snapshotRoot = Join-Path ([IO.Path]::GetTempPath()) ('MDesk-diagnostic-export-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $snapshotRoot | Out-Null
try {
    foreach ($file in $files) {
        try { Copy-Item -LiteralPath $file.FullName -Destination $snapshotRoot }
        catch [System.IO.FileNotFoundException] { Write-Warning 'A rotated log disappeared during export; retry after disconnecting if needed.' }
    }
    $copies = @(Get-ChildItem -LiteralPath $snapshotRoot -File)
    if ($copies.Count -eq 0) { throw 'No logs could be copied.' }
    Compress-Archive -LiteralPath $copies.FullName -DestinationPath $destination
    Write-Output "Saved $($copies.Count) diagnostic files: $destination"
} finally {
    # Delete only files in the exact temporary directory created by this run.
    Get-ChildItem -LiteralPath $snapshotRoot -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $snapshotRoot
}
