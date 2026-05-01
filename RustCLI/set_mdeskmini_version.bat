@echo off
setlocal

if "%~1"=="" (
  echo Usage: %~nx0 ^<version^>
  echo Example: %~nx0 0.1.1
  exit /b 1
)

set "NEW_VERSION=%~1"
set "TARGET_FILE=%~dp0..\MDeskMini\Cargo.toml"

if not exist "%TARGET_FILE%" (
  echo ERROR: MDeskMini Cargo.toml not found: "%TARGET_FILE%"
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $path='%TARGET_FILE%'; $ver='%NEW_VERSION%'; $lines=Get-Content -LiteralPath $path; $inPackage=$false; $updated=$false; for($i=0; $i -lt $lines.Count; $i++){ $line=$lines[$i]; if($line -match '^\s*\[package\]\s*$'){ $inPackage=$true; continue }; if($line -match '^\s*\[.+\]\s*$'){ if($inPackage){ break } else { continue } }; if($inPackage -and $line -match '^\s*version\s*='){ $q=[char]34; $lines[$i]='version = ' + $q + $ver + $q; $updated=$true; break } }; if(-not $updated){ throw 'Could not find [package] version in MDeskMini Cargo.toml'; }; Set-Content -LiteralPath $path -Value $lines -Encoding UTF8;"

if errorlevel 1 (
  echo ERROR: Failed to update mdeskmini version.
  exit /b 1
)

echo Updated mdeskmini version to %NEW_VERSION%
echo File: %TARGET_FILE%
exit /b 0
