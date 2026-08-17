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

# All COM interop lives in the C# block below — PowerShell's
# [IPersistFile]$obj cast does a .NET type conversion, not a COM
# QueryInterface, so it fails on an RCW with "Cannot convert". In C# the
# CLR's cast operator does QueryInterface automatically, so the casts
# (IPersistFile)shellLink and (IPropertyStore)shellLink work correctly.
if (-not ([System.Management.Automation.PSTypeName]'AppIdSetter').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("00021401-0000-0000-C000-000000000046"), ClassInterface(ClassInterfaceType.None)]
class ShellLink { }

[ComImport, Guid("0000010B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPersistFile {
    void GetClassID(out Guid pClassID);
    [PreserveSig] int IsDirty();
    void Load([In, MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
    void Save([In, MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [In] bool fRemember);
    void SaveCompleted([In, MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
    void GetCurFile([Out, MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
struct PROPERTYKEY { public Guid fmtid; public int pid; }

[StructLayout(LayoutKind.Explicit, Size = 16)]
struct PROPVARIANT {
    [FieldOffset(0)] public ushort vt;
    [FieldOffset(8)] public IntPtr pwszVal;
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPropertyStore {
    void GetCount(out uint cProps);
    void GetAt(uint i, out PROPERTYKEY pkey);
    void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
    void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
    void Commit();
}

public static class AppIdSetter {
    public static void Set(string shortcutPath, string appId) {
        var shellLink = new ShellLink();
        var pf = (IPersistFile)shellLink;
        pf.Load(shortcutPath, 0);   // STGM_READ = 0

        var ps = (IPropertyStore)shellLink;
        var key = new PROPERTYKEY {
            fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
            pid   = 5
        };
        // VT_LPWSTR = 31; the CLR marshals the IntPtr as a raw pointer,
        // so we allocate the native string ourselves and free it after
        // SetValue copies it into the property store.
        var pv = new PROPVARIANT {
            vt      = 31,
            pwszVal = Marshal.StringToCoTaskMemUni(appId)
        };
        try {
            ps.SetValue(ref key, ref pv);
            ps.Commit();
        } finally {
            if (pv.pwszVal != IntPtr.Zero) Marshal.FreeCoTaskMem(pv.pwszVal);
        }
        pf.Save(shortcutPath, true);
    }
}
"@
}

[AppIdSetter]::Set($full, $AppId)

Write-Host "Set AppUserModel.ID = '$AppId' on $full"
Write-Host "Unpin and re-pin the shortcut so the taskbar picks up the new ID."
