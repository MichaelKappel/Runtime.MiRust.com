param(
    [string]$BaseUrl = "https://runtime.mirust.com",
    [string]$ReceiptPath = "",
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:ReceiptMaximumBytes = 65536
$script:ReceiptProfile = "runtime.mirust.redirect-verification.v5"
$script:MaximumRawResponseBytes = 131072
$script:MaximumBoundaryBodyBytes = 65536
$script:GoneBytes = [byte[]](71, 111, 110, 101, 10)
$script:BadRequestBytes = [byte[]](66, 97, 100, 32, 82, 101, 113, 117, 101, 115, 116, 10)

function Assert-ExactHeaderValue {
    param(
        [Parameter(Mandatory)][object[]]$Values,
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Name
    )

    $actual = @($Values)
    if ($actual.Count -ne 1 -or [string]$actual[0] -cne $Expected) {
        throw "$Name must contain exactly '$Expected'"
    }
}

function Test-ByteEquality {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Actual,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Expected
    )

    if ($Actual.Length -ne $Expected.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Actual.Length; $index++) {
        if ($Actual[$index] -ne $Expected[$index]) {
            return $false
        }
    }
    return $true
}

# Checks a route's non-followed response before recording redirect success.
function Assert-RedirectObservation {
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$LocationValues,
        [Parameter(Mandatory)][string]$SourceUrl,
        [Parameter(Mandatory)][string]$ExpectedLocation
    )

    if ($StatusCode -ne 301) {
        throw "$SourceUrl must return HTTP 301"
    }
    if ($LocationValues.Count -ne 1) {
        throw "$SourceUrl must return exactly one Location header"
    }
    $location = [string]$LocationValues[0]
    if ($location -cne $ExpectedLocation) {
        throw "$SourceUrl returned an unexpected redirect target"
    }
    return $location
}

function Assert-TerminalObservation {
    param(
        [Parameter(Mandatory)][object]$Observation,
        [Parameter(Mandatory)][int]$ExpectedStatus,
        [Parameter(Mandatory)][byte[]]$ExpectedBytes,
        [Parameter(Mandatory)][string]$Label
    )

    if ($Observation.Method -cnotin @("GET", "HEAD")) {
        throw "$Label method must be GET or HEAD"
    }
    if ([int]$Observation.StatusCode -ne $ExpectedStatus) {
        throw "$Label must return HTTP $ExpectedStatus"
    }
    if (@($Observation.LocationValues).Count -ne 0) {
        throw "$Label must not return Location"
    }
    Assert-ExactHeaderValue -Values @($Observation.CacheControlValues) `
        -Expected "no-store" -Name "Cache-Control"
    Assert-ExactHeaderValue -Values @($Observation.RobotsValues) `
        -Expected "noindex, nofollow" -Name "X-Robots-Tag"
    Assert-ExactHeaderValue -Values @($Observation.NosniffValues) `
        -Expected "nosniff" -Name "X-Content-Type-Options"
    if ([string]$Observation.MediaType -ine "text/plain") {
        throw "$Label must return text/plain"
    }
    if ([string]$Observation.Charset -ine "utf-8") {
        throw "$Label must return charset=utf-8"
    }
    if ([long]$Observation.ContentLength -ne $ExpectedBytes.Length) {
        throw "$Label must declare Content-Length: $($ExpectedBytes.Length)"
    }
    $expectedBody = [byte[]]@()
    if ($Observation.Method -cne "HEAD") {
        $expectedBody = $ExpectedBytes
    }
    $actualBody = [byte[]]@($Observation.BodyBytes)
    if (-not (Test-ByteEquality -Actual $actualBody -Expected $expectedBody)) {
        throw "$Label returned unexpected response bytes"
    }
}

function Assert-RetiredObservation {
    param([Parameter(Mandatory)][object]$Observation)

    Assert-TerminalObservation -Observation $Observation -ExpectedStatus 410 `
        -ExpectedBytes $script:GoneBytes -Label "Retired route"
}

