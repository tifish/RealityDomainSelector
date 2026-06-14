<#
.SYNOPSIS
Select random Tranco domains and verify them with RealiTLScanner.

.DESCRIPTION
The default policy follows this project:
- rank range: 5,000 to 300,000
- sample size: 100 domains
- exclude hot brands and sensitive categories
- prefer docs/static/assets/download/dl/support/help/developer/mirrors/cdn names
- keep scanner rows that are usable TLS 1.3 results

Outputs are written to a timestamped folder under .\reality-scan-results.
#>

[CmdletBinding()]
param(
    [string]$TrancoCsv = '',
    [string]$ScannerPath = '',
    [string]$OutputDir = '',

    [int]$MinRank = 5000,
    [int]$MaxRank = 300000,
    [int]$SampleCount = 100,

    [int]$Thread = 16,
    [int]$Timeout = 8,
    [int]$Port = 443,

    [bool]$RequireTls13 = $true,
    [bool]$RequireCertDomainMatch = $false,
    [string[]]$ExcludedGeoCodes = @('CLOUDFLARE', 'GOOGLE', 'FACEBOOK', 'MICROSOFT', 'APPLE'),

    [switch]$IncludeIpv6,
    [switch]$SkipScan,
    [int]$Seed = 0
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

if ([string]::IsNullOrWhiteSpace($TrancoCsv)) {
    $TrancoCsv = Join-Path $ScriptDir 'top-1m.csv'
}
if ([string]::IsNullOrWhiteSpace($ScannerPath)) {
    $ScannerPath = Join-Path $ScriptDir 'RealiTLScanner.exe'
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $ScriptDir 'reality-scan-results'
}

function Test-ReadableFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Name not found: $Path"
    }
}

function Test-DomainPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Domain,
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if ($Domain -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-PriorityReason {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Domain
    )

    foreach ($item in $PriorityRegexes) {
        if ($item.Regex.IsMatch($Domain)) {
            return $item.Name
        }
    }

    return ''
}

function Select-RandomItems {
    param(
        [object[]]$Items,
        [int]$Count
    )

    if ($Count -le 0 -or $Items.Count -eq 0) {
        return @()
    }

    if ($Items.Count -le $Count) {
        return @($Items)
    }

    return @(Get-Random -InputObject $Items -Count $Count)
}

function Test-CertDomainMatch {
    param(
        [string]$CertDomain,
        [string]$Origin
    )

    if ([string]::IsNullOrWhiteSpace($CertDomain) -or [string]::IsNullOrWhiteSpace($Origin)) {
        return $false
    }

    $originValue = $Origin.Trim().ToLowerInvariant()
    $certValues = $CertDomain.ToLowerInvariant() -split '[,; ]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($certValue in $certValues) {
        $cert = $certValue.Trim()

        if ($cert -eq $originValue) {
            return $true
        }

        if ($cert.StartsWith('*.')) {
            $suffix = $cert.Substring(1)
            if ($originValue.EndsWith($suffix) -and $originValue.Length -gt $suffix.Length) {
                return $true
            }
        }
    }

    return $false
}

Test-ReadableFile -Path $TrancoCsv -Name 'Tranco CSV'
Test-ReadableFile -Path $ScannerPath -Name 'RealiTLScanner'

if ($MinRank -lt 1 -or $MaxRank -lt $MinRank) {
    throw "Invalid rank range: $MinRank to $MaxRank"
}

if ($SampleCount -lt 1) {
    throw "SampleCount must be greater than 0."
}

if ($Seed -ne 0) {
    Get-Random -SetSeed $Seed | Out-Null
}

$HotBrandPatterns = @(
    '(^|[.-])(google|gstatic|googleapis|googletagmanager|googleusercontent|googlevideo|gmail|youtube|ytimg)([.-]|$)',
    '(^|[.-])(facebook|fbcdn|instagram|whatsapp|meta)([.-]|$)',
    '(^|[.-])(cloudflare)([.-]|$)',
    '(^|[.-])(microsoft|windows|office|outlook|bing|msn|azure|onedrive|skype|github)([.-]|$)',
    '(^|[.-])(apple|icloud|itunes|mzstatic)([.-]|$)',
    '(^|[.-])(amazon|amazonaws|aws|netflix|wikipedia|yahoo)([.-]|$)'
)

$SensitivePatterns = @(
    '\.ai$',
    '(^|[.-])(openai|chatgpt|gpt|claude|anthropic|gemini|deepmind|midjourney|perplexity|stability)([.-]|$)',
    '^x\.com$',
    '(^|[.-])(twitter|tiktok|reddit|discord|telegram|linkedin|pinterest|snapchat|threads|weibo|vk|mastodon|bsky)([.-]|$)',
    '(^|[.-])(porn|xxx|sex|adult|hentai|nude|erotic)([.-]|$)|pornhub|xvideos|xnxx|redtube|onlyfans',
    '(^|[.-])(casino|bet|betting|gamble|gambling|poker|sportsbook|lotto|lottery|odds|bwin)([.-]|$)',
    '(^|[.-])(crypto|bitcoin|btc|ethereum|eth|binance|coinbase|wallet|token|nft|defi|blockchain|bybit|okx|bitget|kraken|kucoin)([.-]|$)',
    '(^|[.-])(politic|politics|political|election|vote|parliament|congress|senate|campaign|democrat|republican|whitehouse|government|gov)([.-]|$)',
    '(^|[.-])(torrent|pirate|crack|warez|repack|keygen|serial|magnet|utorrent|1337x|rarbg|yts|skidrow|fitgirl)([.-]|$)|thepiratebay'
)

