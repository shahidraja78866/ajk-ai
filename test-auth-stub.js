// Tiny local stub of the two Phase N auth providers — used ONLY by
// test.sh so the modern-auth tests never make a real provider call.
// The server under test is started with GOOGLE_TOKENINFO_BASE and
// MAILER_API_BASE both pointing here.
//
//   GET  /tokeninfo?id_token=<t>  -> a Google-shaped payload, keyed by t:
//        "valid-google-token"        -> sub "google-sub-1", email
//                                     "googleuser@example.com", verified
//        "valid-google-token-two"    -> sub "google-sub-2", email
//                                     "secondgoogle@example.com"
//        "merge-google-token"        -> sub "google-sub-merge", email
//                                     "mergepw@example.com" (a password
//                                     account owns that email in the
//                                     tests — the no-auto-merge proof)
//        "wrong-aud-token"           -> aud "some-other-client"
//        "expired-token"             -> exp in the past
//        "unverified-email-token"    -> email_verified "false"
//        anything else               -> HTTP 400 (Google's answer for a
//                                     malformed/unknown token)
//   POST /send                    -> records the mail; answers 200 —
//        UNLESS the recipient contains "failmail" (case-insensitive —
//        the server lowercases addresses before sending), which gets
//        a 500 (the mail-send-failure test).
//   GET  /__calls                 -> every request received:
//        { tokeninfo: [id_token...], mails: [{to, subject, text}] }
//
// Run:  node test-auth-stub.js   (port: AUTH_STUB_PORT, default 18043;
//         client id: AUTH_STUB_CLIENT_ID, default "test-client-id")
import http from 'node:http';

const port = Number(process.env.AUTH_STUB_PORT || 18043);
const clientId = process.env.AUTH_STUB_CLIENT_ID || 'test-client-id';

const tokeninfoCalls = [];
const mails = [];

function googlePayload(sub, email) {
  return { aud: clientId, iss: 'https://accounts.google.com',
           sub, email, email_verified: 'true',
           name: 'Stub Google User', picture: 'https://example.com/pic.png',
           exp: String(Math.floor(Date.now() / 1000) + 3600),
           iat: String(Math.floor(Date.now() / 1000)) };
}
const TOKENS = {
  'valid-google-token': () => googlePayload('google-sub-1', 'googleuser@example.com'),
  'valid-google-token-two': () => googlePayload('google-sub-2', 'secondgoogle@example.com'),
  'merge-google-token': () => googlePayload('google-sub-merge', 'mergepw@example.com'),
  'wrong-aud-token': () => ({ ...googlePayload('google-sub-1', 'googleuser@example.com'),
                             aud: 'some-other-client' }),
  'expired-token': () => ({ ...googlePayload('google-sub-1', 'googleuser@example.com'),
                           exp: String(Math.floor(Date.now() / 1000) - 60) }),
  'unverified-email-token': () => ({ ...googlePayload('google-sub-1', 'googleuser@example.com'),
                                    email_verified: 'false' }),
};

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');
  const send = (code, obj) => {
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(obj));
  };
  if (req.method === 'GET' && u.pathname === '/__calls')
    return send(200, { tokeninfo: tokeninfoCalls, mails });
  if (req.method === 'GET' && u.pathname === '/tokeninfo') {
    const t = u.searchParams.get('id_token') || '';
    tokeninfoCalls.push(t);
    const make = TOKENS[t];
    if (!make) { res.writeHead(400); return res.end('invalid token'); }
    return send(200, make());
  }
  if (req.method === 'POST' && u.pathname === '/send') {
    let raw = '';
    req.on('data', c => { raw += c; });
    req.on('end', () => {
      let body = null;
      try { body = JSON.parse(raw || '{}'); } catch { body = null; }
      if (body && String(body.to || '').toLowerCase().includes('failmail')) {
        res.writeHead(500);
        return res.end('stub mail failure');
      }
      mails.push({ to: body?.to || null, subject: body?.subject || null,
                   text: body?.text || null, from: body?.from || null,
                   auth: req.headers.authorization || null });
      return send(200, { ok: true, id: `stub-mail-${mails.length}` });
    });
    return;
  }
  res.writeHead(404);
  res.end('not found');
}).listen(port, () => console.log(`auth stub listening on port ${port}`));
