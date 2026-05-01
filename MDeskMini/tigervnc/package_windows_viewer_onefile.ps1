param(
  [string]$SourceDir = $PSScriptRoot,

  [string]$ViewerDistDir = (Join-Path $PSScriptRoot 'dist-windows-viewer'),

  [string]$OutputDir = (Join-Path $PSScriptRoot 'dist-windows-viewer-onefile'),

  [string]$MingwPrefix = 'C:\msys64\mingw64'
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

if (($env:Path -split ';') -notcontains $mingwBin) {
  $env:Path = "$mingwBin;$env:Path"
}

$viewer = Join-Path $ViewerDistDir 'vncviewer.exe'
if (!(Test-Path $viewer)) {
  throw "vncviewer.exe was not found in viewer distribution: $viewer"
}

$payloads = Get-ChildItem -Path $ViewerDistDir -File | Sort-Object Name
if ($payloads.Count -eq 0) {
  throw "No payload files were found in: $ViewerDistDir"
}

if (!(Test-Path $OutputDir)) {
  New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$buildDir = Join-Path $SourceDir 'build-windows-viewer-onefile'
if (!(Test-Path $buildDir)) {
  New-Item -ItemType Directory -Path $buildDir | Out-Null
}

function RcPath([string]$path) {
  return ($path -replace '\\', '/')
}

function CString([string]$text) {
  return ($text -replace '\\', '\\' -replace '"', '\"')
}

function Test-OutputWritable([string]$path) {
  if (!(Test-Path $path)) {
    return $true
  }

  $stream = $null
  try {
    $stream = [System.IO.File]::Open(
      $path,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::ReadWrite,
      [System.IO.FileShare]::None)
    return $true
  } catch {
    return $false
  } finally {
    if ($stream) {
      $stream.Close()
    }
  }
}

function Resolve-OutputPath([string]$path) {
  if (Test-OutputWritable $path) {
    return $path
  }

  $dir = Split-Path -Parent $path
  $name = [System.IO.Path]::GetFileNameWithoutExtension($path)
  $ext = [System.IO.Path]::GetExtension($path)

  do {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $candidate = Join-Path $dir "$name-$stamp$ext"
    Start-Sleep -Milliseconds 50
  } while (Test-Path $candidate)

  Write-Warning "Output file is locked and cannot be overwritten: $path"
  Write-Warning "Creating a timestamped output instead: $candidate"
  return $candidate
}

$rcPath = Join-Path $buildDir 'vncviewer_onefile_payload.rc'
$resPath = Join-Path $buildDir 'vncviewer_onefile_payload.res'
$headerPath = Join-Path $buildDir 'vncviewer_onefile_payload.h'
$outExe = Resolve-OutputPath (Join-Path $OutputDir 'TigerVNC-Viewer-OneFile.exe')
$source = Join-Path $SourceDir 'tools\vncviewer_onefile.c'

$rcLines = for ($i = 0; $i -lt $payloads.Count; $i++) {
  $id = 101 + $i
  '{0} RCDATA "{1}"' -f $id, (RcPath $payloads[$i].FullName)
}
$rcLines | Set-Content -Path $rcPath -Encoding Ascii

$headerLines = @('static const struct payload_entry payloads[] = {')
for ($i = 0; $i -lt $payloads.Count; $i++) {
  $id = 101 + $i
  $headerLines += '  {{ {0}, L"{1}" }},' -f $id, (CString $payloads[$i].Name)
}
$headerLines += '};'
$headerLines += 'static const int payload_count = sizeof(payloads) / sizeof(payloads[0]);'
$headerLines | Set-Content -Path $headerPath -Encoding Ascii

& $windres -O coff $rcPath $resPath
if ($LASTEXITCODE -ne 0) {
  throw "windres failed with exit code $LASTEXITCODE"
}

& $gcc -municode -mwindows -Os -s -I $buildDir $source $resPath -o $outExe -lshell32 -luser32
if ($LASTEXITCODE -ne 0) {
  throw "gcc failed with exit code $LASTEXITCODE"
}

Write-Host "[onefile] Created: $outExe"
Write-Host "[onefile] Embedded payload files: $($payloads.Count)"
