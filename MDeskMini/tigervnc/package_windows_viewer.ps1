param(
  [Parameter(Mandatory = $true)]
  [string]$BuildDir,

  [Parameter(Mandatory = $true)]
  [string]$DistDir,

  [Parameter(Mandatory = $true)]
  [string]$MingwPrefix
)

$ErrorActionPreference = 'Stop'

$mingwBin = Join-Path $MingwPrefix 'bin'
$objdump = Join-Path $mingwBin 'objdump.exe'
$viewer = Join-Path $BuildDir 'vncviewer\vncviewer.exe'

if (!(Test-Path $objdump)) {
  throw "objdump.exe was not found: $objdump"
}

if (!(Test-Path $viewer)) {
  throw "vncviewer.exe was not found: $viewer"
}

if (!(Test-Path $DistDir)) {
  New-Item -ItemType Directory -Path $DistDir | Out-Null
}

Copy-Item $viewer $DistDir -Force

$seen = @{}

function Add-DependencyDlls {
  param(
    [Parameter(Mandatory = $true)]
    [string]$File
  )

  if (!(Test-Path $File)) {
    throw "File was not found: $File"
  }

  $imports = & $objdump -p $File | ForEach-Object {
    if ($_ -match 'DLL Name:\s*(.+)$') {
      $matches[1].Trim()
    }
  }

  foreach ($dll in $imports) {
    $key = $dll.ToLowerInvariant()
    if ($seen.ContainsKey($key)) {
      continue
    }

    $src = Join-Path $mingwBin $dll
    if (!(Test-Path $src)) {
      continue
    }

    $seen[$key] = $true
    Copy-Item $src $DistDir -Force
    Add-DependencyDlls (Join-Path $DistDir $dll)
  }
}

Add-DependencyDlls (Join-Path $DistDir 'vncviewer.exe')

Write-Host "[dist] Copied MinGW DLLs: $($seen.Count)"
