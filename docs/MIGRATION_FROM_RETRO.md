# Migration from Retro AudioSorter v23

Your original script was optimized for a fixed set of 7 retro/electronic genres.

This repo generalizes it to *any music type* by changing the genre strategy:

- **Old**: MusicBrainz (artist tags) -> limited hardcoded mapping -> BPM fallback
- **New**: **File genre tags first** (ID3/Vorbis/etc) -> optional MusicBrainz fallback -> `Unknown`

Why this is better for "all music":
- Rock / Pop / Jazz / Classical etc are typically already present in file tags.
- MusicBrainz is only used when tags are missing (optional).
- No hardcoded 7-genre limit.

## BPM buckets fix
Retro v23 had a `BpmBucketSize` parameter but always used 5 in the function call.
This repo correctly uses `bucketSize` from profile (default 10) so you get:
`110-120`, `130-140`, `150-160`, ...

## Same features kept
- `-WhatIf` support
- `-RemoveExactDuplicates` (SHA256)
- `-CleanupEmptyDirs`
- `-DetectBpmFromAudio` (ffmpeg + node)

## New feature: profiles
All "how to sort" logic is moved to `profiles/*.json`.
