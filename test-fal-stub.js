// Tiny local stub of the fal.ai API — used ONLY by test.sh so the voice
// tests never make a real provider call. The server under test is started
// with FAL_API_BASE_URL and FAL_QUEUE_BASE_URL both pointing here.
//
//   POST /fal-ai/gemini-3.1-flash-tts          -> { audio: { url: <tone.mp3> } }
//   POST /fal-ai/elevenlabs/tts/eleven-v3      -> { audio: { url: <tone.mp3> } }
//        (a prompt/text containing "FAILME" gets an HTTP 500 instead)
//   POST /minimax/h3-max/lip-sync/image-to-video  (queue submit)
//   POST /fal-ai/latentsync                       (queue submit)
//        -> { request_id: "stub-req-1" }
//   GET  /<model>/requests/stub-req-1/status   -> { status: "COMPLETED" }
//   GET  /<model>/requests/stub-req-1          -> { video: { url: <clip.mp4> }, duration: 2 }
//   GET  /media/<file>                         -> the generated media files
//   GET  /__calls                              -> every POST received
//        ({ calls: [{ path, body }] }) so tests can assert request shapes
//
// The media files are generated at boot with the pinned ffmpeg-static
// binary: tone.mp3 is a 2-second sine tone; clip.mp4 is a 2-second
// 320x240 video WITH an audio track (used as a lip-sync result and as a
// voiceover source video).
//
// Run:  node test-fal-stub.js   (port: FAL_STUB_PORT, default 18090)
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import ffmpegStatic from 'ffmpeg-static';

const port = Number(process.env.FAL_STUB_PORT || 18090);
const mediaDir = fs.mkdtempSync(path.join(os.tmpdir(), 'falstub-media-'));
execFileSync(ffmpegStatic, ['-y', '-v', 'error', '-f', 'lavfi',
  '-i', 'sine=frequency=660:duration=2', '-c:a', 'libmp3lame',
  path.join(mediaDir, 'tone.mp3')]);
execFileSync(ffmpegStatic, ['-y', '-v', 'error', '-f', 'lavfi',
  '-i', 'color=c=green:size=320x240:rate=24:duration=2', '-f', 'lavfi',
  '-i', 'sine=frequency=440:duration=2', '-c:v', 'libx264', '-pix_fmt',
  'yuv420p', '-c:a', 'aac', '-shortest', path.join(mediaDir, 'clip.mp4')]);

const calls = [];
const TTS_PATHS = new Set(['/fal-ai/gemini-3.1-flash-tts', '/fal-ai/elevenlabs/tts/eleven-v3']);
const QUEUE_PATHS = new Set(['/minimax/h3-max/lip-sync/image-to-video', '/fal-ai/latentsync']);

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');
  const send = (code, obj) => {
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(obj));
  };
  if (req.method === 'GET' && u.pathname === '/__calls') return send(200, { calls });
  if (req.method === 'GET' && u.pathname.startsWith('/media/')) {
    const file = path.join(mediaDir, path.basename(u.pathname));
    if (!fs.existsSync(file)) { res.writeHead(404); return res.end('not found'); }
    res.writeHead(200, { 'Content-Type': u.pathname.endsWith('.mp3') ? 'audio/mpeg' : 'video/mp4' });
    return fs.createReadStream(file).pipe(res);
  }
  if (req.method === 'GET' && /\/requests\/stub-req-1\/status$/.test(u.pathname))
    return send(200, { status: 'COMPLETED' });
  if (req.method === 'GET' && /\/requests\/stub-req-1$/.test(u.pathname))
    return send(200, { video: { url: `http://127.0.0.1:${port}/media/clip.mp4` }, duration: 2 });
  if (req.method === 'POST') {
    let raw = '';
    req.on('data', c => { raw += c; });
    req.on('end', () => {
      let body = null;
      try { body = JSON.parse(raw || '{}'); } catch { body = null; }
      calls.push({ path: u.pathname, body });
      if (TTS_PATHS.has(u.pathname)) {
        const text = String(body?.prompt || body?.text || '');
        if (text.includes('FAILME')) { res.writeHead(500); return res.end('stub TTS failure'); }
        return send(200, { audio: { url: `http://127.0.0.1:${port}/media/tone.mp3` } });
      }
      if (QUEUE_PATHS.has(u.pathname)) return send(200, { request_id: 'stub-req-1' });
      res.writeHead(404);
      res.end('not found');
    });
    return;
  }
  res.writeHead(404);
  res.end('not found');
}).listen(port, () => console.log(`fal stub listening on port ${port}`));
