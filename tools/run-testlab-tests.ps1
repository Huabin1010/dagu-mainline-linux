#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$tests = @(
    "tools\test\test_display.py",
    "tools\test\test_serial_log.py",
    "tools\test\test_usb_log.py",
    "tools\test\test_testlab_flow.py"
)
foreach ($t in $tests) {
    Write-Host "=== $t ===" -ForegroundColor Cyan
    python (Join-Path $Root $t)
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
Write-Host "=== all testlab unit tests passed ===" -ForegroundColor Green
