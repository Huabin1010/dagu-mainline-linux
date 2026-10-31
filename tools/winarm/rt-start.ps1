# Start a PnP driver at runtime instead of at boot, so a hang or crash in its
# init cannot block the next boot. The service Start is set to 3 only long
# enough for PnP to load the image, then restored to 4 and flushed.
#
#   powershell -File C:\dagu\rt-start.ps1 -Svc qcsmmu -Id 'ACPI\QCOM2509\1'
#   (run as SYSTEM via schtasks so the SSH session can drop without killing it)
#
# Progress goes to C:\dagu\rt-<svc>.log, one line every 2 s for ~60 s.
param([Parameter(Mandatory)][string]$Svc, [Parameter(Mandatory)][string]$Id)
$log = "C:\dagu\rt-$Svc.log"
function L($m) { Add-Content $log ("{0:HH:mm:ss.fff} {1}" -f (Get-Date), $m) }
Set-Content $log ''
$keyPath = "SYSTEM\CurrentControlSet\Services\$Svc"
function SetStart($v) {
  $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($keyPath, $true)
  $k.SetValue('Start', $v, [Microsoft.Win32.RegistryValueKind]::DWord); $k.Flush(); $k.Close()
  L "$Svc Start=$v (flushed)"
}
function State {
  $d = Get-PnpDevice -InstanceId $Id -EA SilentlyContinue
  $ps = (Get-PnpDeviceProperty -InstanceId $Id -KeyName DEVPKEY_Device_ProblemStatus -EA SilentlyContinue).Data
  $drv = Get-CimInstance Win32_SystemDriver -Filter "Name='$Svc'" -EA SilentlyContinue
  "dev=$($d.Status) prob=$($d.Problem) probstatus=0x{0:x8} drv=$($drv.State)" -f [uint32]$ps
}
L ("before: " + (State))
SetStart 3
$p = Start-Process -FilePath pnputil.exe -ArgumentList '/restart-device', "`"$Id`"" -PassThru -WindowStyle Hidden `
     -RedirectStandardOutput "C:\dagu\rt-$Svc-pnputil.txt"
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 250
  $drv = Get-CimInstance Win32_SystemDriver -Filter "Name='$Svc'" -EA SilentlyContinue
  if ($drv.State -ne 'Stopped') { L "driver state=$($drv.State) after $($i*0.25)s"; break }
}
SetStart 4
for ($i = 0; $i -lt 30; $i++) {
  L ((State) + " pnputil_exited=$($p.HasExited)")
  if ($p.HasExited -and $i -ge 3) { break }
  Start-Sleep 2
}
L ('pnputil: ' + ((Get-Content "C:\dagu\rt-$Svc-pnputil.txt" -EA SilentlyContinue) -join ' | '))
L 'DONE'
