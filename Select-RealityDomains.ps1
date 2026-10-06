<#
.SYNOPSIS
Select random Tranco domains and verify them with RealiTLScanner.

.DESCRIPTION
The default policy follows this project:
- rank range: 2,000 to 30,000
- batch size: 2,000 domains
- result target: 300 qualified domains
- exclude hot brands and sensitive categories
- prefer docs/static/assets/download/dl/support/help/developer/mirrors names
- keep scanner rows that are usable TLS 1.3 results
- optionally keep only IPs in the given countries (-IncludedGeoCodes)
- require the certificate to cover the domain on every kept IP
- require an HTTPS 2xx response without changing the website domain, in every check round
- re-scan hosts reached by same-site redirects (example.com -> www.example.com)

Outputs are written to a timestamped folder under .\reality-scan-results.
#>

[CmdletBinding()]
param(
    [string]$TrancoCsv = '',
    [string]$ScannerPath = '',
    [string]$OutputDir = '',

    [int]$MinRank = 3000,
    [int]$MaxRank = 200000,
    [int]$SampleCount = 2000,
    [int]$ResultCount = 100,
    [int]$MaxBatches = 10,

    [int]$Thread = 16,
    [int]$Timeout = 8,
    [int]$Port = 443,
    [int]$WebsiteTimeout = 10,
    [int]$WebsiteCheckRounds = 3,

    [bool]$RequireTls13 = $true,
    [bool]$RequireCertDomainMatch = $true,
    [string[]]$IncludedGeoCodes = @(),
    [string[]]$ExcludedGeoCodes = @(
        'CLOUDFLARE', 'CLOUDFRONT', 'FASTLY', 'GOOGLE', 'FACEBOOK',
        'NETFLIX', 'TWITTER', 'TELEGRAM', 'MICROSOFT', 'APPLE'
    ),

    [switch]$IncludeIpv6,
    [switch]$SkipScan,
    [int]$Seed = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Net.Http

# Tls12 | Tls13; numeric because older .NET builds lack the Tls13 name.
$TlsProtocols = [System.Security.Authentication.SslProtocols]15360

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
    $ScannerPath = Join-Path $ScriptDir 'RealiTLScanner-windows-64.exe'
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $ScriptDir 'reality-scan-results'
}

# The scanner runs from $ScriptDir (see below), so pin user paths first.
$TrancoCsv = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TrancoCsv)
$ScannerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ScannerPath)
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
$CountryMmdbPath = Join-Path $ScriptDir 'Country.mmdb'

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

function Test-CertOnIp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Ip,
        [Parameter(Mandatory = $true)]
        [string]$Domain,
        [Parameter(Mandatory = $true)]
        [int]$HttpsPort,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    # Scanner CERT_DOMAIN only carries the certificate CN, so verify the full
    # chain and SAN list with a real handshake against this specific IP.
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $sslStream = $null

    try {
        $connectTask = $tcpClient.ConnectAsync($Ip, $HttpsPort)
        if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            return $false
        }

        $tcpClient.ReceiveTimeout = $TimeoutSeconds * 1000
        $tcpClient.SendTimeout = $TimeoutSeconds * 1000
        $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false)
        $sslStream.AuthenticateAsClient($Domain, $null, $TlsProtocols, $false)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $sslStream) {
            $sslStream.Dispose()
        }
        $tcpClient.Dispose()
    }
}

