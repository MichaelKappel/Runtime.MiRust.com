param(
    [string]$BaseUrl = "https://runtime.mirust.com"
)
$ErrorActionPreference = "Stop"
$BaseUrl = $BaseUrl.TrimEnd('/')
function Test-HeadRoute {
    param([string]$Path)
    $Url = "$BaseUrl$Path"
    Write-Host "==> $Url"
    $response = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 5
    Write-Host "$($response.StatusCode) $($response.StatusDescription)"
}
function Test-BodyRoute {
    param([string]$Path)
    $Url = "$BaseUrl$Path"
    Write-Host "==> body $Url"
    $response = Invoke-WebRequest -Uri $Url -MaximumRedirection 5
    $response.Content.Split("`n") | Select-Object -First 12 | ForEach-Object { Write-Host $_ }
}
Test-HeadRoute "/"
Test-BodyRoute "/healthz"
Test-BodyRoute "/version.json"
Test-BodyRoute "/llms.txt"
Test-BodyRoute "/docs/index.md"
Test-BodyRoute "/.uai/index.uai"
Write-Host "==> Markdown negotiation"
Invoke-WebRequest -Uri "$BaseUrl/source-facts/" -Headers @{ Accept = "text/markdown" } | Select-Object -ExpandProperty Content | ForEach-Object { $_.Split("`n") | Select-Object -First 24 }
Write-Host "Verification completed for $BaseUrl"