$ExcludePatterns = @($HotBrandPatterns + $SensitivePatterns)

$PriorityPatterns = [ordered]@{
    docs      = '(^|[.-])(docs?|documentation)([.-]|$)'
    static    = '(^|[.-])static([.-]|$)'
    assets    = '(^|[.-])assets?([.-]|$)'
    download  = 'download'
    dl        = '(^|[.-])dl([.-]|$)'
    support   = '(^|[.-])support([.-]|$)'
    help      = '(^|[.-])help([.-]|$)'
    developer = '(^|[.-])(developers?|dev)([.-]|$)'
    mirrors   = '(^|[.-])mirrors?([.-]|$)'
    cdn       = '(^|[.-])cdn([.-]|$)'
}

$regexOptions =
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
    [System.Text.RegularExpressions.RegexOptions]::Compiled

$ExcludeRegex = [regex]::new(($ExcludePatterns -join '|'), $regexOptions)
$PriorityRegexes = @(
    foreach ($entry in $PriorityPatterns.GetEnumerator()) {
        [pscustomobject]@{
            Name  = $entry.Key
            Regex = [regex]::new([string]$entry.Value, $regexOptions)
        }
    }
)

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $OutputDir $runId
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$selectedDomainsPath = Join-Path $runDir 'selected-domains.txt'
$selectedCsvPath = Join-Path $runDir 'selected-domains.csv'
$scannerRawPath = Join-Path $runDir 'scanner-raw.csv'
$usableCsvPath = Join-Path $runDir 'usable-results.csv'
$usableDomainsPath = Join-Path $runDir 'usable-domains.txt'
$summaryPath = Join-Path $runDir 'summary.txt'

Write-Host "Loading Tranco CSV: $TrancoCsv"

$rangeRows = 0
$excludedRows = 0
$duplicateRows = 0
$candidates = New-Object 'System.Collections.Generic.List[object]'
$seenDomains = @{}

$reader = [System.IO.File]::OpenText($TrancoCsv)
try {
    while (($line = $reader.ReadLine()) -ne $null) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $separatorIndex = $line.IndexOf(',')
        if ($separatorIndex -lt 1) {
            continue
        }

        $rankText = $line.Substring(0, $separatorIndex)
        $domainText = $line.Substring($separatorIndex + 1)

    $rankValue = 0
        if (-not [int]::TryParse($rankText, [ref]$rankValue)) {
            continue
        }

        if ($rankValue -gt $MaxRank) {
            break
        }

        if ($rankValue -lt $MinRank) {
            continue
        }

        $rangeRows++
        $domain = $domainText.Trim().ToLowerInvariant()

        if ([string]::IsNullOrWhiteSpace($domain)) {
            continue
        }

        if ($seenDomains.ContainsKey($domain)) {
            $duplicateRows++
            continue
        }

        $seenDomains[$domain] = $true

        if ($ExcludeRegex.IsMatch($domain)) {
            $excludedRows++
            continue
        }

        $priorityReason = Get-PriorityReason -Domain $domain
        $candidates.Add([pscustomobject]@{
            Rank       = $rankValue
            Domain     = $domain
            Priority   = $priorityReason
            IsPriority = -not [string]::IsNullOrWhiteSpace($priorityReason)
        })
    }
}
finally {
    $reader.Dispose()
}

if ($candidates.Count -eq 0) {
    throw 'No candidate domains remained after filtering.'
}

$priorityCandidates = @($candidates | Where-Object { $_.IsPriority })
$normalCandidates = @($candidates | Where-Object { -not $_.IsPriority })

if ($priorityCandidates.Count -ge $SampleCount) {
    $selected = Select-RandomItems -Items $priorityCandidates -Count $SampleCount
}
else {
    $selected = @($priorityCandidates)
    $selected += Select-RandomItems -Items $normalCandidates -Count ($SampleCount - $selected.Count)
}

$selected = Select-RandomItems -Items $selected -Count $selected.Count
$selected | Sort-Object Rank | Export-Csv -LiteralPath $selectedCsvPath -NoTypeInformation -Encoding UTF8
$selected | ForEach-Object { $_.Domain } | Set-Content -LiteralPath $selectedDomainsPath -Encoding ASCII

Write-Host "Selected $($selected.Count) domains. Input saved to: $selectedDomainsPath"