function Test-WebsiteAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Domain,
        [Parameter(Mandatory = $true)]
        [System.Net.Http.HttpClient]$HttpClient,
        [Parameter(Mandatory = $true)]
        [int]$HttpsPort,
        [string]$InitialPath = '/'
    )

    $requestUri = [System.UriBuilder]::new('https', $Domain, $HttpsPort, $InitialPath).Uri
    $currentUri = $requestUri
    $response = $null
    $redirectCount = 0
    $maxRedirects = 10
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        while ($true) {
            $response = $HttpClient.GetAsync(
                $currentUri,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()

            $statusCode = [int]$response.StatusCode
            $isRedirect = $statusCode -ge 300 -and $statusCode -le 399

            if (-not $isRedirect) {
                $isSuccess = $statusCode -ge 200 -and $statusCode -le 299

                return [pscustomobject]@{
                    Domain        = $Domain
                    Url           = [string]$requestUri
                    FinalUrl      = [string]$currentUri
                    AccessOk      = $isSuccess
                    StatusCode    = $statusCode
                    Redirected    = $redirectCount -gt 0
                    RedirectCount = $redirectCount
                    DomainChanged = $false
                    Location      = ''
                    Error         = ''
                    ElapsedMs     = $stopwatch.ElapsedMilliseconds
                }
            }

            if ($null -eq $response.Headers.Location) {
                return [pscustomobject]@{
                    Domain        = $Domain
                    Url           = [string]$requestUri
                    FinalUrl      = [string]$currentUri
                    AccessOk      = $false
                    StatusCode    = $statusCode
                    Redirected    = $true
                    RedirectCount = $redirectCount
                    DomainChanged = $false
                    Location      = ''
                    Error         = 'Redirect response did not include a Location header.'
                    ElapsedMs     = $stopwatch.ElapsedMilliseconds
                }
            }

            $location = $response.Headers.Location
            if ($location.IsAbsoluteUri) {
                $nextUri = $location
            }
            else {
                $nextUri = [System.Uri]::new($currentUri, $location)
            }

            $redirectCount++
            $domainChanged = -not $nextUri.DnsSafeHost.Equals(
                $requestUri.DnsSafeHost,
                [System.StringComparison]::OrdinalIgnoreCase
            )

            if ($domainChanged) {
                return [pscustomobject]@{
                    Domain        = $Domain
                    Url           = [string]$requestUri
                    FinalUrl      = [string]$nextUri
                    AccessOk      = $false
                    StatusCode    = $statusCode
                    Redirected    = $true
                    RedirectCount = $redirectCount
                    DomainChanged = $true
                    Location      = [string]$location
                    Error         = 'Redirect changed the website domain.'
                    ElapsedMs     = $stopwatch.ElapsedMilliseconds
                }
            }

            if ($redirectCount -gt $maxRedirects) {
                return [pscustomobject]@{
                    Domain        = $Domain
                    Url           = [string]$requestUri
                    FinalUrl      = [string]$nextUri
                    AccessOk      = $false
                    StatusCode    = $statusCode
                    Redirected    = $true
                    RedirectCount = $redirectCount
                    DomainChanged = $false
                    Location      = [string]$location
                    Error         = "More than $maxRedirects redirects."
                    ElapsedMs     = $stopwatch.ElapsedMilliseconds
                }
            }

            $response.Dispose()
            $response = $null
            $currentUri = $nextUri
        }
    }
    catch {
        return [pscustomobject]@{
            Domain        = $Domain
            Url           = [string]$requestUri
            FinalUrl      = [string]$currentUri
            AccessOk      = $false
            StatusCode    = ''
            Redirected    = $redirectCount -gt 0
            RedirectCount = $redirectCount
            DomainChanged = $false
            Location      = ''
            Error         = $_.Exception.GetBaseException().Message
            ElapsedMs     = $stopwatch.ElapsedMilliseconds
        }
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

Test-ReadableFile -Path $TrancoCsv -Name 'Tranco CSV'
Test-ReadableFile -Path $ScannerPath -Name 'RealiTLScanner'

# RealiTLScanner loads Country.mmdb from its working directory; without it
# GEO_CODE is N/A and every GEO_CODE filter silently stops working.
if (-not $SkipScan) {
    Test-ReadableFile -Path $CountryMmdbPath -Name 'Country.mmdb'

    $mmdbContent = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($CountryMmdbPath))
    if ($mmdbContent.IndexOf('CLOUDFLARE', [System.StringComparison]::Ordinal) -lt 0) {
        Write-Warning "Country.mmdb has no CDN tags such as CLOUDFLARE; CDN-hosted IPs will not be excluded. Run Update-CountryMmdb.ps1."
    }
    $mmdbContent = $null
}