function Assert-BadRequestObservation {
    param([Parameter(Mandatory)][object]$Observation)

    Assert-TerminalObservation -Observation $Observation -ExpectedStatus 400 `
        -ExpectedBytes $script:BadRequestBytes -Label "Hostile route"
}

function Assert-ServerBoundaryObservation {
    param([Parameter(Mandatory)][object]$Observation)

    if ($Observation.Method -cnotin @("GET", "HEAD")) {
        throw "Server-boundary method must be GET or HEAD"
    }
    if ([int]$Observation.StatusCode -notin @(400, 404)) {
        throw "Server-boundary route must return HTTP 400 or 404"
    }
    if (@($Observation.LocationValues).Count -ne 0) {
        throw "Server-boundary route must not return Location"
    }
    $body = [byte[]]@($Observation.BodyBytes)
    if ($body.Length -gt $script:MaximumBoundaryBodyBytes) {
        throw "Server-boundary response body exceeds the bounded limit"
    }
    if ($Observation.Method -ceq "HEAD" -and $body.Length -ne 0) {
        throw "Server-boundary HEAD returned response-body bytes"
    }
}

function New-RetiredFixture {
    param(
        [string]$Method = "GET",
        [hashtable]$Overrides = @{}
    )

    $body = [byte[]]@()
    if ($Method -cne "HEAD") {
        $body = [byte[]]$script:GoneBytes.Clone()
    }
    $fixture = [ordered]@{
        Method = $Method
        StatusCode = 410
        LocationValues = @()
        CacheControlValues = @("no-store")
        RobotsValues = @("noindex, nofollow")
        NosniffValues = @("nosniff")
        MediaType = "text/plain"
        Charset = "UTF-8"
        ContentLength = 5L
        BodyBytes = [byte[]]$body
    }
    foreach ($key in $Overrides.Keys) {
        if (-not $fixture.Contains($key)) {
            throw "Unknown fixture field: $key"
        }
        $fixture[$key] = $Overrides[$key]
    }
    return [pscustomobject]$fixture
}

function Invoke-RetiredVerifierSelfTest {
    $redirectTarget = "https://tinyrustlm.mirust.com/developer-portal/"
    $redirectCases = @(
        @{ Name = "permanent"; Pass = $true; Status = 301; Locations = @($redirectTarget) },
        @{ Name = "temporary-302"; Pass = $false; Status = 302; Locations = @($redirectTarget) },
        @{ Name = "temporary-307"; Pass = $false; Status = 307; Locations = @($redirectTarget) },
        @{ Name = "different-permanent-308"; Pass = $false; Status = 308; Locations = @($redirectTarget) },
        @{ Name = "success-with-location"; Pass = $false; Status = 200; Locations = @($redirectTarget) },
        @{ Name = "missing-location"; Pass = $false; Status = 301; Locations = @() },
        @{ Name = "duplicate-location"; Pass = $false; Status = 301; Locations = @($redirectTarget, $redirectTarget) },
        @{ Name = "wrong-location"; Pass = $false; Status = 301; Locations = @("https://tinyrustlm.mirust.com/docs/") },
        @{ Name = "normalized-location"; Pass = $false; Status = 301; Locations = @("https://TINYRUSTLM.MIRUST.COM/developer-portal/") }
    )
    foreach ($case in $redirectCases) {
        $passed = $true
        try {
            $location = Assert-RedirectObservation -StatusCode $case.Status `
                -LocationValues $case.Locations -SourceUrl "https://runtime.mirust.com/" `
                -ExpectedLocation $redirectTarget
            if ($location -cne $redirectTarget) { throw "Redirect output changed" }
        }
        catch { $passed = $false }
        if ($passed -ne $case.Pass) {
            throw "Redirect verifier fixture produced the wrong verdict: $($case.Name)"
        }
    }
    Write-Host "PASS PowerShell exact-301 redirect fixtures ($($redirectCases.Count))"
    $rawRedirectCases = @(
        @{ Name = "http-field-whitespace"; Pass = $true; Headers = "lOcAtIoN:`t $redirectTarget `t" },
        @{ Name = "uri-host-case"; Pass = $false; Headers = "Location: https://TINYRUSTLM.MIRUST.COM/developer-portal/" },
        @{ Name = "uri-default-port"; Pass = $false; Headers = "Location: https://tinyrustlm.mirust.com:443/developer-portal/" },
        @{ Name = "uri-dot-segment"; Pass = $false; Headers = "Location: https://tinyrustlm.mirust.com/./developer-portal/" },
        @{ Name = "duplicate-location"; Pass = $false; Headers = "Location: $redirectTarget`r`nLocation: $redirectTarget" },
        @{ Name = "carriage-return"; Pass = $false; Headers = "Location: $redirectTarget`r" },
        @{ Name = "vertical-tab"; Pass = $false; Headers = "Location: $redirectTarget$([char]11)" },
        @{ Name = "null"; Pass = $false; Headers = "Location: $redirectTarget$([char]0)" },
        @{ Name = "delete"; Pass = $false; Headers = "Location: $redirectTarget$([char]127)" },
        @{ Name = "non-http-whitespace"; Pass = $false; Headers = "Location: $redirectTarget$([char]160)" },
        @{ Name = "folded-location"; Pass = $false; Headers = "Location: $redirectTarget`r`n`tignored" },
        @{ Name = "folded-with-colon"; Pass = $false; Headers = "Location: $redirectTarget`r`n`tignored: suffix" }
    )
    foreach ($case in $rawRedirectCases) {
        $passed = $true
        try {
            $raw = [Text.Encoding]::GetEncoding(28591).GetBytes(
                "HTTP/1.1 301 Moved Permanently`r`n$($case.Headers)`r`n`r`n")
            $observation = ConvertFrom-RawHttpResponseBytes -Bytes $raw -Method "GET"
            Assert-RedirectObservation -StatusCode $observation.StatusCode `
                -LocationValues @($observation.LocationValues) -SourceUrl "https://runtime.mirust.com/" `
                -ExpectedLocation $redirectTarget | Out-Null
        }
        catch { $passed = $false }
        if ($passed -ne $case.Pass) {
            throw "Raw redirect fixture produced the wrong verdict: $($case.Name)"
        }
    }
    Write-Host "PASS PowerShell raw redirect fixtures ($($rawRedirectCases.Count))"
    $cases = @(
        [pscustomobject]@{ Name = "valid-get"; Pass = $true; Value = (New-RetiredFixture) },
        [pscustomobject]@{ Name = "valid-head"; Pass = $true; Value = (New-RetiredFixture -Method "HEAD") },
        [pscustomobject]@{ Name = "wrong-status"; Pass = $false; Value = (New-RetiredFixture -Overrides @{ StatusCode = 200 }) },
        [pscustomobject]@{ Name = "location-present"; Pass = $false; Value = (New-RetiredFixture -Overrides @{ LocationValues = @("https://example.invalid/") }) },
        [pscustomobject]@{ Name = "cache-extra"; Pass = $false; Value = (New-RetiredFixture -Overrides @{ CacheControlValues = @("private, no-store") }) },
        [pscustomobject]@{ Name = "robots-spacing"; Pass = $false; Value = (New-RetiredFixture -Overrides @{ RobotsValues = @("noindex,nofollow") }) },
        [pscustomobject]@{ Name = "nosniff-missing"; Pass = $false; Value = (New-RetiredFixture -Overrides @{ NosniffValues = @() }) },
        [pscustomobject]@{ Name = "wrong-media-type"; Pass = $false; Value = (New-RetiredFixture -Overrides @{ MediaType = "text/html" }) },
        [pscustomobject]@{ Name = "missing-charset"; Pass = $false; Value = (New-RetiredFixture -Overrides @{ Charset = "" }) },
        [pscustomobject]@{ Name = "wrong-length"; Pass = $false; Value = (New-RetiredFixture -Overrides @{ ContentLength = 4L }) },
        [pscustomobject]@{ Name = "missing-newline"; Pass = $false; Value = (New-RetiredFixture -Overrides @{ BodyBytes = [byte[]](71, 111, 110, 101) }) },
        [pscustomobject]@{ Name = "head-has-body"; Pass = $false; Value = (New-RetiredFixture -Method "HEAD" -Overrides @{ BodyBytes = [byte[]](71, 111, 110, 101, 10) }) }
    )

    foreach ($case in $cases) {
        $passed = $true
        $failureMessage = ""
        try {
            Assert-RetiredObservation -Observation $case.Value
        }
        catch {
            $passed = $false
            $failureMessage = $_.Exception.Message
        }
        if ($passed -ne [bool]$case.Pass) {
            throw "Retired verifier fixture produced the wrong verdict: $($case.Name) ($failureMessage)"
        }
    }
    $rawHeaders = "HTTP/1.1 410 Gone`r`n" +
        "Cache-Control: no-store`r`nX-Robots-Tag: noindex, nofollow`r`n" +
        "X-Content-Type-Options: nosniff`r`n" +
        "Content-Type: text/plain; charset=UTF-8`r`nContent-Length: 5`r`n`r`n"
    $goodRaw = [System.Text.Encoding]::ASCII.GetBytes($rawHeaders)
    Assert-RetiredObservation -Observation (
        ConvertFrom-RawHttpResponseBytes -Bytes $goodRaw -Method "HEAD")
    $badRaw = [System.Text.Encoding]::ASCII.GetBytes("${rawHeaders}Gone`n")
    $badRejected = $false
    try {
        Assert-RetiredObservation -Observation (
            ConvertFrom-RawHttpResponseBytes -Bytes $badRaw -Method "HEAD")
    }
    catch { $badRejected = $true }
    if (-not $badRejected) { throw "Raw HEAD parser ignored forbidden response-body bytes" }
    $boundaryRaw = [System.Text.Encoding]::ASCII.GetBytes(
        "HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`n`r`n")
    Assert-ServerBoundaryObservation -Observation (
        ConvertFrom-RawHttpResponseBytes -Bytes $boundaryRaw -Method "HEAD")
    Write-Host "PASS PowerShell retired-route verifier fixtures ($($cases.Count) plus raw-wire fixtures)"
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-Sha256FromBytes {
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Invoke-GitScalar {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = @(& git -C $RepositoryRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed while preparing the verification receipt"
    }
    return ($output -join "`n").Trim()
}

function Get-SafeFailureCode {
    param([System.Management.Automation.ErrorRecord]$Failure)

    if ($null -eq $Failure) {
        return $null
    }
    $exception = $Failure.Exception
    $typeName = $exception.GetType().FullName -replace '[^A-Za-z0-9.]', '-'
    return "verifier-error/$typeName/$($exception.HResult)"
}

function Write-CreateOnlyReceipt {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][byte[]]$Bytes
    )

    if ($Bytes.Length -gt $script:ReceiptMaximumBytes) {
        throw "Verification receipt exceeds the bounded byte limit"
    }
    $directory = [System.IO.Path]::GetDirectoryName($TargetPath)
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    if ([System.IO.File]::Exists($TargetPath)) {
        throw "Verification receipt already exists"
    }
    $temporaryPath = [System.IO.Path]::Combine(
        $directory,
        ".receipt-$PID-$([Guid]::NewGuid().ToString('N')).tmp"
    )
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [System.IO.File]::Move($temporaryPath, $TargetPath)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
    }
}

