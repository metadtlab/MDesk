param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [ValidateSet('x86', 'x64')]
    [string]$Architecture = 'x64'
)

$ErrorActionPreference = 'Stop'
$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$bytes = [System.IO.File]::ReadAllBytes($resolvedPath)

if ($bytes.Length -lt 512) {
    throw "The executable is too small to contain a valid PE header."
}

if ($bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
    throw "The file does not have an MZ executable header."
}

$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
if ($peOffset -lt 0 -or ($peOffset + 96) -ge $bytes.Length) {
    throw "The PE header offset is invalid."
}

if ([BitConverter]::ToUInt32($bytes, $peOffset) -ne 0x00004550) {
    throw "The file does not have a valid PE signature."
}

$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
$sectionCount = [BitConverter]::ToUInt16($bytes, $peOffset + 6)
$optionalHeaderSize = [BitConverter]::ToUInt16($bytes, $peOffset + 20)
$optionalHeader = $peOffset + 24
$optionalMagic = [BitConverter]::ToUInt16($bytes, $optionalHeader)
$osMajor = [BitConverter]::ToUInt16($bytes, $optionalHeader + 40)
$osMinor = [BitConverter]::ToUInt16($bytes, $optionalHeader + 42)
$subsystemMajor = [BitConverter]::ToUInt16($bytes, $optionalHeader + 48)
$subsystemMinor = [BitConverter]::ToUInt16($bytes, $optionalHeader + 50)
$subsystem = [BitConverter]::ToUInt16($bytes, $optionalHeader + 68)

$expectedMachine = if ($Architecture -eq 'x86') { 0x014C } else { 0x8664 }
$expectedMagic = if ($Architecture -eq 'x86') { 0x010B } else { 0x020B }
$peKind = if ($Architecture -eq 'x86') { 'I386 PE32' } else { 'AMD64 PE32+' }
$thunkSize = if ($Architecture -eq 'x86') { 4 } else { 8 }
$importDirectoryOffset = if ($Architecture -eq 'x86') { 104 } else { 120 }

if ($machine -ne $expectedMachine) {
    throw ('Expected {0}, but PE machine is 0x{1:X4}.' -f $peKind, $machine)
}
if ($optionalMagic -ne $expectedMagic) {
    throw ('Expected {0}, but optional header is 0x{1:X4}.' -f $peKind, $optionalMagic)
}
if ($osMajor -ne 6 -or $osMinor -ne 1) {
    throw "Expected minimum OS version 6.1, but found $osMajor.$osMinor."
}
if ($subsystemMajor -ne 6 -or $subsystemMinor -ne 1) {
    throw "Expected subsystem version 6.1, but found $subsystemMajor.$subsystemMinor."
}
if ($subsystem -ne 2) {
    throw "Expected Windows GUI subsystem 2, but found $subsystem."
}

function Convert-RvaToFileOffset {
    param([UInt32]$Rva)

    foreach ($section in $script:sections) {
        $span = [Math]::Max($section.VirtualSize, $section.RawSize)
        if ($Rva -ge $section.VirtualAddress -and $Rva -lt ($section.VirtualAddress + $span)) {
            return [Int64]($section.RawOffset + ($Rva - $section.VirtualAddress))
        }
    }

    throw ('RVA 0x{0:X8} is not mapped by a PE section.' -f $Rva)
}

function Read-AsciiZeroTerminated {
    param([Int64]$Offset)

    if ($Offset -lt 0 -or $Offset -ge $bytes.Length) {
        throw "String offset is outside the executable."
    }

    $end = $Offset
    while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) {
        $end++
    }
    if ($end -ge $bytes.Length) {
        throw "Unterminated string in the PE import table."
    }

    return [Text.Encoding]::ASCII.GetString($bytes, [int]$Offset, [int]($end - $Offset))
}

$sections = @()
$sectionTable = $optionalHeader + $optionalHeaderSize
for ($index = 0; $index -lt $sectionCount; $index++) {
    $offset = $sectionTable + ($index * 40)
    if (($offset + 40) -gt $bytes.Length) {
        throw "The PE section table is truncated."
    }

    $sections += [PSCustomObject]@{
        VirtualSize    = [BitConverter]::ToUInt32($bytes, $offset + 8)
        VirtualAddress = [BitConverter]::ToUInt32($bytes, $offset + 12)
        RawSize        = [BitConverter]::ToUInt32($bytes, $offset + 16)
        RawOffset      = [BitConverter]::ToUInt32($bytes, $offset + 20)
    }
}
$script:sections = $sections

