#Requires -RunAsAdministrator
<#
dagu GPU bring-up, run inside Windows.

Stage 1 (-Stage install): stage the dagu SMMU shim and the qcdx display
driver. Both services are left so that nothing GPU-related loads at boot:
QCDX Start=4. The shim root device is created through devcon so its
interfaces exist before qcdx asks for them.

Stage 2 (-Stage run): start qcdx once at runtime. QCDX is set back to
Start=4 before the device is restarted, so a crash or a reset brings
the next boot back to the safe state. The shim's stop code tells which
gate failed (0xDA0xxx).

  powershell -ExecutionPolicy Bypass -File gpu.ps1 -Stage install
  powershell -ExecutionPolicy Bypass -File gpu.ps1 -Stage run
#>
param([ValidateSet('install', 'run', 'status')][string]$Stage = 'status')

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Log = Join-Path $Here "gpu-$Stage.txt"
$Copy = "C:\Windows\Temp\dagu-gpu-$Stage.txt"
$Gpu = 'ACPI\QCOM253A\0'
$Thumb = 'F11518C396DAEEAEF651812116C5783B35A9F746'
$RootThumb = 'EB968A1AC3F69712139302D3B8687BAF8815FF73'
$Svc = 'HKLM:\SYSTEM\CurrentControlSet\Services'

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
function SetStart([string]$name, [int]$v) {
    $k = Join-Path $Svc $name
    if (Test-Path $k) {
        Set-ItemProperty $k -Name Start -Value $v -Type DWord
        Log "$name Start=$v"
    }
}
function FixClock {
    $cert = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $RootThumb
    if (-not $cert) { return }
    if ((Get-Date) -lt $cert.NotBefore) {
        $want = $cert.NotBefore.AddMinutes(1)
        $stamp = Join-Path $Here 'clock.txt'
        if (Test-Path $stamp) {
            $staged = [datetime]::Parse((Get-Content $stamp -Raw).Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal).ToLocalTime()
            if ($staged -gt $want) { $want = $staged }
        }
        Set-Date -Date $want | Out-Null
        Log "clock set to $((Get-Date).ToString('s'))"
    }
}
function Snapshot {
    Run 'pnputil.exe' @('/enum-devices', '/instanceid', $Gpu, '/drivers') | Out-Null
    Run (Join-Path $Here 'devcon.exe') @('status', 'root\DAGUSMMU') | Out-Null
    foreach ($n in @('QCDX', 'dagusmmu', 'qcsmmu')) {
        $k = Join-Path $Svc $n
        if (Test-Path $k) {
            $p = Get-ItemProperty $k
            $names = @($p.PSObject.Properties.Name)
            $st = if ($names -contains 'Start') { $p.Start } else { '-' }
            $img = if ($names -contains 'ImagePath') { $p.ImagePath } else { '-' }
            Log "svc $n Start=$st ImagePath=$img"
        } else {
            Log "svc $n missing"
        }
    }
    $par = Join-Path $Svc 'dagusmmu\Parameters'
    if (Test-Path $par) {
        $p = Get-ItemProperty $par
        $have = @($p.PSObject.Properties.Name)
        foreach ($n in @('bootgen', 'step', 'qpatch', 'ihit', 'nirq', 'ncall', 'fail', 'fsite', 'fcall', 'nfail', 'subok', 'fmcall', 'fmhit', 'map', 'rstonfail',
                         'cb0', 'idlax', 'cb0_state', 'cb0_on', 'cb0_sync', 'cb0_fsr', 'io_err', 'io_maps', 'io_iova', 'io_idmiss', 'io_kinds',
                         'pt0_tables', 'pt0_mapped', 'pt1_tables', 'pt1_mapped', 'io_leak')) {
            if ($have -contains $n) { Log ("shim {0} = 0x{1:x}" -f $n, [uint32]$p.$n) }
        }
    }
    Get-CimInstance Win32_VideoController | ForEach-Object { Log "video: $($_.Name) status=$($_.Status) err=$($_.ConfigManagerErrorCode)" }
}

