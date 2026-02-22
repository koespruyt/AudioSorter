# Usage

## Dry-run
Always start with `-WhatIf`:

```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Profile profiles\default.json -WhatIf
```

## Move (default profile)
```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Move
```

## Copy (keep originals)
```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Copy
```

## Online genre lookup (MusicBrainz)
```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Move -OnlineGenreLookup
```

## BPM from audio (only if no tag BPM exists)
```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Move -DetectBpmFromAudio -AudioBpmSeconds 10
```

## Cleanup empty dirs after moving
```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Move -CleanupEmptyDirs
```

## Where are logs?
Logs go to:
`<Target>\_AudioSorter\logs\audio_sorter_log_YYYYMMDD_HHMMSS.txt`
