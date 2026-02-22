<#
.SYNOPSIS
  Retro AudioSorter v23.0 (Clean genres + clean logging + duplicate removal)
  - Max 7 genres: Ambient, House, Trance, Hard Trance, Techno, Hardcore, Other
  - Optionele MusicBrainz genre lookup (toont API OK/FAIL + timing)
  - Optionele BPM detectie uit audio (toont scan tijd ~10s)
  - Optionele exacte duplicate removal (SHA256)
  - Optionele cleanup van lege mappen na Move

.VEREISTEN (optioneel)
  - ffmpeg + ffprobe in PATH (voor BPM audio detectie / tags)
  - node in PATH (voor bpm_detect.js)
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [Parameter(Mandatory=$true)]
  [string]$Source,

  [string]$Target,

  [switch]$Move,

  # Online genre lookup via MusicBrainz (artist tags)
  [switch]$OnlineGenreLookup,

  # BPM detectie via audio snippet (ffmpeg -> wav -> node bpm_detect.js)
  [switch]$DetectBpmFromAudio,

  # Hoeveel seconden audio analyseren (default 10s)
  [ValidateRange(5,60)]
  [int]$AudioBpmSeconds = 10,

  # Verwijder exacte duplicaten (SHA256) vóór sorteren
  [switch]$RemoveExactDuplicates,

  # Submappen per BPM-range (bv. Trance\135-140)
  [bool]$UseBpmSubfolders = $true,

  # Grootte van BPM-bucket: 5 => 135-140, 10 => 130-140
  [ValidateSet(5,10)]
  [int]$BpmBucketSize = 10,

  # Foldernaam als BPM onbekend
  [string]$NoBpmFolderName = 'No-BPM',

  # Verwijder lege mappen na Move
  [switch]$CleanupEmptyDirs
)

# ---------------------------
# Globals / Init
# ---------------------------
$Global:GenreCache = @{}   # artist -> genre (final limited genre)
$Global:ApiCache   = @{}   # artist -> api result (optional)
$Global:NowStamp   = (Get-Date).ToString("yyyyMMdd_HHmmss")

$src = (Resolve-Path $Source).Path
$dst = if ($Target) { (Resolve-Path $Target).Path } else { $src }

$workRoot = Join-Path $dst "_AudioSorter"
$toolsDir = Join-Path $workRoot "tools"
$logsDir  = Join-Path $workRoot "logs"
New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
New-Item -ItemType Directory -Path $logsDir  -Force | Out-Null

$logFile = Join-Path $logsDir ("audio_sorter_log_{0}.txt" -f $Global:NowStamp)

# Tools
$ffmpeg  = Get-Command ffmpeg  -ErrorAction SilentlyContinue
$ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
$node    = Get-Command node    -ErrorAction SilentlyContinue

# JS BPM tool (tiny + fast, good enough for retro sorting)
$jsTool = Join-Path $toolsDir "bpm_detect.js"
@'
const fs = require("fs");
try {
  const buf = fs.readFileSync(process.argv[2]);
  // WAV header is typically 44 bytes for PCM16 LE
  const pcm = buf.slice(44);
  const data = new Int16Array(pcm.buffer, pcm.byteOffset, Math.floor(pcm.length / 2));
  const step = 441; // ~10ms at 44100Hz
  const energy = [];
  for (let i=0; i<data.length; i+=step){
    let sum = 0;
    for (let j=0; j<step && (i+j)<data.length; j++) sum += Math.abs(data[i+j]);
    energy.push(sum);
  }
  const onsets = energy.map((v,i)=> i===0 ? 0 : Math.max(0, v-energy[i-1]));
  let bestBpm = 0, maxCorr = 0;
  for (let bpm=80; bpm<=190; bpm++){
    let corr = 0;
    const interval = Math.max(1, Math.round((60 / bpm) * 100)); // ~100 samples/sec
    for (let i=interval; i<onsets.length; i++) corr += onsets[i] * onsets[i-interval];
    if (corr > maxCorr){ maxCorr = corr; bestBpm = bpm; }
  }
  console.log(JSON.stringify({ ok: true, bpm: bestBpm }));
} catch (e){
  console.log(JSON.stringify({ ok: false }));
}
'@ | Set-Content -Path $jsTool -Encoding UTF8

