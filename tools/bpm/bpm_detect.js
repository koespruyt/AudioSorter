// Simple BPM estimation on mono PCM16 WAV.
// Usage: node bpm_detect.js input.wav
// Output: JSON { ok: true, bpm: <int> } or { ok: false }
//
// Notes:
// - This is a lightweight heuristic (good enough for "bucket" sorting).
// - For maximum accuracy, use a dedicated BPM library; this tool is intentionally minimal.

const fs = require("fs");

try {
  const wavPath = process.argv[2];
  const buf = fs.readFileSync(wavPath);

  // WAV header is typically 44 bytes for PCM16 LE
  const pcm = buf.slice(44);
  const data = new Int16Array(pcm.buffer, pcm.byteOffset, Math.floor(pcm.length / 2));

  // ~10ms windows at 44.1kHz => 441 samples
  const step = 441;
  const energy = [];
  for (let i = 0; i < data.length; i += step) {
    let sum = 0;
    for (let j = 0; j < step && (i + j) < data.length; j++) sum += Math.abs(data[i + j]);
    energy.push(sum);
  }

  // Onset strength (simple derivative)
  const onsets = energy.map((v, i) => i === 0 ? 0 : Math.max(0, v - energy[i - 1]));

  // Autocorrelation search
  let bestBpm = 0, maxCorr = 0;
  for (let bpm = 80; bpm <= 190; bpm++) {
    let corr = 0;
    const interval = Math.max(1, Math.round((60 / bpm) * 100)); // ~100 onset samples/sec
    for (let i = interval; i < onsets.length; i++) corr += onsets[i] * onsets[i - interval];
    if (corr > maxCorr) { maxCorr = corr; bestBpm = bpm; }
  }

  console.log(JSON.stringify({ ok: true, bpm: bestBpm }));
} catch (e) {
  console.log(JSON.stringify({ ok: false }));
}