if (-not $SkipScan) {
    $scannerArgs = @(
        '-in', $selectedDomainsPath,
        '-out', $scannerRawPath,
        '-port', [string]$Port,
        '-thread', [string]$Thread,
        '-timeout', [string]$Timeout
    )

    if ($IncludeIpv6.IsPresent) {
        $scannerArgs += '-46'
    }

    Write-Host "Running RealiTLScanner..."
    & $ScannerPath @scannerArgs

    if ($LASTEXITCODE -ne 0) {
        throw "RealiTLScanner exited with code $LASTEXITCODE"
    }
}
elseif (-not (Test-Path -LiteralPath $scannerRawPath -PathType Leaf)) {
    "IP,ORIGIN,TLS,ALPN,CURVE,CERT_LENGTH,CERT_SIGNATURE,CERT_PUBLICKEY,CERT_DOMAIN,CERT_ISSUER,GEO_CODE" |
        Set-Content -LiteralPath $scannerRawPath -Encoding ASCII
}

$selectedByDomain = @{}
foreach ($item in $selected) {
    $selectedByDomain[$item.Domain] = $item
}

$excludedGeoLookup = @{}
foreach ($geoCode in $ExcludedGeoCodes) {
    if (-not [string]::IsNullOrWhiteSpace($geoCode)) {
        $excludedGeoLookup[$geoCode.Trim().ToUpperInvariant()] = $true
    }
}

$scannerRows = @()
if (Test-Path -LiteralPath $scannerRawPath -PathType Leaf) {
    $scannerRows = @(Import-Csv -LiteralPath $scannerRawPath)
}

$usableRows = New-Object 'System.Collections.Generic.List[object]'
$seenUsableRows = @{}

foreach ($row in $scannerRows) {
    $origin = ([string]$row.ORIGIN).Trim().ToLowerInvariant()

    if (-not $selectedByDomain.ContainsKey($origin)) {
        continue
    }

    if ($RequireTls13 -and ([string]$row.TLS -ne 'TLS 1.3')) {
        continue
    }

    if ([string]::IsNullOrWhiteSpace([string]$row.CERT_DOMAIN)) {
        continue
    }

    $geoCode = ([string]$row.GEO_CODE).Trim().ToUpperInvariant()
    if ($excludedGeoLookup.ContainsKey($geoCode)) {
        continue
    }

    if ($RequireCertDomainMatch -and -not (Test-CertDomainMatch -CertDomain ([string]$row.CERT_DOMAIN) -Origin $origin)) {
        continue
    }

    $dedupeKey = "$origin|$($row.IP)"
    if ($seenUsableRows.ContainsKey($dedupeKey)) {
        continue
    }

    $seenUsableRows[$dedupeKey] = $true
    $source = $selectedByDomain[$origin]

    $usableRows.Add([pscustomobject]@{
        Rank          = $source.Rank
        Domain        = $origin
        IP            = $row.IP
        TLS           = $row.TLS
        ALPN          = $row.ALPN
        Curve         = $row.CURVE
        CertDomain    = $row.CERT_DOMAIN
        CertIssuer    = $row.CERT_ISSUER
        GeoCode       = $row.GEO_CODE
        Priority      = $source.Priority
    })
}

$usableSorted = @($usableRows | Sort-Object Rank, Domain, IP)
$usableSorted | Export-Csv -LiteralPath $usableCsvPath -NoTypeInformation -Encoding UTF8

$usableDomains = @($usableSorted | Select-Object -ExpandProperty Domain -Unique)
$usableDomains | Set-Content -LiteralPath $usableDomainsPath -Encoding ASCII

$summaryLines = @(
    "Run ID: $runId",
    "Tranco CSV: $TrancoCsv",
    "Scanner: $ScannerPath",
    "Rank range: $MinRank-$MaxRank",
    "Range rows: $rangeRows",
    "Excluded by keyword: $excludedRows",
    "Duplicate domains skipped: $duplicateRows",
    "Candidates after filter: $($candidates.Count)",
    "Priority candidates: $($priorityCandidates.Count)",
    "Normal candidates: $($normalCandidates.Count)",
    "Selected domains: $($selected.Count)",
    "Scanner rows: $($scannerRows.Count)",
    "Usable rows: $($usableSorted.Count)",
    "Usable domains: $($usableDomains.Count)",
    "Require TLS 1.3: $RequireTls13",
    "Require cert domain match: $RequireCertDomainMatch",
    "Excluded GEO_CODE values: $($ExcludedGeoCodes -join ', ')",
    "Selected CSV: $selectedCsvPath",
    "Scanner raw CSV: $scannerRawPath",
    "Usable CSV: $usableCsvPath",
    "Usable domains TXT: $usableDomainsPath"
)

$summaryLines | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host ''
$summaryLines | ForEach-Object { Write-Host $_ }

if ($usableDomains.Count -gt 0) {
    Write-Host ''
    Write-Host 'Usable domains:'
    $usableDomains | ForEach-Object { Write-Host $_ }
}
else {
    Write-Host ''
    Write-Host 'No usable domains found in this sample. Re-run the script to try another random sample.'
}
