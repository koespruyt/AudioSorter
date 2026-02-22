# AudioSorter PowerShell module
# Supports: genre (tags + optional MusicBrainz), optional BPM from tags or audio snippet (ffmpeg+node),
# exact duplicate removal (SHA256), and moving/copying into a profile-driven folder layout.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------
# Logging
# ---------------------------
function Write-ASLog {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message,
    [ConsoleColor]$Color = [ConsoleColor]::Gray,
    [string]$LogFile,
    [switch]$NoConsole,
    [switch]$NoTimestamp
  )
  if ($null -eq $Message) { return }

  if (-not $NoConsole) {
    if ($Message -eq "") { Write-Host "" }
    else { Write-Host $Message -ForegroundColor $Color }
  }

  # Avoid thousands of "What if: Add Content" lines
  if ($WhatIfPreference) { return }
  if (-not $LogFile) { return }

  $ts = if ($NoTimestamp) { "" } else { "[{0}] " -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
  $line = "$ts$Message"
  try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 }
  catch { Write-Host ("WARN: Failed to write log file '{0}': {1}" -f $LogFile, $_.Exception.Message) -ForegroundColor Yellow }
}

function Write-ASSeparator {
  param([string]$LogFile)
  Write-ASLog -Message "------------------------------------------------------------" -Color DarkGray -NoTimestamp -LogFile $LogFile
}

# ---------------------------
# Utils
# ---------------------------
function Get-ASFileExtensionsRegex {
  param([string[]]$Extensions)
  if (-not $Extensions -or $Extensions.Count -eq 0) { $Extensions = @('mp3','flac','wav','m4a','aac','ogg') }
  $ext = ($Extensions | ForEach-Object { $_.Trim().TrimStart('.').ToLowerInvariant() } | Where-Object { $_ }) | Select-Object -Unique
  return ($ext -join '|')
}

function ConvertTo-ASSafeFolderName {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [int]$MaxLength = 60,
    [string]$Default = "Unknown"
  )
  $n = ( $(if($null -eq $Name) { "" } else { [string]$Name }) ).Trim()
  if ([string]::IsNullOrWhiteSpace($n)) { return $Default }

  # replace invalid Windows filename chars
  $n = $n -replace '[<>:"/\\|?*\x00-\x1F]', '_'
  $n = $n -replace '\s+', ' '
  $n = $n.Trim(' .')

  if ([string]::IsNullOrWhiteSpace($n)) { return $Default }
  if ($n.Length -gt $MaxLength) { $n = $n.Substring(0, $MaxLength).Trim() }
  return $n
}

function Get-CleanArtist {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$FileName)

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

  return "Unknown"
}

# ---------------------------
# BPM
# ---------------------------
function Get-BpmFromTags {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$FfprobePath
  )
  if (-not $FfprobePath) { return $null }

  try {
    # Try common tag names: TBPM (ID3), BPM (Vorbis/FLAC), bpm
    $out = & $FfprobePath -v error -show_entries format_tags=TBPM,BPM,bpm -of default=nw=1:nk=0 $Path 2>$null
    if (-not $out) { return $null }

    foreach ($line in $out) {
      if ($line -match '=\s*([0-9]+(\.[0-9]+)?)\s*$') {
        $val = [double]$matches[1]
        if ($val -ge 40 -and $val -le 250) { return [int][math]::Round($val) }
      }
    }
  } catch { }
  return $null
}

function Get-EffectiveBpm {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][int]$RawBpm,
    [int]$DoubleIfBetweenMin = 60,
    [int]$DoubleIfBetweenMax = 95
  )
  $effective = $RawBpm
  $mult = 1
  if ($RawBpm -gt $DoubleIfBetweenMin -and $RawBpm -lt $DoubleIfBetweenMax) { $effective = $RawBpm * 2; $mult = 2 }
  return [pscustomobject]@{ raw=$RawBpm; effective=$effective; mult=$mult }
}

function Get-BpmRange {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][int]$Bpm,
    [int]$Step = 10,
    [string]$NoBpm = 'No-BPM'
  )
  if ($Bpm -le 0) { return $NoBpm }
  if ($Step -lt 1) { $Step = 10 }
  $lo = [int]([math]::Floor($Bpm / $Step) * $Step)
  $hi = $lo + $Step
  return ("{0}-{1}" -f $lo, $hi)
}