function Resolve-ReceiptTarget {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RawPath
    )

    $target = if ([System.IO.Path]::IsPathRooted($RawPath)) {
        [System.IO.Path]::GetFullPath($RawPath)
    }
    else {
        [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($RepositoryRoot, $RawPath))
    }
    $receiptRoot = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($RepositoryRoot, "verification", "receipts")
    )
    $prefix = $receiptRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Receipt path must remain below verification/receipts"
    }
    if ([System.IO.Path]::GetExtension($target) -cne ".json") {
        throw "Receipt path must use a .json extension"
    }
    $leaf = [System.IO.Path]::GetFileName($target)
    if ($leaf -cnotmatch '^runtime-redirect-verification-[0-9]{8}T[0-9]{6}Z\.json$') {
        throw "Receipt file name is invalid"
    }
    return $target
}

function Write-VerificationReceipt {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][string]$Origin,
        [Parameter(Mandatory)][DateTimeOffset]$StartedUtc,
        [Parameter(Mandatory)][object[]]$Redirects,
        [Parameter(Mandatory)][object[]]$RetiredRoutes,
        [Parameter(Mandatory)][object[]]$HostileRoutes,
        [Parameter(Mandatory)][object[]]$ServerBoundaryRoutes,
        [Parameter(Mandatory)][object[]]$Readbacks,
        [System.Management.Automation.ErrorRecord]$Failure
    )

    $statusLines = @(& git -C $RepositoryRoot status --porcelain 2>&1)
    if ($LASTEXITCODE -ne 0 -or $statusLines.Count -ne 0) {
        throw "A verification receipt requires a clean repository"
    }
    $sourceCommit = Invoke-GitScalar -RepositoryRoot $RepositoryRoot -Arguments @("rev-parse", "HEAD")
    $upstreamCommit = Invoke-GitScalar -RepositoryRoot $RepositoryRoot -Arguments @("rev-parse", "@{u}")
    if ($sourceCommit -cne $upstreamCommit) {
        throw "A verification receipt requires an upstream-exact repository"
    }
    $sourceTree = Invoke-GitScalar -RepositoryRoot $RepositoryRoot -Arguments @("rev-parse", "HEAD^{tree}")
    $powerShellVerifier = [System.IO.Path]::GetFullPath($PSCommandPath)
    $shellVerifier = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($PSScriptRoot, "verify-runtime-mirust.sh")
    )
    $completedUtc = [DateTimeOffset]::UtcNow
    $failureCode = Get-SafeFailureCode -Failure $Failure
    $status = if ($null -eq $Failure) {
        "redirects-retirements-and-destinations-verified"
    }
    else {
        "failed"
    }
    $receipt = [ordered]@{
        schema = "runtime.mirust.redirect_verification_receipt.v5"
        site = "Runtime.MiRust.com"
        origin = $Origin
        verification_profile = $script:ReceiptProfile
        source_commit = $sourceCommit
        source_tree = $sourceTree
        started_utc = $StartedUtc.ToString("O")
        completed_utc = $completedUtc.ToString("O")
        status = $status
        failure_code = $failureCode
        deployment_attempted = $false
        deployment_profile_used = $false
        known_deployment_blocker = "unsafe-deployment-profile"
        redirect_count = $Redirects.Count
        retired_route_count = $RetiredRoutes.Count
        hostile_route_count = $HostileRoutes.Count
        server_boundary_route_count = $ServerBoundaryRoutes.Count
        readback_count = $Readbacks.Count
        verifier_files = @(
            [ordered]@{
                path = "tools/verify-runtime-mirust.ps1"
                bytes = ([System.IO.FileInfo]$powerShellVerifier).Length
                sha256 = Get-Sha256 -Path $powerShellVerifier
            },
            [ordered]@{
                path = "tools/verify-runtime-mirust.sh"
                bytes = ([System.IO.FileInfo]$shellVerifier).Length
                sha256 = Get-Sha256 -Path $shellVerifier
            }
        )
        redirects = $Redirects
        retired_routes = $RetiredRoutes
        hostile_routes = $HostileRoutes
        server_boundary_routes = $ServerBoundaryRoutes
        readbacks = $Readbacks
    }
    $json = $receipt | ConvertTo-Json -Depth 8
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes("$json`n")
    Write-CreateOnlyReceipt -TargetPath $TargetPath -Bytes $bytes
    Write-Host "RECEIPT $TargetPath"
}

