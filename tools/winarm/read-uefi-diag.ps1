# Read the volatile DaguDiag UEFI variable that DaguPlatDxe writes (stage 13).
# Usage from the host: tools/winarm/dagu-ps.sh - < tools/winarm/read-uefi-diag.ps1
$src = @"
using System; using System.Runtime.InteropServices;
public class FwVar {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern uint GetFirmwareEnvironmentVariableW(string n, string g, byte[] b, uint s);
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint a, out IntPtr t);
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LookupPrivilegeValueW(string s, string n, out long l);
  [StructLayout(LayoutKind.Sequential, Pack=1)] public struct TP { public uint C; public long L; public uint A; }
  [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr t, bool d, ref TP n, uint l, IntPtr p, IntPtr r);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  public static void Priv() { IntPtr t; OpenProcessToken(GetCurrentProcess(), 0x28, out t); long l; LookupPrivilegeValueW(null, "SeSystemEnvironmentPrivilege", out l); TP p = new TP(); p.C=1; p.L=l; p.A=2; AdjustTokenPrivileges(t, false, ref p, 0, IntPtr.Zero, IntPtr.Zero); }
}
"@
Add-Type -TypeDefinition $src
[FwVar]::Priv()
$b = New-Object byte[] 16384
$n = [FwVar]::GetFirmwareEnvironmentVariableW("DaguDiag", "{d4a9c1e2-7b3f-4c6a-9e51-0da600000001}", $b, 16384)
$e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
"var bytes=$n err=$e"
if ($n -gt 0) { [Text.Encoding]::ASCII.GetString($b, 0, $n) }
$d='C:\dagu\espmnt'
if (-not (Test-Path "$d\EFI")) { Add-PartitionAccessPath -DiskNumber 0 -PartitionNumber 35 -AccessPath "$d\" -EA SilentlyContinue }
"esp diag file: " + (Test-Path "$d\dagu-uefi-diag.txt")
