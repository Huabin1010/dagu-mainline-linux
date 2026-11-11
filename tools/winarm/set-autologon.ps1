#Requires -RunAsAdministrator
<#
dagu: set a password for the local account and log in without a prompt.

Why: the WinPE deploy creates the local admin `dagu` with no password (see
docs/woa-dagu-status-2026-10-26.md §6). Windows cannot auto-logon to an empty
password, so every boot lands on the sign-in screen and any typed password is
rejected.

  set-autologon.cmd                 # password hhb1010 + auto-logon
  set-autologon.cmd status          # show what is configured now
  set-autologon.cmd off             # stop logging in automatically
  powershell -File set-autologon.ps1 -User dagu -Password other

AutoAdminLogon keeps the password in HKLM\...\Winlogon\DefaultPassword as plain
text. That is acceptable on this bench tablet and must not be used on a shared
machine.
#>
param(
    [string]$User = '',
    [string]$Password = 'hhb1010',
    [switch]$DisableAutologon,
    [switch]$Status
)

$ErrorActionPreference = 'Stop'
$WKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$PolKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

function Show-Status {
    $w = Get-ItemProperty $WKey
    foreach ($n in @('AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName', 'DefaultPassword')) {
        $v = '(unset)'
        if ($w.PSObject.Properties.Name -contains $n) {
            $v = $w.$n
            if ($n -eq 'DefaultPassword' -and $v) { $v = '<set>' }
        }
        Write-Host ("{0,-20} {1}" -f $n, $v)
    }
    $p = Get-ItemProperty $PolKey -ErrorAction SilentlyContinue
    $cad = '(unset)'
    if ($p -and $p.PSObject.Properties.Name -contains 'DisableCAD') { $cad = $p.DisableCAD }
    Write-Host ("{0,-20} {1}" -f 'DisableCAD', $cad)
    Write-Host ''
    Write-Host 'local accounts:'
    Get-LocalUser | ForEach-Object {
        $set = $_.PasswordLastSet -ne $null
        Write-Host ("  {0,-16} enabled={1} passwordset={2}" -f $_.Name, $_.Enabled, $set)
    }
}

if ($Status) {
    Show-Status
    return
}

if ($DisableAutologon) {
    Set-ItemProperty $WKey -Name AutoAdminLogon -Value '0' -Type String
    Remove-ItemProperty $WKey -Name DefaultPassword -ErrorAction SilentlyContinue
    Write-Host 'auto-logon off; the sign-in screen will ask for the password'
    Show-Status
    return
}

if (-not $User) {
    $pick = Get-LocalUser | Where-Object { $_.Enabled -and $_.Name -ne 'Guest' } |
            Sort-Object { $_.Name -ne $env:USERNAME } | Select-Object -First 1
    if (-not $pick) { throw 'no enabled local account found; pass -User' }
    $User = $pick.Name
}

$acct = Get-LocalUser -Name $User -ErrorAction Stop
if (-not $acct.Enabled) { throw "account $User is disabled" }

if ($Password) {
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    Set-LocalUser -Name $User -Password $secure
    Write-Host "password set for $User"
} elseif (-not $acct.PasswordLastSet) {
    throw "$User still has an empty password; Windows cannot auto-logon without one. Pass -Password."
}

Set-ItemProperty $WKey -Name AutoAdminLogon -Value '1' -Type String
Set-ItemProperty $WKey -Name DefaultUserName -Value $User -Type String
Set-ItemProperty $WKey -Name DefaultDomainName -Value $env:COMPUTERNAME -Type String
Set-ItemProperty $WKey -Name DefaultPassword -Value $Password -Type String
# Ctrl+Alt+Del gate is pointless on a tablet with no keyboard.
New-Item $PolKey -Force | Out-Null
Set-ItemProperty $PolKey -Name DisableCAD -Value 1 -Type DWord
Write-Host "auto-logon on: $User@$env:COMPUTERNAME. Reboot to check."
Show-Status
