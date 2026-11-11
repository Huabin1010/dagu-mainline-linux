#Requires -RunAsAdministrator
<#
dagu stage 24: can Windows program the Adreno SMMU context bank the way
Linux does? Runs dagu-smmuwt.sys once with test=100 (see the driver header):
eight single-register writes on CB0 (each restored), then the full Linux
CB0 sequence with SCTLR.M=1 and no stream routed, then a snapshot.

Results: C:\dagu-gpu\smmuwt-run.txt and smmuwt-run.reg. Afterwards the
tablet reboots into fastboot so the host can read them from B-slot Linux.
If the SoC resets mid-test, Parameters\step in the SYSTEM hive says where.

  powershell -ExecutionPolicy Bypass -File smmuwt.ps1 [-NoFastboot]
#>
param([switch]$NoFastboot)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Out = Join-Path $Here 'smmuwt-run.txt'
$Reg = Join-Path $Here 'smmuwt-run.reg'
$Sys = Join-Path $Here 'smmuwt\dagu-smmuwt.sys'
$Svc = 'daguwt'
$Par = "HKLM:\SYSTEM\CurrentControlSet\Services\$Svc\Parameters"
$RootThumb = 'EB968A1AC3F69712139302D3B8687BAF8815FF73'

Remove-Item $Out, $Reg -ErrorAction SilentlyContinue
function Log([string]$m) {
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $m
    Add-Content -Path $Out -Value $line -Encoding UTF8
    Write-Host $line
}
function U64($v) {
    # Registry DWORD/QWORD come back signed; reinterpret the bits.
    if ($v -is [int32]) { return [uint64][BitConverter]::ToUInt32([BitConverter]::GetBytes($v), 0) }
    if ($v -is [int64]) { return [BitConverter]::ToUInt64([BitConverter]::GetBytes($v), 0) }
    return [uint64]$v
}
function Hex($v) {
    if ($null -eq $v) { return '-' }
    return ('0x{0:x}' -f (U64 $v))
}

