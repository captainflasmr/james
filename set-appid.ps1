# set-appid.ps1 — stamp a Windows shortcut (.lnk) with the same
# AppUserModelID the james binary sets on its running process, so Windows
# groups the running button with the pinned shortcut that shares the ID
# (and Super+N activates it) instead of spawning a separate cmd.exe button
# at the end of the taskbar.
#
# The james exe calls SetCurrentProcessExplicitAppUserModelID(L"JamesDyer.James")
# at startup (src/main.zig); this script writes that same ID onto the .lnk's
# property store via IShellLinkW + IPersistFile + IPropertyStore, the
# canonical path documented under "App User Model IDs" in the Windows Shell
# docs. Run it once per shortcut:
#
#   powershell -ExecutionPolicy Bypass -File set-appid.ps1 path\to\james.lnk
#
# After running, unpin and re-pin the shortcut so the taskbar picks up the
# new ID. Requires Windows PowerShell 5+ (the .NET interop types it uses
# ship with every Windows).

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ShortcutPath,

    [string]$AppId = "JamesDyer.James"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ShortcutPath)) {
    throw "Shortcut not found: $ShortcutPath"
}
$full = (Resolve-Path $ShortcutPath).Path

# The COM interfaces and structs needed to reach the shortcut's property
# store. IShellLinkW is declared empty because we never call its methods —
# we only CoCreateInstance it, then QueryInterface for IPersistFile (to load
# and save the .lnk) and IPropertyStore (to write the AppUserModel_ID key).
Add-Type @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, Pack = 4)]
public struct PROPERTYKEY { public Guid fmtid; public int pid; }

[StructLayout(LayoutKind.Explicit, Size = 16)]
public struct PROPVARIANT {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pwszVal;
    public void SetString(string s) { vt = 31; pwszVal = Marshal.StringToCoTaskMemUni(s); }
    public void Clear() { if (vt == 31 && pwszVal != IntPtr.Zero) Marshal.FreeCoTaskMem(pwszVal); vt = 0; pwszVal = IntPtr.Zero; }
}

[ComImport, Guid("00021401-0000-0000-C000-000000000046"), ClassInterface(ClassInterfaceType.None)]
public class ShellLink { }

[ComImport, Guid("0000010B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPersistFile {
    void GetClassID(out Guid pClassID);
    [PreserveSig] int IsDirty();
    void Load([In, MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
    void Save([In, MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [In] bool fRemember);
    void SaveCompleted([In, MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
    void GetCurFile([Out, MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore {
    uint GetCount(out uint cProps);
    uint GetAt(uint i, out PROPERTYKEY pkey);
    uint GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
    uint SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
    uint Commit();
}
"@

# PKEY_AppUserModel_ID = {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, pid 5
$key = New-Object PROPERTYKEY
$key.fmtid = [Guid]"9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"
$key.pid   = 5

$link  = New-Object ShellLink
$pf    = [IPersistFile]$link
$pf.Load($full, 0)            # STGM_READ

$ps    = [IPropertyStore]$link
$pv    = New-Object PROPVARIANT
$pv.SetString($AppId)
$hr = $ps.SetValue([ref]$key, [ref]$pv)
if ($hr -ne 0) {
    $pv.Clear()
    throw "IPropertyStore::SetValue failed: 0x$($hr.ToString('X8'))"
}
$ps.Commit() | Out-Null
$pv.Clear()

$pf.Save($full, $true)        # fRemember — persist back to the same .lnk

Write-Host "Set AppUserModel.ID = '$AppId' on $full"
Write-Host "Unpin and re-pin the shortcut so the taskbar picks up the new ID."