try {
    Log "dagu gpu $Stage, $(Get-Date -Format s)"
    if ($Stage -eq 'install') {
        FixClock
        $root = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $RootThumb
        if (-not $root) {
            Import-Certificate -FilePath (Join-Path $Here 'dagu-test-root.cer') -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
            Log 'root CA added'
        }
        $tp = Get-ChildItem Cert:\LocalMachine\TrustedPublisher | Where-Object Thumbprint -eq $Thumb
        if (-not $tp) {
            Import-Certificate -FilePath (Join-Path $Here 'dagu-test-codesign.cer') -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
            Log 'leaf added to TrustedPublisher'
        }
        FixClock

        # GPU0 overlay: Windows writes its own registry. Same chunk layout as
        # asl.exe /loadtable. Takes effect on the next boot.
        $aml = [IO.File]::ReadAllBytes((Join-Path $Here 'ov-gpu0.aml'))
        $sum = 0; foreach ($b in $aml) { $sum = ($sum + $b) -band 0xFF }
        if ([Text.Encoding]::ASCII.GetString($aml, 0, 4) -ne 'DSDT' -or $sum -ne 0) { throw 'ov-gpu0.aml failed checks' }
        $ovKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\ACPI\Parameters\DSDT\QCOMM_\SM8250_\00000004'
        $bak = Join-Path $Here 'acpi-overlay-before.reg'
        if (-not (Test-Path $bak)) {
            & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\ACPI\Parameters\DSDT' $bak /y | Out-Null
            Log "old overlay exported to $bak"
        }
        New-Item $ovKey -Force | Out-Null
        foreach ($n in (Get-Item $ovKey).Property) {
            if ($n -ne 'Action') { Remove-ItemProperty $ovKey -Name $n }
        }
        $pos = 0; $idx = 0
        while ($pos -lt $aml.Length) {
            $cap = if ($idx -eq 0) { 7152 } else { 7160 }
            $n = [Math]::Min($cap, $aml.Length - $pos)
            $ms = New-Object IO.MemoryStream
            $bw = New-Object IO.BinaryWriter($ms)
            if ($idx -eq 0) { $bw.Write([uint32]$aml.Length); $bw.Write([uint32]0); $bw.Write([uint32]0); $bw.Write([uint32]$n) }
            else { $bw.Write([uint32]$pos); $bw.Write([uint32]$n) }
            $bw.Write($aml, $pos, $n)
            Set-ItemProperty $ovKey -Name ('{0:X8}' -f $idx) -Value $ms.ToArray() -Type Binary
            $pos += $n; $idx++
        }
        Set-ItemProperty $ovKey -Name Action -Value 0 -Type DWord
        $back = New-Object byte[] $aml.Length
        for ($i = 0; $i -lt $idx; $i++) {
            $v = (Get-ItemProperty $ovKey -Name ('{0:X8}' -f $i)).('{0:X8}' -f $i)
            if ($i -eq 0) { $n = [BitConverter]::ToUInt32($v, 12); [Array]::Copy($v, 16, $back, 0, $n) }
            else { $o = [BitConverter]::ToUInt32($v, 0); $n = [BitConverter]::ToUInt32($v, 4); [Array]::Copy($v, 8, $back, $o, $n) }
        }
        if (-not [Linq.Enumerable]::SequenceEqual($back, $aml)) { throw 'overlay readback mismatch' }
        Log "overlay written: $($aml.Length) bytes in $idx chunks, readback ok"

        $shim = Join-Path $Here 'shim'
        # pnputil refuses a third-party INF without a signed catalog
        # (0xE000022F). Build the catalog here and sign it with the test cert.
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object Thumbprint -eq $Thumb
        if (-not $cert) {
            $pfx = Join-Path $Here 'dagu-test-codesign.pfx'
            if (-not (Test-Path $pfx)) { throw "missing $pfx" }
            $pw = ConvertTo-SecureString (Get-Content (Join-Path $Here 'pfx-pass.txt') -Raw).Trim() -AsPlainText -Force
            $cert = Import-PfxCertificate -FilePath $pfx -CertStoreLocation Cert:\LocalMachine\My -Password $pw |
                Where-Object Thumbprint -eq $Thumb
            Log "imported signing cert $($cert.Thumbprint)"
        }
        if (-not $cert -or -not $cert.HasPrivateKey) { throw 'signing cert has no private key' }
        $cat = Join-Path $shim 'dagu-smmushim.cat'
        Remove-Item $cat -ErrorAction SilentlyContinue
        New-FileCatalog -Path $shim -CatalogFilePath $cat -CatalogVersion 2.0 | Out-Null
        $sig = Set-AuthenticodeSignature -FilePath $cat -Certificate $cert -HashAlgorithm SHA256
        Log "shim catalog signed: $($sig.Status) $($sig.StatusMessage)"
        if ($sig.Status -ne 'Valid') { throw "shim catalog signature is $($sig.Status)" }

        $rc = Run 'pnputil.exe' @('/add-driver', (Join-Path $shim 'dagu-smmushim.inf'))
        if ($rc -ne 0 -and $rc -ne 259) { throw "shim add-driver rc=$rc" }
        # The service must point at this build. An older driver store copy
        # with the same INF version is kept as "already present".
        $want = (Get-FileHash (Join-Path $shim 'dagu-smmushim.sys') -Algorithm SHA256).Hash
        Log "package shim sha256 $($want.Substring(0, 16))"
        New-Item (Join-Path $Svc 'dagusmmu\Parameters') -Force | Out-Null
        Set-ItemProperty (Join-Path $Svc 'dagusmmu\Parameters') -Name map -Value 0 -Type DWord
        Set-ItemProperty (Join-Path $Svc 'dagusmmu\Parameters') -Name rstonfail -Value 1 -Type DWord
        # Stage 25: real IOVA domains. cb0=1 programs the Adreno CB0 tables
        # (no stream routed, map stays 0). idlax=1 is diagnostic: an MDP
        # identity map whose MDL pages differ from the IOVA is reported
        # (io_idmiss) but allowed, so the next gate becomes visible.
        Set-ItemProperty (Join-Path $Svc 'dagusmmu\Parameters') -Name cb0 -Value 1 -Type DWord
        Set-ItemProperty (Join-Path $Svc 'dagusmmu\Parameters') -Name idlax -Value 1 -Type DWord
        Log 'shim map=0 rstonfail=1 cb0=1 idlax=1'
        # devcon names root devices ROOT\SYSTEM\NNNN, so match by hardware id.
        # Exactly one shim device: extra copies are removed, a missing one is
        # created, and the remaining one is moved onto the new driver build.
        $devcon = Join-Path $Here 'devcon.exe'
        $ids = @()
        foreach ($l in ((& $devcon find 'root\DAGUSMMU' 2>&1 | Out-String) -split "`r?`n")) {
            if ($l -match '^(ROOT\\\S+)\s*:') { $ids += $Matches[1] }
        }
        Log "shim devices: $($ids -join ', ')"
        if ($ids.Count -gt 1) {
            foreach ($id in $ids[1..($ids.Count - 1)]) { Run $devcon @('remove', "@$id") | Out-Null }
        }
        if ($ids.Count -eq 0) {
            $rc = Run $devcon @('install', (Join-Path $shim 'dagu-smmushim.inf'), 'root\DAGUSMMU')
            if ($rc -ne 0 -and $rc -ne 1) { throw "devcon install rc=$rc" }
        } else {
            $rc = Run $devcon @('update', (Join-Path $shim 'dagu-smmushim.inf'), 'root\DAGUSMMU')
            if ($rc -ne 0 -and $rc -ne 1) { throw "devcon update rc=$rc" }
            Run $devcon @('restart', 'root\DAGUSMMU') | Out-Null
        }
        Start-Sleep -Seconds 2
        $img = (Get-ItemProperty (Join-Path $Svc 'dagusmmu')).ImagePath -replace '^\\SystemRoot', $env:SystemRoot
        $have = if (Test-Path $img) { (Get-FileHash $img -Algorithm SHA256).Hash } else { 'missing' }
        Log "service image $img sha256 $($have.Substring(0, [Math]::Min(16, $have.Length)))"
        if ($have -ne $want) { throw 'the shim service still points at an old build; send me this report' }
        $shimSt = & $devcon status 'root\DAGUSMMU' 2>&1 | Out-String
        foreach ($l in ($shimSt -split "`r?`n")) { if ($l.Trim()) { Log "  shim: $l" } }
        if ($shimSt -notmatch 'Driver is running') { throw 'shim did not start; send me this report' }

        # Re-adding qcdx8250.inf re-registers QCDX as demand start and PnP
        # restarts the GPU device right away, before 2-run.cmd. Add it only
        # once, and keep QCDX off on both sides of that call.
        SetStart 'QCDX' 4
        $staged = & pnputil.exe /enum-drivers 2>&1 | Out-String
        if ($staged -match '(?i)qcdx8250\.inf') {
            Log 'qcdx8250.inf already in the driver store; not re-added'
        } else {
            $rc = Run 'pnputil.exe' @('/add-driver', (Join-Path $Here 'qcdx\qcdx8250.inf'))
            if ($rc -ne 0 -and $rc -ne 259) { throw "qcdx add-driver rc=$rc" }
        }
        SetStart 'QCDX' 4
        # /add-driver only stages the package. QCDX gets its service key when
        # the GPU device is installed onto it, which needs ACPI\QCOM253A\0 to
        # exist; that device only appears after the overlay has been loaded
        # at boot. Before that reboot this is expected to say "not present".
        SetStart 'qcsmmu' 4
        Snapshot
        if (Test-Path (Join-Path $Svc 'QCDX')) {
            SetStart 'QCDX' 4
            Log 'RESULT installed; QCDX stays off at boot. Run 2-run.cmd.'
        } else {
            Log 'RESULT staged; reboot once so the GPU device appears, then run 2-run.cmd.'
        }
    } elseif ($Stage -eq 'run') {
        SetStart 'qcsmmu' 4
        Snapshot
        $dev = & pnputil.exe /enum-devices /instanceid $Gpu 2>&1 | Out-String
        if ($dev -notmatch '(?im)^\s*\S.*:\s*ACPI\\QCOM253A\\0\s*$') {
            throw 'ACPI\QCOM253A\0 is not present: the GPU0 overlay was not loaded at boot. Reboot and run again.'
        }
        # qcdx without a running shim waits for SMMU interfaces nobody
        # publishes and the screen goes black. Never start it in that state.
        $devcon = Join-Path $Here 'devcon.exe'
        $shimSt = & $devcon status 'root\DAGUSMMU' 2>&1 | Out-String
        foreach ($l in ($shimSt -split "`r?`n")) { if ($l.Trim()) { Log "  shim: $l" } }
        if ($shimSt -notmatch 'Driver is running') {
            throw 'dagu SMMU shim is not running; qcdx is not started. Send me this report.'
        }
        Log 'shim device running'
        if (-not (Test-Path (Join-Path $Svc 'QCDX'))) {
            # devcon update starts the device right away, so QCDX must already
            # be off. The service key does not exist yet; create Start=4 first.
            New-Item (Join-Path $Svc 'QCDX') -Force | Out-Null
            Set-ItemProperty (Join-Path $Svc 'QCDX') -Name Start -Value 4 -Type DWord
            $rc = Run (Join-Path $Here 'devcon.exe') @('update', (Join-Path $Here 'qcdx\qcdx8250.inf'), 'ACPI\VEN_QCOM&DEV_253A')
            Log "devcon update rc=$rc"
            if (-not (Test-Path (Join-Path $Svc 'QCDX'))) { throw 'QCDX service still missing after binding the driver' }
        }
        # Safe state first: if this start crashes, the next boot does not load qcdx.
        SetStart 'QCDX' 4
        $k = Join-Path $Svc 'QCDX'
        Set-ItemProperty $k -Name Start -Value 3 -Type DWord
        Log 'QCDX Start=3 for this start only'
        $rc = Run 'pnputil.exe' @('/restart-device', $Gpu)
        Start-Sleep -Seconds 20
        Set-ItemProperty $k -Name Start -Value 4 -Type DWord
        Log 'QCDX Start=4 again'
        Snapshot
        $v = Get-CimInstance Win32_VideoController | Where-Object Name -like '*Adreno*'
        if ($v -and $v.ConfigManagerErrorCode -eq 0) { Log "RESULT adapter running: $($v.Name)" } else { Log 'RESULT adapter not running' }
    } else {
        Snapshot
    }
} catch {
    Log "ERROR $_"
} finally {
    Copy-Item $Log $Copy -Force -ErrorAction SilentlyContinue
    Log "report: $Log and $Copy"
}
