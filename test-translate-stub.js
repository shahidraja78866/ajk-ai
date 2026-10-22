// Tiny local stub of Google Translate's "gtx" web endpoint — used ONLY by
// test.sh so the test battery never calls the real translate endpoint.
// The server under test is started with TRANSLATE_API_BASE pointing here.
//
//   GET /translate_a/single?client=gtx&sl=<code>&tl=en&dt=t&q=<text>
//     -> gtx-shaped body whose joined segments read "TRANSLATED: <text>"
//        (returned as TWO segments so the server's segment-joining runs)
//   GET /__count  ->  {"calls": <translate calls so far>} (tests use this to
//        prove English/Chinese prompts never hit the translator)
//   A prompt containing "FAILME" gets an HTTP 500 (translation-failure test).
//
// Run:  node test-translate-stub.js   (port: TRANSLATE_STUB_PORT, default 18099)
import http from 'node:http';

const port = Number(process.env.TRANSLATE_STUB_PORT || 18099);
let calls = 0;

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');
  if (u.pathname === '/__count') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ calls }));
  }
  if (u.pathname !== '/translate_a/single') {
    res.writeHead(404);
    return res.end('not found');
  }
  calls++;
  const q = u.searchParams.get('q') || '';
  const sl = u.searchParams.get('sl') || 'auto';
  if (q.includes('FAILME')) {
    res.writeHead(500);
    return res.end('stub translation failure');
  }
  const translated = `TRANSLATED: ${q}`;
  const mid = Math.ceil(translated.length / 2);
  const body = [[[translated.slice(0, mid), q, null, null, 3],
                 [translated.slice(mid), '', null, null, 3]], null, sl];
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}).listen(port, () => console.log(`translate stub listening on port ${port}`));
