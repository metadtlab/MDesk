param(
  [Parameter(Mandatory = $true)]
  [string]$SourceDir,

  [Parameter(Mandatory = $true)]
  [string]$StaticDistDir,

  [Parameter(Mandatory = $true)]
  [string]$OutputDir,

  [Parameter(Mandatory = $true)]
  [string]$MingwPrefix
)

$ErrorActionPreference = 'Stop'

$mingwBin = Join-Path $MingwPrefix 'bin'
$windres = Join-Path $mingwBin 'windres.exe'
$gcc = Join-Path $mingwBin 'gcc.exe'

foreach ($tool in @($windres, $gcc)) {
  if (!(Test-Path $tool)) {
    throw "Required build tool was not found: $tool"
  }
}

$inputs = @{
  winvnc = Join-Path $StaticDistDir 'winvnc4.exe'
  config = Join-Path $StaticDistDir 'vncconfig.exe'
  hooks = Join-Path $StaticDistDir 'wm_hooks.dll'
  pthread = Join-Path $StaticDistDir 'libwinpthread-1.dll'
}

foreach ($input in $inputs.Values) {
  if (!(Test-Path $input)) {
    throw "Required payload file was not found: $input"
  }
}

if (!(Test-Path $OutputDir)) {
  New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$buildDir = Join-Path $SourceDir 'build-windows-onefile'
if (!(Test-Path $buildDir)) {
  New-Item -ItemType Directory -Path $buildDir | Out-Null
}

function RcPath([string]$path) {
  return ($path -replace '\\', '/')
}

$rcPath = Join-Path $buildDir 'winvnc_onefile_payload.rc'
$resPath = Join-Path $buildDir 'winvnc_onefile_payload.res'
$outExe = Join-Path $OutputDir 'TigerVNC-Server-OneFile.exe'
$source = Join-Path $SourceDir 'tools\winvnc_onefile.c'

@"
101 RCDATA "$(RcPath $inputs.winvnc)"
102 RCDATA "$(RcPath $inputs.config)"
103 RCDATA "$(RcPath $inputs.hooks)"
104 RCDATA "$(RcPath $inputs.pthread)"
"@ | Set-Content -Path $rcPath -Encoding Ascii

& $windres -O coff $rcPath $resPath
if ($LASTEXITCODE -ne 0) {
  throw "windres failed with exit code $LASTEXITCODE"
}

& $gcc -municode -Os -s $source $resPath -o $outExe -lshell32
if ($LASTEXITCODE -ne 0) {
  throw "gcc failed with exit code $LASTEXITCODE"
}

Write-Host "[onefile] Created: $outExe"