# ---------------------------
# Logging helpers
# ---------------------------
function Write-Log {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)]
    [AllowEmptyString()]
    [string]$Message,
    [ConsoleColor]$Color = [ConsoleColor]::Gray,
    [switch]$NoConsole,
    [switch]$NoTimestamp
  )

  if ($null -eq $Message) { return }

  # Console output (never triggers WhatIf noise)
  if (-not $NoConsole) {
    if ($Message -eq "") {
      Write-Host ""
    } else {
      Write-Host $Message -ForegroundColor $Color
    }
  }

  # File logging: skip when -WhatIf is used (prevents thousands of "What if: Add Content" lines)
  if ($WhatIfPreference) { return }
  if (-not $logFile) { return }

  $ts = if ($NoTimestamp) { "" } else { "[{0}] " -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
  $line = "$ts$Message"
  try {
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
  } catch {
    Write-Host ("WARN: Failed to write to log file '{0}': {1}" -f $logFile, $_.Exception.Message) -ForegroundColor Yellow
  }
}


function Write-Separator {
  Write-Log "------------------------------------------------------------" -Color DarkGray -NoTimestamp
}

# ---------------------------
# Filename / Artist parsing
# ---------------------------
function Get-CleanArtist([string]$FileName) {
  $name = [System.IO.Path]::GetFileNameWithoutExtension($FileName)

  # 1) (Artist) Title OR [Artist] Title (but ignore if bracket part is only digits)
  if ($name -match '^[\(\[](.*?)[\)\]]\s*(?!-)(.*)') {
    $artistPart = $matches[1].Trim()
    $titlePart  = $matches[2].Trim()
    if ($artistPart -notmatch '^\d+$') { return $artistPart }
    $name = $titlePart
  }

  # 2) strip leading junk: brackets, tracknr, separators
  while ($name -match '^[\(\[].*?[\)\]]\s*|^\d+[\s\.\-]*') {
    $name = $name -replace '^[\(\[].*?[\)\]]\s*|^\d+[\s\.\-]*', ''
  }

  # 3) Artist - Title (first dash with spaces)
  if ($name -match '^(.*?)\s+-\s+.*') { return ($matches[1].Trim()) }

  # 4) Artist-Title (dash without spaces) -> take left part if it looks sane
  if ($name -match '^(.{2,40}?)-\s*.+') {
    $left = $matches[1].Trim()
    if ($left -notmatch '\s' -and $left.Length -ge 2) { return $left }
  }

  # 5) fallback: unknown
  return "Unknown"
}

# ---------------------------
# BPM detection
# ---------------------------
function Get-BpmFromTags {
  param([Parameter(Mandatory=$true)][string]$Path)
  if (-not $ffprobe) { return $null }

  try {
    # Try common tag names: TBPM (ID3), BPM (Vorbis/FLAC), bpm
    $out = & $ffprobe.Path -v error -show_entries format_tags=TBPM,BPM,bpm -of default=nw=1:nk=0 $Path 2>$null
    if (-not $out) { return $null }

    foreach ($line in $out) {
      # formats: "TAG:TBPM=138" or "TAG:BPM=138"
      if ($line -match '=\s*([0-9]+(\.[0-9]+)?)\s*$') {
        $val = [double]$matches[1]
        if ($val -ge 40 -and $val -le 250) { return [int][math]::Round($val) }
      }
    }
  } catch { }
  return $null
}

function Detect-BpmFromAudioSnippet {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [int]$Seconds = 10
  )

  $result = [ordered]@{
    ok = $false
    bpm = 0
    seconds = 0.0
    reason = ""
  }

  if (-not $DetectBpmFromAudio) {
    $result.reason = "Skip"
    return [pscustomobject]$result
  }
  if (-not $ffmpeg -or -not $node) {
    $result.reason = "Missing tools (ffmpeg/node)"
    return [pscustomobject]$result
  }

  $tmpWav = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString() + ".wav")
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  try {
    # take a slice (start at 30s to avoid long intros if possible)
    & $ffmpeg.Path -hide_banner -loglevel error -y -i $Path -ss 30 -t $Seconds -ac 1 -ar 44100 -c:a pcm_s16le $tmpWav 2>$null
    $raw = & $node.Path $jsTool $tmpWav 2>$null
    $json = $raw | ConvertFrom-Json
    if ($json.ok -and $json.bpm) {
      $result.ok = $true
      $result.bpm = [int]$json.bpm
      $result.reason = "Audio"
    } else {
      $result.reason = "Audio parse failed"
    }
  } catch {
    $result.reason = "Audio detect error"
  } finally {
    $sw.Stop()
    $result.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    if (Test-Path $tmpWav) { Remove-Item $tmpWav -Force -ErrorAction SilentlyContinue }
  }

  return [pscustomobject]$result
}

