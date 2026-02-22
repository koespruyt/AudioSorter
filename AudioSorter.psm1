{
  "workRoot": "_AudioSorter",
  "extensions": [
    "mp3",
    "flac",
    "wav",
    "m4a",
    "aac",
    "ogg"
  ],
  "destinationTemplate": "{genre}",
  "genre": {
    "unknownName": "Unknown",
    "sanitizeForFolder": true
  },
  "bpm": {
    "useSubfolders": false,
    "bucketSize": 10,
    "noBpmFolderName": "No-BPM"
  },
  "musicBrainz": {
    "delayMs": 900,
    "userAgent": "AudioSorter/1.0 (+https://github.com/yourname/AudioSorter)"
  }
}