function Get-ResponseHeaderValues {
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpResponseMessage]$Response,
        [Parameter(Mandatory)][string]$Name
    )

    $values = [System.Collections.Generic.IEnumerable[string]]$null
    if ($Response.Headers.TryGetValues($Name, [ref]$values)) {
        return @($values)
    }
    $values = [System.Collections.Generic.IEnumerable[string]]$null
    if ($Response.Content.Headers.TryGetValues($Name, [ref]$values)) {
        return @($values)
    }
    return @()
}

function Find-ByteSequence {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][byte[]]$Needle,
        [int]$Start = 0
    )

    for ($offset = $Start; $offset -le $Bytes.Length - $Needle.Length; $offset++) {
        $matched = $true
        for ($index = 0; $index -lt $Needle.Length; $index++) {
            if ($Bytes[$offset + $index] -ne $Needle[$index]) {
                $matched = $false
                break
            }
        }
        if ($matched) { return $offset }
    }
    return -1
}

function ConvertFrom-RawHttpResponseBytes {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Method
    )

    if ($Bytes.Length -eq 0 -or $Bytes.Length -gt $script:MaximumRawResponseBytes) {
        throw "Raw HTTP response is empty or exceeds its bounded limit"
    }
    $delimiter = [byte[]](13, 10, 13, 10)
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $offset = 0
    while ($true) {
        $boundary = Find-ByteSequence -Bytes $Bytes -Needle $delimiter -Start $offset
        if ($boundary -lt 0) { throw "Raw HTTP response omitted its header terminator" }
        $headerText = $latin1.GetString($Bytes, $offset, $boundary - $offset)
        $lines = @($headerText -split "`r`n")
        $statusMatch = [regex]::Match([string]$lines[0], '^HTTP/1[.][01] ([0-9]{3})(?: |$)')
        if (-not $statusMatch.Success) { throw "Raw HTTP response has an invalid status line" }
        $statusCode = [int]$statusMatch.Groups[1].Value
        $headers = @{}
        for ($lineIndex = 1; $lineIndex -lt $lines.Count; $lineIndex++) {
            $line = [string]$lines[$lineIndex]
            $colon = $line.IndexOf(':')
            if ($colon -le 0 -or $line -match '^[ \t]' -or
                $line -match '[\x00-\x08\x0A-\x1F\x7F]') {
                throw "Raw HTTP response contains an invalid header"
            }
            $name = $line.Substring(0, $colon).ToLowerInvariant()
            if (-not $headers.ContainsKey($name)) {
                $headers[$name] = [System.Collections.Generic.List[string]]::new()
            }
            $headers[$name].Add($line.Substring($colon + 1).Trim([char[]]" `t"))
        }
        $offset = $boundary + $delimiter.Length
        if ($statusCode -ge 100 -and $statusCode -lt 200) { continue }

        $bodyLength = $Bytes.Length - $offset
        $body = [byte[]]::new($bodyLength)
        if ($bodyLength -gt 0) { [Array]::Copy($Bytes, $offset, $body, 0, $bodyLength) }
        $contentTypeValues = @(if ($headers.ContainsKey('content-type')) {
            $headers['content-type'].ToArray()
        })
        $mediaType = ""
        $charset = ""
        if ($contentTypeValues.Count -eq 1) {
            $parts = @([string]$contentTypeValues[0] -split ';')
            $mediaType = $parts[0].Trim()
            foreach ($part in $parts | Select-Object -Skip 1) {
                if ($part.Trim() -match '^charset=(.+)$') { $charset = $Matches[1].Trim(' ', '"') }
            }
        }
        $contentLength = -1L
        if ($headers.ContainsKey('content-length')) {
            $lengthValues = @($headers['content-length'].ToArray())
            $parsedLength = 0L
            if ($lengthValues.Count -eq 1 -and
                [long]::TryParse($lengthValues[0], [ref]$parsedLength)) {
                $contentLength = $parsedLength
            }
        }
        return [pscustomobject][ordered]@{
            Method = $Method
            StatusCode = $statusCode
            LocationValues = if ($headers.ContainsKey('location')) { @($headers['location'].ToArray()) } else { @() }
            CacheControlValues = if ($headers.ContainsKey('cache-control')) { @($headers['cache-control'].ToArray()) } else { @() }
            RobotsValues = if ($headers.ContainsKey('x-robots-tag')) { @($headers['x-robots-tag'].ToArray()) } else { @() }
            NosniffValues = if ($headers.ContainsKey('x-content-type-options')) { @($headers['x-content-type-options'].ToArray()) } else { @() }
            MediaType = $mediaType
            Charset = $charset
            ContentLength = $contentLength
            BodyBytes = $body
            Observation = "raw-tls-http1.1-until-close"
        }
    }
}

