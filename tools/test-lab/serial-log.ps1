#Requires -Version 5.1
<#
.SYNOPSIS
  Capture dagu UEFI UART boot log (115200 8N1).

.EXAMPLE
  .\tools\test-lab\serial-log.ps1 list
  .\tools\test-lab\serial-log.ps1 watch
  .\tools\test-lab\serial-log.ps1 watch --log logs\test-lab\boot.log
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
$Py = Join-Path $Root "tools/test-lab/serial_log.py"
if (-not (Test-Path $Py)) { throw "missing $Py" }

$pyArgs = @($Action) + $Args
& python $Py @pyArgs
exit $LASTEXITCODE
