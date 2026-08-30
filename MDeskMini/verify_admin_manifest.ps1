[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$bytes = [System.IO.File]::ReadAllBytes($resolvedPath)
$content = [System.Text.Encoding]::UTF8.GetString($bytes)
$requiredExecutionLevel = '(?is)<requestedExecutionLevel\b(?=[^>]*\blevel\s*=\s*["'']requireAdministrator["''])[^>]*>'

if ($content -notmatch $requiredExecutionLevel) {
    Write-Error "Administrator manifest is missing from executable: $resolvedPath"
    exit 1
}

Write-Host "[OK] Administrator manifest verified: $resolvedPath"
exit 0
