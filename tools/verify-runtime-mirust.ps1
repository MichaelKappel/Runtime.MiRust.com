param(
    [string]$BaseUrl = "https://runtime.mirust.com",
    [string]$ReceiptPath = ""
)

$ErrorActionPreference = "Stop"
$script:ReceiptMaximumBytes = 65536
$script:ReceiptProfile = "runtime.mirust.redirect-verification.v1"
$startedUtc = [DateTimeOffset]::UtcNow
$redirectObservations = [System.Collections.Generic.List[object]]::new()
$readbackObservations = [System.Collections.Generic.List[object]]::new()
$operationFailure = $null

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
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
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
        "redirects-and-destinations-verified"
    }
    else {
        "failed"
    }

    $receipt = [ordered]@{
        schema = "runtime.mirust.redirect_verification_receipt.v1"
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
        readbacks = $Readbacks
    }

    $json = $receipt | ConvertTo-Json -Depth 8
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes("$json`n")
    Write-CreateOnlyReceipt -TargetPath $TargetPath -Bytes $bytes
    Write-Host "RECEIPT $TargetPath"
}

$baseUri = $null
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
$client.DefaultRequestHeaders.UserAgent.ParseAdd("Runtime.MiRust.com-release-verifier/1")

$redirects = [ordered]@{
    "/"               = "https://tinyrustlm.mirust.com/developer-portal/"
    "/healthz"        = "https://tinyrustlm.mirust.com/docs/runtime-portal/package/healthz"
    "/version.json"   = "https://tinyrustlm.mirust.com/docs/runtime-portal/package/version.json"
    "/llms.txt"       = "https://tinyrustlm.mirust.com/llms.txt"
    "/docs/index.md"  = "https://tinyrustlm.mirust.com/docs/runtime-portal/runtime-docs/index.md"
    "/.uai/index.uai" = "https://tinyrustlm.mirust.com/docs/runtime-portal/runtime-docs/long-term-memory.uai"
    "/source-facts/"  = "https://tinyrustlm.mirust.com/developer-portal/"
}

function Invoke-GetWithoutRedirect {
    param([Parameter(Mandatory)][string]$Url)

    return $client.GetAsync($Url).GetAwaiter().GetResult()
}

try {
    try {
        foreach ($entry in $redirects.GetEnumerator()) {
            $sourceUrl = "$BaseUrl$($entry.Key)"
            $response = Invoke-GetWithoutRedirect -Url $sourceUrl
            try {
                $status = [int]$response.StatusCode
                if ($status -notin @(301, 302, 307, 308)) {
                    throw "$sourceUrl returned an unexpected HTTP status"
                }
                $location = $response.Headers.Location
                if ($null -eq $location) {
                    throw "$sourceUrl returned a redirect without a Location header"
                }
                $resolved = if ($location.IsAbsoluteUri) {
                    $location.AbsoluteUri
                }
                else {
                    [Uri]::new([Uri]$sourceUrl, $location).AbsoluteUri
                }
                if ($resolved -cne $entry.Value) {
                    throw "$sourceUrl returned an unexpected redirect target"
                }
                $redirectObservations.Add([ordered]@{
                    path = $entry.Key
                    source_url = $sourceUrl
                    status_code = $status
                    expected_location = $entry.Value
                    actual_location = $resolved
                    status = "pass"
                })
                Write-Host "PASS redirect $($entry.Key) -> $resolved"
            }
            finally {
                $response.Dispose()
            }
        }

        foreach ($targetUrl in ($redirects.Values | Sort-Object -Unique)) {
            $response = Invoke-GetWithoutRedirect -Url $targetUrl
            try {
                $status = [int]$response.StatusCode
                if ($status -ne 200) {
                    throw "$targetUrl returned an unexpected HTTP status"
                }
                $readbackObservations.Add([ordered]@{
                    url = $targetUrl
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
        -Readbacks $readbackObservations.ToArray() `
        -Failure $operationFailure
}
if ($null -ne $operationFailure) {
    throw $operationFailure
}

Write-Host "Verification completed for $BaseUrl"
