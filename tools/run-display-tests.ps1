#Requires -Version 5.1
$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
& (Join-Path $Root "tools\run-testlab-tests.ps1") @args
exit $LASTEXITCODE
