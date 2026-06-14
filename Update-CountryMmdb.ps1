<#
.SYNOPSIS
Download the latest GeoLite2 Country MMDB for RealiTLScanner.
#>

[CmdletBinding()]
param(
    [string]$DownloadUrl = 'https://github.com/P3TERX/GeoLite.mmdb/releases/latest/download/GeoLite2-Country.mmdb',
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

Invoke-WebRequest -Uri $DownloadUrl -OutFile $OutputPath -UseBasicParsing

$item = Get-Item -LiteralPath $OutputPath
if ($item.Length -le 0) {
    throw "Downloaded MMDB is empty: $OutputPath"
}

Write-Host "Done. $($item.Length) bytes."