function Get-EffectiveBpm {
  param([int]$RawBpm)
  $effective = $RawBpm
  $mult = 1
  if ($RawBpm -gt 60 -and $RawBpm -lt 95) { $effective = $RawBpm * 2; $mult = 2 }
  return [pscustomobject]@{ raw=$RawBpm; effective=$effective; mult=$mult }
}

function Get-BpmRange {
  param(
    [int]$Bpm,
    [int]$Step = 5,
    [string]$NoBpm = 'No-BPM'
  )
  if ($Bpm -le 0) { return $NoBpm }
  if ($Step -lt 1) { $Step = 5 }
  $lo = [int]([math]::Floor($Bpm / $Step) * $Step)
  $hi = $lo + $Step
  return ("{0}-{1}" -f $lo, $hi)
}

# Backward compat (oude naam)
function Get-BpmRange5 {
  param([int]$Bpm)
  return (Get-BpmRange -Bpm $Bpm -Step 5 -NoBpm $NoBpmFolderName)
}

# ---------------------------
# Genre mapping (limited retro buckets)
# ---------------------------
function Map-ToRetroGenre {
  param(
    [string]$Hint,   # tag hint from MB (e.g. "trance","techno","house",...)
    [int]$EffectiveBpm
  )

  $h = ([string]$Hint).ToLowerInvariant()

  # 1) Strong tag hints
  if ($h -match 'hardcore|gabber|rave|hardstyle') { return "Hardcore" }
  if ($h -match 'techno|acid|industrial|ebm')     { return "Techno" }
  if ($h -match 'house')                         { return "House" }
  if ($h -match 'ambient|downtempo|triphop')      { return "Ambient" }
  if ($h -match 'trance|goa')                     { 
    if ($EffectiveBpm -ge 150) { return "Hard Trance" }
    return "Trance"
  }
  if ($h -match 'eurodance|dance|electronic|idm|breakbeat|jungle') {
    # fall back to BPM for these broad labels
    # (retro: eurodance/dance often <=140, but keep simple)
  }

  # 2) BPM-only fallback (retro friendly)
  if ($EffectiveBpm -ge 170) { return "Hardcore" }
  if ($EffectiveBpm -ge 150 -and $EffectiveBpm -lt 170) { return "Hard Trance" }
  if ($EffectiveBpm -ge 130 -and $EffectiveBpm -lt 150) { return "Trance" }
  if ($EffectiveBpm -ge 115 -and $EffectiveBpm -lt 130) { return "House" }
  if ($EffectiveBpm -gt 0  -and $EffectiveBpm -lt 115)  { return "Ambient" }

  return "Other"
}

