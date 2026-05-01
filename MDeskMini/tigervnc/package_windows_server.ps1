param(
  [Parameter(Mandatory = $true)]
  [string]$DistDir,

  [Parameter(Mandatory = $true)]
  [string]$MingwPrefix
)

$ErrorActionPreference = 'Stop'

$mingwBin = Join-Path $MingwPrefix 'bin'
$objdump = Join-Path $mingwBin 'objdump.exe'

if (!(Test-Path $objdump)) {
  throw "objdump.exe was not found: $objdump"
}

if (!(Test-Path $DistDir)) {
  New-Item -ItemType Directory -Path $DistDir | Out-Null
}

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

@('winvnc4.exe', 'vncconfig.exe', 'wm_hooks.dll') | ForEach-Object {
  Add-DependencyDlls (Join-Path $DistDir $_)
}

Write-Host "[dist] Copied MinGW DLLs: $($seen.Count)"
