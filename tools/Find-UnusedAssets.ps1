[CmdletBinding()]
param(
    [Parameter()]
    [string] $ModRoot = (Split-Path -Parent $PSScriptRoot),

    [Parameter()]
    [string] $OutputPath = (Join-Path $PSScriptRoot 'unused-assets-report.txt'),

    [Parameter()]
    [string] $JsonOutputPath = (Join-Path $PSScriptRoot 'unused-assets-report.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This is intentionally a report-only tool. It contains no deletion operation.
$assetRoots = @('entities', 'static_objects')

$knownAssetExtensions = @(
    '.ent', '.dae', '.msh', '.fbx', '.lxo', '.obj',
    '.anm', '.dae_anim', '.anno',
    '.mat', '.dds', '.tga', '.png', '.jpg', '.jpeg', '.bmp', '.psd',
    '.ogg', '.wav', '.flac', '.fsb', '.fev', '.fdp', '.snt',
    '.ps', '.fnt', '.ttf', '.otf', '.xml'
)

$dependencyCarrierExtensions = @(
    '.ent', '.dae', '.msh', '.fbx', '.lxo', '.obj',
    '.anm', '.dae_anim', '.anno', '.mat', '.ps', '.fnt',
    '.fev', '.fsb', '.fdp', '.snt', '.xml'
)

$ignoredRootExtensions = @(
    '.db', '.map_cache', '.preload_cache', '.nodes', '.gen_node_cache',
    '.expobj', '.bak', '.tmp'
)

function Get-NormalizedExtension {
    param([string] $Path)

    $name = [System.IO.Path]::GetFileName($Path).ToLowerInvariant()
    if ($name.EndsWith('.dae_anim')) {
        return '.dae_anim'
    }

    return [System.IO.Path]::GetExtension($name).ToLowerInvariant()
}

function Get-RelativeModPath {
    param(
        [string] $FullPath,
        [string] $RootPath
    )

    return $FullPath.Substring($RootPath.Length).TrimStart([char[]]@('\', '/')).Replace('\', '/')
}

function Get-PathKey {
    param([string] $Path)

    return $Path.Replace('\', '/').TrimStart('/').ToLowerInvariant()
}

function Test-StartsWithAssetRoot {
    param([string] $RelativePath)

    $firstPart = ($RelativePath.Replace('\', '/') -split '/', 2)[0]
    return $assetRoots -contains $firstPart.ToLowerInvariant()
}

function Test-IsCandidateAsset {
    param([string] $RelativePath)

    if (-not (Test-StartsWithAssetRoot -RelativePath $RelativePath)) {
        return $false
    }

    if ((Get-NormalizedExtension -Path $RelativePath) -in @('.db', '.tmp', '.bak', '.preload_cache')) {
        return $false
    }

    $root = ($RelativePath.Replace('\', '/') -split '/', 2)[0].ToLowerInvariant()
    # Every custom file under these two mod roots belongs in the inventory,
    # including source/compiled sidecars with less common extensions.
    return $true
}

$modRootItem = Get-Item -LiteralPath $ModRoot
$modRootFull = $modRootItem.FullName.TrimEnd([char[]]@('\', '/'))
$modName = $modRootItem.Name
$modRootForward = $modRootFull.Replace('\', '/')

$allFiles = @(Get-ChildItem -LiteralPath $modRootFull -Recurse -File)
$allFilesByKey = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$candidateByKey = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($file in $allFiles) {
    $relativePath = Get-RelativeModPath -FullPath $file.FullName -RootPath $modRootFull
    $key = Get-PathKey -Path $relativePath
    $record = [pscustomobject]@{
        Key          = $key
        RelativePath = $relativePath
        FullPath     = $file.FullName
        Length       = $file.Length
        LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
        Extension    = Get-NormalizedExtension -Path $relativePath
        Root         = ($relativePath -split '/', 2)[0].ToLowerInvariant()
    }

    $allFilesByKey[$key] = $record
    if (Test-IsCandidateAsset -RelativePath $relativePath) {
        $candidateByKey[$key] = $record
    }
}

$usedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$queuedKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$dependencyQueue = [System.Collections.Generic.Queue[string]]::new()
$reasonByKey = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
$warnings = [System.Collections.Generic.List[string]]::new()
$staleMapIndexEntries = [System.Collections.Generic.List[object]]::new()
$indexedReferencesResolved = 0
$rootFilesScanned = 0
$dependencyFilesScanned = 0
$exactReferencesResolved = 0
$extensionInferredReferencesResolved = 0

function Add-Reason {
    param(
        [string] $Key,
        [string] $Reason
    )

    if (-not $reasonByKey.ContainsKey($Key)) {
        $reasonByKey[$Key] = [System.Collections.Generic.List[string]]::new()
    }

    if (($reasonByKey[$Key].Count -lt 5) -and (-not $reasonByKey[$Key].Contains($Reason))) {
        $reasonByKey[$Key].Add($Reason)
    }
}

function Add-CompanionAssets {
    param(
        [string] $Key,
        [string] $SourceDescription
    )

    $record = $candidateByKey[$Key]
    $extension = $record.Extension
    $stem = $record.RelativePath.Substring(0, $record.RelativePath.Length - $extension.Length)
    $companionExtensions = @()

    switch ($extension) {
        '.dae'      { $companionExtensions = @('.msh', '.fbx', '.mat') }
        '.msh'      { $companionExtensions = @('.dae', '.fbx', '.mat') }
        '.fbx'      { $companionExtensions = @('.msh', '.dae', '.mat', '.anm', '.dae_anim', '.anno') }
        '.mat'      { $companionExtensions = @('.dae', '.msh', '.fbx') }
        '.anm'      { $companionExtensions = @('.dae_anim', '.fbx', '.anno') }
        '.dae_anim' { $companionExtensions = @('.anm', '.fbx', '.anno') }
        '.anno'     { $companionExtensions = @('.anm', '.dae_anim', '.fbx') }
        '.dds'      { $companionExtensions = @('.png', '.tga', '.psd') }
        '.png'      { $companionExtensions = @('.dds', '.tga', '.psd') }
        '.tga'      { $companionExtensions = @('.dds', '.png', '.psd') }
        '.psd'      { $companionExtensions = @('.dds', '.png', '.tga') }
        '.ogg'      { $companionExtensions = @('.wav') }
        '.wav'      { $companionExtensions = @('.ogg') }
    }

    foreach ($companionExtension in $companionExtensions) {
        $companionKey = Get-PathKey -Path ($stem + $companionExtension)
        if ($candidateByKey.ContainsKey($companionKey)) {
            Add-UsedAsset -Key $companionKey -Reason ("Companion of {0} ({1})" -f $record.RelativePath, $SourceDescription) -SkipCompanions
        }
    }
}

function Add-UsedAsset {
    param(
        [string] $Key,
        [string] $Reason,
        [switch] $SkipCompanions
    )

    if (-not $candidateByKey.ContainsKey($Key)) {
        return
    }

    Add-Reason -Key $Key -Reason $Reason
    $wasAdded = $usedKeys.Add($Key)
    if ($wasAdded -and $queuedKeys.Add($Key)) {
        $dependencyQueue.Enqueue($Key)
    }

    if ($wasAdded -and (-not $SkipCompanions)) {
        Add-CompanionAssets -Key $Key -SourceDescription $Reason
    }
}

function Convert-ReferenceToKey {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    $candidate = [System.Uri]::UnescapeDataString($Value).Replace('\', '/').Trim()
    $candidate = $candidate.Trim([char[]]@('"', "'", '`', '(', ')', '[', ']', '{', '}', ',', ';'))
    $candidate = $candidate -replace '^file:/+', ''
    $candidate = $candidate -replace '[?#].*$', ''

    $escapedModRoot = [regex]::Escape($modRootForward)
    $candidate = $candidate -replace ("(?i)^" + $escapedModRoot + '/?'), ''

    $modMarkerPattern = '(?i)(?:^|/)mods/' + [regex]::Escape($modName) + '/'
    $markerMatch = [regex]::Match($candidate, $modMarkerPattern)
    if ($markerMatch.Success) {
        $candidate = $candidate.Substring($markerMatch.Index + $markerMatch.Length)
    }

    $assetRootPattern = '(?i)(?:^|/)(?:' + (($assetRoots | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')/'
    $rootMatch = [regex]::Match($candidate, $assetRootPattern)
    if ($rootMatch.Success -and $rootMatch.Index -gt 0) {
        $candidate = $candidate.Substring($rootMatch.Index + 1)
    }

    $candidate = $candidate.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    return Get-PathKey -Path $candidate
}

function Add-ReferenceValue {
    param(
        [string] $Value,
        [string] $SourceDescription,
        [switch] $IndexedReference
    )

    # Almost all engine asset references are rooted paths. This fast rejection
    # avoids normalizing every numeric/name attribute in large HPM tracks.
    if ($Value -notmatch '[\\/]') {
        return
    }

    $key = Convert-ReferenceToKey -Value $Value
    if ([string]::IsNullOrWhiteSpace($key)) {
        return
    }

    if ($candidateByKey.ContainsKey($key)) {
        Add-UsedAsset -Key $key -Reason $SourceDescription
        $script:exactReferencesResolved++
        if ($IndexedReference) {
            $script:indexedReferencesResolved++
        }
        return
    }

    # Reference values can contain HPL syntax characters which are illegal in a
    # Windows filesystem path. Do not pass untrusted extracted text to
    # System.IO.Path.GetExtension().
    if (-not [regex]::IsMatch($key, '(?i)\.[a-z0-9_]+$')) {
        $matches = [System.Collections.Generic.List[string]]::new()
        foreach ($extension in $knownAssetExtensions) {
            $possibleKey = $key + $extension
            if ($candidateByKey.ContainsKey($possibleKey)) {
                $matches.Add($possibleKey)
            }
        }

        if ($matches.Count -eq 1) {
            Add-UsedAsset -Key $matches[0] -Reason ("{0} [extension inferred]" -f $SourceDescription)
            $script:extensionInferredReferencesResolved++
        }
    }
}

function Get-ReferenceValuesFromText {
    param([string] $Text)

    $results = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($match in [regex]::Matches($Text, '["''](?<value>[^"''\r\n]+)["'']')) {
        [void] $results.Add($match.Groups['value'].Value)
    }

    $escapedExtensions = $knownAssetExtensions | ForEach-Object { [regex]::Escape($_.TrimStart('.')) }
    # Start at a known resource root. A previous broad prefix expression could
    # backtrack heavily on multi-megabyte HPM/XML files.
    $pathPattern = '(?i)(?:mods[\\/]+[^\\/]+[\\/]+)?(?:' + (($assetRoots | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')[\\/][a-z0-9_ .()\-\\/]+?\.(?:' + ($escapedExtensions -join '|') + ')'
    foreach ($match in [regex]::Matches($Text, $pathPattern)) {
        [void] $results.Add($match.Value.Trim())
    }

    return $results
}

function Add-ReferencesFromText {
    param(
        [string] $Text,
        [string] $SourceDescription
    )

    foreach ($value in (Get-ReferenceValuesFromText -Text $Text)) {
        Add-ReferenceValue -Value $value -SourceDescription $SourceDescription
    }
}

function Get-PrintableBinaryStrings {
    param([byte[]] $Bytes)

    $results = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $asciiText = [System.Text.Encoding]::ASCII.GetString($Bytes)
    foreach ($match in [regex]::Matches($asciiText, '[\x20-\x7E]{4,}')) {
        [void] $results.Add($match.Value)
    }

    if ($Bytes.Length -ge 8) {
        $unicodeText = [System.Text.Encoding]::Unicode.GetString($Bytes)
        foreach ($match in [regex]::Matches($unicodeText, '[\x20-\x7E]{4,}')) {
            [void] $results.Add($match.Value)
        }
    }

    return $results
}

function Add-ReferencesFromFile {
    param(
        [object] $FileRecord,
        [string] $SourceDescription
    )

    $extension = $FileRecord.Extension
    $textExtensions = @(
        '.ent', '.dae', '.mat', '.ps', '.fnt', '.fdp', '.snt', '.xml',
        '.hps', '.cfg', '.lang', '.voice', '.swd', '.hpc', '.txt', '.json'
    )

    if ($extension -in $textExtensions -or $FileRecord.RelativePath -match '(?i)\.hpm(?:_|$)') {
        $text = Get-Content -LiteralPath $FileRecord.FullPath -Raw
        Add-ReferencesFromText -Text $text -SourceDescription $SourceDescription
        return
    }

    if ($extension -notin $dependencyCarrierExtensions) {
        return
    }

    if ($FileRecord.Length -gt 134217728) {
        $warnings.Add(("Skipped binary dependency scan over 128 MiB: {0}" -f $FileRecord.RelativePath))
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($FileRecord.FullPath)
    foreach ($printableString in (Get-PrintableBinaryStrings -Bytes $bytes)) {
        foreach ($value in (Get-ReferenceValuesFromText -Text $printableString)) {
            Add-ReferenceValue -Value $value -SourceDescription $SourceDescription
        }
    }
}

function Test-IsInsideFileIndex {
    param([System.Xml.XmlElement] $Element)

    $parent = $Element.ParentNode
    while ($null -ne $parent -and $parent -is [System.Xml.XmlElement]) {
        if ($parent.LocalName.StartsWith('FileIndex_', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        $parent = $parent.ParentNode
    }

    return $false
}

function Scan-HpmFile {
    param([object] $FileRecord)

    try {
        [xml] $xml = Get-Content -LiteralPath $FileRecord.FullPath -Raw
    }
    catch {
        $warnings.Add(("Could not parse HPM XML; conservatively scanned raw text: {0}: {1}" -f $FileRecord.RelativePath, $_.Exception.Message))
        Add-ReferencesFromFile -FileRecord $FileRecord -SourceDescription ("Malformed HPM fallback: {0}" -f $FileRecord.RelativePath)
        return
    }

    foreach ($section in @($xml.SelectNodes('//*[local-name()="Section"]'))) {
        $sectionName = [string] $section.GetAttribute('Name')
        foreach ($indexNode in @($section.SelectNodes('.//*[starts-with(local-name(), "FileIndex_")]'))) {
            $filesById = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($fileNode in @($indexNode.SelectNodes('./*[local-name()="File"]'))) {
                $filesById[[string] $fileNode.GetAttribute('Id')] = [string] $fileNode.GetAttribute('Path')
            }

            $usedIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($objectNode in @($section.SelectNodes('.//*[@FileIndex]'))) {
                [void] $usedIds.Add([string] $objectNode.GetAttribute('FileIndex'))
            }

            foreach ($id in $usedIds) {
                if ($filesById.ContainsKey($id)) {
                    Add-ReferenceValue -Value $filesById[$id] -SourceDescription ("HPM indexed object: {0}; section={1}; FileIndex={2}" -f $FileRecord.RelativePath, $sectionName, $id) -IndexedReference
                }
                else {
                    $warnings.Add(("Missing HPM index entry: {0}; section={1}; FileIndex={2}" -f $FileRecord.RelativePath, $sectionName, $id))
                }
            }

            foreach ($entry in $filesById.GetEnumerator()) {
                if (-not $usedIds.Contains($entry.Key)) {
                    $staleKey = Convert-ReferenceToKey -Value $entry.Value
                    if ((-not [string]::IsNullOrWhiteSpace($staleKey)) -and $candidateByKey.ContainsKey($staleKey)) {
                        $staleMapIndexEntries.Add([pscustomobject]@{
                            TrackFile = $FileRecord.RelativePath
                            Section   = $sectionName
                            IndexType = $indexNode.LocalName
                            IndexId   = $entry.Key
                            Path      = $candidateByKey[$staleKey].RelativePath
                        })
                    }
                }
            }
        }
    }

    foreach ($element in @($xml.SelectNodes('//*'))) {
        if ((Test-IsInsideFileIndex -Element $element) -or $null -eq $element.Attributes) {
            continue
        }

        foreach ($attribute in @($element.Attributes)) {
            Add-ReferenceValue -Value ([string] $attribute.Value) -SourceDescription ("HPM attribute: {0}; {1}@{2}" -f $FileRecord.RelativePath, $element.LocalName, $attribute.Name)
        }
    }
}

$rootSourceTopDirectories = @('maps', 'script', 'config')
foreach ($file in $allFiles) {
    $relativePath = Get-RelativeModPath -FullPath $file.FullName -RootPath $modRootFull
    $key = Get-PathKey -Path $relativePath
    if ($candidateByKey.ContainsKey($key)) {
        continue
    }

    $extension = Get-NormalizedExtension -Path $relativePath
    if ($extension -in $ignoredRootExtensions) {
        continue
    }

    $parts = $relativePath -split '/', 2
    $isTopLevelFile = $parts.Count -eq 1
    $isRootSource = $isTopLevelFile -or ($parts[0].ToLowerInvariant() -in $rootSourceTopDirectories)
    if (-not $isRootSource) {
        continue
    }

    # From maps, only the main HPM, indexed entity/static-object tracks, and
    # map scripts can establish use of the two asset roots in this report.
    if ($parts[0].ToLowerInvariant() -eq 'maps') {
        $isRelevantMapFile =
            ($relativePath -match '(?i)\.hpm$') -or
            ($relativePath -match '(?i)\.hpm_(?:Entity|StaticObject)$') -or
            ($extension -eq '.hps')
        if (-not $isRelevantMapFile) {
            continue
        }
    }

    $record = $allFilesByKey[$key]
    $rootFilesScanned++
    if ($relativePath -match '(?i)\.hpm(?:_|$)') {
        Scan-HpmFile -FileRecord $record
    }
    else {
        Add-ReferencesFromFile -FileRecord $record -SourceDescription ("Root reference: {0}" -f $relativePath)
    }
}

while ($dependencyQueue.Count -gt 0) {
    $key = $dependencyQueue.Dequeue()
    $record = $candidateByKey[$key]
    if ($record.Extension -notin $dependencyCarrierExtensions) {
        continue
    }

    $dependencyFilesScanned++
    Add-ReferencesFromFile -FileRecord $record -SourceDescription ("Dependency of used asset: {0}" -f $record.RelativePath)
}

$unusedAssets = @(
    foreach ($entry in $candidateByKey.GetEnumerator()) {
        if (-not $usedKeys.Contains($entry.Key)) {
            $entry.Value
        }
    }
) | Sort-Object RelativePath

$usedAssets = @(
    foreach ($key in $usedKeys) {
        $candidateByKey[$key]
    }
) | Sort-Object RelativePath

$unusedEntityStaticAssets = @($unusedAssets | Where-Object { $_.Root -in @('entities', 'static_objects') })
$totalUnusedBytes = ($unusedAssets | Measure-Object -Property Length -Sum).Sum
if ($null -eq $totalUnusedBytes) {
    $totalUnusedBytes = 0
}

$summaryByRoot = @(
    foreach ($group in ($unusedAssets | Group-Object Root | Sort-Object Name)) {
        [pscustomobject]@{
            Root  = $group.Name
            Count = $group.Count
            Bytes = ($group.Group | Measure-Object -Property Length -Sum).Sum
        }
    }
)

$outputDirectory = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [void] (New-Item -ItemType Directory -Path $outputDirectory -Force)
}

$jsonOutputDirectory = Split-Path -Parent $JsonOutputPath
if (-not [string]::IsNullOrWhiteSpace($jsonOutputDirectory)) {
    [void] (New-Item -ItemType Directory -Path $jsonOutputDirectory -Force)
}

$builder = [System.Text.StringBuilder]::new()
[void] $builder.AppendLine('BunkersEdge unused asset report')
[void] $builder.AppendLine('MODE: REPORT ONLY - this script never deletes files')
[void] $builder.AppendLine(('Generated: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')))
[void] $builder.AppendLine(('Mod root: {0}' -f $modRootFull))
[void] $builder.AppendLine()
[void] $builder.AppendLine('How usage was determined:')
[void] $builder.AppendLine('- Inventoried only files under this mod''s entities/ and static_objects/ folders.')
[void] $builder.AppendLine('- Scanned the mod''s main .hpm, .hpm_Entity, and .hpm_StaticObject files.')
[void] $builder.AppendLine('- Resolved HPM FileIndex values per Section; stale index entries do not count as usage.')
[void] $builder.AppendLine('- Scanned scripts/configuration/map attributes and recursively followed asset dependencies.')
[void] $builder.AppendLine('- Kept matching source/compiled companion files together (for example .dae + .msh).')
[void] $builder.AppendLine('- Results are candidates, not deletion approval: dynamic/generated references may be invisible to static analysis.')
[void] $builder.AppendLine()
[void] $builder.AppendLine('Summary:')
[void] $builder.AppendLine(('  Candidate assets:                 {0}' -f $candidateByKey.Count))
[void] $builder.AppendLine(('  Used/reachable assets:            {0}' -f $usedAssets.Count))
[void] $builder.AppendLine(('  Unused candidates:                {0}' -f $unusedAssets.Count))
[void] $builder.AppendLine(('  Unused under entities/static_objects: {0}' -f $unusedEntityStaticAssets.Count))
[void] $builder.AppendLine(('  Unused candidate bytes:           {0:N0}' -f $totalUnusedBytes))
[void] $builder.AppendLine(('  Root files scanned:               {0}' -f $rootFilesScanned))
[void] $builder.AppendLine(('  Dependency files scanned:         {0}' -f $dependencyFilesScanned))
[void] $builder.AppendLine(('  Exact references resolved:        {0}' -f $exactReferencesResolved))
[void] $builder.AppendLine(('  Extension-inferred references:    {0}' -f $extensionInferredReferencesResolved))
[void] $builder.AppendLine(('  Indexed HPM references resolved:  {0}' -f $indexedReferencesResolved))
[void] $builder.AppendLine(('  Stale HPM index entries:          {0}' -f $staleMapIndexEntries.Count))
[void] $builder.AppendLine()

[void] $builder.AppendLine('Unused candidates by asset root:')
foreach ($summary in $summaryByRoot) {
    [void] $builder.AppendLine(('  {0,-20} {1,6} files  {2,14:N0} bytes' -f $summary.Root, $summary.Count, $summary.Bytes))
}
[void] $builder.AppendLine()

[void] $builder.AppendLine('UNUSED CANDIDATES UNDER entities/ AND static_objects/')
[void] $builder.AppendLine('------------------------------------------------------')
foreach ($asset in $unusedEntityStaticAssets) {
    [void] $builder.AppendLine(("{0}`t{1}" -f $asset.RelativePath, $asset.Length))
}
[void] $builder.AppendLine()

[void] $builder.AppendLine('ALL UNUSED CANDIDATES')
[void] $builder.AppendLine('---------------------')
foreach ($asset in $unusedAssets) {
    [void] $builder.AppendLine(("{0}`t{1}" -f $asset.RelativePath, $asset.Length))
}
[void] $builder.AppendLine()

[void] $builder.AppendLine('STALE HPM FILE-INDEX ENTRIES (diagnostic only)')
[void] $builder.AppendLine('----------------------------------------------')
foreach ($entry in ($staleMapIndexEntries | Sort-Object TrackFile, Section, IndexType, IndexId)) {
    [void] $builder.AppendLine(("{0}`tsection={1}`t{2}`tid={3}`t{4}" -f $entry.TrackFile, $entry.Section, $entry.IndexType, $entry.IndexId, $entry.Path))
}

if ($warnings.Count -gt 0) {
    [void] $builder.AppendLine()
    [void] $builder.AppendLine('WARNINGS')
    [void] $builder.AppendLine('--------')
    foreach ($warning in ($warnings | Sort-Object -Unique)) {
        [void] $builder.AppendLine(('- {0}' -f $warning))
    }
}

[System.IO.File]::WriteAllText($OutputPath, $builder.ToString(), [System.Text.UTF8Encoding]::new($false))

$jsonReport = [ordered]@{
    schemaVersion = 2
    mode = 'report-only'
    generatedAt = (Get-Date).ToString('o')
    modRoot = $modRootFull
    summary = [ordered]@{
        candidateAssets = $candidateByKey.Count
        usedAssets = $usedAssets.Count
        unusedCandidates = $unusedAssets.Count
        unusedEntitiesAndStaticObjects = $unusedEntityStaticAssets.Count
        unusedCandidateBytes = [long] $totalUnusedBytes
        rootFilesScanned = $rootFilesScanned
        dependencyFilesScanned = $dependencyFilesScanned
        exactReferencesResolved = $exactReferencesResolved
        extensionInferredReferencesResolved = $extensionInferredReferencesResolved
        indexedHpmReferencesResolved = $indexedReferencesResolved
        staleHpmIndexEntries = $staleMapIndexEntries.Count
    }
    unusedAssets = @($unusedAssets | ForEach-Object {
        [ordered]@{
            path = $_.RelativePath
            bytes = $_.Length
            lastWriteTimeUtc = $_.LastWriteTimeUtc
            root = $_.Root
            extension = $_.Extension
        }
    })
    staleHpmIndexEntries = @($staleMapIndexEntries)
    warnings = @($warnings | Sort-Object -Unique)
}

[System.IO.File]::WriteAllText(
    $JsonOutputPath,
    ($jsonReport | ConvertTo-Json -Depth 6),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host ''
Write-Host 'BunkersEdge unused asset scan complete.' -ForegroundColor Green
Write-Host ("Unused candidates: {0} ({1:N0} bytes)" -f $unusedAssets.Count, $totalUnusedBytes)
Write-Host ("Under entities/static_objects: {0}" -f $unusedEntityStaticAssets.Count)
Write-Host ("Stale HPM index entries: {0}" -f $staleMapIndexEntries.Count)
Write-Host ("Text report: {0}" -f (Resolve-Path -LiteralPath $OutputPath))
Write-Host ("JSON report: {0}" -f (Resolve-Path -LiteralPath $JsonOutputPath))
