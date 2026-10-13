param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [ValidateSet('B1','B2','B3')][string]$Variant = 'B3',
    [ValidateSet('x64','x86')][string]$Architecture = 'x64',
    [Parameter(Mandatory=$true)][string]$OutEnvFile
)
$ErrorActionPreference = 'Stop'
# Parent shells may expose a PowerShell 7 module path to Windows PowerShell 5.
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Utility" -ErrorAction Stop
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Management" -ErrorAction Stop
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd('\')
$deps = Join-Path $repo '.deps'
$localNative = Join-Path $deps 'vcpkg'
if ($Architecture -eq 'x86') { $localNative = Join-Path $deps 'vcpkg-x86' }
$nativeTriplet = "$Architecture-windows-static"
$envOutput = [IO.Path]::GetFullPath($OutEnvFile)
function Assert-MDeskOwnedPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (!$full.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Native preparation path must remain inside the repository'
    }
    $parent = $full
    while ($parent) {
        if (Test-Path -LiteralPath $parent) {
            if ((Get-Item -Force -LiteralPath $parent).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing to write through a linked native preparation path: $parent"
            }
        }
        if ($parent -eq $repo) { break }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
}
if (!$envOutput.StartsWith($deps + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Native environment output must remain in the repository .deps directory'
}
Assert-MDeskOwnedPath $envOutput
$baseFiles = @('lib\vpx.lib','lib\yuv.lib','lib\aom.lib','lib\opus.lib','lib\jpeg.lib',
    'include\vpx\vp8.h','include\libyuv.h','include\aom\aom.h','include\opus\opus_multistream.h')
$gpuFiles = @('lib\avcodec.lib','lib\avutil.lib','lib\avformat.lib','lib\libmfx.lib',
    'include\libavcodec\avcodec.h')
function Test-MDeskNative([string]$Root) {
    if (!$Root -or !(Test-Path -LiteralPath (Join-Path $Root 'vcpkg.exe'))) { return $false }
    $triplet = Join-Path $Root "installed\$nativeTriplet"
    $required = $baseFiles
    if ($Variant -ne 'B1') { $required += $gpuFiles }
    foreach ($relative in $required) {
        $file = Join-Path $triplet $relative
        if (!(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) {
            return $false
        }
    }
    if ($Variant -ne 'B1') {
        $statusPath = Join-Path $Root 'installed\vcpkg\status'
        if (!(Test-Path -LiteralPath $statusPath)) { return $false }
        $blocks = (Get-Content -LiteralPath $statusPath -Raw) -split '\r?\n\r?\n'
        foreach ($feature in @('amf','nvcodec','qsv')) {
            $match = @($blocks | Where-Object {
                $_ -match '(?m)^Package: ffmpeg\r?$' -and
                $_ -match ('(?m)^Feature: ' + $feature + '\r?$') -and
                $_ -match ('(?m)^Architecture: ' + [regex]::Escape($nativeTriplet) + '\r?$') -and
                $_ -match '(?m)^Status: install ok installed\r?$'
            })
            if ($match.Count -eq 0) { return $false }
        }
    }
    return $true
}
function Export-MDeskRoot([string]$Root) {
    [IO.Directory]::CreateDirectory($deps) | Out-Null
    [IO.File]::WriteAllText($envOutput, $Root, [Text.Encoding]::ASCII)
}
# A configured complete root is read-only; only the repo-owned fallback is installed.
if (Test-MDeskNative $env:VCPKG_ROOT) {
    Export-MDeskRoot ([IO.Path]::GetFullPath($env:VCPKG_ROOT))
    Write-Output '[OK] Configured native dependencies include all requested codecs.'
    exit 0
}
if (Test-MDeskNative $localNative) {
    Export-MDeskRoot $localNative
    Write-Output '[OK] Using repository native dependencies.'
    exit 0
}
Assert-MDeskOwnedPath (Join-Path $localNative 'installed')
Assert-MDeskOwnedPath (Join-Path $deps 'downloads')
Assert-MDeskOwnedPath (Join-Path $deps 'native-cache')
[IO.Directory]::CreateDirectory($deps) | Out-Null
if (!(Test-Path -LiteralPath $localNative)) {
    $existingCheckout = Join-Path $deps 'vcpkg'
    if ($Architecture -eq 'x86' -and (Test-Path -LiteralPath (Join-Path $existingCheckout '.git'))) {
        # Separate checkout and installed tree: x86 installation must not prune
        # or change the already verified x64 dependencies.
        & git clone --no-hardlinks $existingCheckout $localNative
    } else {
        & git clone https://github.com/microsoft/vcpkg.git $localNative
    }
    if ($LASTEXITCODE -ne 0) { throw 'Unable to create repository vcpkg checkout' }
}
if (!(Test-Path -LiteralPath (Join-Path $localNative '.git'))) {
    throw 'Repository vcpkg directory is incomplete; preserve it and inspect before rebuilding'
}
$manifest = Get-Content -LiteralPath (Join-Path $repo 'vcpkg.json') -Raw | ConvertFrom-Json
$baseline = $manifest.'vcpkg-configuration'.'default-registry'.baseline
& git -C $localNative checkout --detach $baseline
if ($LASTEXITCODE -ne 0) { throw 'Unable to select the pinned vcpkg baseline' }
if (!(Test-Path -LiteralPath (Join-Path $localNative 'vcpkg.exe'))) {
    & (Join-Path $localNative 'bootstrap-vcpkg.bat') -disableMetrics
    if ($LASTEXITCODE -ne 0) { throw 'vcpkg bootstrap failed' }
}
$env:VCPKG_ROOT = $localNative
$env:VCPKG_INSTALLED_ROOT = Join-Path $localNative 'installed'
$env:VCPKG_DOWNLOADS = Join-Path $deps 'downloads'
$nativeCache = Join-Path $deps 'native-cache'
[IO.Directory]::CreateDirectory($nativeCache) | Out-Null
$env:VCPKG_BINARY_SOURCES = "clear;files,$nativeCache,readwrite"
$env:VCPKG_DISABLE_METRICS = '1'
Write-Output "[INFO] Preparing pinned $nativeTriplet dependencies, including AMF/NVENC/QSV."
# FFmpeg is declared as a host dependency in this manifest; its host triplet
# must match the application architecture so hwcodec links the correct libs.
& (Join-Path $localNative 'vcpkg.exe') install --triplet $nativeTriplet --host-triplet $nativeTriplet "--x-manifest-root=$repo" "--x-install-root=$env:VCPKG_INSTALLED_ROOT" --disable-metrics
if ($LASTEXITCODE -ne 0) { throw 'Native dependency installation failed' }
if (!(Test-MDeskNative $localNative)) { throw 'Native install completed without required libraries, headers or GPU features' }
Export-MDeskRoot $localNative
