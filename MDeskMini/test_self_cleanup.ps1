# Tests use disposable data files in a new temporary folder, never a real Mini executable.
$ErrorActionPreference = 'Stop'
$scriptText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'src/self_cleanup.ps1'))
$parseErrors = $null
$tokens = $null
$null = [Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw ($parseErrors | Out-String) }
$definition = [regex]::Match($scriptText, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
if (-not $definition.Success) { throw 'Missing helper definition' }
Add-Type -TypeDefinition $definition.Groups[1].Value
$flags = [Reflection.BindingFlags]'NonPublic,Static'
function Get-Identity([string]$Path) {
    $method = [MiniExecutableCleanup].GetMethod('CreateFileW', $flags)
    $handle = $method.Invoke($null, @($Path, [uint32]0x80, [uint32]7, [IntPtr]::Zero, [uint32]3, [uint32]0x02200000, [IntPtr]::Zero))
    try {
        $arguments = [object[]]@($handle, $null)
        if (-not [MiniExecutableCleanup].GetMethod('GetFileInformationByHandle', $flags).Invoke($null, $arguments)) { throw 'Cannot read identity' }
        return [MiniExecutableCleanup].GetMethod('Identity', $flags).Invoke($null, @($arguments[1]))
    } finally { $handle.Dispose() }
}
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    Write-Output "PASS: $Message"
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('mini-cleanup-' + [Guid]::NewGuid().ToString('N'))
$downloads = Join-Path $testRoot 'Downloads'
$other = Join-Path $testRoot 'Other'
$nested = Join-Path $downloads 'Nested'
$null = [IO.Directory]::CreateDirectory($downloads)
$null = [IO.Directory]::CreateDirectory($other)
$null = [IO.Directory]::CreateDirectory($nested)
$createdFiles = [Collections.Generic.List[string]]::new()
function New-Dummy([string]$Path) {
    [IO.File]::WriteAllText($Path, 'Only dummy test data. Never execute.')
    $createdFiles.Add($Path)
    return $Path
}
$folderId = Get-Identity $downloads
$koreanName = [string][char]0xD55C + [char]0xAE00
$helper = $null
$parent = $null
try {
    $neighbor = New-Dummy (Join-Path $downloads 'keep.txt')
    $target = New-Dummy (Join-Path $downloads "Mini ' & [check] $koreanName.exe")
    $identity = Get-Identity $target
    $result = [MiniExecutableCleanup]::TryDelete($target, $identity, $downloads, $folderId)
    Assert ($result -eq 0 -and -not [IO.File]::Exists($target)) 'Only matching executable is deleted (spaces, Korean, shell characters)'
    Assert ([IO.File]::Exists($neighbor)) 'Neighboring files are preserved'

    $target = New-Dummy (Join-Path $other 'Mini.exe')
    Assert ([MiniExecutableCleanup]::TryDelete($target, (Get-Identity $target), $downloads, $folderId) -eq 2) 'Other folder rejected'
    Assert ([IO.File]::Exists($target)) 'Other-folder executable preserved'
    $target = New-Dummy (Join-Path $nested 'Mini.exe')
    Assert ([MiniExecutableCleanup]::TryDelete($target, (Get-Identity $target), $downloads, $folderId) -eq 2) 'Downloads subfolder rejected'

    $target = New-Dummy (Join-Path $downloads 'replace.exe')
    $originalId = Get-Identity $target
    $original = Join-Path $downloads 'original.exe'
    [IO.File]::Move($target, $original)
    $createdFiles.Add($original)
    $null = New-Dummy $target
    Assert ([MiniExecutableCleanup]::TryDelete($target, $originalId, $downloads, $folderId) -eq 2) 'Replacement file identity rejected'
    Assert ([IO.File]::Exists($target) -and [IO.File]::Exists($original)) 'Replacement and renamed original preserved'

    $target = New-Dummy (Join-Path $downloads 'locked.exe')
    $identity = Get-Identity $target
    $lock = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        Assert ([MiniExecutableCleanup]::TryDelete($target, $identity, $downloads, $folderId) -eq 1) 'Locked file retries without forcing access'
        Assert ([IO.File]::Exists($target)) 'Locked file preserved'
    } finally { $lock.Dispose() }
    Assert ([MiniExecutableCleanup]::TryDelete($target, $identity, $downloads, $folderId) -eq 0) 'Released lock allows cleanup'

    $target = New-Dummy (Join-Path $downloads 'readonly.exe')
    $identity = Get-Identity $target
    [IO.File]::SetAttributes($target, [IO.FileAttributes]::ReadOnly)
    try {
        Assert ([MiniExecutableCleanup]::TryDelete($target, $identity, $downloads, $folderId) -eq 1) 'Read-only file is not forced'
        Assert ([IO.File]::Exists($target)) 'Read-only file preserved'
    } finally { [IO.File]::SetAttributes($target, [IO.FileAttributes]::Normal) }

    # Execute the production helper against a dummy file and an unrelated, short-lived parent.
    $target = New-Dummy (Join-Path $downloads "deferred ' $koreanName.exe")
    $powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $parent = Start-Process -FilePath $powershell -ArgumentList '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 4' -WindowStyle Hidden -PassThru
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $powershell
    $info.Arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['MDESK_MINI_CLEANUP_TARGET'] = '\\?\' + $target
    $info.EnvironmentVariables['MDESK_MINI_CLEANUP_FILE_ID'] = Get-Identity $target
    $info.EnvironmentVariables['MDESK_MINI_CLEANUP_DOWNLOADS'] = '\\?\' + $downloads
    $info.EnvironmentVariables['MDESK_MINI_CLEANUP_DOWNLOADS_ID'] = $folderId
    $info.EnvironmentVariables['MDESK_MINI_CLEANUP_PID'] = [string]$parent.Id
    $helper = [Diagnostics.Process]::Start($info)
    Start-Sleep -Milliseconds 1000
    Assert (-not $parent.HasExited -and [IO.File]::Exists($target)) 'Helper does not delete before parent exit'
    Assert ($helper.WaitForExit(20000)) 'Helper terminates within bounded time'
    $stderr = $helper.StandardError.ReadToEnd()
    Assert ($helper.ExitCode -eq 0 -and -not [IO.File]::Exists($target)) "Deferred production helper deletes after parent exit: $stderr"
    Assert ([IO.File]::Exists($neighbor)) 'Deferred cleanup preserves other Downloads files'
} finally {
    if ($null -ne $helper) { $null = $helper.WaitForExit(20000); $helper.Dispose() }
    if ($null -ne $parent) { $null = $parent.WaitForExit(10000); $parent.Dispose() }
    # Exact test-created paths only; no recursive deletion or wildcard operations.
    foreach ($path in $createdFiles) {
        if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
    }
    foreach ($path in @($nested, $other, $downloads, $testRoot)) { [IO.Directory]::Delete($path, $false) }
}