try {
    Log "dagu smmuwt stage 24, $(Get-Date -Format s)"
    $cert = Get-ChildItem Cert:\LocalMachine\Root | Where-Object Thumbprint -eq $RootThumb
    if ($cert -and (Get-Date) -lt $cert.NotBefore) {
        Set-Date -Date $cert.NotBefore.AddMinutes(1) | Out-Null
        Log "clock set to $((Get-Date).ToString('s'))"
    }
    if (-not (Test-Path $Sys)) { throw "missing $Sys" }
    Log ("driver sha256 " + (Get-FileHash $Sys -Algorithm SHA256).Hash.Substring(0, 16))

    # Ask the service manager, not the registry: an earlier run created
    # Services\daguwt\Parameters by hand, and that bare key is not a service.
    & sc.exe query $Svc *> $null
    if ($LASTEXITCODE -eq 1060) {
        Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\$Svc" -Recurse -Force -ErrorAction SilentlyContinue
        $r = & sc.exe create $Svc type= kernel start= demand binPath= $Sys 2>&1 | Out-String
        $rc = $LASTEXITCODE
        Log "service created rc=$rc $($r.Trim())"
    } else {
        & sc.exe stop $Svc 2>&1 | Out-Null
        $r = & sc.exe config $Svc start= demand binPath= $Sys 2>&1 | Out-String
        $rc = $LASTEXITCODE
        Log "service updated rc=$rc $($r.Trim())"
    }
    if ($rc -ne 0) { throw "sc.exe could not register $Svc (rc=$rc)" }
    # Fresh key: values from an earlier run must not look like results.
    Remove-Item $Par -Recurse -Force -ErrorAction SilentlyContinue
    New-Item $Par -Force | Out-Null
    Set-ItemProperty $Par -Name test -Value 100 -Type DWord

    Log 'sc start (the driver returns an error on purpose and unloads)'
    $r = & sc.exe start $Svc 2>&1 | Out-String
    $rcStart = $LASTEXITCODE
    foreach ($l in ($r -split "`r?`n")) { if ($l.Trim()) { Log "  $l" } }
    Log "  sc start rc=$rcStart"
    if ($rcStart -eq 1060) { throw "service $Svc not installed (1060)" }

    & reg.exe export "HKLM\SYSTEM\CurrentControlSet\Services\$Svc\Parameters" $Reg /y | Out-Null
    $p = Get-ItemProperty $Par
    $names = @($p.PSObject.Properties.Name | Where-Object { $_ -notlike 'PS*' })
    $g = { param($n) if ($names -contains $n) { $p.$n } else { $null } }

    Log ("step=" + (Hex (& $g 'step')) + " single_fails=" + (Hex (& $g 'single_fails')) + " table_pa=" + (Hex (& $g 'table_pa')))
    Log ("power cx=" + (Hex (& $g 'pw_cx_gdscr')) + " ahb=" + (Hex (& $g 'pw_gpucc_ahb')) + " cfg_ahb=" + (Hex (& $g 'pw_cfg_ahb')))
    $tests = @(@(31, 'CB0.TTBR1'), @(32, 'CB0.TCR'), @(33, 'CB0.TCR2'), @(34, 'CB0.MAIR0'),
               @(35, 'CB0.SCTLR'), @(36, 'CB0.ACTLR'), @(37, 'CBA2R0'), @(38, 'CBAR0'))
    foreach ($t in $tests) {
        $k = $t[0]; $label = $t[1]
        $pre = & $g "t${k}_pre"; $wr = & $g "t${k}_wr"; $rb = & $g "t${k}_rb"; $rb2 = & $g "t${k}_rb2"; $rs = & $g "t${k}_rs"
        $verdict = if ($null -eq $rb) { 'not run' } elseif ((U64 $rb) -eq (U64 $wr)) { 'STUCK' } elseif ((U64 $rb) -eq (U64 $pre)) { 'reverted' } else { 'changed' }
        Log ("{0,-10} pre={1} wr={2} rb={3} rb50ms={4} restored={5}  {6}" -f $label, (Hex $pre), (Hex $wr), (Hex $rb), (Hex $rb2), (Hex $rs), $verdict)
    }
    foreach ($f in 'actlr', 'cba2r', 'cbar', 'tcr2', 'tcr', 'ttbr0', 'ttbr1', 'mair0', 'mair1', 'sctlr') {
        Log ("combined {0,-6} pre={1} got={2} back={3}" -f $f, (Hex (& $g "t40_p_$f")), (Hex (& $g "t40_g_$f")), (Hex (& $g "t40_r_$f")))
    }
    Log ("combined sync=" + (Hex (& $g 't40_sync')) + " fsr=" + (Hex (& $g 't40_fsr')) + " sctlr100ms=" + (Hex (& $g 't40_sctlr2')) +
         " fsr100ms=" + (Hex (& $g 't40_fsr2')) + " sgfsr=" + (Hex (& $g 't40_sgfsr')) + " restored=" + (Hex (& $g 't40_restored')))
    Log ("combined_skip=" + (Hex (& $g 'combined_skip')) + "  (0 ran, 1 a restore failed, 2 CB0 already in use)")
    if ((U64 (& $g 'step')) -eq 0x6399) { Log 'RESULT programme finished, Windows alive' } else { Log 'RESULT programme stopped early, see step' }
} catch {
    Log "ERROR $_"
} finally {
    Copy-Item $Out "C:\Windows\Temp\dagu-smmuwt-run.txt" -Force -ErrorAction SilentlyContinue
}

if (-not $NoFastboot) {
    Write-Host ''
    Write-Host 'Rebooting into fastboot in 15 s (Ctrl+C to stay in Windows)...' -ForegroundColor Yellow
    Start-Sleep -Seconds 15
    # DaguPlatDxe sees \dagu-fastboot on the ESP at the next boot.
    & mountvol.exe S: /S
    New-Item -ItemType File -Path 'S:\dagu-fastboot' -Force | Out-Null
    & mountvol.exe S: /D
    & shutdown.exe /r /t 0
}