function Invoke-RawHttpsObservation {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$RequestTarget,
        [Parameter(Mandatory)][string]$Method
    )

    if ($HostName -cne "runtime.mirust.com" -or $Method -cnotin @("GET", "HEAD") -or
        $RequestTarget.Length -eq 0 -or $RequestTarget.Length -gt 4096 -or
        $RequestTarget[0] -cne '/' -or $RequestTarget -match '[\x00-\x20\x7F-\xFF]') {
        throw "Raw HTTPS request identity is invalid"
    }
    $tcp = [System.Net.Sockets.TcpClient]::new()
    $ssl = $null
    $memory = [System.IO.MemoryStream]::new()
    try {
        $tcp.ReceiveTimeout = 30000
        $tcp.SendTimeout = 30000
        $tcp.Connect($HostName, 443)
        $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false)
        $ssl.ReadTimeout = 30000
        $ssl.WriteTimeout = 30000
        $ssl.AuthenticateAsClient($HostName)
        $requestText = "$Method $RequestTarget HTTP/1.1`r`n" +
            "Host: $HostName`r`n" +
            "User-Agent: Runtime.MiRust.com-release-verifier/5`r`n" +
            "Accept: */*`r`nAccept-Encoding: identity`r`nConnection: close`r`n`r`n"
        $requestBytes = [System.Text.Encoding]::ASCII.GetBytes($requestText)
        $ssl.Write($requestBytes, 0, $requestBytes.Length)
        $ssl.Flush()
        $buffer = [byte[]]::new(8192)
        while (($read = $ssl.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($memory.Length + $read -gt $script:MaximumRawResponseBytes) {
                throw "Raw HTTPS response exceeds its bounded limit"
            }
            $memory.Write($buffer, 0, $read)
        }
        return ConvertFrom-RawHttpResponseBytes -Bytes $memory.ToArray() -Method $Method
    }
    finally {
        $memory.Dispose()
        if ($null -ne $ssl) { $ssl.Dispose() }
        $tcp.Dispose()
    }
}

