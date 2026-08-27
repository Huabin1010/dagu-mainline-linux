#Requires -Version 5.1
<#
.SYNOPSIS
  Verify artifacts/boot-dagu-latest.img is present and matches its stamp.
.EXAMPLE
  .\tools\verify-boot-artifact.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $Root "tools/test-lab/TestLab.psm1") -Force

$img = Get-CanonicalUefiImagePath
$bytes = Assert-UefiArtifactPublished -ImagePath $img
Write-Host "[verify-artifact] OK: $img ($bytes bytes)" -ForegroundColor Green

Remove-StaleBootImageCopies | Out-Null