function Get-GenreSmart {
  param(
    [Parameter(Mandatory=$true)][string]$Artist,
    [Parameter(Mandatory=$true)][int]$EffectiveBpm
  )

  # cache hit
  if ($Global:GenreCache.ContainsKey($Artist)) {
    return [pscustomobject]@{
      genre     = $Global:GenreCache[$Artist]
      source    = "Cache"
      apiUsed   = $false
      apiOk     = $null
      apiMs     = $null
      apiHint   = ""
    }
  }

  $apiHint = ""
  $apiOk   = $null
  $apiMs   = $null
  $source  = "BPM-Guess"
  $apiUsed = $false

  if ($OnlineGenreLookup -and $Artist -ne "Unknown" -and $Artist.Length -gt 2) {
    $apiUsed = $true
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      Start-Sleep -Milliseconds 900  # gentle
      $uID = Get-Random -Maximum 9999
      $query = [Uri]::EscapeDataString(('artist:"{0}"' -f $Artist))
      $url   = "https://musicbrainz.org/ws/2/artist/?query=$query&fmt=json"
      $resp = Invoke-RestMethod -Uri $url -UserAgent ("RetroSorter_v21_{0}" -f $uID) -TimeoutSec 15
      $apiOk = $true
      $source = "MusicBrainz"

      if ($resp.artists.Count -gt 0) {
        # pick best matching artist, take top tags
        $tags = $resp.artists[0].tags | Sort-Object count -Descending
        if ($tags) { $apiHint = ([string]$tags[0].name) }
      }
    } catch {
      $apiOk = $false
      $source = "BPM-Guess"  # fallback
    } finally {
      $sw.Stop()
      $apiMs = [int][math]::Round($sw.Elapsed.TotalMilliseconds, 0)
    }
  }

  $finalGenre = Map-ToRetroGenre -Hint $apiHint -EffectiveBpm $EffectiveBpm
  $Global:GenreCache[$Artist] = $finalGenre

  return [pscustomobject]@{
    genre     = $finalGenre
    source    = $source
    apiUsed   = $apiUsed
    apiOk     = $apiOk
    apiMs     = $apiMs
    apiHint   = $apiHint
  }
}

# ---------------------------
# Duplicate removal (exact hash)
# ---------------------------
function Get-ExtPriority {
  param([string]$Ext)
  switch -Regex ($Ext.ToLowerInvariant()) {
    '\.flac' { return 4 }
    '\.wav'  { return 3 }
    '\.m4a'  { return 2 }
    '\.mp3'  { return 1 }
    default  { return 0 }
  }
}

function Remove-ExactDuplicatesByHash {
  param(
    [Parameter(Mandatory=$true)][System.IO.FileInfo[]]$Files
  )

  Write-Log ("Exact duplicate scan (SHA256) over {0} files..." -f $Files.Count) -Color Cyan
  $hashMap = @{}

  $i = 0
  foreach ($f in $Files) {
    $i++
    if (($i % 200) -eq 0) {
      Write-Progress -Activity "Hashing..." -Status "$i / $($Files.Count)" -PercentComplete ([int](100*$i/$Files.Count))
    }

    try {
      $h = (Get-FileHash -Algorithm SHA256 -Path $f.FullName).Hash
      if (-not $hashMap.ContainsKey($h)) { $hashMap[$h] = New-Object System.Collections.Generic.List[System.IO.FileInfo] }
      $hashMap[$h].Add($f)
    } catch {
      Write-Log ("WARN: Hash failed: {0}" -f $f.FullName) -Color DarkYellow -NoConsole
    }
  }
  Write-Progress -Activity "Hashing..." -Completed

  $dupeGroups = $hashMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }
  $removed = 0

  foreach ($g in $dupeGroups) {
    $items = $g.Value

    # choose best to keep: ext priority, then size
    $keep = $items | Sort-Object @{Expression={ Get-ExtPriority $_.Extension }; Descending=$true}, @{Expression={$_.Length}; Descending=$true} | Select-Object -First 1
    foreach ($d in $items) {
      if ($d.FullName -eq $keep.FullName) { continue }
      if ($PSCmdlet.ShouldProcess($d.FullName, "Remove duplicate (same SHA256 as $($keep.FullName))")) {
        try {
          Remove-Item $d.FullName -Force
          $removed++
          Write-Log ("DUPLICATE REMOVED: {0} (kept: {1})" -f $d.FullName, $keep.FullName) -Color DarkYellow
        } catch {
          Write-Log ("WARN: Failed to remove duplicate: {0}" -f $d.FullName) -Color DarkYellow
        }
      }
    }
  }

  Write-Log ("Duplicate scan done. Removed: {0}" -f $removed) -Color Cyan
}

# ---------------------------
# Move helpers
# ---------------------------
function Get-UniqueDestinationPath {
  param(
    [Parameter(Mandatory=$true)][string]$DestDir,
    [Parameter(Mandatory=$true)][string]$FileName
  )
  $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
  $ext  = [System.IO.Path]::GetExtension($FileName)
  $dest = Join-Path $DestDir $FileName
  if (-not (Test-Path $dest)) { return $dest }

  for ($n=2; $n -le 999; $n++) {
    $cand = Join-Path $DestDir ("{0} ({1}){2}" -f $base, $n, $ext)
    if (-not (Test-Path $cand)) { return $cand }
  }
  # last resort
  return Join-Path $DestDir ("{0}_{1}{2}" -f $base, ([Guid]::NewGuid().ToString("N").Substring(0,6)), $ext)
}

