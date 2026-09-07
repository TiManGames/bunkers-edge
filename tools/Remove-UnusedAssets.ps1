[CmdletBinding()]
param(
    [Parameter()]
    [string] $ModRoot = (Split-Path -Parent $PSScriptRoot),

    [Parameter()]
    [string] $ReportPath = (Join-Path $PSScriptRoot 'unused-assets-report.json'),

    [Parameter()]
    [ValidateRange(1, 1440)]
    [int] $MaxReportAgeMinutes = 60,

    [Parameter()]
    [switch] $RefreshReport,

    [Parameter()]
    [switch] $Apply,

    [Parameter()]
    [switch] $Force,

    [Parameter()]
    [switch] $RemoveEmptyDirectories
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

throw 'Disabled: the previous static scanner produced false negatives. This remover will remain disabled until the used-asset graph is independently verified.'

# The remover is deliberately restricted to the two roots inventoried by
# Find-UnusedAssets.ps1. It never accepts a target path outside this list.
$allowedRoots = @('entities', 'static_objects')

function Get-FullPath {
    param([string] $Path)

    return [System.IO.Path]::GetFullPath($Path)
}

function Test-IsPathInside {
    param(
        [string] $Path,
        [string] $ParentPath
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $parentWithSeparator = $ParentPath.TrimEnd([char[]]@('\', '/')) + $separator
    return $Path.StartsWith($parentWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-HasReparsePoint {
    param(
        [string] $Path,
        [string] $StopAt
    )

    $current = Get-Item -LiteralPath $Path
    $stopAtFull = (Get-FullPath -Path $StopAt).TrimEnd([char[]]@('\', '/'))

    while ($true) {
        if (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $true
        }

        if ($current.FullName.TrimEnd([char[]]@('\', '/')).Equals($stopAtFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }

        if ($current -is [System.IO.DirectoryInfo]) {
            $parent = $current.Parent
        }
        else {
            $parent = $current.Directory
        }
        if ($null -eq $parent) {
            throw "Could not walk from '$Path' to '$StopAt'."
        }
        $current = $parent
    }
}

function Get-ReportTarget {
    param(
        [object] $Asset,
        [string] $ModRootFull,
        [hashtable] $AllowedRootPaths
    )

    $relativePath = [string] $Asset.path
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        throw 'The report contains an empty asset path.'
    }

    if ($relativePath -match '^(?:[A-Za-z]:|[\\/])') {
        throw "The report contains a rooted path, which is not allowed: $relativePath"
    }

    $segments = $relativePath.Replace('\', '/') -split '/'
    if (($segments.Count -lt 2) -or ($segments | Where-Object { $_ -in @('', '.', '..') })) {
        throw "The report contains an invalid relative path: $relativePath"
    }

    $rootName = $segments[0].ToLowerInvariant()
    if (-not $AllowedRootPaths.ContainsKey($rootName)) {
        throw "The report target is outside the allowed roots: $relativePath"
    }

    try {
        $fullPath = Get-FullPath -Path (Join-Path $ModRootFull $relativePath)
    }
    catch {
        throw "The report contains an invalid path: $relativePath. $($_.Exception.Message)"
    }

    $allowedRootPath = $AllowedRootPaths[$rootName]
    if (-not (Test-IsPathInside -Path $fullPath -ParentPath $allowedRootPath)) {
        throw "Resolved target escaped its allowed root: $relativePath"
    }

    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "A report target no longer exists: $relativePath. Refresh the scan before deleting."
    }

    if (Test-HasReparsePoint -Path $fullPath -StopAt $allowedRootPath) {
        throw "Refusing to follow a symlink/junction in target path: $relativePath"
    }

    $file = Get-Item -LiteralPath $fullPath
    $expectedBytes = [int64] $Asset.bytes
    if ($Asset.lastWriteTimeUtc -is [datetime]) {
        $expectedLastWrite = ([datetime] $Asset.lastWriteTimeUtc).ToUniversalTime()
    }
    else {
        $expectedLastWrite = [DateTimeOffset]::Parse(
            [string] $Asset.lastWriteTimeUtc,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        ).UtcDateTime
    }

    if ($file.Length -ne $expectedBytes) {
        throw "Target size changed since the scan: $relativePath. Refresh the scan before deleting."
    }

    if ($file.LastWriteTimeUtc.Ticks -ne $expectedLastWrite.Ticks) {
        throw "Target modification time changed since the scan: $relativePath. Refresh the scan before deleting."
    }

    return [pscustomobject]@{
        RelativePath = $relativePath.Replace('\', '/')
        FullPath     = $fullPath
        Root          = $rootName
        Bytes         = $file.Length
    }
}

function Get-ScannerInputsChangedAfter {
    param(
        [string] $ModRootFull,
        [datetime] $GeneratedAtUtc
    )

    $changed = [System.Collections.Generic.List[string]]::new()
    $scanRoots = @('entities', 'static_objects', 'script', 'config', 'maps')
    foreach ($scanRoot in $scanRoots) {
        $directory = Join-Path $ModRootFull $scanRoot
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            continue
        }

        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Recurse -File)) {
            if ($file.LastWriteTimeUtc -gt $GeneratedAtUtc) {
                $changed.Add($file.FullName)
            }
        }
    }

    return $changed
}

$modRootFull = (Get-Item -LiteralPath $ModRoot).FullName.TrimEnd([char[]]@('\', '/'))
$reportPathFull = Get-FullPath -Path $ReportPath
$scannerPath = Join-Path $PSScriptRoot 'Find-UnusedAssets.ps1'

if ($RefreshReport) {
    if (-not (Test-Path -LiteralPath $scannerPath -PathType Leaf)) {
        throw "Cannot refresh: scanner was not found at $scannerPath"
    }

    $textReportPath = [System.IO.Path]::ChangeExtension($reportPathFull, '.txt')
    & $scannerPath -ModRoot $modRootFull -OutputPath $textReportPath -JsonOutputPath $reportPathFull
}

if (-not (Test-Path -LiteralPath $reportPathFull -PathType Leaf)) {
    throw "Report not found: $reportPathFull. Run Find-UnusedAssets.ps1 first or pass -RefreshReport."
}

$report = Get-Content -LiteralPath $reportPathFull -Raw | ConvertFrom-Json
if ([int] $report.schemaVersion -lt 2) {
    throw 'This report predates the deletion safety fields. Run Find-UnusedAssets.ps1 again before deleting.'
}
if ([string] $report.mode -ne 'report-only') {
    throw 'The report is not a report-only unused-assets scan.'
}
if (-not ((Get-FullPath -Path ([string] $report.modRoot)).TrimEnd([char[]]@('\', '/')).Equals($modRootFull, [System.StringComparison]::OrdinalIgnoreCase))) {
    throw 'The report belongs to a different mod root.'
}

if ($report.generatedAt -is [datetime]) {
    $generatedAtUtc = ([datetime] $report.generatedAt).ToUniversalTime()
}
else {
    $generatedAtUtc = [DateTimeOffset]::Parse(
        [string] $report.generatedAt,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    ).UtcDateTime
}
$age = (Get-Date).ToUniversalTime() - $generatedAtUtc
if ($age.TotalMinutes -gt $MaxReportAgeMinutes) {
    throw ("The report is {0:N1} minutes old (limit: {1}). Run with -RefreshReport before deleting." -f $age.TotalMinutes, $MaxReportAgeMinutes)
}

$changedInputs = @(Get-ScannerInputsChangedAfter -ModRootFull $modRootFull -GeneratedAtUtc $generatedAtUtc)
if ($changedInputs.Count -gt 0) {
    $sample = ($changedInputs | Select-Object -First 5) -join '; '
    throw ("Mod inputs changed after the scan ({0} files; for example: {1}). Run with -RefreshReport before deleting." -f $changedInputs.Count, $sample)
}

$allowedRootPaths = @{}
foreach ($root in $allowedRoots) {
    $path = Join-Path $modRootFull $root
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "Allowed asset root is missing: $path"
    }
    $allowedRootPaths[$root] = (Get-Item -LiteralPath $path).FullName.TrimEnd([char[]]@('\', '/'))
}

$targets = [System.Collections.Generic.List[object]]::new()
$seenTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($asset in @($report.unusedAssets)) {
    $target = Get-ReportTarget -Asset $asset -ModRootFull $modRootFull -AllowedRootPaths $allowedRootPaths
    if (-not $seenTargets.Add($target.FullPath)) {
        throw "The report contains a duplicate target: $($target.RelativePath)"
    }
    $targets.Add($target)
}

$totalBytes = ($targets | Measure-Object -Property Bytes -Sum).Sum
if ($null -eq $totalBytes) {
    $totalBytes = 0
}

Write-Host ''
Write-Host 'BunkersEdge unused asset removal plan' -ForegroundColor Yellow
Write-Host ("Validated targets: {0} ({1:N0} bytes)" -f $targets.Count, $totalBytes)
Write-Host ("Report: {0}" -f $reportPathFull)
Write-Host 'Allowed roots: entities/, static_objects/'

if (-not $Apply) {
    Write-Host ''
    Write-Host 'PREVIEW ONLY: no files were deleted. Use -Apply to perform this validated plan.' -ForegroundColor Green
    Write-Host 'First 25 targets:'
    $targets | Select-Object -First 25 RelativePath, Bytes | Format-Table -AutoSize
    return
}

if (-not $Force) {
    $expectedConfirmation = "DELETE $($targets.Count)"
    $answer = Read-Host "Type '$expectedConfirmation' to permanently delete the validated files"
    if ($answer -ne $expectedConfirmation) {
        Write-Warning 'Deletion cancelled. No files were deleted.'
        return
    }
}

$logPath = Join-Path $PSScriptRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-unused-assets-deletion.json')
$deleted = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[object]]::new()

foreach ($target in $targets) {
    try {
        # Revalidate immediately before deletion to reduce the chance of acting
        # on a file changed after the report was validated.
        $file = Get-Item -LiteralPath $target.FullPath -ErrorAction Stop
        if ($file.Length -ne $target.Bytes) {
            throw 'Size changed after validation.'
        }
        [System.IO.File]::Delete($target.FullPath)
        $deleted.Add([ordered]@{ path = $target.RelativePath; bytes = $target.Bytes })
    }
    catch {
        $failures.Add([ordered]@{ path = $target.RelativePath; error = $_.Exception.Message })
    }
}

$deletedDirectories = [System.Collections.Generic.List[string]]::new()
if ($RemoveEmptyDirectories) {
    foreach ($rootPath in $allowedRootPaths.Values) {
        $directories = @(Get-ChildItem -LiteralPath $rootPath -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending)
        foreach ($directory in $directories) {
            if (Test-HasReparsePoint -Path $directory.FullName -StopAt $rootPath) {
                $failures.Add([ordered]@{ path = $directory.FullName; error = 'Refused to remove a symlink/junction directory.' })
                continue
            }
            try {
                [System.IO.Directory]::Delete($directory.FullName, $false)
                $deletedDirectories.Add($directory.FullName)
            }
            catch [System.IO.IOException] {
                # Non-empty directories are expected and are intentionally kept.
            }
            catch {
                $failures.Add([ordered]@{ path = $directory.FullName; error = $_.Exception.Message })
            }
        }
    }
}

$deletionLog = [ordered]@{
    schemaVersion = 1
    generatedAt = (Get-Date).ToString('o')
    reportPath = $reportPathFull
    modRoot = $modRootFull
    deletedFiles = @($deleted)
    deletedDirectories = @($deletedDirectories)
    failures = @($failures)
}
[System.IO.File]::WriteAllText($logPath, ($deletionLog | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))

Write-Host ("Deleted files: {0}" -f $deleted.Count) -ForegroundColor Green
Write-Host ("Deletion log: {0}" -f $logPath)
if ($failures.Count -gt 0) {
    throw ("Deletion completed with {0} failure(s). Review: {1}" -f $failures.Count, $logPath)
}
