# FAQ

## It says "Missing tools (ffmpeg/node)" or "ffprobe missing"
- Install FFmpeg (includes `ffmpeg` and `ffprobe`) and make sure it's in PATH.
- Install Node.js and make sure `node` is in PATH.

Without these tools, AudioSorter still works:
- Genre can still be resolved via MusicBrainz (if enabled)
- BPM-from-audio won't run without ffmpeg+node
- BPM-from-tags won't run without ffprobe

## My genres are messy / too many
That's expected if the original tags are inconsistent.
Options:
- Keep only the first genre token (the sorter does that by default)
- Turn off MusicBrainz and rely on your own curated tags

## Does this edit audio tags?
No. This tool only reads tags and moves/copies files.
