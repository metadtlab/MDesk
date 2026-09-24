# Collect camera checkpoints from UI/server/service logs in one package.
# No configuration, credentials, command lines, images or crash dumps are copied.
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path ([Environment]::GetFolderPath('Desktop')) ('MDesk-camera-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')),
    [ValidateRange(1, 7)][int]$Days = 2,
    [string]$AppDataRoot = $env:APPDATA,
    [string]$LocalDataRoot = $env:LOCALAPPDATA,
    [string]$InstallDirectory = (Join-Path $env:ProgramFiles 'MDesk'),
    [string]$SystemProfileRoot = (Join-Path $env:windir 'System32\config\systemprofile')
)
$ErrorActionPreference = 'Stop'
$destination = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $destination) { throw "Output already exists: $destination" }
$since = (Get-Date).AddDays(-$Days)
$snapshotRoot = Join-Path ([IO.Path]::GetTempPath()) ('MDesk-camera-export-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $snapshotRoot | Out-Null
$issues = New-Object 'System.Collections.Generic.List[string]'
$sources = New-Object 'System.Collections.Generic.List[object]'
$count = 0
try {
    $logRoots = @(
        @{Label='user'; Path=(Join-Path $AppDataRoot 'MDesk\log')},
        @{Label='system'; Path=(Join-Path $SystemProfileRoot 'AppData\Roaming\MDesk\log')}
    )
    foreach ($root in $logRoots) {
        try {
            if (-not (Test-Path -LiteralPath $root.Path)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $root.Path -Recurse -File -Filter 'MDesk_r*.log')) {
                # Active Windows files may report stale LastWriteTime/Length.
                if ($file.Name -notlike '*CURRENT*' -and $file.LastWriteTime -lt $since) { continue }
                $lines = @(Get-Content -LiteralPath $file.FullName | Where-Object {
                    $_ -match '\[(CameraDiag|CameraSession|ProcessDiag)\]'
                })
                if ($lines.Count -eq 0) { continue }
                $name = '{0:D3}-{1}-{2}-{3}' -f $count,$root.Label,$file.Directory.Name,$file.Name
                $lines | Set-Content -LiteralPath (Join-Path $snapshotRoot $name) -Encoding UTF8
                $sources.Add(@{File=$name; Source=$file.FullName; Lines=$lines.Count})
                $count++
            }
        } catch { $issues.Add('Could not read ' + $root.Path + ' (' + $_.Exception.GetType().Name + ')') }
    }
    $diagRoots = @(
        @{Label='user'; Path=(Join-Path $LocalDataRoot 'MDesk\diagnostics')},
        @{Label='system'; Path=(Join-Path $SystemProfileRoot 'AppData\Local\MDesk\diagnostics')}
    )
    foreach ($root in $diagRoots) {
        try {
            if (-not (Test-Path -LiteralPath $root.Path)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $root.Path -File -Filter '*.jsonl')) {
                if ($file.Name -notmatch '^mdesk-(ui-)?diag-[\d-]+(\.\d)?\.jsonl$') { continue }
                # Use run epoch instead of LastWriteTime, which can be stale.
                $epoch = [regex]::Match($file.Name, 'diag-(\d+)-').Groups[1].Value
                if (-not $epoch -or [DateTimeOffset]::FromUnixTimeMilliseconds([long]$epoch).LocalDateTime -lt $since) { continue }
                $name = $root.Label + '-' + $file.Name
                Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $snapshotRoot $name)
                $sources.Add(@{File=$name; Source=$file.FullName})
            }
        } catch { $issues.Add('Could not read ' + $root.Path + ' (' + $_.Exception.GetType().Name + ')') }
    }
    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000,1001; StartTime=$since} -ErrorAction Stop | ForEach-Object {
            $xml = [xml]$_.ToXml()
            $data = @{}
            foreach ($item in $xml.Event.EventData.Data) { $data[[string]$item.Name] = [string]$item.'#text' }
            if (($data.Values -join ' ') -match '(?i)mdesk|librustdesk') {
                $safe = [ordered]@{Time=$_.TimeCreated.ToString('o'); EventId=$_.Id; Provider=$_.ProviderName}
                foreach ($key in @('AppName','AppVersion','ModuleName','ModuleVersion','ExceptionCode','FaultingOffset','ProcessId','AppPath','ModulePath','ReportId')) {
                    if ($data.ContainsKey($key)) { $safe[$key] = $data[$key] }
                }
                $safe
            }
        })
    } catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $issues.Add('Application events unavailable (' + $_.Exception.GetType().Name + ')') }
    }
    ConvertTo-Json -InputObject $events -Depth 5 | Set-Content -LiteralPath (Join-Path $snapshotRoot 'windows-events.json') -Encoding UTF8
    $binaries = @()
    foreach ($relative in @('MDesk.exe','libmdesk.dll','data\app.so')) {
        $binaryPath = Join-Path $InstallDirectory $relative
        if (Test-Path -LiteralPath $binaryPath) {
            $file = Get-Item -LiteralPath $binaryPath
            $binaries += @{File=$relative; SHA256=(Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash; Bytes=$file.Length; Modified=$file.LastWriteTime.ToString('o')}
        }
    }
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $metadata = [ordered]@{CollectedAt=(Get-Date -Format o); Utc=(Get-Date).ToUniversalTime().ToString('o'); TimeZone=[TimeZoneInfo]::Local.Id; Admin=$admin; Since=$since.ToString('o'); CheckpointFiles=$count; Binaries=$binaries; Sources=@($sources.ToArray()); Issues=@($issues.ToArray())}
    $metadata | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $snapshotRoot 'manifest.json') -Encoding UTF8
    Compress-Archive -LiteralPath @(Get-ChildItem -LiteralPath $snapshotRoot -File | Select-Object -ExpandProperty FullName) -DestinationPath $destination
    Write-Output "Saved camera diagnostics: $destination"
    Write-Output "Checkpoint log files: $count. Collection issues: $($issues.Count)."
    if (-not $admin) { Write-Warning 'Run as administrator to include SYSTEM diagnostics if access was denied.' }
    if ($count -eq 0) { Write-Warning 'No camera diagnostic markers found. Reproduce with the diagnostic build before collecting.' }
} finally {
    # Only delete files from the exact temporary directory created above.
    $resolvedSnapshot = [IO.Path]::GetFullPath($snapshotRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\MDesk-camera-export-'
    if (-not $resolvedSnapshot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected temporary directory' }
    Get-ChildItem -LiteralPath $resolvedSnapshot -File | ForEach-Object { Remove-Item -LiteralPath $_.FullName }
    Remove-Item -LiteralPath $resolvedSnapshot
}
