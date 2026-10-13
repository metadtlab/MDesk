[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][ValidateSet('B1','B2','B3')][string]$Variant,
    [ValidateSet('x64','x86')][string]$Architecture = 'x64',
    [Version]$MinimumSubsystemVersion,
    [switch]$RequireWindowsCodecPolicy,
    [string]$OutputJson
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Windows PowerShell can inherit PowerShell 7 module paths from a build caller.
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Utility" -ErrorAction Stop
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Management" -ErrorAction Stop
$exe = (Resolve-Path -LiteralPath $Path).Path
$pe = [IO.File]::ReadAllBytes($exe)
if ($pe.Length -lt 64 -or [BitConverter]::ToUInt16($pe, 0) -ne 0x5a4d) { throw 'Invalid DOS header' }
$peOffset = [BitConverter]::ToInt32($pe, 0x3c)
if ($peOffset -lt 0 -or $peOffset + 76 -gt $pe.Length -or [BitConverter]::ToUInt32($pe, $peOffset) -ne 0x4550) {
    throw 'Invalid PE header'
}
$machine = [BitConverter]::ToUInt16($pe, $peOffset + 4)
$expectedMachine = @{ x64=0x8664; x86=0x14c }[$Architecture]
if ($machine -ne $expectedMachine) { throw "PE machine does not match requested $Architecture architecture" }
$optionalHeader = $peOffset + 24
$subsystemVersion = [Version]::new([BitConverter]::ToUInt16($pe, $optionalHeader + 48), [BitConverter]::ToUInt16($pe, $optionalHeader + 50))
if ($MinimumSubsystemVersion -and $subsystemVersion -lt $MinimumSubsystemVersion) {
    throw "PE subsystem version $subsystemVersion is below $MinimumSubsystemVersion"
}
$rustArchitecture = @{ x64='x86_64'; x86='x86' }[$Architecture]
$probeFile = Join-Path ([IO.Path]::GetDirectoryName($exe)) ('.mini-capabilities-' + [Guid]::NewGuid().ToString('N') + '.json')
$beforeHash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
try {
    # This command returns before Mini's logging, config, certificate, host,
    # GPU discovery, installed-host handoff or cleanup initialization.
    # Mini retains its requireAdministrator manifest; UAC may be required.
    $process = Start-Process -FilePath $exe -ArgumentList @('capabilities', '--output', ('"{0}"' -f $probeFile)) -WindowStyle Hidden -PassThru
    if (!$process.WaitForExit(15000)) {
        $process.Kill()
        throw 'MDeskMini capability command timed out; host startup must never run here.'
    }
    if ($process.ExitCode -ne 0) { throw "MDeskMini capability command failed: $($process.ExitCode)" }
    $data = Get-Content -LiteralPath $probeFile -Raw | ConvertFrom-Json
    if ($data.schema_version -ne 1 -or $data.product -ne 'MDeskMini' -or $data.architecture -ne $rustArchitecture) {
        throw 'Unexpected capability schema, product or architecture.'
    }
    if (![String]::Equals([IO.Path]::GetFullPath($data.executable), $exe, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Capability report came from a different executable.'
    }
    if ($RequireWindowsCodecPolicy) {
        if ($data.hwcodec_min_windows_major -ne 10 -or $data.hwcodec_os_allowed -isnot [bool]) {
            throw 'Missing Windows hardware-codec OS policy.'
        }
        $osAllowed = $null -ne $data.windows_version -and $data.windows_version[0] -ge 10
        if ($data.hwcodec_os_allowed -ne $osAllowed) {
            throw 'Hardware-codec OS policy does not match the detected Windows version.'
        }
    }
    $expectedHardware = $Variant -ne 'B1'
    $expectedVram = $Variant -eq 'B3'
    if ($data.hwcodec -isnot [bool] -or $data.vram -isnot [bool] -or $data.gpu_texture_render -isnot [bool] -or
        $data.hwcodec -ne $expectedHardware -or $data.vram -ne $expectedVram -or $data.gpu_texture_render -ne $expectedVram) {
        throw "Linked engine capabilities do not match $Variant. Rebuild Mini with the selected features."
    }
    $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    if ($hash -ne $beforeHash) { throw 'Executable changed during verification.' }
    if ($OutputJson) {
        [ordered]@{
            variant = $Variant
            pe_architecture = $Architecture
            pe_subsystem_version = $subsystemVersion.ToString()
            executable_sha256 = $hash.ToLowerInvariant()
            compiled_capabilities = $data
            method = 'MDeskMini capabilities; linked engine FFI DATA values'
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
    }
    Write-Host "[OK] Mini $Architecture $Variant hwcodec=$($data.hwcodec) vram=$($data.vram) GPU-texture=$($data.gpu_texture_render) subsystem=$subsystemVersion"
    Write-Host "[OK] EXE SHA256=$($hash.ToLowerInvariant())"
} finally {
    if (Test-Path -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile -Force }
}
