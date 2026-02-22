# Profiles

Profiles are JSON files that define *how* your library is organized without hardcoding a specific music style.

## Fields

### `destinationTemplate`
A path template (relative to target root). Tokens:

- `{genre}`: genre resolved from:
  1) embedded file tag (fast)
  2) MusicBrainz artist tag (optional, slower)
  3) `genre.unknownName`

- `{bpmRange}`: bucketed BPM range, e.g. `130-140` or `No-BPM`
- `{bpm}`: effective BPM integer
- `{artist}`: artist parsed from filename (fallback `Unknown`)
- `{artistInitial}`: first letter of artist (fallback `U`)

Examples:
- `{genre}\{bpmRange}` (Genre + BPM buckets)
- `{genre}` (Genre only)
- `{bpmRange}` (BPM only)
- `{artistInitial}\{artist}` (Artist A-Z)

### `extensions`
List of audio extensions considered.

### `workRoot`
Folder created under target for logs/tools, default: `_AudioSorter`

### `genre`
- `unknownName`: used when genre can't be resolved
- `sanitizeForFolder`: replaces invalid characters for Windows folder names

### `bpm`
- `bucketSize`: 10 -> `130-140`, 5 -> `135-140`
- `noBpmFolderName`: folder name when BPM unknown
- `doubleIfBetweenMin` / `doubleIfBetweenMax`: auto-double half-tempo BPM (e.g., 70 -> 140)

### `musicBrainz`
- `delayMs`: wait between calls (be nice)
- `userAgent`: required by many APIs; set this to your GitHub repo URL

## Tips

- If you already have good tags: prefer `genre_only.json` (fast).
- If your tags are messy: enable `-OnlineGenreLookup`.
- If you only want BPM buckets: use `bpm_only.json`.
