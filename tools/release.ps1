# Prepares a MOHAB Plus release: bumps VERSION, updates CHANGELOG.md, builds, zips, commits and tags.
#
#   powershell -ExecutionPolicy Bypass -File tools\release.ps1 -Version 1.2.0 -Draft
#       Only writes a changelog draft (from the commits since the last tag) to dist\release\. Changes nothing else.
#   powershell -ExecutionPolicy Bypass -File tools\release.ps1 -Version 1.2.0 [-Notes notes.md]
#       Full release. -Notes = curated changelog section (markdown); default = the generated draft.
#
# Output (dist\release\):  MOHABPlus-v1.2.0.zip       -> attach to the GitHub release
#                          RELEASE-NOTES-v1.2.0.md    -> paste as the GitHub release description
# Nothing is pushed: run "git push origin main --follow-tags" afterwards.
param(
    [Parameter(Mandatory)][string]$Version,
    [switch]$Draft,
    [string]$Notes,
    [switch]$AllowDirty
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

# Windows PowerShell turns any stderr line of a native command into an error under 'Stop': run git with 'Continue'.
function Invoke-Git { $ErrorActionPreference = 'Continue'; $out = & git.exe @args 2>$null; if ($LASTEXITCODE -ne 0) { throw "git $args failed (exit $LASTEXITCODE)" }; $out }
function Invoke-GitQuiet { $ErrorActionPreference = 'Continue'; & git.exe @args 2>$null }

if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must be MAJOR.MINOR.PATCH (e.g. 1.2.0), got '$Version'." }
$tag = "v$Version"
Invoke-GitQuiet rev-parse -q --verify "refs/tags/$tag" | Out-Null
if ($LASTEXITCODE -eq 0) { throw "Tag $tag already exists." }

$current = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
if (-not $Draft -and [version]$Version -le [version]$current) { throw "New version $Version must be greater than the current $current." }

# ---- Changelog section ---------------------------------------------------------------------------------------------
$prevTag = Invoke-GitQuiet describe --tags --abbrev=0 --match 'v[0-9]*'
$range = if ($LASTEXITCODE -eq 0 -and $prevTag) { "$prevTag..HEAD" } else { 'HEAD' }
$subjects = @(Invoke-Git log --no-merges --format='%s' $range)
$groups = [ordered]@{ 'New' = @(); 'Improvements' = @(); 'Fixes' = @(); 'Other' = @() }
foreach ($s in $subjects) {
    if ($s -match '^(?<type>\w+)(\([^)]*\))?!?:\s*(?<msg>.+)$') {
        $type = $Matches.type.ToLower(); $msg = $Matches.msg
    } else { $type = 'other'; $msg = $s }
    if ($type -in 'chore', 'docs', 'build', 'ci', 'test', 'style') { continue }
    $msg = $msg.Substring(0, 1).ToUpper() + $msg.Substring(1)
    $key = switch ($type) { 'feat' { 'New' } 'fix' { 'Fixes' } { $_ -in 'perf', 'refactor' } { 'Improvements' } default { 'Other' } }
    $groups[$key] += "- $msg"
}
# FEATURES.md (launcher FEATURES tab) should follow player-visible changes.
if ($range -ne 'HEAD' -and ($groups['New'].Count + $groups['Fixes'].Count) -gt 0) {
    $featuresChanged = Invoke-GitQuiet diff --name-only $prevTag HEAD -- FEATURES.md
    if (-not $featuresChanged) {
        Write-Warning "There are feat/fix commits since $prevTag but FEATURES.md was not updated. Review it before releasing."
    }
    # Translations of the feature list (FEATURES.<code>.md) must follow the English one.
    if ($featuresChanged) {
        foreach ($f in Get-ChildItem (Join-Path $root 'FEATURES.*.md')) {
            if (-not (Invoke-GitQuiet diff --name-only $prevTag HEAD -- $f.Name)) {
                Write-Warning "FEATURES.md changed since $prevTag but $($f.Name) did not. Update the translation before releasing."
            }
        }
    }
}
$date = Get-Date -Format 'yyyy-MM-dd'
$header = "## $tag - $date"
if ($Notes) {
    $body = (Get-Content $Notes -Raw).Trim()
    if ($body -match '^## ') { $body = ($body -split "`r?`n", 2)[1].Trim() }   # drop its own version header
} else {
    $parts = foreach ($k in $groups.Keys) { if ($groups[$k].Count) { "### $k`n`n" + ($groups[$k] -join "`n") } }
    $body = if ($parts) { $parts -join "`n`n" } else { '- Maintenance release.' }
}
$section = "$header`n`n$body`n"

$utf8 = New-Object System.Text.UTF8Encoding $false
$out = Join-Path $root 'dist\release'
New-Item -ItemType Directory -Force $out | Out-Null
if ($Draft) {
    $draftPath = Join-Path $out "CHANGELOG-DRAFT-$tag.md"
    [IO.File]::WriteAllText($draftPath, $section, $utf8)
    Write-Host "Changelog draft ($range, $($subjects.Count) commits): $draftPath"
    return
}

if (-not $AllowDirty -and (Invoke-Git status --porcelain)) { throw 'The working tree has uncommitted changes. Commit or stash them first.' }

# ---- Bump version + changelog ----------------------------------------------------------------------------------------
$changelogPath = Join-Path $root 'CHANGELOG.md'
$intro = "# Changelog`n`nAll notable changes to MOHAB Plus. Versions follow MAJOR.MINOR.PATCH.`n"
$old = if (Test-Path $changelogPath) { (Get-Content $changelogPath -Raw) } else { $intro }
$idx = $old.IndexOf("`n## ")
$newChangelog = if ($idx -ge 0) { $old.Substring(0, $idx + 1) + "`n" + $section + "`n" + $old.Substring($idx + 1).TrimStart() } else { $old.TrimEnd() + "`n`n" + $section }
$newChangelog = ($newChangelog -replace "`r`n", "`n") -replace "`n{3,}", "`n`n"

[IO.File]::WriteAllText((Join-Path $root 'VERSION'), "$Version`n", $utf8)
[IO.File]::WriteAllText($changelogPath, $newChangelog, $utf8)

try {
    # ---- Build + package --------------------------------------------------------------------------------------------
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'build.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'build.ps1 failed' }
    $dist = Join-Path $root 'dist\MOHABPlus'

    $exclude = @('launcher.ini', 'launcher.log', 'ue4ss\UE4SS.log', 'ue4ss\Mods\MOHABPlus\config.ini', 'ue4ss\Mods\MOHABPlus\cmd.txt')
    $excludeDirs = @('ue4ss\cache', 'ue4ss\CXXHeaderDump', 'ue4ss\Mods\MOHABDump')
    $files = Get-ChildItem $dist -Recurse -File | Where-Object {
        $rel = $_.FullName.Substring($dist.Length + 1)
        -not ($exclude -contains $rel) -and -not ($excludeDirs | Where-Object { $rel.StartsWith("$_\") }) -and $rel -notlike '*.mohabplus-old'
    }
    $exe = Join-Path $dist 'MOHABPlusLauncher.exe'
    $built = (Get-Item $exe).VersionInfo.ProductVersion
    if (-not $built.StartsWith($Version)) { throw "Built launcher reports version $built, expected $Version." }

    $zipPath = Join-Path $out "MOHABPlus-$tag.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        foreach ($f in $files) {
            $entry = 'MOHABPlus/' + $f.FullName.Substring($dist.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $entry, 'Optimal') | Out-Null
        }
    } finally { $zip.Dispose() }

    $notesPath = Join-Path $out "RELEASE-NOTES-$tag.md"
    [IO.File]::WriteAllText($notesPath, "$body`n`n**Install:** extract ``MOHABPlus-$tag.zip`` anywhere and run ``MOHABPlusLauncher.exe``. Existing installs can update from the launcher.`n", $utf8)
} catch {
    Invoke-GitQuiet checkout -- VERSION CHANGELOG.md | Out-Null
    throw
}

# ---- Commit + tag ----------------------------------------------------------------------------------------------------
Invoke-Git add VERSION CHANGELOG.md | Out-Null
Invoke-Git commit -m "chore(release): $tag" | Out-Null
Invoke-Git tag -a $tag -m "MOHAB Plus $tag" | Out-Null

$size = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Host ''
Write-Host "Release $tag ready:"
Write-Host "  Zip:   $zipPath ($size MB, $($files.Count) files)"
Write-Host "  Notes: $notesPath"
Write-Host "Next: git push origin main --follow-tags, then create the GitHub release for $tag with the zip and the notes."
