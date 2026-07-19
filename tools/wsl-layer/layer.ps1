#Requires -Version 5.1
<#
.SYNOPSIS
  Persistent WSL shell layer with streaming output.

.EXAMPLE
  .\tools\wsl-layer\layer.ps1 start
  .\tools\wsl-layer\layer.ps1 run "uname -a"
  .\tools\wsl-layer\layer.ps1 run "cd edk2-msm && ls -la"
  .\tools\wsl-layer\layer.ps1 cd /mnt/e/Projects/xiaomi-pad870-win11-arm
  .\tools\wsl-layer\layer.ps1 status
  .\tools\wsl-layer\layer.ps1 stop
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "stop", "status", "run", "cd", "logs")]
    [string] $Command = "status",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Args
)

$ErrorActionPreference = "Stop"
$Root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$Client = Join-Path $PSScriptRoot "client.py"

function Invoke-WslLayer {
    param([string[]] $ClientArgs)
    $env:PYTHONUNBUFFERED = "1"
    & python -u $Client @ClientArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

switch ($Command) {
    "start"  { Invoke-WslLayer @("start") }
    "stop"   { Invoke-WslLayer @("stop") }
    "status" { Invoke-WslLayer @("status") }
    "run" {
        if (-not $Args -or $Args.Count -eq 0) {
            Write-Error "Usage: layer.ps1 run <command>"
        }
        $cmd = ($Args -join " ")
        Invoke-WslLayer @("run", $cmd)
    }
    "cd" {
        if (-not $Args -or $Args.Count -eq 0) {
            Write-Error "Usage: layer.ps1 cd <path>"
        }
        Invoke-WslLayer @("cd", $Args[0])
    }
    "logs" {
        if ($Args -contains "-f" -or $Args -contains "--follow") {
            Invoke-WslLayer @("logs", "--follow")
        } else {
            Invoke-WslLayer @("logs")
        }
    }
}