# Data directory entry 1 is the normal import directory. Its offset differs
# between PE32 (x86) and PE32+ (x64).
$importRva = [BitConverter]::ToUInt32($bytes, $optionalHeader + $importDirectoryOffset)
$importedDlls = @()
$importedSymbols = @()
if ($importRva -ne 0) {
    $descriptorOffset = Convert-RvaToFileOffset $importRva

    for ($descriptorIndex = 0; $descriptorIndex -lt 4096; $descriptorIndex++) {
        $offset = $descriptorOffset + ($descriptorIndex * 20)
        if (($offset + 20) -gt $bytes.Length) {
            throw "The PE import descriptor table is truncated."
        }

        $originalFirstThunk = [BitConverter]::ToUInt32($bytes, [int]$offset)
        $timeDateStamp = [BitConverter]::ToUInt32($bytes, [int]$offset + 4)
        $forwarderChain = [BitConverter]::ToUInt32($bytes, [int]$offset + 8)
        $nameRva = [BitConverter]::ToUInt32($bytes, [int]$offset + 12)
        $firstThunk = [BitConverter]::ToUInt32($bytes, [int]$offset + 16)

        if (($originalFirstThunk -bor $timeDateStamp -bor $forwarderChain -bor $nameRva -bor $firstThunk) -eq 0) {
            break
        }

        $importedDlls += Read-AsciiZeroTerminated (Convert-RvaToFileOffset $nameRva)
        $thunkRva = if ($originalFirstThunk -ne 0) { $originalFirstThunk } else { $firstThunk }
        $thunkOffset = Convert-RvaToFileOffset $thunkRva

        for ($thunkIndex = 0; $thunkIndex -lt 65536; $thunkIndex++) {
            $entryOffset = $thunkOffset + ($thunkIndex * $thunkSize)
            if (($entryOffset + $thunkSize) -gt $bytes.Length) {
                throw "The PE import thunk table is truncated."
            }

            $entry = if ($thunkSize -eq 8) {
                [BitConverter]::ToUInt64($bytes, [int]$entryOffset)
            } else {
                [UInt64][BitConverter]::ToUInt32($bytes, [int]$entryOffset)
            }
            if ($entry -eq 0) {
                break
            }

            # The high bit marks an import by ordinal rather than by name.
            $isOrdinal = if ($thunkSize -eq 8) {
                ($entry -shr 63) -ne 0
            } else {
                ($entry -shr 31) -ne 0
            }
            if (-not $isOrdinal) {
                $symbolRva = [UInt32]$entry
                $symbolOffset = (Convert-RvaToFileOffset $symbolRva) + 2
                $importedSymbols += Read-AsciiZeroTerminated $symbolOffset
            }
        }
    }
}

$forbiddenDlls = @(
    'combase.dll',
    'api-ms-win-core-synch-l1-2-0.dll',
    'shcore.dll',
    'vcruntime140.dll',
    'msvcp140.dll',
    'ucrtbase.dll'
)
$forbiddenSymbols = @(
    'WaitOnAddress',
    'WakeByAddressAll',
    'WakeByAddressSingle',
    'ProcessPrng',
    'GetSystemTimePreciseAsFileTime',
    'SetThreadDescription',
    'GetDpiForWindow',
    'SetProcessDpiAwareness',
    'SetProcessDpiAwarenessContext'
)

foreach ($name in $forbiddenDlls) {
    if ($importedDlls -icontains $name) {
        throw "Found a Windows 7-incompatible or non-static imported DLL: $name"
    }
}
foreach ($name in $forbiddenSymbols) {
    if ($importedSymbols -ccontains $name) {
        throw "Found a Windows 8/10-only imported API: $name"
    }
}

$file = Get-Item -LiteralPath $resolvedPath
$hash = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash
Write-Host ('[OK] {0}, Windows GUI 6.1, {1:N0} bytes' -f $peKind, $file.Length)
Write-Host ('[OK] {0} imported DLLs; no known Windows 8/10-only loader imports found.' -f $importedDlls.Count)
Write-Host "SHA256: $hash"
