param(
    [Parameter(Position = 0)][string]$Deb,
    [string]$Config,
    [switch]$Build,
    [switch]$BuildOnly,
    [switch]$InitKey,
    [switch]$Check,
    [switch]$Help
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# WSL emits UTF-8. Windows PowerShell 5.1 otherwise corrupts Korean paths.
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Console]::OutputEncoding = $OutputEncoding
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))

try {
    if ($Help) {
        Write-Host @'
MDesk Linux publisher - https://787.kr/linux/

  build_linux.bat                        Compile, package, sign, prepare upload.
  build_linux.bat -BuildOnly             Compile/package without signing.
  publish-linux.bat                      Publish the latest successful build.
                                        Builds automatically if none exists.
  publish-linux.bat -InitKey             Optional: create a passphrase key.
  publish-linux.bat -Check                Check tools and signing key.
  publish-linux.bat "D:\release\mdesk.deb" Prepare a signed repository.
  publish-linux.bat -Config custom.json "D:\release\mdesk.deb"

The first run copies publish-linux.example.json to publish-linux.local.json.
Output: dist\linux-publish\upload\linux\
Hosting instructions: UPLOAD.txt next to the linux folder.
An unattended signing key is created/reused automatically inside WSL.
No server upload is performed.
'@
        exit 0
    }
    if ([string]::IsNullOrWhiteSpace($Config)) {
        $Config = Join-Path $repo 'publish-linux.local.json'
        if (-not (Test-Path -LiteralPath $Config)) {
            Copy-Item -LiteralPath (Join-Path $repo 'publish-linux.example.json') -Destination $Config
            Write-Host "Created local settings: $Config"
        }
    }
    $Config = (Resolve-Path -LiteralPath $Config).Path
    $settings = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
    $wsl = (Get-Command wsl.exe -ErrorAction Stop).Source
    $wslArgs = @('-d', $settings.wslDistribution)
    if ($settings.wslUser) { $wslArgs += @('-u', $settings.wslUser) }

    function Convert-ToWslPath([string]$Path) {
        $converted = & $wsl @wslArgs --exec wslpath -a -u $Path
        if ($LASTEXITCODE -ne 0) { throw "WSL path conversion failed: $Path" }
        return ($converted -join "`n").Trim()
    }
    $backend = Convert-ToWslPath (Join-Path $PSScriptRoot 'publish_linux.py')
    $linuxConfig = Convert-ToWslPath $Config
    $common = @('--config', $linuxConfig)
    if ($InitKey) {
        & $wsl @wslArgs --exec python3 $backend @common --init-key
        exit $LASTEXITCODE
    }
    if ($Check) {
        & $wsl @wslArgs --exec python3 $backend @common --check
        exit $LASTEXITCODE
    }
    if ($Build -or $BuildOnly -or [string]::IsNullOrWhiteSpace($Deb)) {
        if ($Deb) { throw 'Use either -Build or a .deb path, not both.' }
        $builder = Convert-ToWslPath (Join-Path $PSScriptRoot 'build_linux.py')
        $linuxRepo = Convert-ToWslPath $repo
        $buildArgs = @('--repo', $linuxRepo)
        if ($BuildOnly) { $buildArgs += '--build-only' }
        elseif (-not $Build) { $buildArgs += '--publish-latest' }
        & $wsl @wslArgs --exec python3 $builder @common @buildArgs
        exit $LASTEXITCODE
    }
    $Deb = (Resolve-Path -LiteralPath $Deb).Path
    $linuxDeb = Convert-ToWslPath $Deb
    & $wsl @wslArgs --exec python3 $backend @common --auto-key --deb $linuxDeb
    exit $LASTEXITCODE
} catch {
    [Console]::Error.WriteLine("Publish failed: " + $_.Exception.Message)
    exit 1
}