function ConvertTo-RetiredObservation {
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpResponseMessage]$Response,
        [Parameter(Mandatory)][string]$Method
    )

    $contentType = $Response.Content.Headers.ContentType
    $bodyBytes = $Response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    return [pscustomobject][ordered]@{
        Method = $Method
        StatusCode = [int]$Response.StatusCode
        LocationValues = @(Get-ResponseHeaderValues -Response $Response -Name "Location")
        CacheControlValues = @(Get-ResponseHeaderValues -Response $Response -Name "Cache-Control")
        RobotsValues = @(Get-ResponseHeaderValues -Response $Response -Name "X-Robots-Tag")
        NosniffValues = @(Get-ResponseHeaderValues -Response $Response -Name "X-Content-Type-Options")
        MediaType = if ($null -eq $contentType) { "" } else { [string]$contentType.MediaType }
        Charset = if ($null -eq $contentType) { "" } else { [string]$contentType.CharSet }
        ContentLength = if ($null -eq $Response.Content.Headers.ContentLength) { -1L } else { [long]$Response.Content.Headers.ContentLength }
        BodyBytes = [byte[]]$bodyBytes
    }
}

function Invoke-RequestWithoutRedirect {
    param(
        [Parameter(Mandatory)][System.Net.Http.HttpClient]$Client,
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Url
    )

    $request = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::new($Method),
        $Url
    )
    try {
        return $Client.SendAsync($request).GetAwaiter().GetResult()
    }
    finally {
        $request.Dispose()
    }
}

if ($SelfTest) {
    Invoke-RetiredVerifierSelfTest
    exit 0
}