function Detect-BpmFromAudioSnippet {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$FfmpegPath,
    [Parameter(Mandatory=$true)][string]$NodePath,
    [Parameter(Mandatory=$true)][string]$JsToolPath,
    [ValidateRange(5,60)][int]$Seconds = 10,
    [int]$StartAtSeconds = 30
  )

  $result = [ordered]@{ ok=$false; bpm=0; seconds=0.0; reason="" }

  if (-not (Test-Path -LiteralPath $JsToolPath)) {
    $result.reason = "Missing bpm_detect.js"
    return [pscustomobject]$result
  }

  $tmpWav = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString() + ".wav")
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  try {
    & $FfmpegPath -hide_banner -loglevel error -y -i $Path -ss $StartAtSeconds -t $Seconds -ac 1 -ar 44100 -c:a pcm_s16le $tmpWav 2>$null
    $raw = & $NodePath $JsToolPath $tmpWav 2>$null
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
    if (Test-Path -LiteralPath $tmpWav) { Remove-Item -LiteralPath $tmpWav -Force -ErrorAction SilentlyContinue }
  }

  return [pscustomobject]$result
}

# ---------------------------
# Genre (tags -> optional MusicBrainz -> fallback)
# ---------------------------
function Get-GenreFromFileTags {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$FfprobePath
  )
  if (-not $FfprobePath) { return $null }
  try {
    # Common keys across containers: genre/GENRE, ID3 TCON
    $out = & $FfprobePath -v error -show_entries format_tags=genre,GENRE,TCON -of default=nw=1:nk=0 $Path 2>$null
    if (-not $out) { return $null }
    foreach ($line in $out) {
      if ($line -match '=\s*(.+?)\s*$') {
        $val = $matches[1].Trim()
        if ($val) {
          # If multiple genres are present, take the first (foldering remains stable)
          $first = ($val -split '[,;/]|\\' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 1)
          if ($first) { return $first }
        }
      }
    }
  } catch { }
  return $null
}

function Get-MusicBrainzGenreHintForArtist {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Artist,
    [int]$DelayMs = 900,
    [int]$TimeoutSec = 15,
    [string]$UserAgent = "AudioSorter/1.0 (+https://github.com/yourname/AudioSorter)"
  )

  Start-Sleep -Milliseconds $DelayMs

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $query = [Uri]::EscapeDataString(('artist:"{0}"' -f $Artist))
    $url   = "https://musicbrainz.org/ws/2/artist/?query=$query&fmt=json"
    $resp = Invoke-RestMethod -Uri $url -UserAgent $UserAgent -TimeoutSec $TimeoutSec

    if ($resp.artists.Count -gt 0) {
      $tags = $resp.artists[0].tags | Sort-Object count -Descending
      if ($tags -and $tags[0].name) {
        $sw.Stop()
        return [pscustomobject]@{ ok=$true; hint=[string]$tags[0].name; ms=[int][math]::Round($sw.Elapsed.TotalMilliseconds,0) }
      }
    }

    $sw.Stop()
    return [pscustomobject]@{ ok=$true; hint=""; ms=[int][math]::Round($sw.Elapsed.TotalMilliseconds,0) }
  } catch {
    $sw.Stop()
    return [pscustomobject]@{ ok=$false; hint=""; ms=[int][math]::Round($sw.Elapsed.TotalMilliseconds,0) }
  }
}

