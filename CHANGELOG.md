# Changelog

## 1.0.0
- Generalized Retro AudioSorter v23 to work for **any genre**
- Profile-driven destination structure (`profiles/*.json`)
- Genre resolution: file tags -> optional MusicBrainz -> Unknown
- BPM buckets now correctly use profile `bucketSize` (default: 10)
- Optional BPM detection from audio snippet (ffmpeg + node)
- Optional exact duplicate removal (SHA256)
- Basic GitHub Actions Pester CI scaffold
