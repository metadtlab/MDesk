param(
    [Parameter(Mandatory=$true)][string]$RustDll,
    [Parameter(Mandatory=$true)][string]$PackagedDll,
    [ValidateSet('B1','B2','B3')][string]$Variant,
    [string]$OutputJson
)
$ErrorActionPreference = 'Stop'
function Get-MDeskSha256([string]$Path) {
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $stream = [System.IO.File]::OpenRead($resolved)
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $hasher.Dispose() }
}
$rustHash = Get-MDeskSha256 $RustDll
$packageHash = Get-MDeskSha256 $PackagedDll
if ($rustHash -ne $packageHash) { throw 'Packaged libmdesk.dll differs from the current Rust build' }
Write-Output "[OK] Rust/packaged DLL SHA256=$($rustHash.ToLowerInvariant())"
if (!$Variant) { exit 0 }
Import-Module "$PSHOME\Modules\Microsoft.PowerShell.Utility" -ErrorAction Stop
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class MDeskBuildProbe {
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32", SetLastError=true)]
    public static extern IntPtr GetProcAddress(IntPtr module, string name);
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern uint GetModuleFileName(IntPtr module, StringBuilder path, int size);
    [DllImport("kernel32")] public static extern bool FreeLibrary(IntPtr module);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate uint Capabilities();
}
'@
$dllPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackagedDll)
$module = [MDeskBuildProbe]::LoadLibraryEx($dllPath, [IntPtr]::Zero, 0x1100)
if ($module -eq [IntPtr]::Zero) { throw "Unable to load build DLL (Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error()))" }
try {
    $entry = [MDeskBuildProbe]::GetProcAddress($module, 'mdesk_build_capabilities_v1')
    if ($entry -eq [IntPtr]::Zero) { throw 'DLL has no current build capability probe; rebuild the Rust core' }
    $probe = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($entry, [type][MDeskBuildProbe+Capabilities])
    $flags = $probe.Invoke()
    $name = New-Object Text.StringBuilder 32768
    if ([MDeskBuildProbe]::GetModuleFileName($module, $name, $name.Capacity) -eq 0) { throw 'Unable to identify loaded build DLL' }
    $loadedDll = [IO.Path]::GetFullPath($name.ToString())
    if (![String]::Equals($dllPath, $loadedDll, [StringComparison]::OrdinalIgnoreCase)) { throw 'Loaded DLL path differs from the requested build DLL' }
    $loadedHash = Get-MDeskSha256 $loadedDll
    if ($loadedHash -ne $packageHash) { throw 'Loaded DLL hash differs from packaged DLL' }
    $expected = @{ B1=0; B2=1; B3=7 }[$Variant]
    if ($flags -ne $expected) { throw "DLL capabilities $flags do not match $Variant ($expected)" }
    $data = @{ main_has_hwcodec=[bool]($flags -band 1); main_has_vram=[bool]($flags -band 2); main_has_gpu_texture_render=[bool]($flags -band 4) }
    Write-Output "[OK] $Variant DATA hwcodec=$($data.main_has_hwcodec) vram=$($data.main_has_vram) GPU-texture=$($data.main_has_gpu_texture_render)"
    if ($OutputJson) {
        $record = @{ variant=$Variant; call_success=$true; data=$data; requested_dll=$dllPath; loaded_dll=$loadedDll; dll_sha256=$loadedHash.ToLowerInvariant(); method='mdesk_build_capabilities_v1 calling existing FFI DATA values'; device_support='not tested'; session_backend='not tested' }
        $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputJson -Encoding UTF8
    }
} finally { [void][MDeskBuildProbe]::FreeLibrary($module) }