if ($MinRank -lt 1 -or $MaxRank -lt $MinRank) {
    throw "Invalid rank range: $MinRank to $MaxRank"
}

if ($SampleCount -lt 1) {
    throw "SampleCount must be greater than 0."
}

if ($ResultCount -lt 1) {
    throw "ResultCount must be greater than 0."
}

if ($MaxBatches -lt 1) {
    throw "MaxBatches must be greater than 0."
}

if ($WebsiteTimeout -lt 1) {
    throw "WebsiteTimeout must be greater than 0."
}

if ($WebsiteCheckRounds -lt 1) {
    throw "WebsiteCheckRounds must be greater than 0."
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

# Keywords must be followed by '.' or '-' so they never match the TLD
# (.dev, .help, .support, .download are all real TLDs).
$PriorityPatterns = [ordered]@{
    docs      = '(^|[.-])(docs?|documentation)[.-]'
    static    = '(^|[.-])static[.-]'
    assets    = '(^|[.-])assets?[.-]'
    download  = 'download[^.]*\.'
    dl        = '(^|[.-])dl[.-]'
    support   = '(^|[.-])support[.-]'
    help      = '(^|[.-])help[.-]'
    developer = '(^|[.-])(developers?|dev)[.-]'
    mirrors   = '(^|[.-])mirrors?[.-]'
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
$websiteChecksPath = Join-Path $runDir 'website-checks.csv'
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

function ConvertTo-GeoLookup {
    param(
        [string[]]$GeoCodes
    )

    # powershell -File passes "US,JP" as one string, so split on commas too.
    $lookup = @{}
    foreach ($geoCode in @($GeoCodes) -split ',') {
        if (-not [string]::IsNullOrWhiteSpace($geoCode)) {
            $lookup[$geoCode.Trim().ToUpperInvariant()] = $true
        }
    }

    return $lookup
}

$excludedGeoLookup = ConvertTo-GeoLookup -GeoCodes $ExcludedGeoCodes
$includedGeoLookup = ConvertTo-GeoLookup -GeoCodes $IncludedGeoCodes

$remainingPriority = @($priorityCandidates)
$remainingNormal = @($normalCandidates)
$selected = New-Object 'System.Collections.Generic.List[object]'
$allScannerRows = New-Object 'System.Collections.Generic.List[object]'
$usableRows = New-Object 'System.Collections.Generic.List[object]'
$seenUsableRows = @{}
$websiteChecks = New-Object 'System.Collections.Generic.List[object]'
$accessibleDomainLookup = @{}
$certRejectedRows = @{}
$batchCount = 0

$httpHandler = New-Object System.Net.Http.HttpClientHandler
$httpHandler.AllowAutoRedirect = $false
$httpHandler.AutomaticDecompression =
[System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$httpClient = [System.Net.Http.HttpClient]::new($httpHandler)
$httpClient.Timeout = [TimeSpan]::FromSeconds($WebsiteTimeout)
$httpClient.DefaultRequestHeaders.UserAgent.ParseAdd(
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) RealityDomainSelector/1.0'
)
$httpClient.DefaultRequestHeaders.Accept.ParseAdd(
    'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
)

try {
    while (
        $accessibleDomainLookup.Count -lt $ResultCount -and
        $batchCount -lt $MaxBatches -and
        ($remainingPriority.Count + $remainingNormal.Count) -gt 0
    ) {
        $batchCount++

        if ($remainingPriority.Count -ge $SampleCount) {
            $batchSource = Select-RandomItems -Items $remainingPriority -Count $SampleCount
        }
        else {
            $batchSource = @($remainingPriority)
            $batchSource += Select-RandomItems -Items $remainingNormal -Count ($SampleCount - $batchSource.Count)
        }

        $batchSource = Select-RandomItems -Items $batchSource -Count $batchSource.Count
        $batchDomainLookup = @{}
        $selectedByDomain = @{}
        $batchSelected = New-Object 'System.Collections.Generic.List[object]'
        $batchHasPriority = $false
        $batchHasNormal = $false

        foreach ($item in $batchSource) {
            $batchDomainLookup[$item.Domain] = $true
            if ($item.IsPriority) {
                $batchHasPriority = $true
            }
            else {
                $batchHasNormal = $true
            }

            $batchItem = [pscustomobject]@{
                Batch        = $batchCount
                Rank         = $item.Rank
                Domain       = $item.Domain
                Priority     = $item.Priority
                IsPriority   = $item.IsPriority
                RedirectFrom = ''
            }
            $batchSelected.Add($batchItem)
            $selected.Add($batchItem)
            $selectedByDomain[$item.Domain] = $batchItem
        }

        if ($batchHasPriority) {
            $remainingPriority = @(
                $remainingPriority | Where-Object { -not $batchDomainLookup.ContainsKey($_.Domain) }
            )
        }
        if ($batchHasNormal) {
            $remainingNormal = @(
                $remainingNormal | Where-Object { -not $batchDomainLookup.ContainsKey($_.Domain) }
            )
        }

        $batchLabel = '{0:D3}' -f $batchCount

        Write-Host ''
        Write-Host "Batch $batchCount/${MaxBatches}: selected $($batchSelected.Count) domains."

        # Pass 1 scans the sampled domains. Pass 2 scans hosts that pass-1 domains
        # redirected to inside their own site (example.com -> www.example.com):
        # those hosts are the ones that actually serve the website.
        $passItems = $batchSelected.ToArray()
        $pass = 1

        while ($passItems.Count -gt 0 -and $accessibleDomainLookup.Count -lt $ResultCount) {
            if ($pass -eq 1) {
                $passPrefix = "batch-$batchLabel"
            }
            else {
                $passPrefix = "batch-$batchLabel-redirect"
                Write-Host "Following same-site redirects for $($passItems.Count) hosts..."
            }

            $batchInputPath = Join-Path $runDir "$passPrefix-selected-domains.txt"
            $batchRawPath = Join-Path $runDir "$passPrefix-scanner-raw.csv"
            $passItems | ForEach-Object { $_.Domain } |
            Set-Content -LiteralPath $batchInputPath -Encoding ASCII
            $nextPassItems = New-Object 'System.Collections.Generic.List[object]'

            if (-not $SkipScan) {
                $scannerArgs = @(
                    '-in', $batchInputPath,
                    '-out', $batchRawPath,
                    '-port', [string]$Port,
                    '-thread', [string]$Thread,
                    '-timeout', [string]$Timeout
                )

                if ($IncludeIpv6.IsPresent) {
                    $scannerArgs += '-46'
                }

                Write-Host "Running RealiTLScanner for batch $batchCount pass $pass..."
                Push-Location -LiteralPath $ScriptDir
                try {
                    & $ScannerPath @scannerArgs
                }
                finally {
                    Pop-Location
                }

                if ($LASTEXITCODE -ne 0) {
                    throw "RealiTLScanner exited with code $LASTEXITCODE in batch $batchCount pass $pass"
                }
            }
            elseif (-not (Test-Path -LiteralPath $batchRawPath -PathType Leaf)) {
                "IP,ORIGIN,TLS,ALPN,CURVE,CERT_LENGTH,CERT_SIGNATURE,CERT_PUBLICKEY,CERT_DOMAIN,CERT_ISSUER,GEO_CODE" |
                Set-Content -LiteralPath $batchRawPath -Encoding ASCII
            }

            $passScannerRows = @()
            if (Test-Path -LiteralPath $batchRawPath -PathType Leaf) {
                $passScannerRows = @(Import-Csv -LiteralPath $batchRawPath)
            }

            $passUsableRows = New-Object 'System.Collections.Generic.List[object]'

            foreach ($row in $passScannerRows) {
                $allScannerRows.Add($row)
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

                if ($includedGeoLookup.Count -gt 0 -and -not $includedGeoLookup.ContainsKey($geoCode)) {
                    continue
                }

                $dedupeKey = "$origin|$($row.IP)"
                if ($seenUsableRows.ContainsKey($dedupeKey)) {
                    continue
                }

                $seenUsableRows[$dedupeKey] = $true
                $source = $selectedByDomain[$origin]
                $usableRow = [pscustomobject]@{
                    Batch        = $source.Batch
                    Rank         = $source.Rank
                    Domain       = $origin
                    IP           = $row.IP
                    TLS          = $row.TLS
                    ALPN         = $row.ALPN
                    Curve        = $row.CURVE
                    CertDomain   = $row.CERT_DOMAIN
                    CertIssuer   = $row.CERT_ISSUER
                    GeoCode      = $row.GEO_CODE
                    Priority     = $source.Priority
                    RedirectFrom = $source.RedirectFrom
                }
                $usableRows.Add($usableRow)
                $passUsableRows.Add($usableRow)
            }

            $passTlsDomains = @(
                $passUsableRows |
                Sort-Object Rank, Domain |
                Select-Object -ExpandProperty Domain -Unique
            )

            if ($passTlsDomains.Count -gt 0) {
                Write-Host "Checking direct HTTPS access for $($passTlsDomains.Count) domains..."

                foreach ($domain in $passTlsDomains) {
                    $check = Test-WebsiteAccess -Domain $domain -HttpClient $httpClient -HttpsPort $Port
                    $elapsedSamples = @($check.ElapsedMs)

                    # Repeat the request so one lucky response does not qualify a flaky site.
                    for ($round = 2; $check.AccessOk -and $round -le $WebsiteCheckRounds; $round++) {
                        Start-Sleep -Milliseconds 500
                        $retry = Test-WebsiteAccess -Domain $domain -HttpClient $httpClient -HttpsPort $Port

                        if (-not $retry.AccessOk) {
                            $retry.Error = "Round $round failed: status $($retry.StatusCode) $($retry.Error)".Trim()
                            $check = $retry
                            break
                        }

                        $elapsedSamples += $retry.ElapsedMs
                    }

                    $avgElapsedMs = [int]($elapsedSamples | Measure-Object -Average).Average
                    $check | Add-Member -NotePropertyName AvgElapsedMs -NotePropertyValue $avgElapsedMs
                    $check | Add-Member -NotePropertyName Batch -NotePropertyValue $batchCount

                    if ($check.AccessOk -and $RequireCertDomainMatch) {
                        $certOkCount = 0
                        foreach ($usableRow in @($passUsableRows | Where-Object { $_.Domain -eq $domain })) {
                            if (Test-CertOnIp -Ip $usableRow.IP -Domain $domain -HttpsPort $Port -TimeoutSeconds $Timeout) {
                                $certOkCount++
                            }
                            else {
                                $certRejectedRows["$domain|$($usableRow.IP)"] = $true
                            }
                        }

                        if ($certOkCount -eq 0) {
                            $check.AccessOk = $false
                            $check.Error = 'No scanned IP served a certificate valid for the domain.'
                        }
                    }

                    $websiteChecks.Add($check)

                    if ($pass -eq 1 -and $check.DomainChanged) {
                        $redirectHost = ([System.Uri]$check.FinalUrl).DnsSafeHost.ToLowerInvariant()

                        if (
                            $redirectHost.EndsWith(".$domain") -and
                            -not $seenDomains.ContainsKey($redirectHost) -and
                            -not $ExcludeRegex.IsMatch($redirectHost)
                        ) {
                            $seenDomains[$redirectHost] = $true
                            $source = $selectedByDomain[$domain]
                            $redirectItem = [pscustomobject]@{
                                Batch        = $batchCount
                                Rank         = $source.Rank
                                Domain       = $redirectHost
                                Priority     = $source.Priority
                                IsPriority   = $source.IsPriority
                                RedirectFrom = $domain
                            }
                            $nextPassItems.Add($redirectItem)
                            $selected.Add($redirectItem)
                            $selectedByDomain[$redirectHost] = $redirectItem
                        }
                    }

                    if ($check.AccessOk) {
                        $accessibleDomainLookup[$domain] = $avgElapsedMs

                        if ($accessibleDomainLookup.Count -ge $ResultCount) {
                            break
                        }
                    }
                }
            }

            if ($pass -ge 2) {
                break
            }

            $passItems = $nextPassItems.ToArray()
            $pass++
        }

        Write-Host "Qualified domains so far: $($accessibleDomainLookup.Count)/$ResultCount"

        if ($SkipScan) {
            break
        }
    }
}
finally {
    $httpClient.Dispose()
    $httpHandler.Dispose()
}

$selected | Sort-Object Batch, Rank |
Export-Csv -LiteralPath $selectedCsvPath -NoTypeInformation -Encoding UTF8
$selected | ForEach-Object { $_.Domain } |
Set-Content -LiteralPath $selectedDomainsPath -Encoding ASCII

if ($allScannerRows.Count -gt 0) {
    $allScannerRows | Export-Csv -LiteralPath $scannerRawPath -NoTypeInformation -Encoding UTF8
}
else {
    "IP,ORIGIN,TLS,ALPN,CURVE,CERT_LENGTH,CERT_SIGNATURE,CERT_PUBLICKEY,CERT_DOMAIN,CERT_ISSUER,GEO_CODE" |
    Set-Content -LiteralPath $scannerRawPath -Encoding ASCII
}

$tlsUsableDomains = @(
    $usableRows |
    Select-Object -ExpandProperty Domain -Unique
)

$websiteChecks | Export-Csv -LiteralPath $websiteChecksPath -NoTypeInformation -Encoding UTF8

$usableSorted = @(
    $usableRows |
    Where-Object {
        $accessibleDomainLookup.ContainsKey($_.Domain) -and
        -not $certRejectedRows.ContainsKey("$($_.Domain)|$($_.IP)")
    } |
    Select-Object *, @{ Name = 'HttpsAvgMs'; Expression = { $accessibleDomainLookup[$_.Domain] } } |
    Sort-Object Rank, Domain, IP
)
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
    "Candidate batch size: $SampleCount",
    "Batches run: $batchCount",
    "Maximum batches: $MaxBatches",
    "Total selected domains: $($selected.Count)",
    "Same-site redirect hosts scanned: $(@($selected | Where-Object { $_.RedirectFrom }).Count)",
    "Qualified domain target: $ResultCount",
    "Target reached: $($accessibleDomainLookup.Count -ge $ResultCount)",
    "Scanner rows: $($allScannerRows.Count)",
    "TLS-usable domains before website check: $($tlsUsableDomains.Count)",
    "Website checks: $($websiteChecks.Count)",
    "HTTPS 2xx without domain change: $($accessibleDomainLookup.Count)",
    "Usable rows: $($usableSorted.Count)",
    "Usable domains: $($usableDomains.Count)",
    "Require TLS 1.3: $RequireTls13",
    "Require cert domain match: $RequireCertDomainMatch",
    "IP rows rejected by certificate check: $($certRejectedRows.Count)",
    "Website timeout seconds: $WebsiteTimeout",
    "Website check rounds: $WebsiteCheckRounds",
    "Excluded GEO_CODE values: $($ExcludedGeoCodes -join ', ')",
    "Included GEO_CODE values: $(if ($includedGeoLookup.Count -gt 0) { $includedGeoLookup.Keys -join ', ' } else { 'all' })",
    "Selected CSV: $selectedCsvPath",
    "Scanner raw CSV: $scannerRawPath",
    "Website checks CSV: $websiteChecksPath",
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

    if ($usableDomains.Count -lt $ResultCount -and -not $SkipScan) {
        Write-Warning "Only $($usableDomains.Count) qualified domains were found after $batchCount batches; target: $ResultCount."
    }
}
else {
    Write-Host ''
    Write-Host 'No usable domains found.'
}