function Resolve-ASGenre {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Artist,
    [Parameter(Mandatory=$true)][hashtable]$Cache,
    [string]$FfprobePath,
    [switch]$OnlineGenreLookup,
    [string]$UnknownGenreName = "Unknown",
    [int]$MusicBrainzDelayMs = 900,
    [string]$UserAgent = "AudioSorter/1.0 (+https://github.com/yourname/AudioSorter)"
  )

  if ($Cache.ContainsKey($Path)) { return $Cache[$Path] }

  # 1) embedded file genre tag
  $tagGenre = Get-GenreFromFileTags -Path $Path -FfprobePath $FfprobePath
  if ($tagGenre) {
    $g = [pscustomobject]@{ genre=$tagGenre; source="Tag"; apiUsed=$false; apiOk=$null; apiMs=$null; apiHint="" }
    $Cache[$Path] = $g
    return $g
  }

  # 2) MusicBrainz (artist tags) if enabled
  if ($OnlineGenreLookup -and $Artist -ne "Unknown" -and $Artist.Length -gt 2) {
    $mb = Get-MusicBrainzGenreHintForArtist -Artist $Artist -DelayMs $MusicBrainzDelayMs -UserAgent $UserAgent
    if ($mb.ok -and $mb.hint) {
      $g = [pscustomobject]@{ genre=$mb.hint; source="MusicBrainz"; apiUsed=$true; apiOk=$true; apiMs=$mb.ms; apiHint=$mb.hint }
      $Cache[$Path] = $g
      return $g
    }
    # MB ok but no tag -> fallback to Unknown
    $srcName = "Fallback"; if ($mb.ok) { $srcName = "MusicBrainz" }
    $g = [pscustomobject]@{ genre=$UnknownGenreName; source=$srcName; apiUsed=$true; apiOk=$mb.ok; apiMs=$mb.ms; apiHint="" }
    $Cache[$Path] = $g
    return $g
  }

  $g = [pscustomobject]@{ genre=$UnknownGenreName; source="Fallback"; apiUsed=$false; apiOk=$null; apiMs=$null; apiHint="" }
  $Cache[$Path] = $g
  return $g
}

# ---------------------------
# Duplicates
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
  [CmdletBinding(SupportsShouldProcess=$true)]
  param(
    [Parameter(Mandatory=$true)][System.IO.FileInfo[]]$Files,
    [string]$LogFile
  )

  Write-ASLog -Message ("Exact duplicate scan (SHA256) over {0} files..." -f $Files.Count) -Color Cyan -LogFile $LogFile

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
      Write-ASLog -Message ("WARN: Hash failed: {0}" -f $f.FullName) -Color DarkYellow -NoConsole -LogFile $LogFile
    }
  }
  Write-Progress -Activity "Hashing..." -Completed

  $dupeGroups = $hashMap.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }
  $removed = 0

  foreach ($g in $dupeGroups) {
    $items = $g.Value
    $keep = $items | Sort-Object @{Expression={ Get-ExtPriority $_.Extension }; Descending=$true}, @{Expression={$_.Length}; Descending=$true} | Select-Object -First 1

    foreach ($d in $items) {
      if ($d.FullName -eq $keep.FullName) { continue }
      if ($PSCmdlet.ShouldProcess($d.FullName, "Remove duplicate (same SHA256 as $($keep.FullName))")) {
        try {
          Remove-Item -LiteralPath $d.FullName -Force
          $removed++
          Write-ASLog -Message ("DUPLICATE REMOVED: {0} (kept: {1})" -f $d.FullName, $keep.FullName) -Color DarkYellow -LogFile $LogFile
        } catch {
          Write-ASLog -Message ("WARN: Failed to remove duplicate: {0}" -f $d.FullName) -Color DarkYellow -LogFile $LogFile
        }
      }
    }
  }

  Write-ASLog -Message ("Duplicate scan done. Removed: {0}" -f $removed) -Color Cyan -LogFile $LogFile
}

# ---------------------------
# Move helpers
# ---------------------------
function Get-UniqueDestinationPath {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$DestDir,
    [Parameter(Mandatory=$true)][string]$FileName
  )
  $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
  $ext  = [System.IO.Path]::GetExtension($FileName)
  $dest = Join-Path $DestDir $FileName
  if (-not (Test-Path -LiteralPath $dest)) { return $dest }

  for ($n=2; $n -le 999; $n++) {
    $cand = Join-Path $DestDir ("{0} ({1}){2}" -f $base, $n, $ext)
    if (-not (Test-Path -LiteralPath $cand)) { return $cand }
  }
  return Join-Path $DestDir ("{0}_{1}{2}" -f $base, ([Guid]::NewGuid().ToString("N").Substring(0,6)), $ext)
}

function Remove-EmptyDirs {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [string]$ExcludePattern = "_AudioSorter"
  )

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
      }
    } catch { }
  }
}

# ---------------------------
# Profile loading
# ---------------------------
function Get-ASProfile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$ProfilePath
  )
  if (-not (Test-Path -LiteralPath $ProfilePath)) {
    throw "Profile not found: $ProfilePath"
  }
  $raw = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8
  $p = $raw | ConvertFrom-Json
  return $p
}

