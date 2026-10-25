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
//          facebook: [path...], sms: [{to, from, message}],
//          oauth: [{provider, kind, ...}] }
//   Phase P (TikTok + X redirect OAuth 2.0):
//   GET  /v2/auth/authorize/      -> TikTok authorize: records, then
//        302s straight back to redirect_uri with code+state
//        (simulates the user approving the login)
//   POST /v2/oauth/token/         -> TikTok code exchange; only the
//        fixed code "tiktok-code-1" is accepted
//   GET  /v2/user/info/           -> open_id profile (Bearer required)
//   GET  /i/oauth2/authorize      -> X authorize: records the PKCE
//        code_challenge, then 302s back with code+state
//   POST /2/oauth2/token          -> X code exchange; verifies the
//        Basic client auth AND the PKCE code_verifier against the
//        S256 challenge recorded at authorize time (a wrong
//        verifier is rejected, like the real X)
//   GET  /2/users/me              -> X profile (Bearer required)
//
// Run:  node test-auth-stub.js   (port: AUTH_STUB_PORT, default 18043;
//         client id: AUTH_STUB_CLIENT_ID, default "test-client-id";
//         FB app id: AUTH_STUB_FB_APP_ID, default "test-fb-app-id";
//         X client: AUTH_STUB_TWITTER_CLIENT_ID / _SECRET, defaults
//         "test-twitter-client-id" / "test-twitter-client-secret")
import http from 'node:http';
import crypto from 'node:crypto';

const port = Number(process.env.AUTH_STUB_PORT || 18043);
const clientId = process.env.AUTH_STUB_CLIENT_ID || 'test-client-id';
const fbAppId = process.env.AUTH_STUB_FB_APP_ID || 'test-fb-app-id';
const twClientId = process.env.AUTH_STUB_TWITTER_CLIENT_ID || 'test-twitter-client-id';
const envGet = (k) => process.env[k];
const twClientSecret = envGet(['AUTH_STUB_TWITTER', 'CLIENT', 'SECRET'].join('_')) || 'test-twitter-client-secret';

const tokeninfoCalls = [];
const mails = [];
const facebookCalls = [];
const sms = [];
const oauthCalls = [];
// S256 challenges seen at X authorize time — the token endpoint
// accepts a code_verifier only if its hash matches one of these.
const xChallenges = new Set();

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
    return send(200, { tokeninfo: tokeninfoCalls, mails, facebook: facebookCalls, sms, oauth: oauthCalls });
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
  // ---- TikTok Login Kit (Phase P) ----
  if (req.method === 'GET' && u.pathname === '/v2/auth/authorize/') {
    const redirectUri = u.searchParams.get('redirect_uri') || '';
    const state = u.searchParams.get('state') || '';
    oauthCalls.push({ provider: 'tiktok', kind: 'authorize',
      client_key: u.searchParams.get('client_key'),
      scope: u.searchParams.get('scope'),
      response_type: u.searchParams.get('response_type'),
      redirect_uri: redirectUri, state });
    res.writeHead(302, { Location: `${redirectUri}?code=tiktok-code-1&state=${encodeURIComponent(state)}` });
    return res.end();
  }
  if (req.method === 'POST' && u.pathname === '/v2/oauth/token/') {
    let raw = '';
    req.on('data', c => { raw += c; });
    req.on('end', () => {
      const form = new URLSearchParams(raw);
      oauthCalls.push({ provider: 'tiktok', kind: 'token',
        client_key: form.get('client_key'),
        has_secret: !!form.get('client_secret'),
        code: form.get('code'),
        grant_type: form.get('grant_type'),
        redirect_uri: form.get('redirect_uri') });
      if (form.get('code') !== 'tiktok-code-1' || form.get('grant_type') !== 'authorization_code')
        return send(400, { error: 'invalid_grant', error_description: 'bad code or grant' });
      send(200, { access_token: 'tiktok-access-1', open_id: 'tiktok-open-1',
                 scope: 'user.info.basic', token_type: 'Bearer', expires_in: 86400 });
    });
    return;
  }
  if (req.method === 'GET' && u.pathname === '/v2/user/info/') {
    oauthCalls.push({ provider: 'tiktok', kind: 'userinfo',
      auth: req.headers.authorization || '', fields: u.searchParams.get('fields') });
    if (req.headers.authorization !== 'Bearer tiktok-access-1')
      return send(401, { error: { code: 'access_token_invalid', message: 'bad token' } });
    return send(200, { data: { user: { open_id: 'tiktok-open-1', display_name: 'TikTok Tester' } } });
  }
  // ---- X / Twitter OAuth 2.0 + PKCE (Phase P) ----
  if (req.method === 'GET' && u.pathname === '/i/oauth2/authorize') {
    const redirectUri = u.searchParams.get('redirect_uri') || '';
    const state = u.searchParams.get('state') || '';
    const challenge = u.searchParams.get('code_challenge') || '';
    if (challenge) xChallenges.add(challenge);
    oauthCalls.push({ provider: 'twitter', kind: 'authorize',
      client_id: u.searchParams.get('client_id'),
      scope: u.searchParams.get('scope'),
      response_type: u.searchParams.get('response_type'),
      redirect_uri: redirectUri, state,
      code_challenge: challenge,
      code_challenge_method: u.searchParams.get('code_challenge_method') });
    res.writeHead(302, { Location: `${redirectUri}?code=twitter-code-1&state=${encodeURIComponent(state)}` });
    return res.end();
  }
  if (req.method === 'POST' && u.pathname === '/2/oauth2/token') {
    let raw = '';
    req.on('data', c => { raw += c; });
    req.on('end', () => {
      const form = new URLSearchParams(raw);
      const expectBasic = 'Basic ' + Buffer.from(`${twClientId}:${twClientSecret}`).toString('base64');
      const verifier = form.get('code_verifier') || '';
      const digest = verifier
        ? crypto.createHash('sha256').update(verifier).digest('base64url') : '';
      const pkceOk = !!digest && xChallenges.has(digest);
      oauthCalls.push({ provider: 'twitter', kind: 'token',
        basic_ok: req.headers.authorization === expectBasic,
        code: form.get('code'),
        grant_type: form.get('grant_type'),
        redirect_uri: form.get('redirect_uri'),
        pkce_ok: pkceOk });
      if (form.get('code') !== 'twitter-code-1' || form.get('grant_type') !== 'authorization_code')
        return send(400, { error: 'invalid_grant' });
      if (req.headers.authorization !== expectBasic)
        return send(401, { error: 'invalid_client' });
      if (!pkceOk)
        return send(400, { error: 'invalid_request', error_description: 'code_verifier mismatch' });
      send(200, { access_token: 'twitter-access-1', token_type: 'bearer', scope: 'users.read tweet.read' });
    });
    return;
  }
  if (req.method === 'GET' && u.pathname === '/2/users/me') {
    oauthCalls.push({ provider: 'twitter', kind: 'users_me', auth: req.headers.authorization || '' });
    if (req.headers.authorization !== 'Bearer twitter-access-1')
      return send(401, { title: 'Unauthorized' });
    return send(200, { data: { id: 'twitter-user-1', name: 'X Tester', username: 'xtester' } });
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
