#Requires -Version 5.1
<#
.SYNOPSIS
  Capture dagu UEFI boot log from TESTLAB USB volume (v2).

.EXAMPLE
  .\tools\test-lab\usb-log.ps1 preflight
  .\tools\test-lab\usb-log.ps1 watch --log logs\test-lab\boot.log
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Action = "watch",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Args
)

$ErrorActionPreference = "Stop"
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Py = Join-Path $Root "tools/test-lab/usb_log.py"
if (-not (Test-Path $Py)) { throw "missing $Py" }

$pyArgs = @($Action) + $Args
& python $Py @pyArgs
exit $LASTEXITCODE