$startedUtc = [DateTimeOffset]::UtcNow
$redirectObservations = [System.Collections.Generic.List[object]]::new()
$retiredRouteObservations = [System.Collections.Generic.List[object]]::new()
$hostileRouteObservations = [System.Collections.Generic.List[object]]::new()
$serverBoundaryRouteObservations = [System.Collections.Generic.List[object]]::new()
$readbackObservations = [System.Collections.Generic.List[object]]::new()
$operationFailure = $null

try {
    $baseUri = [Uri]$BaseUrl
}
catch {
    throw "Base URL is invalid"
}
if (-not $baseUri.IsAbsoluteUri -or $baseUri.Scheme -cne "https" -or
    $baseUri.Host -cne "runtime.mirust.com" -or $baseUri.AbsolutePath -cne "/" -or
    -not [string]::IsNullOrEmpty($baseUri.UserInfo) -or
    -not [string]::IsNullOrEmpty($baseUri.Query) -or
    -not [string]::IsNullOrEmpty($baseUri.Fragment)) {
    throw "Base URL must be the canonical Runtime.MiRust.com HTTPS origin"
}
$BaseUrl = "https://runtime.mirust.com"
$repositoryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, ".."))
$tabooPath = [System.IO.Path]::Combine($repositoryRoot, ".uai", "taboo.uai")
$antiDriftRule = "Any committed change to a declared public artifact invalidates deployed-current status"
if (-not [System.IO.File]::Exists($tabooPath) -or
    -not [System.IO.File]::ReadAllText($tabooPath).Contains($antiDriftRule)) {
    throw "The current anti-drift source-authority policy is missing"
}
$resolvedReceiptPath = if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $null
}
else {
    Resolve-ReceiptTarget -RepositoryRoot $repositoryRoot -RawPath $ReceiptPath
}

Add-Type -AssemblyName System.Net.Http
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(30)
$client.DefaultRequestHeaders.UserAgent.ParseAdd("Runtime.MiRust.com-release-verifier/4")

$redirects = [ordered]@{
    "/"               = "https://tinyrustlm.mirust.com/developer-portal/"
    "/healthz"        = "https://tinyrustlm.mirust.com/developer-portal/"
    "/version.json"   = "https://tinyrustlm.mirust.com/developer-portal/"
    "/llms.txt"       = "https://tinyrustlm.mirust.com/llms.txt"
    "/docs/index.md"  = "https://tinyrustlm.mirust.com/docs/"
    "/.uai/index.uai" = "https://tinyrustlm.mirust.com/docs/long-term-memory.md"
    "/.uai/taboo.uai" = "https://tinyrustlm.mirust.com/docs/long-term-memory.md"
    "/source-facts/"  = "https://tinyrustlm.mirust.com/developer-portal/"
    "/workspace.uai" = "https://tinyrustlm.mirust.com/developer-portal/"
    "/assets/js/site.js" = "https://tinyrustlm.mirust.com/developer-portal/"
    "/assets/css/site.css" = "https://tinyrustlm.mirust.com/developer-portal/"
    "/data/pages.json" = "https://tinyrustlm.mirust.com/developer-portal/"
    "/inc/site.php" = "https://tinyrustlm.mirust.com/developer-portal/"
    "/tools/build-runtime-manifests.js" = "https://tinyrustlm.mirust.com/developer-portal/"
    "/tools/verify-runtime-mirust.sh" = "https://tinyrustlm.mirust.com/developer-portal/"
}
$retiredRoutes = @(
    "/docs/workspace.uai",
    "/DOCS/WORKSPACE.UAI",
    "/docs/workspace.uai/",
    "/docs/workspace.uai?retired=1",
    "/docs/%77orkspace.uai",
    "/docs/workspace%2Euai"
)
$hostileRoutes = @(
    "//docs/workspace.uai",
    "/docs//workspace.uai",
    "/docs/workspace.uai//"
)
$serverBoundaryRoutes = @(
    "/docs/workspace.uai%2F%2F",
    "/%2Fdocs/workspace.uai",
    "/docs/%2577orkspace.uai",
    "/docs/%2e%2e/workspace.uai",
    "/docs/../workspace.uai",
    "/docs/foo%5C..%5Cworkspace.uai",
    "/docs/workspace.uai%3Fignored",
    "/docs/%ZZworkspace.uai",
    "/docs/%00workspace.uai",
    "/docs/%FFworkspace.uai"
)

