# Fixed read-only query. No settings, file paths or model output are executed.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$eventPolicy = @'
__MDESK_EVENT_POLICY_JSON__
'@ | ConvertFrom-Json
$eventSamples = @()
$eventWarnings = @()
$eventTruncated = $false
$eventStart = [DateTime]::UtcNow.AddHours(-48)
foreach ($eventChannel in @('Application', 'System')) {
    try {
        # Query only explicitly allowed OS/device providers, not generic application failures.
        $eventProviders = @($eventPolicy.$eventChannel.PSObject.Properties.Name)
        # Windows XPath supports limited expression counts. Use small Select clauses
        # inside one structured query so the provider union still has one newest-first limit.
        $eventSelects = @()
        for ($eventOffset = 0; $eventOffset -lt $eventProviders.Count; $eventOffset += 8) {
            $eventProviderQuery = ($eventProviders | Select-Object -Skip $eventOffset -First 8 | ForEach-Object { "Provider[@Name='$_']" }) -join ' or '
            $eventQuery = "*[System[(Level=2) and TimeCreated[timediff(@SystemTime) >= 0 and timediff(@SystemTime) <= 172800000] and ($eventProviderQuery)]]"
            $eventSelects += "<Select Path='$eventChannel'>$([System.Security.SecurityElement]::Escape($eventQuery))</Select>"
        }
        $eventXml = "<QueryList><Query Id='0' Path='$eventChannel'>$($eventSelects -join '')</Query></QueryList>"
        $eventRows = @(Get-WinEvent -FilterXml $eventXml -MaxEvents 201 -ErrorAction Stop)
        if ($eventRows.Count -gt 200) { $eventTruncated = $true }
        $eventText = New-Object System.Text.StringBuilder
        foreach ($eventRow in ($eventRows | Select-Object -First 200)) {
            if ($eventRow.ProviderName -notin $eventProviders -or $eventRow.Level -ne 2 -or $eventRow.TimeCreated.ToUniversalTime() -lt $eventStart) { continue }
            $eventMessage = [string]$eventRow.Message
            $eventMessage = ($eventMessage -replace '\s+', ' ').Trim()
            if ($eventMessage.Length -gt 400) { $eventMessage = $eventMessage.Substring(0,400); $eventTruncated = $true }
            $eventMessage = $eventMessage -replace '\r?\n', "`n  "
            $eventLine = '{0} Channel={1} Provider={2} EventID={3} Level={4} RecordID={5}' -f $eventRow.TimeCreated.ToUniversalTime().ToString('o'), $eventChannel, $eventRow.ProviderName, $eventRow.Id, $eventRow.Level, $eventRow.RecordId
            if ($eventText.Length + $eventLine.Length + $eventMessage.Length + 5 -gt 24000) { $eventTruncated = $true; break }
            [void]$eventText.AppendLine($eventLine)
            [void]$eventText.AppendLine('  ' + $eventMessage)
        }
        if ($eventText.Length -gt 0) { $eventSamples += @{path=('windows-event://' + $eventChannel); text=$eventText.ToString()} }
    } catch {
        $eventCode = if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { 'no_matches' } elseif ($_.Exception -is [UnauthorizedAccessException] -or $_.Exception.HResult -eq -2147024891) { 'permission_denied' } else { 'read_failed' }
        $eventWarnings += @{path=('windows-event://' + $eventChannel); code=$eventCode}
    }
}
@{files=@($eventSamples); warnings=@($eventWarnings); truncated=$eventTruncated} | ConvertTo-Json -Depth 4 -Compress
