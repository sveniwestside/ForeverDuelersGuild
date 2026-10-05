<#
.SYNOPSIS
Installs the ForeverDuel addon folder into a WoW AddOns directory for live testing.

.DESCRIPTION
Every live test must map to an exact commit. The script therefore refuses to
install uncommitted addon sources (unless -AllowDirty), stamps the commit into
the installed TOC as "## X-Build: <sha>", backs up the previous installation,
verifies every copied file by SHA-256 and never touches SavedVariables.

.EXAMPLE
pwsh tools/install-addon.ps1 -AddOnsDirectory "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns"
#>
param(
    [Parameter(Mandatory = $true)][string]$AddOnsDirectory,
    [switch]$AllowDirty
)
$ErrorActionPreference = 'Stop'

$repository = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$source = (Resolve-Path -LiteralPath (Join-Path $repository 'ForeverDuel')).Path
$addOns = (Resolve-Path -LiteralPath $AddOnsDirectory).Path
if ((Split-Path -Leaf $addOns) -ne 'AddOns') { throw "Expected an Interface\AddOns directory, got: $addOns" }
$target = Join-Path $addOns 'ForeverDuel'

$status = git -C $repository status --porcelain -- ForeverDuel
if ($LASTEXITCODE -ne 0) { throw 'git is required to identify the installed build.' }
if ($status -and -not $AllowDirty) {
    throw "Uncommitted changes in ForeverDuel/. Commit them first (or pass -AllowDirty for a throwaway test):`n$status"
}
$sha = (git -C $repository rev-parse --short=12 HEAD).Trim()
if ($status) { $sha = "$sha-dirty" }
$version = ((Get-Content -LiteralPath (Join-Path $source 'ForeverDuel.toc') | Select-String '^## Version:').Line -replace '^## Version:\s*', '').Trim()

$backupRoot = Join-Path $repository 'dist\installation-backups'
$backup = $null
if (Test-Path -LiteralPath $target) {
    $previous = ((Get-Content -LiteralPath (Join-Path $target 'ForeverDuel.toc') -ErrorAction SilentlyContinue |
        Select-String '^## Version:').Line -replace '^## Version:\s*', '').Trim()
    $backup = Join-Path $backupRoot ("before-$version-from-$previous-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $backup | Out-Null
    Copy-Item -LiteralPath $target -Destination $backup -Recurse
    # Remove the old copy so files deleted from the source cannot linger.
    Remove-Item -LiteralPath $target -Recurse -Force
}
New-Item -ItemType Directory -Path $target | Out-Null

$files = @()
foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse) {
    $relative = $file.FullName.Substring($source.Length + 1)
    $destination = Join-Path $target $relative
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    if ($relative -eq 'ForeverDuel.toc') {
        $lines = Get-Content -LiteralPath $file.FullName | Where-Object { $_ -notmatch '^## X-Build:' }
        $stamped = @()
        foreach ($line in $lines) {
            $stamped += $line
            if ($line -match '^## Version:') { $stamped += "## X-Build: $sha" }
        }
        [IO.File]::WriteAllLines($destination, [string[]]$stamped, (New-Object Text.UTF8Encoding $false))
    } else {
        Copy-Item -LiteralPath $file.FullName -Destination $destination
        $expected = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $expected) { throw "Copy mismatch: $relative" }
    }
    $files += $relative
}
$modules = @(Get-Content -LiteralPath (Join-Path $target 'ForeverDuel.toc') | Where-Object { $_ -match '^[\w]+\.lua\s*$' })
foreach ($module in $modules) {
    if (-not (Test-Path -LiteralPath (Join-Path $target $module.Trim()))) { throw "Missing module listed in TOC: $module" }
}
[PSCustomObject]@{
    version = $version; build = $sha; installed = $target; backup = $backup
    files = $files.Count; tocModules = $modules.Count; savedVariablesModified = $false
} | ConvertTo-Json -Compress
