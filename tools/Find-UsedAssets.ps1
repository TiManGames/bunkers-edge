[CmdletBinding()]
param(
    [string] $ModRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $OutputPath = (Join-Path $PSScriptRoot 'used-assets-report.txt'),
    [string] $JsonOutputPath = (Join-Path $PSScriptRoot 'used-assets-report.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Report-only. This program intentionally has no deletion code.
$roots = @('entities', 'static_objects')
$textExtensions = @('.ent', '.dae', '.mat', '.ps', '.xml', '.hps', '.cfg', '.lang', '.voice', '.swd')
$binaryReferenceExtensions = @('.msh', '.fbx', '.anm', '.dae_anim', '.anno')
$bundleAnchorExtensions = @('.ent', '.dae', '.msh', '.fbx')

function Get-Extension([string] $Path) {
    $name = [IO.Path]::GetFileName($Path).ToLowerInvariant()
    if ($name.EndsWith('.dae_anim')) { return '.dae_anim' }
    return [IO.Path]::GetExtension($name).ToLowerInvariant()
}
function Get-Key([string] $Path) { return $Path.Replace('\', '/').TrimStart('/').ToLowerInvariant() }
function Get-Relative([string] $FullPath, [string] $RootPath) { return $FullPath.Substring($RootPath.Length).TrimStart([char[]]@('\','/')).Replace('\','/') }

$modRootFull = (Get-Item -LiteralPath $ModRoot).FullName.TrimEnd([char[]]@('\','/'))
$modName = (Split-Path -Leaf $modRootFull)
$modForward = $modRootFull.Replace('\','/')
$candidates = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
$byFileName = [Collections.Generic.Dictionary[string,Collections.Generic.List[string]]]::new([StringComparer]::OrdinalIgnoreCase)

foreach ($file in @(Get-ChildItem -LiteralPath $modRootFull -Recurse -File)) {
    $relative = Get-Relative $file.FullName $modRootFull
    $parts = $relative -split '/',2
    if ($parts.Count -lt 2 -or $parts[0].ToLowerInvariant() -notin $roots) { continue }
    $extension = Get-Extension $relative
    if ($extension -in @('.db','.map_cache','.preload_cache','.tmp','.bak')) { continue }
    $key = Get-Key $relative
    $record = [pscustomobject]@{ Key=$key; Path=$relative; FullPath=$file.FullName; Extension=$extension; Bytes=$file.Length }
    $candidates[$key] = $record
    $name = [IO.Path]::GetFileName($relative)
    if (-not $byFileName.ContainsKey($name)) { $byFileName[$name] = [Collections.Generic.List[string]]::new() }
    $byFileName[$name].Add($key)
}

$used = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$possible = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$queue = [Collections.Generic.Queue[string]]::new()
$reasons = [Collections.Generic.Dictionary[string,Collections.Generic.List[string]]]::new([StringComparer]::OrdinalIgnoreCase)
$ambiguous = [Collections.Generic.List[object]]::new()
$unresolved = [Collections.Generic.List[object]]::new()

function Add-Used([string] $Key, [string] $Reason) {
    if (-not $candidates.ContainsKey($Key)) { return }
    if (-not $reasons.ContainsKey($Key)) { $reasons[$Key] = [Collections.Generic.List[string]]::new() }
    if ($reasons[$Key].Count -lt 6 -and -not $reasons[$Key].Contains($Reason)) { $reasons[$Key].Add($Reason) }
    if ($used.Add($Key)) { $queue.Enqueue($Key) }
}

function Resolve-Reference([string] $Value, [string] $Source) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '[\\/]') { return }
    $value = [Uri]::UnescapeDataString($Value).Replace('\','/').Trim().Trim([char[]]@('"',"'",' ', ';', ',', ')', '('))
    $value = $value -replace '[?#].*$',''
    $value = $value -replace ('(?i)^' + [regex]::Escape($modForward) + '/?'),''
    $marker = [regex]::Match($value, '(?i)(?:^|/)mods/' + [regex]::Escape($modName) + '/')
    if ($marker.Success) { $value = $value.Substring($marker.Index + $marker.Length) }
    $rootMatch = [regex]::Match($value, '(?i)(?:^|/)(entities|static_objects)/')
    if ($rootMatch.Success) {
        if ($rootMatch.Index -gt 0) { $value = $value.Substring($rootMatch.Index + 1) }
        $key = Get-Key $value
        if ($candidates.ContainsKey($key)) { Add-Used $key $Source; return }
    }

    $leaf = [IO.Path]::GetFileName($value)
    if ($byFileName.ContainsKey($leaf)) {
        $matches = @($byFileName[$leaf])
        if ($matches.Count -eq 1) { Add-Used $matches[0] ("Unique filename fallback from {0}: {1}" -f $Source,$value); return }
        foreach ($match in $matches) { [void]$possible.Add($match) }
        $ambiguous.Add([pscustomobject]@{ source=$Source; reference=$value; matches=@($matches | ForEach-Object { $candidates[$_].Path }) })
        return
    }
    $unresolved.Add([pscustomobject]@{ source=$Source; reference=$value })
}

function Get-ReferenceValues([string] $Text) {
    $found = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($match in [regex]::Matches($Text,'["''](?<v>[^"''\r\n]+)["'']')) { [void]$found.Add($match.Groups['v'].Value) }
    foreach ($match in [regex]::Matches($Text,'(?i)(?:mods[\\/]+[^\\/]+[\\/]+)?(?:entities|static_objects)[\\/][a-z0-9_ .()\-\\/]+?\.(?:ent|dae|msh|fbx|anm|dae_anim|anno|mat|dds|tga|png|jpg|jpeg|bmp|psd|ps|xml)')) { [void]$found.Add($match.Value) }
    return $found
}
function Scan-TextFile([string] $Path, [string] $Source) {
    $text = Get-Content -LiteralPath $Path -Raw
    foreach ($value in (Get-ReferenceValues $text)) { Resolve-Reference $value $Source }
}
function Scan-BinaryFile([string] $Path, [string] $Source) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    foreach ($encoding in @([Text.Encoding]::ASCII,[Text.Encoding]::Unicode)) {
        $text = $encoding.GetString($bytes)
        foreach ($stringMatch in [regex]::Matches($text,'[\x20-\x7E]{6,}')) {
            foreach ($value in (Get-ReferenceValues $stringMatch.Value)) { Resolve-Reference $value $Source }
        }
    }
}
function Scan-Hpm([object] $File) {
    try { [xml]$xml = Get-Content -LiteralPath $File.FullName -Raw }
    catch { throw "Cannot parse map XML: $($File.FullName): $($_.Exception.Message)" }
    foreach ($section in @($xml.SelectNodes('//*[local-name()="Section"]'))) {
        foreach ($index in @($section.SelectNodes('.//*[starts-with(local-name(),"FileIndex_")]'))) {
            $paths = @{}
            foreach ($entry in @($index.SelectNodes('./*[local-name()="File"]'))) { $paths[[string]$entry.Id] = [string]$entry.Path }
            foreach ($object in @($section.SelectNodes('.//*[@FileIndex]'))) {
                $id = [string]$object.FileIndex
                if ($paths.ContainsKey($id)) { Resolve-Reference $paths[$id] ("Live HPM index: $($File.Name); section=$($section.Name); id=$id") }
            }
        }
    }
    # HPM attributes outside an index can hold direct particle/entity resource paths.
    # Never treat a stale <FileIndex_*> entry as a live reference.
    foreach ($attribute in @($xml.SelectNodes('//@*'))) {
        $insideIndex = $false; $node = $attribute.OwnerElement
        while ($null -ne $node) {
            if ($node.LocalName.StartsWith('FileIndex_',[StringComparison]::OrdinalIgnoreCase)) { $insideIndex = $true; break }
            $node = $node.ParentNode
        }
        if (-not $insideIndex) { Resolve-Reference ([string]$attribute.Value) ("HPM attribute: $($File.Name)") }
    }
}

# Primary roots: current HPM object indices plus engine-generated preload caches.
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $modRootFull 'maps') -Recurse -File)) {
    if ($file.Name -match '(?i)\.hpm(?:_|$)') { Scan-Hpm $file }
    elseif ($file.Extension -eq '.preload_cache') { Scan-TextFile $file.FullName ("Preload cache: $($file.Name)") }
    elseif ($file.Extension -eq '.hps') { Scan-TextFile $file.FullName ("Map script: $($file.Name)") }
}
foreach ($folder in @('script','config')) {
    $path = Join-Path $modRootFull $folder
    if (Test-Path -LiteralPath $path) {
        foreach ($file in @(Get-ChildItem -LiteralPath $path -Recurse -File)) {
            if ($file.Extension -in @('.hps','.cfg','.xml','.lang')) { Scan-TextFile $file.FullName ("$folder reference: $($file.Name)") }
        }
    }
}

while ($queue.Count -gt 0) {
    $key = $queue.Dequeue(); $asset = $candidates[$key]
    if ($asset.Extension -in $textExtensions) { Scan-TextFile $asset.FullPath ("Dependency: $($asset.Path)") }
    elseif ($asset.Extension -in $binaryReferenceExtensions) { Scan-BinaryFile $asset.FullPath ("Compiled dependency: $($asset.Path)") }
    if ($asset.Extension -eq '.dae') {
        $pair = Get-Key ($asset.Path.Substring(0,$asset.Path.Length-$asset.Extension.Length) + '.msh')
        if ($candidates.ContainsKey($pair)) { Add-Used $pair ("Compiled mesh pair of $($asset.Path)") }
    }
    elseif ($asset.Extension -eq '.msh') {
        $pair = Get-Key ($asset.Path.Substring(0,$asset.Path.Length-$asset.Extension.Length) + '.dae')
        if ($candidates.ContainsKey($pair)) { Add-Used $pair ("Source mesh pair of $($asset.Path)") }
    }
}

# An entity/mesh folder is an HPL asset bundle. Keep sibling files in a distinct
# review category when one of its anchors is used; they are not claimed as direct use.
$bundleRetained = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($key in @($used)) {
    $asset = $candidates[$key]
    if ($asset.Extension -notin $bundleAnchorExtensions) { continue }
    $directory = [IO.Path]::GetDirectoryName($asset.Path).Replace('\','/')
    foreach ($candidate in $candidates.Values) {
        if ([IO.Path]::GetDirectoryName($candidate.Path).Replace('\','/').Equals($directory,[StringComparison]::OrdinalIgnoreCase) -and -not $used.Contains($candidate.Key)) { [void]$bundleRetained.Add($candidate.Key) }
    }
}

$directUsed = @($used | ForEach-Object { $asset=$candidates[$_]; [pscustomobject]@{path=$asset.Path;bytes=$asset.Bytes;reasons=@($reasons[$_])} } | Sort-Object path)
$bundleOnly = @($bundleRetained | Where-Object { -not $used.Contains($_) -and -not $possible.Contains($_) } | ForEach-Object { $candidates[$_]} | Sort-Object Path)
$possibleOnly = @($possible | Where-Object { -not $used.Contains($_) } | ForEach-Object { $candidates[$_]} | Sort-Object Path)
$noRecordedReference = @($candidates.Values | Where-Object { -not $used.Contains($_.Key) -and -not $bundleRetained.Contains($_.Key) -and -not $possible.Contains($_.Key) } | Sort-Object Path)

$report = [ordered]@{ schemaVersion=1; mode='report-only-used-asset-graph'; generatedAt=(Get-Date).ToString('o'); modRoot=$modRootFull; summary=[ordered]@{ inventory=$candidates.Count; directlyUsed=$directUsed.Count; bundleRetained=$bundleOnly.Count; ambiguousPossible=$possibleOnly.Count; noRecordedReference=$noRecordedReference.Count; unresolvedReferences=$unresolved.Count }; directlyUsed=$directUsed; bundleRetained=@($bundleOnly|ForEach-Object{[ordered]@{path=$_.Path;bytes=$_.Bytes}}); ambiguousPossible=@($possibleOnly|ForEach-Object{[ordered]@{path=$_.Path;bytes=$_.Bytes}}); noRecordedReference=@($noRecordedReference|ForEach-Object{[ordered]@{path=$_.Path;bytes=$_.Bytes}}); ambiguousReferences=@($ambiguous); unresolvedReferences=@($unresolved) }
[IO.File]::WriteAllText($JsonOutputPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$lines=[Collections.Generic.List[string]]::new(); $lines.Add('BunkersEdge used-asset graph report'); $lines.Add('REPORT ONLY: no deletion recommendation is made.'); $lines.Add("Inventory: $($candidates.Count)"); $lines.Add("Directly used (traceable): $($directUsed.Count)"); $lines.Add("Retained by used asset bundle: $($bundleOnly.Count)"); $lines.Add("Possible via ambiguous filename: $($possibleOnly.Count)"); $lines.Add("No recorded reference: $($noRecordedReference.Count)"); $lines.Add(''); $lines.Add('DIRECTLY USED (path | reasons)'); foreach($item in $directUsed){$lines.Add(($item.path+' | '+($item.reasons -join ' ; ')))}; $lines.Add(''); $lines.Add('RETAINED BY USED BUNDLE (not direct-use proof)'); foreach($item in $bundleOnly){$lines.Add($item.Path)}; $lines.Add(''); $lines.Add('NO RECORDED REFERENCE (not deletion-safe)'); foreach($item in $noRecordedReference){$lines.Add($item.Path)}
[IO.File]::WriteAllLines($OutputPath,$lines,[Text.UTF8Encoding]::new($false))
Write-Host "Used graph complete: $($directUsed.Count) direct, $($bundleOnly.Count) bundle-retained, $($possibleOnly.Count) ambiguous, $($noRecordedReference.Count) with no recorded reference."
Write-Host "Text: $OutputPath"; Write-Host "JSON: $JsonOutputPath"
