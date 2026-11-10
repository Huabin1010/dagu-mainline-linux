#Requires -RunAsAdministrator
<#
Reinstall the QCA6390 Wi-Fi adapter through PnP so Windows builds the
network bindings itself.

The adapter was first set up by writing its registry keys by hand.
Windows' network installer never ran for it, so NativeWifiP and
vwififlt were never bound and the adapter does not show in Network
Connections. This script stages the INF package (with the large
firmware memory block value the firmware needs), signs a catalog with
the dagu test certificate, removes the hand-made device node and lets
PnP install it again.

Run from an elevated prompt:
  powershell -ExecutionPolicy Bypass -File C:\dagu-wifi\install.ps1
#>
param([switch]$SkipRemove)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Log = Join-Path $Here 'install-report.txt'
$Copy = 'C:\Windows\Temp\dagu-wifi-install.txt'
$Id = 'PCI\VEN_17CB&DEV_1101&SUBSYS_010817CB&REV_01\4&354dc085&0&0000'
$Pkg = Join-Path $Here 'pkg'
$Inf = Join-Path $Pkg 'qcwlan6800sc8180.inf'
$Cat = Join-Path $Pkg 'qcwlan6800sc81.cat'
$Thumb = 'F11518C396DAEEAEF651812116C5783B35A9F746'
$RootThumb = 'EB968A1AC3F69712139302D3B8687BAF8815FF73'

Remove-Item $Log -ErrorAction SilentlyContinue
function Log([string]$m) {
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $m
    Add-Content -Path $Log -Value $line -Encoding UTF8
    Write-Host $line
}
function Run([string]$exe, [string[]]$argv) {
    Log ("> $exe " + ($argv -join ' '))
    $out = & $exe @argv 2>&1 | Out-String
    $rc = $LASTEXITCODE
    foreach ($l in ($out -split "`r?`n")) { if ($l.Trim()) { Log "  $l" } }
    Log "  rc=$rc"
    return $rc
}
function Snapshot([string]$tag) {
    Log "== $tag"
    Run 'pnputil.exe' @('/enum-devices', '/instanceid', $Id, '/drivers') | Out-Null
    try {
        Get-NetAdapter -IncludeHidden | Sort-Object ifIndex |
            Format-Table -AutoSize Name, InterfaceDescription, Status, MacAddress, ifIndex |
            Out-String -Width 200 | ForEach-Object { Log $_ }
    } catch { Log "  Get-NetAdapter: $_" }
    $wl = (& netsh.exe wlan show interfaces 2>&1 | Out-String)
    foreach ($l in ($wl -split "`r?`n")) { if ($l.Trim()) { Log "  wlan: $l" } }
}