function Remove-EmptyDirs {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [string]$ExcludePattern = "_AudioSorter"
  )

  # deepest first
  $dirs = Get-ChildItem -Path $Root -Directory -Recurse -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -notmatch [regex]::Escape($ExcludePattern) } |
          Sort-Object FullName -Descending

  foreach ($d in $dirs) {
    try {
      $hasChild = Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1
      if (-not $hasChild) {
        if ($PSCmdlet.ShouldProcess($d.FullName, "Remove empty directory")) {
          Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop
        }
        Write-Log ("REMOVED empty dir: {0}" -f $d.FullName) -Color DarkGray -NoConsole:$false
      }
    } catch { }
  }
}

# ---------------------------
# MAIN
# ---------------------------
# Determine exclusions (avoid re-processing already sorted folders when Source == Target)
$retroBuckets = @("Ambient","House","Trance","Hard Trance","Techno","Hardcore","Other")
$excludePatterns = @("\\_AudioSorter\\")
if ($src -eq $dst) {
  foreach ($b in $retroBuckets) {
    $excludePatterns += ("\\{0}\\" -f [regex]::Escape($b))
  }
}

$files = Get-ChildItem -Path $src -Recurse -File -ErrorAction SilentlyContinue |
         Where-Object { $_.Extension -match "mp3|flac|wav|m4a|aac|ogg" } |
         Where-Object {
           $p = $_.FullName
           foreach ($pat in $excludePatterns) { if ($p -match $pat) { return $false } }
           return $true
         }
Write-Log "" -NoTimestamp
Write-Log ("🚀 Start. Root={0}" -f $src) -Color Cyan
Write-Log ("Log: {0}" -f $logFile) -Color Cyan
Write-Log ("Gevonden audiofiles: {0}" -f $files.Count) -Color Cyan
Write-Log "" -NoTimestamp

# Optional: remove exact duplicates first
if ($RemoveExactDuplicates) {
  Remove-ExactDuplicatesByHash -Files $files
  # refresh list after removals
  $files = Get-ChildItem -Path $src -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Extension -match "mp3|flac|wav|m4a|aac|ogg" } |
           Where-Object {
             $p = $_.FullName
             foreach ($pat in $excludePatterns) { if ($p -match $pat) { return $false } }
             return $true
           }
}