try {
    try {
        foreach ($entry in $redirects.GetEnumerator()) {
            $sourceUrl = "$BaseUrl$($entry.Key)"
            # HttpClient's typed Location parser normalizes URIs; retain raw field identity.
            $observation = Invoke-RawHttpsObservation -HostName $baseUri.Host `
                -RequestTarget $entry.Key -Method "GET"
            $status = [int]$observation.StatusCode
            $location = Assert-RedirectObservation -StatusCode $status `
                -LocationValues @($observation.LocationValues) -SourceUrl $sourceUrl `
                -ExpectedLocation $entry.Value
            $redirectObservations.Add([ordered]@{
                path = $entry.Key
                source_url = $sourceUrl
                method = "GET"
                status_code = $status
                expected_location = $entry.Value
                actual_location = $location
                status = "pass"
            })
            Write-Host "PASS redirect $($entry.Key) -> $location"
        }

        foreach ($path in $retiredRoutes) {
            foreach ($method in @("GET", "HEAD")) {
                $sourceUrl = "$BaseUrl$path"
                $observation = Invoke-RawHttpsObservation -HostName $baseUri.Host `
                    -RequestTarget $path -Method $method
                Assert-RetiredObservation -Observation $observation
                $retiredRouteObservations.Add([ordered]@{
                    path = $path
                    source_url = $sourceUrl
                    method = $method
                    status_code = 410
                    content_length = 5
                    body_bytes = $observation.BodyBytes.Length
                    body_sha256 = Get-Sha256FromBytes -Bytes $observation.BodyBytes
                    location_absent = $true
                    cache_control = "no-store"
                    robots = "noindex, nofollow"
                    content_type = "text/plain; charset=utf-8"
                    nosniff = $true
                    observation = $observation.Observation
                    status = "pass"
                })
                Write-Host "PASS retired $method $path -> 410"
            }
        }

        foreach ($path in $hostileRoutes) {
            foreach ($method in @("GET", "HEAD")) {
                $sourceUrl = "$BaseUrl$path"
                $observation = Invoke-RawHttpsObservation -HostName $baseUri.Host `
                    -RequestTarget $path -Method $method
                Assert-BadRequestObservation -Observation $observation
                $hostileRouteObservations.Add([ordered]@{
                    path = $path
                    source_url = $sourceUrl
                    method = $method
                    status_code = 400
                    content_length = $script:BadRequestBytes.Length
                    body_bytes = $observation.BodyBytes.Length
                    body_sha256 = Get-Sha256FromBytes -Bytes $observation.BodyBytes
                    location_absent = $true
                    cache_control = "no-store"
                    robots = "noindex, nofollow"
                    content_type = "text/plain; charset=utf-8"
                    nosniff = $true
                    observation = $observation.Observation
                    status = "pass"
                })
                Write-Host "PASS hostile $method $path -> 400"
            }
        }

        foreach ($path in $serverBoundaryRoutes) {
            foreach ($method in @("GET", "HEAD")) {
                $sourceUrl = "$BaseUrl$path"
                $observation = Invoke-RawHttpsObservation -HostName $baseUri.Host `
                    -RequestTarget $path -Method $method
                Assert-ServerBoundaryObservation -Observation $observation
                $serverBoundaryRouteObservations.Add([ordered]@{
                    path = $path
                    source_url = $sourceUrl
                    method = $method
                    status_code = $observation.StatusCode
                    body_bytes = $observation.BodyBytes.Length
                    body_sha256 = Get-Sha256FromBytes -Bytes $observation.BodyBytes
                    location_absent = $true
                    observation = $observation.Observation
                    status = "pass"
                })
                Write-Host "PASS server-boundary $method $path -> $($observation.StatusCode)"
            }
        }

        foreach ($targetUrl in ($redirects.Values | Sort-Object -Unique)) {
            $response = Invoke-RequestWithoutRedirect -Client $client -Method "GET" -Url $targetUrl
            try {
                $status = [int]$response.StatusCode
                if ($status -ne 200) {
                    throw "$targetUrl returned an unexpected HTTP status"
                }
                $readbackObservations.Add([ordered]@{
                    url = $targetUrl
                    method = "GET"
                    status_code = $status
                    status = "pass"
                })
                Write-Host "PASS readback $targetUrl"
            }
            finally {
                $response.Dispose()
            }
        }
    }
    catch {
        $operationFailure = $_
    }
}
finally {
    $client.Dispose()
    $handler.Dispose()
}

if ($null -ne $resolvedReceiptPath) {
    Write-VerificationReceipt -RepositoryRoot $repositoryRoot `
        -TargetPath $resolvedReceiptPath `
        -Origin $BaseUrl `
        -StartedUtc $startedUtc `
        -Redirects $redirectObservations.ToArray() `
        -RetiredRoutes $retiredRouteObservations.ToArray() `
        -HostileRoutes $hostileRouteObservations.ToArray() `
        -ServerBoundaryRoutes $serverBoundaryRouteObservations.ToArray() `
        -Readbacks $readbackObservations.ToArray() `
        -Failure $operationFailure
}
if ($null -ne $operationFailure) {
    throw $operationFailure
}

Write-Host "Verification completed for $BaseUrl"
