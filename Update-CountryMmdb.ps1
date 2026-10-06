<#
.SYNOPSIS
Download the latest Country MMDB for RealiTLScanner.

.DESCRIPTION
Uses the Loyalsoldier/geoip build, which adds network tags such as CLOUDFLARE,
CLOUDFRONT and FASTLY on top of GeoLite2 country codes. Select-RealityDomains.ps1
relies on these tags to exclude CDN-hosted targets; a plain GeoLite2 database
would report those IPs as ordinary countries such as US.
#>

[CmdletBinding()]
param(
    [string]$DownloadUrl = 'https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $ScriptDir 'Country.mmdb'
}

Write-Host "Downloading $DownloadUrl"
Write-Host "Output: $OutputPath"

$tempPath = "$OutputPath.download"
Invoke-WebRequest -Uri $DownloadUrl -OutFile $tempPath -UseBasicParsing

$item = Get-Item -LiteralPath $tempPath
if ($item.Length -le 0) {
    Remove-Item -LiteralPath $tempPath -Force
    throw "Downloaded MMDB is empty: $DownloadUrl"
}

$content = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($tempPath))
if ($content.IndexOf('CLOUDFLARE', [System.StringComparison]::Ordinal) -lt 0) {
    Remove-Item -LiteralPath $tempPath -Force
    throw "Downloaded MMDB has no CLOUDFLARE tag, so CDN exclusion would not work: $DownloadUrl"
}

Move-Item -LiteralPath $tempPath -Destination $OutputPath -Force

Write-Host "Done. $($item.Length) bytes."
