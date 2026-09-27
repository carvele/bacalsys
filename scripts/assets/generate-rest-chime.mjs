#!/usr/bin/env node
/**
 * Sprint 4 · Task 4.11 — generates a short, synthesized two-tone "rest
 * complete" chime as a mono 16-bit PCM WAV file, so the repository does not
 * need a third-party audio asset for the rest timer's foreground sound cue.
 * Run once (or whenever the tone is tweaked): `node scripts/assets/generate-rest-chime.mjs`.
 */
import { writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const outPath = join(root, 'assets', 'audio', 'rest-complete.wav');

const SAMPLE_RATE = 44100;
const notes = [
  { freq: 880, durationMs: 160 }, // A5
  { freq: 1318.5, durationMs: 260 }, // E6
];
const gapMs = 20;

function tone(freq, durationMs, sampleRate) {
  const n = Math.round((durationMs / 1000) * sampleRate);
  const samples = new Float32Array(n);
  const attack = Math.min(200, Math.floor(n * 0.1));
  const release = Math.min(400, Math.floor(n * 0.3));
  for (let i = 0; i < n; i++) {
    let envelope = 1;
    if (i < attack) envelope = i / attack;
    else if (i > n - release) envelope = (n - i) / release;
    samples[i] = Math.sin((2 * Math.PI * freq * i) / sampleRate) * envelope * 0.6;
  }
  return samples;
}

function silence(durationMs, sampleRate) {
  return new Float32Array(Math.round((durationMs / 1000) * sampleRate));
}

const chunks = [];
notes.forEach((n, i) => {
  chunks.push(tone(n.freq, n.durationMs, SAMPLE_RATE));
  if (i < notes.length - 1) chunks.push(silence(gapMs, SAMPLE_RATE));
});
const total = chunks.reduce((n, c) => n + c.length, 0);
const merged = new Float32Array(total);
let offset = 0;
for (const c of chunks) {
  merged.set(c, offset);
  offset += c.length;
}

// Encode as 16-bit PCM mono WAV.
const bytesPerSample = 2;
const dataSize = merged.length * bytesPerSample;
const buffer = Buffer.alloc(44 + dataSize);
buffer.write('RIFF', 0);
buffer.writeUInt32LE(36 + dataSize, 4);
buffer.write('WAVE', 8);
buffer.write('fmt ', 12);
buffer.writeUInt32LE(16, 16); // fmt chunk size
buffer.writeUInt16LE(1, 20); // PCM
buffer.writeUInt16LE(1, 22); // mono
buffer.writeUInt32LE(SAMPLE_RATE, 24);
buffer.writeUInt32LE(SAMPLE_RATE * bytesPerSample, 28); // byte rate
buffer.writeUInt16LE(bytesPerSample, 32); // block align
buffer.writeUInt16LE(16, 34); // bits per sample
buffer.write('data', 36);
buffer.writeUInt32LE(dataSize, 40);
for (let i = 0; i < merged.length; i++) {
  const clamped = Math.max(-1, Math.min(1, merged[i]));
  buffer.writeInt16LE(Math.round(clamped * 32767), 44 + i * bytesPerSample);
}

writeFileSync(outPath, buffer);
console.log(`Wrote ${outPath} (${(buffer.length / 1024).toFixed(1)} KB, ${(total / SAMPLE_RATE).toFixed(2)}s)`);
