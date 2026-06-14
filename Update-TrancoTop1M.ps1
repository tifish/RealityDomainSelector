<#
.SYNOPSIS
Download and extract the latest Tranco top-1m.csv list.

.DESCRIPTION
Downloads the official Tranco top-1m CSV zip, extracts the CSV, validates the
basic rank/domain format, and replaces the existing top-1m.csv.

Default source:
https://tranco-list.eu/top-1m.csv.zip
#>

[CmdletBinding()]
param(
    [string]$DownloadUrl = 'https://tranco-list.eu/top-1m.csv.zip',
    [string]$ListIdUrl = 'https://tranco-list.eu/top-1m-id',
    [string]$OutputCsv = '',
    [string]$DownloadDir = '',

    [int]$Retries = 3,
    [int]$TimeoutSec = 180,

    [switch]$KeepZip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($OutputCsv)) {
    $OutputCsv = Join-Path $ScriptDir 'top-1m.csv'
}
if ([string]::IsNullOrWhiteSpace($DownloadDir)) {
    $DownloadDir = Join-Path $ScriptDir 'tranco-downloads'
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,
        [int]$MaxAttempts = 3,
        [string]$ActionName = 'operation'
    )

    $attempt = 0
    while ($true) {
        $attempt++

        try {
            return & $Action
        }
        catch {
            if ($attempt -ge $MaxAttempts) {
                throw
            }

            $delaySeconds = [Math]::Min(30, [Math]::Pow(2, $attempt))
            Write-Warning "$ActionName failed on attempt $attempt/${MaxAttempts}: $($_.Exception.Message). Retrying in $delaySeconds seconds..."
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Get-RemoteText {
    param(
        [string]$Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }

    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec
        return ([string]$response.Content).Trim()
    }
    catch {
        Write-Warning "Unable to retrieve list ID from ${Url}: $($_.Exception.Message)"
        return ''
    }
}

function Get-ZipCsvEntry {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchive]$Zip
    )

    $entries = @($Zip.Entries | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.Name) -and $_.Name.ToLowerInvariant().EndsWith('.csv')
    })

    if ($entries.Count -eq 0) {
        throw 'The downloaded zip does not contain a CSV file.'
    }

    $preferred = @($entries | Where-Object { $_.Name -eq 'top-1m.csv' })
    if ($preferred.Count -gt 0) {
        return $preferred[0]
    }

    if ($entries.Count -eq 1) {
        return $entries[0]
    }

    $entryNames = ($entries | Select-Object -ExpandProperty FullName) -join ', '
    throw "The downloaded zip contains multiple CSV files and no top-1m.csv: $entryNames"
}

function Test-TrancoCsv {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $reader = [System.IO.File]::OpenText($Path)
    try {
        $lineCount = 0
        $firstLine = $null
        $lastRank = 0

        while (($line = $reader.ReadLine()) -ne $null) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $lineCount++
            if ($null -eq $firstLine) {
                $firstLine = $line
            }

            $separatorIndex = $line.IndexOf(',')
            if ($separatorIndex -lt 1 -or $separatorIndex -eq ($line.Length - 1)) {
                throw "Invalid CSV format at non-empty line ${lineCount}: $line"
            }

            $rankText = $line.Substring(0, $separatorIndex)
            $domainText = $line.Substring($separatorIndex + 1).Trim()
            $rank = 0

            if (-not [int]::TryParse($rankText, [ref]$rank)) {
                throw "Invalid rank at non-empty line ${lineCount}: $rankText"
            }

            if ([string]::IsNullOrWhiteSpace($domainText) -or $domainText.Contains(' ')) {
                throw "Invalid domain at non-empty line ${lineCount}: $domainText"
            }

            $lastRank = $rank
        }

        if ($lineCount -lt 100000) {
            throw "CSV has too few non-empty lines for a Tranco Top 1M list: $lineCount"
        }

        return [pscustomobject]@{
            LineCount = $lineCount
            FirstLine = $firstLine
            LastRank  = $lastRank
        }
    }
    finally {
        $reader.Dispose()
    }
}

if ($Retries -lt 1) {
    throw 'Retries must be greater than 0.'
}
if ($TimeoutSec -lt 1) {
    throw 'TimeoutSec must be greater than 0.'
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $DownloadDir $runId
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$zipPath = Join-Path $runDir 'top-1m.csv.zip'
$extractedCsvPath = Join-Path $runDir 'top-1m.csv'
$summaryPath = Join-Path $runDir 'summary.txt'

Write-Host "Tranco download URL: $DownloadUrl"
Write-Host "Output CSV: $OutputCsv"

$listId = Get-RemoteText -Url $ListIdUrl
if (-not [string]::IsNullOrWhiteSpace($listId)) {
    Write-Host "Latest Tranco list ID: $listId"
}

if (Test-Path -LiteralPath $OutputCsv -PathType Leaf) {
    Write-Host "Existing CSV found. It will be replaced without backup."
}

Invoke-WithRetry -MaxAttempts $Retries -ActionName 'Download Tranco zip' -Action {
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec $TimeoutSec
} | Out-Null

$zipItem = Get-Item -LiteralPath $zipPath
if ($zipItem.Length -le 0) {
    throw "Downloaded zip is empty: $zipPath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

$zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $csvEntry = Get-ZipCsvEntry -Zip $zip
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($csvEntry, $extractedCsvPath, $true)
}
finally {
    $zip.Dispose()
}

$csvInfo = Test-TrancoCsv -Path $extractedCsvPath

$outputDir = Split-Path -Parent $OutputCsv
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

Move-Item -LiteralPath $extractedCsvPath -Destination $OutputCsv -Force

$finalItem = Get-Item -LiteralPath $OutputCsv

if (-not $KeepZip) {
    Remove-Item -LiteralPath $zipPath -Force
}

$summaryLines = @(
    "Run ID: $runId",
    "Download URL: $DownloadUrl",
    "List ID URL: $ListIdUrl",
    "List ID: $listId",
    "Output CSV: $OutputCsv",
    "Downloaded ZIP path: $zipPath",
    "Kept ZIP: $($KeepZip.IsPresent)",
    "CSV bytes: $($finalItem.Length)",
    "CSV non-empty lines: $($csvInfo.LineCount)",
    "First line: $($csvInfo.FirstLine)",
    "Last rank: $($csvInfo.LastRank)"
)

$summaryLines | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host ''
$summaryLines | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host "Tranco CSV updated successfully."
