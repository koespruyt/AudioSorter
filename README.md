# AudioSorter (PowerShell)

Profile-driven **music library sorter** for **any music genre** (not just retro/electronic).

It can:
- read **Genre** from file tags (ID3/Vorbis/etc) via `ffprobe`
- optionally enrich missing genres via **MusicBrainz** (artist tags)
- read **BPM** from tags (TBPM/BPM) via `ffprobe`
- optionally estimate BPM from audio (short snippet) via `ffmpeg` + `node` (lightweight `bpm_detect.js`)
- optionally remove **exact duplicates** (SHA256) before sorting
- **move** or **copy** audio into a clean folder structure using a **profile (JSON)**

> Safety: by default it only **analyzes + logs**. Use `-Move` or `-Copy` to actually change files.  
> Supports `-WhatIf`.

---

## Quick start

### 1) Clone and run (Windows PowerShell 5.1+ or PowerShell 7+)

```powershell
git clone https://github.com/koespruyt/AudioSorter
cd AudioSorter
Unblock-File .\AudioSorter.ps1
```

### 2) Dry-run (recommended)

```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Profile profiles\default.json -WhatIf
```

### 3) Move into folders (Genre\BPMRange)

```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Move -Profile profiles\default.json
```

### 4) BPM buckets like 110-120, 130-140, 150-160, ...

`profiles/default.json` uses `"bucketSize": 10` so you automatically get:
- 110-120
- 120-130
- 130-140
- 140-150
- 150-160
etc.

---

## Requirements

### Mandatory
- PowerShell 5.1+ (Windows) or PowerShell 7+

### Optional (recommended) tools

De sorter kan zonder deze tools draaien, maar met extra tools krijg je **betere genre/BPM detectie**.

- **ffprobe** (onderdeel van FFmpeg) — *aanrader*
  - Wordt gebruikt om **tags** uit audio te lezen (Genre, BPM, Artist, Title, …)
  - Zonder ffprobe: tag-based genre/BPM is beperkter (de sorter blijft verder werken).

- **ffmpeg** (FFmpeg) — *aanrader als je BPM uit audio wil*
  - Nodig voor **BPM-from-audio** (decode/convert om BPM te analyseren)
  - Zonder ffmpeg: `-DetectBpmFromAudio` wordt automatisch overgeslagen (logt “missing tool”).

- **node** (Node.js) — *aanrader als je BPM uit audio wil*
  - Nodig om de **BPM detector (`tools/bpm`)** te draaien
  - Zonder node: `-DetectBpmFromAudio` wordt automatisch overgeslagen (logt “missing tool”).

### Behavior when tools are missing
- De sorter **crasht niet** als een tool ontbreekt.
- Hij logt duidelijk welke tool ontbreekt en **gaat verder** met wat wél kan:
  - Geen ffprobe → minder/geen tag-based genre/BPM
  - Geen ffmpeg of node → geen BPM-from-audio (tracks gaan dan naar `No-BPM` als er ook geen BPM tag is)

### Quick check (Windows)
```powershell
ffprobe -version
ffmpeg -version
node -v




## Profiles (JSON)

Profiles live in `profiles/`.

Folder layout is controlled via `destinationTemplate` with tokens:
- `{genre}` – resolved genre (Tag -> MusicBrainz -> Unknown)
- `{bpmRange}` – e.g. `130-140` (or `No-BPM`)
- `{bpm}` – effective BPM integer
- `{artist}` – parsed artist from filename
- `{artistInitial}` – first letter of artist

Examples:
- Genre + BPM: `{genre}\{bpmRange}` *(default)*
- Genre only: `{genre}`
- BPM only: `{bpmRange}`
- Artist A-Z: `{artistInitial}\{artist}`

See **docs/PROFILES.md** for details.

---

## Common commands

### Genre from file tags only (fast)
```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Move -Profile profiles\genre_only.json
```

### Add MusicBrainz fallback for missing genres
```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Move -Profile profiles\default.json -OnlineGenreLookup
```

### BPM detection from audio snippet (only if no tag BPM)
```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Move -Profile profiles\default.json -DetectBpmFromAudio -AudioBpmSeconds 10
```

### Exact duplicates removal (SHA256) before sorting
```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Move -RemoveExactDuplicates
```

### Cleanup empty folders after moving
```powershell
.\AudioSorter.ps1 -Source "D:\Music" -Move -CleanupEmptyDirs
```

---

## Notes / caveats

- **MusicBrainz** lookups are rate-limited; the profile includes a small delay (`delayMs`) to be friendly.
- Genre quality depends on your file tags and/or MusicBrainz tagging quality.
- BPM-from-audio is a lightweight heuristic intended for **bucket sorting**, not DJ-grade precision.

---

## Repo layout

- `AudioSorter.ps1` – CLI entrypoint
- `src/AudioSorter/` – module (`Invoke-AudioSorter`)
- `profiles/` – JSON profiles for folder structure & behavior
- `tools/bpm/bpm_detect.js` – small BPM estimator for WAV snippets
- `docs/` – usage + profiles + FAQ
- `.github/workflows/` – basic Pester CI scaffold

---

## License
MIT – see `LICENSE`.