function Expand-ASDestinationTemplate {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Template,
    [Parameter(Mandatory=$true)][hashtable]$Tokens
  )
  $out = $Template
  foreach ($k in $Tokens.Keys) {
    $out = $out -replace ("\{" + [regex]::Escape($k) + "\}"), [string]$Tokens[$k]
  }
  return $out
}

# ---------------------------
# Main entry
# ---------------------------
function Invoke-AudioSorter {
  [CmdletBinding(SupportsShouldProcess=$true)]
  param(
    [Parameter(Mandatory=$true)][string]$Source,
    [string]$Target,
    [string]$Profile = "profiles/default.json",

    [switch]$Move,
    [switch]$Copy,

    [switch]$OnlineGenreLookup,
    [switch]$DetectBpmFromAudio,

    [ValidateRange(5,60)][int]$AudioBpmSeconds = 10,
    [int]$AudioBpmStartAtSeconds = 30,

    [switch]$RemoveExactDuplicates,
    [switch]$CleanupEmptyDirs
  )

  if ($Move -and $Copy) { throw "Choose either -Move or -Copy (not both)." }

  $here = $PSScriptRoot
  $profilePath = if ([System.IO.Path]::IsPathRooted($Profile)) { $Profile } else { Join-Path $here "..\..\$Profile" }
  $profilePath = (Resolve-Path $profilePath).Path
  $profileObj = Get-ASProfile -ProfilePath $profilePath

  $src = (Resolve-Path $Source).Path
  $dst = if ($Target) { (Resolve-Path $Target).Path } else { $src }

  # Work dirs
  $workRoot = Join-Path $dst $(if($null -ne $profileObj.workRoot -and [string]$profileObj.workRoot) { [string]$profileObj.workRoot } else { "_AudioSorter" })
  $toolsDir = Join-Path $workRoot "tools"
  $logsDir  = Join-Path $workRoot "logs"
  New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
  New-Item -ItemType Directory -Path $logsDir  -Force | Out-Null

  $nowStamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
  $logFile = Join-Path $logsDir ("audio_sorter_log_{0}.txt" -f $nowStamp)

  # tools
  $ffmpeg  = Get-Command ffmpeg  -ErrorAction SilentlyContinue
  $ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
  $ffprobePath = $null
  if ($ffprobe) { $ffprobePath = $ffprobe.Path }
  $node    = Get-Command node    -ErrorAction SilentlyContinue

  $jsTool = Join-Path (Join-Path $here "..\..\tools\bpm") "bpm_detect.js"

  # config defaults
  $extensions = @($profileObj.extensions)
  $extRegex = Get-ASFileExtensionsRegex -Extensions $extensions

  $unknownGenre = $(if($null -ne $profileObj.genre -and $null -ne $profileObj.genre.unknownName -and [string]$profileObj.genre.unknownName) { [string]$profileObj.genre.unknownName } else { "Unknown" })
  $sanitizeGenre = $true
  if ($null -ne $profileObj.genre -and $null -ne $profileObj.genre.sanitizeForFolder) { $sanitizeGenre = [bool]$profileObj.genre.sanitizeForFolder }

  $useBpmSubfolders = $true
  if ($null -ne $profileObj.bpm -and $null -ne $profileObj.bpm.useSubfolders) { $useBpmSubfolders = [bool]$profileObj.bpm.useSubfolders }
  $bpmStep = 10
  if ($null -ne $profileObj.bpm -and $null -ne $profileObj.bpm.bucketSize) { $bpmStep = [int]$profileObj.bpm.bucketSize }

  $noBpmFolder = "No-BPM"
  if ($null -ne $profileObj.bpm -and $null -ne $profileObj.bpm.noBpmFolderName -and [string]$profileObj.bpm.noBpmFolderName) { $noBpmFolder = [string]$profileObj.bpm.noBpmFolderName }

  $doubleMin = 60
  if ($null -ne $profileObj.bpm -and $null -ne $profileObj.bpm.doubleIfBetweenMin) { $doubleMin = [int]$profileObj.bpm.doubleIfBetweenMin }

  $doubleMax = 95
  if ($null -ne $profileObj.bpm -and $null -ne $profileObj.bpm.doubleIfBetweenMax) { $doubleMax = [int]$profileObj.bpm.doubleIfBetweenMax }

  $template = $(if($null -ne $profileObj.destinationTemplate -and [string]$profileObj.destinationTemplate) { [string]$profileObj.destinationTemplate } else { "{genre}\{bpmRange}" })

  $mbDelay = 900
  if ($null -ne $profileObj.musicBrainz -and $null -ne $profileObj.musicBrainz.delayMs) { $mbDelay = [int]$profileObj.musicBrainz.delayMs }

  $mbUA = "AudioSorter/1.0 (+https://github.com/yourname/AudioSorter)"
  if ($null -ne $profileObj.musicBrainz -and $null -ne $profileObj.musicBrainz.userAgent -and [string]$profileObj.musicBrainz.userAgent) { $mbUA = [string]$profileObj.musicBrainz.userAgent }

  # caches
  $genreCache = @{} # per-file cache (safe; tags differ per file)
  $bpmCache = @{}   # per-file cache

  Write-ASLog -Message "" -NoTimestamp -LogFile $logFile
  Write-ASLog -Message ("🚀 Start. Source={0}" -f $src) -Color Cyan -LogFile $logFile
  Write-ASLog -Message ("Target={0}" -f $dst) -Color Cyan -LogFile $logFile
  Write-ASLog -Message ("Profile={0}" -f $profilePath) -Color Cyan -LogFile $logFile
  Write-ASLog -Message ("Log={0}" -f $logFile) -Color Cyan -LogFile $logFile
  Write-ASLog -Message "" -NoTimestamp -LogFile $logFile

  # exclusions
  $excludePatterns = @("\\_AudioSorter\\")
  if ($profileObj.workRoot -and $profileObj.workRoot -ne "_AudioSorter") {
    $excludePatterns = @("\\" + [regex]::Escape([string]$profileObj.workRoot) + "\\")
  }
  $files = Get-ChildItem -Path $src -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Extension.TrimStart('.').ToLowerInvariant() -match $extRegex } |
           Where-Object {
             $p = $_.FullName
             foreach ($pat in $excludePatterns) { if ($p -match $pat) { return $false } }
             return $true
           }

  Write-ASLog -Message ("Found audio files: {0}" -f $files.Count) -Color Cyan -LogFile $logFile

  if ($RemoveExactDuplicates) {
    Remove-ExactDuplicatesByHash -Files $files -LogFile $logFile
    # refresh list after removals
    $files = Get-ChildItem -Path $src -Recurse -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension.TrimStart('.').ToLowerInvariant() -match $extRegex } |
             Where-Object {
               $p = $_.FullName
               foreach ($pat in $excludePatterns) { if ($p -match $pat) { return $false } }
               return $true
             }
  }

  foreach ($f in $files) {
    $artist = Get-CleanArtist -FileName $f.Name

    Write-ASSeparator -LogFile $logFile
    Write-ASLog -Message ("FILE: {0}" -f $f.Name) -Color White -NoTimestamp -LogFile $logFile

    # BPM: Tags -> Audio -> none
    $rawBpm  = 0
    $bpmFrom = "None"

    $tagBpm = $null
    if ($ffprobePath) { $tagBpm = Get-BpmFromTags -Path $f.FullName -FfprobePath $ffprobePath }

    $audioInfo = [pscustomobject]@{ ok=$false; bpm=0; seconds=0.0; reason="Skip" }
    if (-not $tagBpm -and $DetectBpmFromAudio) {
      if (-not $ffmpeg -or -not $node) {
        $audioInfo = [pscustomobject]@{ ok=$false; bpm=0; seconds=0.0; reason="Missing tools (ffmpeg/node)" }
      } else {
        $audioInfo = Detect-BpmFromAudioSnippet -Path $f.FullName -FfmpegPath $ffmpeg.Path -NodePath $node.Path -JsToolPath $jsTool -Seconds $AudioBpmSeconds -StartAtSeconds $AudioBpmStartAtSeconds
      }
    }

    if ($tagBpm) { $rawBpm = [int]$tagBpm; $bpmFrom = "Tag" }
    elseif ($audioInfo.ok) { $rawBpm = [int]$audioInfo.bpm; $bpmFrom = "Audio" }
    else { $rawBpm = 0; $bpmFrom = "None" }

    $eff = Get-EffectiveBpm -RawBpm $rawBpm -DoubleIfBetweenMin $doubleMin -DoubleIfBetweenMax $doubleMax
    $range = Get-BpmRange -Bpm $eff.effective -Step $bpmStep -NoBpm $noBpmFolder

    $audioScanText =
      if (-not $DetectBpmFromAudio) { "AudioScan: OFF" }
      elseif ($tagBpm) { "AudioScan: SKIP (tag BPM)" }
      elseif ($audioInfo.reason -eq "Skip") { "AudioScan: SKIP" }
      elseif ($audioInfo.ok) { "AudioScan: OK ({0:0.0}s, window {1}s)" -f $audioInfo.seconds, $AudioBpmSeconds }
      else { "AudioScan: FAIL ({0}, {1:0.0}s)" -f $audioInfo.reason, $audioInfo.seconds }

    $bpmLine = "  Step 1: BPM -> {0} (Effective: {1})" -f $eff.raw, $eff.effective
    if ($eff.mult -eq 2) { $bpmLine += " [x2]" }
    $bpmLine += " | Source: {0} | {1}" -f $bpmFrom, $audioScanText
    Write-ASLog -Message $bpmLine -Color Yellow -NoTimestamp -LogFile $logFile

    Write-ASLog -Message ("  Step 2: Artist -> {0}" -f $artist) -Color Cyan -NoTimestamp -LogFile $logFile

    # Genre
    $genreResolved = Resolve-ASGenre -Path $f.FullName -Artist $artist -Cache $genreCache -FfprobePath $ffprobePath -OnlineGenreLookup:$OnlineGenreLookup -UnknownGenreName $unknownGenre -MusicBrainzDelayMs $mbDelay -UserAgent $mbUA
    $genreName = [string]$genreResolved.genre
    if ($sanitizeGenre) { $genreName = ConvertTo-ASSafeFolderName -Name $genreName -Default $unknownGenre }

    $apiText = "API: OFF"
    if ($OnlineGenreLookup) {
      if ($genreResolved.source -eq "Tag") { $apiText = "API: SKIP (tag present)" }
      elseif ($genreResolved.apiUsed -and $genreResolved.apiOk -eq $true) { $apiText = "API: OK ({0} ms) hint='{1}'" -f $genreResolved.apiMs, $genreResolved.apiHint }
      elseif ($genreResolved.apiUsed -and $genreResolved.apiOk -eq $false) { $apiText = "API: FAIL ({0} ms)" -f $genreResolved.apiMs }
      else { $apiText = "API: ?" }
    }

    # Normalize genre casing (bv. "electronic" -> "Electronic")
    if ($genreResolved -and $genreResolved.genre -and ($genreResolved.genre -ceq $genreResolved.genre.ToLowerInvariant())) {
      try { $genreResolved.genre = (Get-Culture).TextInfo.ToTitleCase($genreResolved.genre) } catch {}
    }

    # FAIL->MISS (Fallback): API bereikbaar maar geen bruikbare genre-hint gevonden.
    $__src = $null
    if ($genreResolved) {
      if ($genreResolved.PSObject.Properties.Name -contains "source") { $__src = $genreResolved.source }
      elseif ($genreResolved.PSObject.Properties.Name -contains "Source") { $__src = $genreResolved.Source }
    }
    if ($OnlineGenreLookup -and $__src -eq "Fallback" -and $apiText -match "API:\s*FAIL") { $apiText = ($apiText -replace "API:\s*FAIL","API: MISS") }
    
    # Normalize genre casing (TitleCase) so folders are "Electronic" not "electronic"
    $__g = $null
    if ($genreResolved) {
      if ($genreResolved.PSObject.Properties.Name -contains "genre") { $__g = $genreResolved.genre }
      elseif ($genreResolved.PSObject.Properties.Name -contains "Genre") { $__g = $genreResolved.Genre }
    }
    if ($__g -and ($__g -ceq $__g.ToLowerInvariant())) {
      try { $__g = (Get-Culture).TextInfo.ToTitleCase($__g) } catch {}
      if ($genreResolved.PSObject.Properties.Name -contains "genre") { $genreResolved.genre = $__g }
      if ($genreResolved.PSObject.Properties.Name -contains "Genre") { $genreResolved.Genre = $__g }
    }

    Write-ASLog -Message ("  Step 3: Genre -> {0} | Source: {1} | {2}" -f $genreName, $genreResolved.source, $apiText) -Color DarkCyan -NoTimestamp -LogFile $logFile

    # Destination
    $artistInitial = if ($artist -and $artist -ne "Unknown") { $artist.Substring(0,1).ToUpperInvariant() } else { "U" }
    $tokens = @{
      genre = $genreName
      bpmRange = $range
      bpm = $eff.effective
      artist = (ConvertTo-ASSafeFolderName -Name $artist -Default "Unknown")
      artistInitial = (ConvertTo-ASSafeFolderName -Name $artistInitial -Default "U")
    }

    $relPath = Expand-ASDestinationTemplate -Template $template -Tokens $tokens
    $relPath = $relPath -replace '[\\\/]+', '\'
    $targetDir = Join-Path $dst $relPath

    # optional: if bpm disabled in template, user can set template without {bpmRange}
    if (-not $useBpmSubfolders -and $template -match '\{bpmRange\}') {
      # keep backward behaviour: remove bpmRange token if disabled
      $targetDir = Join-Path $dst (Expand-ASDestinationTemplate -Template ($template -replace '\\\{bpmRange\}', '') -Tokens $tokens)
    }

    $actionLine =
      if ($range -eq $noBpmFolder) { "Action: {0}" -f $relPath }
      else { "Action: {0} ({1} BPM)" -f $relPath, $range }
    Write-ASLog -Message $actionLine -Color Green -NoTimestamp -LogFile $logFile

    # Already in correct location -> skip
    if (($Move -or $Copy) -and ($f.DirectoryName -ieq $targetDir)) {
      Write-ASLog -Message "  Already correct: skip" -Color DarkGreen -NoTimestamp -LogFile $logFile
      continue
    }

    if ($Move -or $Copy) {
      $op = if ($Move) { "Move" } else { "Copy" }
      if ($PSCmdlet.ShouldProcess($f.FullName, "$op to $targetDir")) {
        try {
          if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }

          $destPath = Join-Path $targetDir $f.Name
          if (Test-Path -LiteralPath $destPath) {
            # if exact same exists -> remove source when moving; skip when copying
            try {
              $h1 = (Get-FileHash -Algorithm SHA256 -Path $f.FullName).Hash
              $h2 = (Get-FileHash -Algorithm SHA256 -Path $destPath).Hash
              if ($h1 -eq $h2) {
                if ($Move) {
                  if ($PSCmdlet.ShouldProcess($f.FullName, "Remove duplicate (dest already has same)")) {
                    Remove-Item -LiteralPath $f.FullName -Force
                  }
                  Write-ASLog -Message ("DUPLICATE REMOVED (dest already had same): {0}" -f $f.FullName) -Color DarkYellow -LogFile $logFile
                } else {
                  Write-ASLog -Message ("Duplicate exists, copy skipped: {0}" -f $f.FullName) -Color DarkYellow -LogFile $logFile
                }
                continue
              }
            } catch { }
            $destPath = Get-UniqueDestinationPath -DestDir $targetDir -FileName $f.Name
          }

          if ($Move) { Move-Item -LiteralPath $f.FullName -Destination $destPath -Force }
          else { Copy-Item -LiteralPath $f.FullName -Destination $destPath -Force }
        } catch {
          Write-ASLog -Message ("ERROR: {0} failed: {1}" -f $op, $f.FullName) -Color Red -LogFile $logFile
        }
      }
    }
  }

  Write-ASSeparator -LogFile $logFile
  Write-ASLog -Message "Done." -Color Cyan -LogFile $logFile

  if ($Move -and $CleanupEmptyDirs) {
    Write-ASLog -Message "Cleanup: Removing empty directories..." -Color Cyan -LogFile $logFile
    Remove-EmptyDirs -Root $src
    Write-ASLog -Message "Cleanup done." -Color Cyan -LogFile $logFile
  }

  Write-ASLog -Message ("Log saved: {0}" -f $logFile) -Color Cyan -LogFile $logFile
  return $logFile
}

Export-ModuleMember -Function Invoke-AudioSorter

