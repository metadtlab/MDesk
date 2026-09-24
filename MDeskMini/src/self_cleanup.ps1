# Embedded constant script; invoked without a shell profile or execution-policy override.
# All target data is supplied by the parent as environment variables, never as code.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    $target = $env:MDESK_MINI_CLEANUP_TARGET
    $downloads = $env:MDESK_MINI_CLEANUP_DOWNLOADS
    $fileId = $env:MDESK_MINI_CLEANUP_FILE_ID
    $downloadsId = $env:MDESK_MINI_CLEANUP_DOWNLOADS_ID
    $parentId = [int]$env:MDESK_MINI_CLEANUP_PID
    if ($parentId -le 0 -or $parentId -eq $PID -or
        -not [IO.Path]::IsPathRooted($target) -or
        -not [IO.Path]::IsPathRooted($downloads) -or
        [IO.Path]::GetExtension($target) -ine '.exe' -or
        $fileId -notmatch '^[0-9A-F]{8}(-[0-9A-F]{8}){4}$' -or
        $downloadsId -notmatch '^[0-9A-F]{8}(-[0-9A-F]{8}){4}$') { exit 1 }

    try { $parent = [Diagnostics.Process]::GetProcessById($parentId) }
    catch [ArgumentException] { $parent = $null }
    if ($null -ne $parent) {
        try { if (-not $parent.WaitForExit(60000)) { exit 1 } }
        finally { $parent.Dispose() }
    }

    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class MiniExecutableCleanup {
    [StructLayout(LayoutKind.Sequential)]
    struct Info {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh;
        public uint WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GetFileInformationByHandle(SafeFileHandle file, out Info info);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool SetFileInformationByHandle(SafeFileHandle file, int type, ref int value, uint size);
    static string Identity(Info info) {
        return String.Format("{0:X8}-{1:X8}-{2:X8}-{3:X8}-{4:X8}", info.Volume,
            info.IndexHigh, info.IndexLow, info.CreationHigh, info.CreationLow);
    }
    static bool Matches(SafeFileHandle handle, string identity, bool directory) {
        Info info;
        return !handle.IsInvalid && GetFileInformationByHandle(handle, out info)
            && (info.Attributes & 0x400) == 0
            && ((info.Attributes & 0x10) != 0) == directory
            && (info.IndexHigh != 0 || info.IndexLow != 0) && Identity(info) == identity;
    }
    // 0 = deleted; 1 = retry lock/access error; 2 = wrong identity/scope, stop.
    public static int TryDelete(string target, string identity, string downloads, string folderIdentity) {
        // Pin the known Downloads directory and actual parent without following final reparse points.
        using (var folder = CreateFileW(downloads, 0x80, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero))
        using (var parent = CreateFileW(Path.GetDirectoryName(target), 0x80, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (!Matches(folder, folderIdentity, true) || !Matches(parent, folderIdentity, true)) return 2;
            using (var file = CreateFileW(target, 0x10080, 7, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero)) {
                if (file.IsInvalid) return 1;
                if (!Matches(file, identity, false)) return 2;
                int delete = 1;
                // Delete the verified open file, not a pathname that might have been replaced.
                return SetFileInformationByHandle(file, 4, ref delete, 4) ? 0 : 1;
            }
        }
    }
}
'@
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        $result = [MiniExecutableCleanup]::TryDelete($target, $fileId, $downloads, $downloadsId)
        if ($result -ne 1) { exit 0 }
        Start-Sleep -Milliseconds 250
    }
} catch {
    # Cleanup is optional: do not force permissions, kill processes, or schedule reboot deletion.
    exit 1
}
