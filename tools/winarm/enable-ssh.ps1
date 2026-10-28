# dagu Windows: enable an OpenSSH server for remote debugging.
# Run in an elevated PowerShell:
#   irm http://<pc>:8765/enable-ssh.ps1 | iex
# Uses the built-in OpenSSH.Server capability if present, otherwise installs
# the Win32-OpenSSH ARM64 package served next to this script (no Windows
# Update or GitHub access needed). Adds the dev PC's key, PowerShell as the
# default shell, and a firewall rule for TCP 22 on all profiles.
$ErrorActionPreference = 'Stop'
$Base = if ($env:DAGU_SSH_BASE) { $env:DAGU_SSH_BASE } else { 'http://192.168.1.172:8765' }
$PubKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPxChBRP8ltTXdMDb0DVDYKMXTk0Xq54ZwzsvhUOUJyy huanghuabin06@gmail.com'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Run this in PowerShell as Administrator.' -ForegroundColor Red
    return
}

# 1. sshd binary
$svc = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $svc) {
    $dst = 'C:\Program Files\OpenSSH'
    try {
        Write-Host "Downloading OpenSSH-ARM64 from $Base ..."
        $zip = Join-Path $env:TEMP 'OpenSSH-ARM64.zip'
        Invoke-WebRequest "$Base/OpenSSH-ARM64.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive $zip -DestinationPath $env:TEMP -Force
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
        Move-Item (Join-Path $env:TEMP 'OpenSSH-ARM64') $dst
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$dst\install-sshd.ps1"
    } catch {
        Write-Host "Package install failed ($_), trying the Windows capability..."
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    }
    $svc = Get-Service sshd
}

# 2. service: start once so sshd generates host keys and C:\ProgramData\ssh
Set-Service sshd -StartupType Automatic
Start-Service sshd
Start-Sleep 2

# 3. key login. Admin accounts use administrators_authorized_keys; ACL must be
#    Administrators + SYSTEM only (SIDs, so a Chinese-locale Windows works).
$ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
if (-not (Test-Path $ak) -or -not (Select-String -Path $ak -SimpleMatch $PubKey -Quiet)) {
    Add-Content -Path $ak -Value $PubKey -Encoding ascii
}
icacls $ak /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
$uk = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
New-Item -ItemType Directory -Force (Split-Path $uk) | Out-Null
if (-not (Test-Path $uk) -or -not (Select-String -Path $uk -SimpleMatch $PubKey -Quiet)) {
    Add-Content -Path $uk -Value $PubKey -Encoding ascii
}

# 4. PowerShell as the login shell
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -PropertyType String -Force `
    -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' | Out-Null

# 5. firewall (Wi-Fi is often the Public profile)
Get-NetFirewallRule -Name 'dagu-sshd' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -Name 'dagu-sshd' -DisplayName 'OpenSSH Server (dagu)' -Direction Inbound `
    -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null

Restart-Service sshd
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' }).IPAddress -join ', '
Write-Host ''
Write-Host "sshd: $((Get-Service sshd).Status)   user: $env:USERNAME   ip: $ip" -ForegroundColor Green
Write-Host "From the PC:  ssh $env:USERNAME@<ip>" -ForegroundColor Green
