# dagu: give Windows a fixed Wi-Fi IPv4 address so SSH always finds it.
#
# Why not fix the MAC instead: qcwlan6800sc81.sys has no MAC source on dagu
# (no Qualcomm DPP partition) and makes up a new 00:03:7F:12:xx:xx address
# every time the adapter starts, so the router leases a new IP on every boot.
# Tried and ignored by this driver: the NetworkAddress advanced property,
# enableMacRandom=0, MacLocation=0..3, and \System32\drivers\macaddress.txt
# (the driver only writes that file). See docs/woa-dagu-bluetooth-2026-10-28.md.
#
# Runs as SYSTEM from a scheduled task (SSH drops when the address changes).
# If the gateway does not answer 30 s after the change, goes back to DHCP.
#
#   powershell -ExecutionPolicy Bypass -File pin-wifi-ip.ps1 -Ip 192.168.1.250
param(
    [Parameter(Mandatory)][string]$Ip,
    [int]$Prefix = 24,
    [string]$Gateway = '192.168.1.1',
    [string[]]$Dns = @('192.168.1.1', '223.5.5.5')
)
$log = 'C:\Windows\Temp\pin-wifi-ip.log'
function L($m) { "$(Get-Date -f s) $m" | Add-Content $log }
$name = 'WLAN'
$key = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}' |
       Where-Object { (Get-ItemProperty $_.PSPath -EA 0).DriverDesc -match 'QCA639' } | Select -First 1
# Undo the MAC experiments: none of them has any effect on this driver.
if ($key) { Remove-ItemProperty $key.PSPath -Name enableMacRandom, NetworkAddress, MacLocation -EA 0 }
Remove-Item "$env:SystemRoot\System32\drivers\macaddress.txt" -Force -EA 0

L "set $name static $Ip/$Prefix gw $Gateway dns $($Dns -join ',')"
Set-NetIPInterface -InterfaceAlias $name -Dhcp Disabled
Get-NetIPAddress -InterfaceAlias $name -AddressFamily IPv4 -EA 0 | Remove-NetIPAddress -Confirm:$false -EA 0
Get-NetRoute -InterfaceAlias $name -DestinationPrefix 0.0.0.0/0 -EA 0 | Remove-NetRoute -Confirm:$false -EA 0
New-NetIPAddress -InterfaceAlias $name -IPAddress $Ip -PrefixLength $Prefix -DefaultGateway $Gateway | Out-Null
Set-DnsClientServerAddress -InterfaceAlias $name -ServerAddresses $Dns
for ($i = 0; $i -lt 6; $i++) {
    Start-Sleep 5
    if (Test-Connection $Gateway -Count 1 -Quiet) { L "ok: $Ip reaches $Gateway"; exit 0 }
}
L "gateway unreachable from $Ip, back to DHCP"
Get-NetIPAddress -InterfaceAlias $name -AddressFamily IPv4 -EA 0 | Remove-NetIPAddress -Confirm:$false -EA 0
Get-NetRoute -InterfaceAlias $name -DestinationPrefix 0.0.0.0/0 -EA 0 | Remove-NetRoute -Confirm:$false -EA 0
Set-NetIPInterface -InterfaceAlias $name -Dhcp Enabled
Set-DnsClientServerAddress -InterfaceAlias $name -ResetServerAddresses
