param([Parameter(Mandatory=$true)][string]$RepoRoot, [switch]$Rust, [switch]$Flutter)
$ErrorActionPreference = 'Stop'
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Management" -ErrorAction Stop
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
$targets = @()
if ($Rust) { $targets += Join-Path $repo 'target\release' }
if ($Flutter) { $targets += Join-Path $repo 'flutter\build\windows' }
foreach ($target in $targets) {
    $full = [IO.Path]::GetFullPath($target)
    if (!$full.StartsWith($repo+'\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Clean target outside repository' }
    $parent = $full
    while ($parent -and $parent -ne $repo) {
        if (Test-Path -LiteralPath $parent) {
            if ((Get-Item -Force -LiteralPath $parent).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing to clean a linked build path: $parent"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Recurse -Force }
}
