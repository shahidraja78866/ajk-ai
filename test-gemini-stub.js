// Tiny local stub of the Gemini generateContent endpoint — used ONLY by
// test.sh so the test battery never calls the real Gemini API.
// The server under test is started with GEMINI_API_KEY set and
// PROMPT_AI_API_BASE pointing here.
//
//   POST /v1beta/models/<model>:generateContent
//     -> Gemini-shaped body whose text reads "EXPANDED PROMPT: <idea> …"
//        (<idea> = the text after "User idea:" in the request)
//   An idea containing "FAILME" gets an HTTP 500 (writer-failure test).
//   The very FIRST non-FAILME request gets a one-time HTTP 503, so the
//   happy-path test also proves the writer's retry/fallback recovers.
//
// Run:  node test-gemini-stub.js   (port: GEMINI_STUB_PORT, default 18197 —
// outside the 180xx block, which the rest of the suite has fully claimed)
import http from 'node:http';

const port = Number(process.env.GEMINI_STUB_PORT || 18197);
let served503 = false;

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');
  if (req.method !== 'POST' || !u.pathname.startsWith('/v1beta/models/')) {
    res.writeHead(404);
    return res.end('not found');
  }
  let raw = '';
  req.on('data', (c) => { raw += c; });
  req.on('end', () => {
    let idea = '';
    try {
      const j = JSON.parse(raw);
      const text = j?.contents?.[0]?.parts?.[0]?.text || '';
      idea = text.split('User idea:').pop().trim();
    } catch { /* fall through with empty idea */ }
    if (idea.includes('FAILME')) {
      res.writeHead(500);
      return res.end('stub gemini failure');
    }
    if (idea.includes('LONGPROMPT')) {
      // A valid but over-long answer (~700 chars, complete sentences):
      // the writer must trim it to <=480 chars at a sentence boundary.
      const long = 'First sentence of a very detailed cinematic scene with rich light and motion. Second sentence adds characters, costumes and the busy street around them. Third sentence describes the camera gliding forward through warm evening haze. Fourth sentence brings in sound, weather and small background details everywhere. Fifth sentence continues with more atmosphere, gestures and expressions. Sixth sentence is pure extra padding to push this answer far beyond the limit. Seventh sentence keeps going so the raw text is well over seven hundred characters long in total. Eighth and final sentence closes the scene.';
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ candidates: [{ content: { parts: [{ text: long }] } }] }));
    }
    if (idea.includes('TRUNC')) {
      // A cut-off fragment: long enough to pass a naive length check,
      // but no terminal punctuation — the writer must reject and retry,
      // and with the stub always truncating, the endpoint must end 502.
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ candidates: [{ content: { parts: [{ text: 'A cinematic photorealistic close-up shot of an elderly man' }] } }] }));
    }
    if (!served503) {
      served503 = true;
      res.writeHead(503);
      return res.end('stub transient overload');
    }
    const out = `EXPANDED PROMPT: ${idea} — a richly detailed cinematic scene, soft natural light, smooth tracking camera, lifelike motion and atmosphere throughout the shot.`;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ candidates: [{ content: { parts: [{ text: out }] } }] }));
  });
}).listen(port, () => console.log(`gemini stub listening on port ${port}`));
