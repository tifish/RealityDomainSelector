<#
.SYNOPSIS
Download the latest Windows RealiTLScanner binary from GitHub releases.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = (Get-Location).Path
}

$headers = @{
    'Accept'     = 'application/vnd.github+json'
    'User-Agent' = 'Update-RealiTLScanner-PowerShell'
}

Write-Host "Querying latest release of XTLS/RealiTLScanner..."
$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/XTLS/RealiTLScanner/releases/latest' -Headers $headers

$asset = $release.assets | Where-Object { $_.name -match '(?i)windows.*64' } | Select-Object -First 1
if (-not $asset) {
    throw "No Windows 64-bit asset found in release '$($release.tag_name)'."
}

$outputPath = Join-Path $ScriptDir $asset.name
Write-Host "Release: $($release.tag_name)"
Write-Host "Asset:   $($asset.name) ($($asset.size) bytes)"
Write-Host "Output:  $outputPath"

Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $outputPath -UseBasicParsing

Write-Host "Done."
