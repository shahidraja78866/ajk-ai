// Tiny local stub of the auth providers — used ONLY by test.sh so the
// modern-auth tests never make a real provider call. The server under
// test is started with GOOGLE_TOKENINFO_BASE, MAILER_API_BASE,
// FB_GRAPH_BASE and SMS_API_BASE pointing here.
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
//   GET  /debug_token?input_token=<t>  -> a Facebook-shaped payload:
//        "valid-fb-token"   -> valid, this app, user "fb-user-1"
//        "fb-token-two"     -> valid, this app, user "fb-user-2"
//        "merge-fb-token"   -> valid, user "fb-user-merge" (its /me
//                              email "mergefb@example.com" is owned by
//                              a password account — no-merge proof)
//        "noemail-fb-token" -> valid, user "fb-user-noemail"
//        "wrong-app-fb-token" -> valid but app_id "some-other-app"
//        anything else      -> { data: { is_valid: false } }
//   GET  /me?access_token=<t>    -> the matching profile; the no-email
//        profile carries NO email field (permission declined), exactly
//        like real Facebook.
//   POST /send                    -> the mailer AND the SMS adapter
//        share this shape: a body with "message" is an SMS, a body
//        with "subject"/"text" is a mail. Mails are recorded and
//        answered 200 — UNLESS the recipient contains "failmail"
//        (case-insensitive — the server lowercases addresses before
//        sending), which gets a 500 (the mail-send-failure test). An
//        SMS to +929999999999 gets a 500 (the sms-send-failure test).
//   GET  /__calls                 -> every request received:
//        { tokeninfo: [id_token...], mails: [{to, subject, text}],
//          facebook: [path...], sms: [{to, from, message}] }
//
// Run:  node test-auth-stub.js   (port: AUTH_STUB_PORT, default 18043;
//         client id: AUTH_STUB_CLIENT_ID, default "test-client-id";
//         FB app id: AUTH_STUB_FB_APP_ID, default "test-fb-app-id")
import http from 'node:http';

const port = Number(process.env.AUTH_STUB_PORT || 18043);
const clientId = process.env.AUTH_STUB_CLIENT_ID || 'test-client-id';
const fbAppId = process.env.AUTH_STUB_FB_APP_ID || 'test-fb-app-id';

const tokeninfoCalls = [];
const mails = [];
const facebookCalls = [];
const sms = [];

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

const FB_USERS = {
  'valid-fb-token':   { user_id: 'fb-user-1',
                        me: { id: 'fb-user-1', name: 'Stub FB User',
                              email: 'fbuser@example.com',
                              picture: { data: { url: 'https://example.com/fb-pic.png' } } } },
  'fb-token-two':     { user_id: 'fb-user-2',
                        me: { id: 'fb-user-2', name: 'Second FB User',
                              email: 'secondfb@example.com' } },
  'merge-fb-token':   { user_id: 'fb-user-merge',
                        me: { id: 'fb-user-merge', name: 'Merge FB User',
                              email: 'mergefb@example.com' } },
  'noemail-fb-token': { user_id: 'fb-user-noemail',
                        me: { id: 'fb-user-noemail', name: 'No Email FB User' } },
};

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://127.0.0.1');
  const send = (code, obj) => {
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(obj));
  };
  if (req.method === 'GET' && u.pathname === '/__calls')
    return send(200, { tokeninfo: tokeninfoCalls, mails, facebook: facebookCalls, sms });
  if (req.method === 'GET' && u.pathname === '/tokeninfo') {
    const t = u.searchParams.get('id_token') || '';
    tokeninfoCalls.push(t);
    const make = TOKENS[t];
    if (!make) { res.writeHead(400); return res.end('invalid token'); }
    return send(200, make());
  }
  if (req.method === 'GET' && u.pathname === '/debug_token') {
    facebookCalls.push(`/debug_token?input_token=${u.searchParams.get('input_token') || ''}`);
    const t = u.searchParams.get('input_token') || '';
    if (t === 'wrong-app-fb-token')
      return send(200, { data: { is_valid: true, app_id: 'some-other-app',
                                 user_id: 'fb-user-1', type: 'USER' } });
    const rec = FB_USERS[t];
    if (!rec) return send(200, { data: { is_valid: false, app_id: fbAppId } });
    return send(200, { data: { is_valid: true, app_id: fbAppId,
                               user_id: rec.user_id, type: 'USER',
                               expires_at: Math.floor(Date.now() / 1000) + 3600 } });
  }
  if (req.method === 'GET' && u.pathname === '/me') {
    facebookCalls.push('/me');
    const rec = FB_USERS[u.searchParams.get('access_token') || ''];
    if (!rec) { res.writeHead(400); return res.end('invalid token'); }
    return send(200, rec.me);
  }
  if (req.method === 'POST' && u.pathname === '/send') {
    let raw = '';
    req.on('data', c => { raw += c; });
    req.on('end', () => {
      let body = null;
      try { body = JSON.parse(raw || '{}'); } catch { body = null; }
      if (body && typeof body.message === 'string') {
        if (String(body.to || '') === '+929999999999') {
          res.writeHead(500);
          return res.end('stub sms failure');
        }
        sms.push({ to: body.to || null, from: body.from || null,
                   message: body.message, auth: req.headers.authorization || null });
        return send(200, { ok: true, id: `stub-sms-${sms.length}` });
      }
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