try {
    Log "dagu wifi install, $(Get-Date -Format s)"
    foreach ($f in @('qcwlan6800sc8180.inf', 'qcwlan6800sc81.sys', 'wlanfw20.mbn', 'm3.bin', 'bdwlan.elf', 'bdwlan.e11')) {
        $p = Join-Path $Pkg $f
        if (-not (Test-Path $p)) { throw "missing $p" }
        Log ("file {0} {1} {2}" -f $f, (Get-Item $p).Length, (Get-FileHash $p -Algorithm SHA256).Hash.Substring(0, 16))
    }
    $fw = (Get-FileHash (Join-Path $Pkg 'wlanfw20.mbn') -Algorithm SHA256).Hash
    if (-not $fw.StartsWith('DD83813933AC1ABA')) { throw "wlanfw20.mbn is not the repaired image ($fw)" }

    # The signer chain must end in a machine Root, or Set-AuthenticodeSignature
    # returns UnknownError and pnputil rejects the catalog.
    $root = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $RootThumb
    if (-not $root) {
        $rcer = Join-Path $Here 'dagu-test-root.cer'
        if (-not (Test-Path $rcer)) { throw "missing $rcer" }
        $root = Import-Certificate -FilePath $rcer -CertStoreLocation Cert:\LocalMachine\Root
        if ($root.Thumbprint -ne $RootThumb) { throw "root thumbprint $($root.Thumbprint)" }
        Log 'root CA added to Root'
    }
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq $Thumb
    if (-not $cert) {
        $pfx = Join-Path $Here 'dagu-test-codesign.pfx'
        if (-not (Test-Path $pfx)) { throw "missing $pfx" }
        $pw = ConvertTo-SecureString (Get-Content (Join-Path $Here 'pfx-pass.txt') -Raw).Trim() -AsPlainText -Force
        $cert = Import-PfxCertificate -FilePath $pfx -CertStoreLocation Cert:\LocalMachine\My -Password $pw |
            Where-Object Thumbprint -eq $Thumb
        Log "imported signing cert $($cert.Thumbprint)"
    }
    if (-not $cert.HasPrivateKey) { throw 'signing cert has no private key' }
    # The tablet has no battery-backed clock, so Windows can boot with a date
    # earlier than the certificates' NotBefore. The chain is then not time
    # valid and signing fails with "cannot build a chain to a trusted root".
    $now = Get-Date
    $notBefore = @($cert.NotBefore, $root.NotBefore) | Sort-Object -Descending | Select-Object -First 1
    Log "clock $($now.ToString('s')) cert NotBefore $($notBefore.ToString('s'))"
    if ($now -lt $notBefore) {
        $stamp = Join-Path $Here 'clock.txt'
        $want = $notBefore.AddMinutes(1)
        if (Test-Path $stamp) {
            $staged = [datetime]::Parse((Get-Content $stamp -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal).ToLocalTime()
            if ($staged -gt $want) { $want = $staged }
        }
        Set-Date -Date $want | Out-Null
        Log "clock was before the certificates; set to $((Get-Date).ToString('s'))"
    }
    foreach ($store in @('Root', 'TrustedPublisher')) {
        $have = Get-ChildItem "Cert:\LocalMachine\$store" | Where-Object Thumbprint -in @($Thumb, $RootThumb)
        Log "store $store has $(@($have).Count) dagu cert(s)"
    }
    $tp = Get-ChildItem Cert:\LocalMachine\TrustedPublisher | Where-Object Thumbprint -eq $Thumb
    if (-not $tp) {
        $cer = Join-Path $Here 'dagu-test-codesign.cer'
        Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
        Log 'leaf added to TrustedPublisher'
    }

    Remove-Item $Cat -ErrorAction SilentlyContinue
    New-FileCatalog -Path $Pkg -CatalogFilePath $Cat -CatalogVersion 2.0 | Out-Null
    $sig = Set-AuthenticodeSignature -FilePath $Cat -Certificate $cert -HashAlgorithm SHA256
    Log "catalog signed: $($sig.Status) $($sig.StatusMessage)"
    if ($sig.Status -ne 'Valid') { throw "catalog signature is $($sig.Status)" }
    $chk = Get-AuthenticodeSignature -FilePath $Cat
    Log "catalog verify: $($chk.Status) signer $($chk.SignerCertificate.Thumbprint)"
    if ($chk.Status -ne 'Valid') { throw "catalog verify is $($chk.Status)" }

    Snapshot 'before'

    if (-not $SkipRemove) {
        $rc = Run 'pnputil.exe' @('/remove-device', $Id)
        if ($rc -ne 0) { throw "remove-device rc=$rc" }
    }
    $rc = Run 'pnputil.exe' @('/add-driver', $Inf, '/install')
    if ($rc -ne 0 -and $rc -ne 3010) { throw "add-driver rc=$rc" }
    $rc = Run 'pnputil.exe' @('/scan-devices')
    Start-Sleep -Seconds 25

    Snapshot 'after'
    $net = Get-NetAdapter -IncludeHidden | Where-Object InterfaceDescription -like 'Qualcomm*'
    if ($net) { Log "RESULT adapter present: $($net.Name) $($net.Status)" } else { Log 'RESULT adapter still missing' }
} catch {
    Log "ERROR $_"
} finally {
    Copy-Item $Log $Copy -Force -ErrorAction SilentlyContinue
    Log "report: $Log and $Copy"
}
