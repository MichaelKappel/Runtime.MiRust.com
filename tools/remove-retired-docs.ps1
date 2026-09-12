[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param()

$ErrorActionPreference = 'Stop'
$repository = 'E:\Source\Rust\Runtime.MiRust.com'
$target = [IO.Path]::GetFullPath((Join-Path $repository 'docs'))
$evidenceRoot = Join-Path $repository 'artifacts\ecosystem-cleanup-20260912'
$inventoryPath = Join-Path $evidenceRoot 'retired-docs-inventory.json'
$receiptPath = Join-Path $evidenceRoot 'retired-docs-deletion-receipt.json'
$inventorySha = 'F5FB888BE1D1AFF4B88958DF546A30A13056FCAF8DC2EF152C8A724094A74C08'

# Require exact direct ancestry before reading or removing any named member.
function Assert-DirectPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse point is not allowed: $current"
        }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

Assert-DirectPath $inventoryPath
if ((Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash -cne $inventorySha) {
    throw 'Reviewed document inventory changed.'
}
$inventory = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
if ($inventory.source -cne $target -or @($inventory.files).Count -ne 174) { throw 'Unexpected inventory.' }
$pending = [Collections.Generic.List[object]]::new()
$named = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($row in $inventory.files) {
    if ($row.path -cnotmatch '^docs/[^:]+$' -or $row.path -match '\\|(^|/)\.\.?(/|$)') {
        throw 'Noncanonical reviewed path.'
    }
    $absolute = [IO.Path]::GetFullPath((Join-Path $repository ($row.path -replace '/', '\')))
    if (-not $absolute.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not $named.Add($absolute)) { throw 'Cleanup path escaped or duplicated its exact root.' }
    if (-not (Test-Path -LiteralPath $absolute)) { continue }
    Assert-DirectPath $absolute
    $item = Get-Item -LiteralPath $absolute -Force
    if ($item.PSIsContainer -or $item.Length -ne $row.bytes -or
        (Get-FileHash -LiteralPath $absolute -Algorithm SHA256).Hash -ine $row.sha256) {
        throw "Reviewed document changed: $($row.path)"
    }
    $pending.Add([pscustomobject]@{ Absolute = $absolute; Row = $row })
}
if (Test-Path -LiteralPath $target) {
    Assert-DirectPath $target
    foreach ($item in Get-ChildItem -LiteralPath $target -Recurse -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            (-not $item.PSIsContainer -and -not $named.Contains($item.FullName))) {
            throw 'Unreviewed entry exists; no deletion was attempted.'
        }
    }
}

$deleted = 0
foreach ($entry in $pending) {
    if ($PSCmdlet.ShouldProcess($entry.Absolute, 'Delete reviewed obsolete document; history is in Git d395307')) {
        Assert-DirectPath $entry.Absolute
        if ((Get-FileHash -LiteralPath $entry.Absolute -Algorithm SHA256).Hash -ine $entry.Row.sha256) {
            throw 'Document changed after preflight.'
        }
        Remove-Item -LiteralPath $entry.Absolute -Force
        if (Test-Path -LiteralPath $entry.Absolute) { throw 'Deleted document remains.' }
        $deleted++
    }
}
if ($WhatIfPreference) {
    Write-Output "Validated $($pending.Count) remaining reviewed documents; no changes made."
    return
}
if (Test-Path -LiteralPath $target) {
    $directories = @(Get-ChildItem -LiteralPath $target -Recurse -Force -Directory | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($directory in $directories) {
        $absolute = [IO.Path]::GetFullPath($directory.FullName)
        if (-not $absolute.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Directory escaped cleanup root.' }
        Assert-DirectPath $absolute
        if (@(Get-ChildItem -LiteralPath $absolute -Force).Count -eq 0) { [IO.Directory]::Delete($absolute) }
    }
    Assert-DirectPath $target
    if (@(Get-ChildItem -LiteralPath $target -Force).Count -eq 0) { [IO.Directory]::Delete($target) }
}
$remaining = @($named | Where-Object { Test-Path -LiteralPath $_ }).Count
$receipt = [ordered]@{ inventory_sha256 = $inventorySha; deleted_this_run = $deleted; remaining = $remaining;
    docs_root_absent = -not (Test-Path -LiteralPath $target); verified_utc = [DateTime]::UtcNow.ToString('o') }
Assert-DirectPath $evidenceRoot
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
if ($remaining -ne 0 -or -not $receipt.docs_root_absent) { throw 'Cleanup is incomplete.' }