foreach ($f in $files) {
  $artist = Get-CleanArtist $f.Name

  Write-Separator
  Write-Log ("FILE: {0}" -f $f.Name) -Color White -NoTimestamp

  # Step 1: BPM (Tag -> Audio -> none)
  $rawBpm  = 0
  $bpmFrom = "None"

  $tagBpm = Get-BpmFromTags -Path $f.FullName

  # Only do the ~10s audio scan if we don't already have a tag-BPM
  $audioInfo = [pscustomobject]@{ ok=$false; bpm=0; seconds=0.0; reason="Skip" }
  if (-not $tagBpm) {
    $audioInfo = Detect-BpmFromAudioSnippet -Path $f.FullName -Seconds $AudioBpmSeconds
  }

  if ($tagBpm) {
    $rawBpm  = [int]$tagBpm
    $bpmFrom = "Tag"
  } elseif ($audioInfo.ok) {
    $rawBpm  = [int]$audioInfo.bpm
    $bpmFrom = "Audio"
  } else {
    $rawBpm  = 0
    $bpmFrom = "None"
  }

  $eff = Get-EffectiveBpm -RawBpm $rawBpm
  $range = Get-BpmRange5 -Bpm $eff.effective

  $bpmLine = "  Step 1: BPM -> {0} (Effectief: {1})" -f $eff.raw, $eff.effective
if ($eff.mult -eq 2) { $bpmLine += " [x2]" }
$bpmLine += " | BPM bron: {0}" -f $bpmFrom

$audioScanText =
  if (-not $DetectBpmFromAudio) { "AudioScan: OFF" }
  elseif ($tagBpm) { "AudioScan: SKIP (tag BPM)" }
  elseif ($audioInfo.reason -eq "Skip") { "AudioScan: SKIP" }
  elseif ($audioInfo.ok) { "AudioScan: OK ({0:0.0}s, window {1}s)" -f $audioInfo.seconds, $AudioBpmSeconds }
  else { "AudioScan: FAIL ({0}, {1:0.0}s)" -f $audioInfo.reason, $audioInfo.seconds }

$bpmLine += " | $audioScanText"
Write-Log $bpmLine -Color Yellow -NoTimestamp

  # Step 2: Artist
  Write-Log ("  Step 2: Artiest -> {0}" -f $artist) -Color Cyan -NoTimestamp

  # Step 3: Genre source + API status
  $g = Get-GenreSmart -Artist $artist -EffectiveBpm $eff.effective

  $apiText = "API: OFF"
  if ($OnlineGenreLookup) {
    if ($g.source -eq "Cache") {
      $apiText = "API: SKIP (cache hit)"
    } elseif (-not $g.apiUsed) {
      $apiText = "API: SKIP (no lookup)"
    } elseif ($g.apiOk -eq $true) {
      $apiText = "API: OK ({0} ms)" -f $g.apiMs
      if ($g.apiHint) { $apiText += " hint='{0}'" -f $g.apiHint }
    } elseif ($g.apiOk -eq $false) {
      $apiText = "API: FAIL ({0} ms)" -f $g.apiMs
    } else {
      $apiText = "API: ?"
    }
  }

  Write-Log ("  Step 3: Bron -> {0} | {1}" -f $g.source, $apiText) -Color DarkCyan -NoTimestamp

  # Action (folder per genre + optioneel BPM-submap)
  $targetGenreDir = Join-Path $dst $g.genre
  $targetDir = $targetGenreDir
  $actionTarget = $g.genre

  if ($UseBpmSubfolders) {
    $targetDir = Join-Path $targetGenreDir $range
    $actionTarget = "$($g.genre)\$range"
  }

  if ($range -eq $NoBpmFolderName) {
    $actionLine = "Actie: Naar {0}" -f $actionTarget
  } else {
    $actionLine = "Actie: Naar {0} ({1} BPM)" -f $actionTarget, $range
  }

  Write-Log $actionLine -Color Green -NoTimestamp

  # Als het bestand al in de juiste map zit: skip (geen onnodige Move)
  if ($Move -and ($f.DirectoryName -ieq $targetDir)) {
    Write-Log "  Reeds correct: skip" -Color DarkGreen -NoTimestamp
    continue
  }

  if ($Move) {
    if ($PSCmdlet.ShouldProcess($f.FullName, "Move to $targetDir")) {
      try {
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }

        $destPath = Join-Path $targetDir $f.Name
        if (Test-Path $destPath) {
          # if exact same file already exists -> remove source as duplicate
          try {
            $h1 = (Get-FileHash -Algorithm SHA256 -Path $f.FullName).Hash
            $h2 = (Get-FileHash -Algorithm SHA256 -Path $destPath).Hash
            if ($h1 -eq $h2) {
              if ($PSCmdlet.ShouldProcess($f.FullName, "Remove duplicate (dest already has same)")) {
                Remove-Item $f.FullName -Force
              }
              Write-Log ("DUPLICATE REMOVED (dest already had same): {0}" -f $f.FullName) -Color DarkYellow
              continue
            }
          } catch { }
          $destPath = Get-UniqueDestinationPath -DestDir $targetDir -FileName $f.Name
        }

        Move-Item -LiteralPath $f.FullName -Destination $destPath -Force
      } catch {
        Write-Log ("ERROR: Move failed: {0}" -f $f.FullName) -Color Red
      }
    }
  }
}

Write-Separator
Write-Log "Done." -Color Cyan

if ($Move -and $CleanupEmptyDirs) {
  Write-Log "Cleanup: Removing empty directories..." -Color Cyan
  Remove-EmptyDirs -Root $src
  Write-Log "Cleanup done." -Color Cyan
}

Write-Log ("Log saved: {0}" -f $logFile) -Color Cyan
