param(
    [string]$BaseUrl = "https://runtime.mirust.com"
)

$ErrorActionPreference = "Stop"
$BaseUrl = $BaseUrl.TrimEnd('/')

Add-Type -AssemblyName System.Net.Http

$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(30)
$client.DefaultRequestHeaders.UserAgent.ParseAdd("Runtime.MiRust.com-release-verifier/1")

$redirects = [ordered]@{
    "/"              = "https://tinyrustlm.mirust.com/developer-portal/"
    "/healthz"       = "https://tinyrustlm.mirust.com/docs/runtime-portal/package/healthz"
    "/version.json"  = "https://tinyrustlm.mirust.com/docs/runtime-portal/package/version.json"
    "/llms.txt"      = "https://tinyrustlm.mirust.com/llms.txt"
    "/docs/index.md" = "https://tinyrustlm.mirust.com/docs/runtime-portal/runtime-docs/index.md"
    "/.uai/index.uai" = "https://tinyrustlm.mirust.com/docs/runtime-portal/runtime-docs/long-term-memory.uai"
    "/source-facts/" = "https://tinyrustlm.mirust.com/developer-portal/"
}

function Invoke-GetWithoutRedirect {
    param([Parameter(Mandatory)][string]$Url)

    return $client.GetAsync($Url).GetAwaiter().GetResult()
}

try {
    foreach ($entry in $redirects.GetEnumerator()) {
        $sourceUrl = "$BaseUrl$($entry.Key)"
        $response = Invoke-GetWithoutRedirect -Url $sourceUrl
        try {
            $status = [int]$response.StatusCode
            if ($status -notin @(301, 302, 307, 308)) {
                throw "$sourceUrl returned HTTP $status; expected a redirect"
            }

            $location = $response.Headers.Location
            if ($null -eq $location) {
                throw "$sourceUrl returned HTTP $status without a Location header"
            }

            $resolved = if ($location.IsAbsoluteUri) {
                $location.AbsoluteUri
            }
            else {
                [Uri]::new([Uri]$sourceUrl, $location).AbsoluteUri
            }

            if ($resolved -cne $entry.Value) {
                throw "$sourceUrl redirected to $resolved; expected $($entry.Value)"
            }

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
                throw "$targetUrl returned HTTP $status; expected 200"
            }
            Write-Host "PASS readback $targetUrl"
        }
        finally {
            $response.Dispose()
        }
    }
}
finally {
    $client.Dispose()
    $handler.Dispose()
}

Write-Host "Verification completed for $BaseUrl"
