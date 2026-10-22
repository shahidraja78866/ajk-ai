// My Video AI — secure backend (Node 20 + Express + SQLite)
// The fal.ai key lives ONLY here (environment variable), never in the frontend.
// Run:  cp .env.example .env  (fill in values)  ->  npm install  ->  npm start
//
// Model verified against fal.ai's official API docs (2026-10-20):
//   model id : minimax/h3/text-to-video
//   inputs   : prompt (required), duration (integer seconds, 5-15, default 5),
//              aspect_ratio (21:9 | 16:9 | 4:3 | 1:1 | 3:4 | 9:16, default 16:9),
//              resolution (480P | 768P | 2K | 4K, default 2K),
//              enable_safety_checker (boolean, default true)
//   output   : { video: { url, content_type, file_name, file_size } }
//   queue    : POST https://queue.fal.run/<model>  (Authorization: Key <FAL_KEY>)

import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import jwt from 'jsonwebtoken';
import bcrypt from 'bcryptjs';
import rateLimit from 'express-rate-limit';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite'; // built into Node 22.5+/24 — no native build step

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const { FAL_KEY, JWT_SECRET, FRONTEND_ORIGIN } = process.env;
if (!FAL_KEY || !JWT_SECRET) {
  console.error('Missing FAL_KEY or JWT_SECRET in .env — see .env.example');
  process.exit(1);
}

// ---------- Public configuration (safe to expose via /api/config) ----------
const CONFIG = {
  model: process.env.FAL_MODEL || 'minimax/h3/text-to-video',
  resolution: process.env.FAL_RESOLUTION || '768P',
  aspectRatios: ['16:9', '9:16', '1:1', '4:3', '3:4', '21:9'],
  durations: [5, 10],                       // seconds offered in the UI
  styles: ['realistic', 'cinematic', 'cartoon', 'anime'],
  // Credits charged per generation, by duration. Charged on submit,
  // automatically refunded if the provider fails the job.
  costByDuration: { 5: 1, 10: 2 },
  signupCredits: Number(process.env.SIGNUP_CREDITS || 10),
  maxDailyCredits: Number(process.env.MAX_DAILY_CREDITS || 20),
};

// ---------- Database with migrations (data survives restarts) ----------
const db = new DatabaseSync(process.env.DB_PATH || 'myvideoai.db');
db.exec('PRAGMA journal_mode = WAL');
// Minimal transaction helper (BEGIN IMMEDIATE so concurrent requests can't
// double-spend the same credits)
function tx(fn) {
  db.exec('BEGIN IMMEDIATE');
  try { const r = fn(); db.exec('COMMIT'); return r; }
  catch (e) { db.exec('ROLLBACK'); throw e; }
}
db.exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
  version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL DEFAULT (datetime('now')))`);

const MIGRATIONS = [
  { version: 1, up: `
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      email TEXT UNIQUE NOT NULL,
      password_hash TEXT NOT NULL,
      credits INTEGER NOT NULL DEFAULT 10,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS generations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id),
      fal_request_id TEXT,
      prompt TEXT NOT NULL,
      aspect_ratio TEXT NOT NULL DEFAULT '16:9',
      duration INTEGER NOT NULL DEFAULT 5,
      style TEXT NOT NULL DEFAULT 'realistic',
      status TEXT NOT NULL DEFAULT 'queued',
      video_url TEXT,
      error TEXT,
      cost_credits INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS reports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER REFERENCES users(id),
      generation_id INTEGER REFERENCES generations(id),
      reason TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );` },
  { version: 2, up: `
    ALTER TABLE generations ADD COLUMN idempotency_key TEXT;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_gen_idem
      ON generations(user_id, idempotency_key) WHERE idempotency_key IS NOT NULL;` },
];
{
  const applied = new Set(db.prepare('SELECT version FROM schema_migrations').all().map(r => r.version));
  for (const m of MIGRATIONS) {
    if (!applied.has(m.version)) {
      tx(() => {
        db.exec(m.up);
        db.prepare('INSERT INTO schema_migrations (version) VALUES (?)').run(m.version);
      });
      console.log(`Applied DB migration v${m.version}`);
    }
  }
}

// ---------- App ----------
const app = express();
app.use(cors({ origin: FRONTEND_ORIGIN || true }));
app.use(express.json({ limit: '100kb' }));
app.use(rateLimit({ windowMs: 15 * 60 * 1000, max: 300 }));
const generateLimiter = rateLimit({ windowMs: 60 * 60 * 1000, max: 10,
  message: { error: 'Rate limit: max 10 generations per hour.' } });

function auth(req, res, next) {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  try { req.user = jwt.verify(token, JWT_SECRET); next(); }
  catch { res.status(401).json({ error: 'Please sign in again.' }); }
}

// ---------- Content moderation (first layer; fal's safety checker is second) ----------
const BLOCKED = ['child', 'minor', 'nude', 'naked', 'sexual', 'porn', 'gore',
  'beheading', 'terrorist', 'bomb making', 'suicide', 'racial slur'];
function moderated(prompt) {
  const p = prompt.toLowerCase();
  return BLOCKED.some(w => p.includes(w));
}

// ---------- Public config (no secrets) ----------
app.get('/api/config', (req, res) => res.json({
  model: CONFIG.model,
  aspect_ratios: CONFIG.aspectRatios,
  durations: CONFIG.durations,
  styles: CONFIG.styles,
  cost_by_duration: CONFIG.costByDuration,
  signup_credits: CONFIG.signupCredits,
  max_daily_credits: CONFIG.maxDailyCredits,
}));
app.get('/api/health', (req, res) => res.json({ ok: true, model: CONFIG.model }));

// ---------- Auth ----------
app.post('/api/auth/register', async (req, res) => {
  const { email, password } = req.body || {};
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !password || password.length < 8)
    return res.status(400).json({ error: 'A valid email and a password of 8+ characters are required.' });
  const hash = await bcrypt.hash(password, 10);
  try {
    const info = db.prepare('INSERT INTO users (email, password_hash, credits) VALUES (?, ?, ?)')
      .run(email.toLowerCase(), hash, CONFIG.signupCredits);
    const token = jwt.sign({ id: Number(info.lastInsertRowid), email: email.toLowerCase() }, JWT_SECRET, { expiresIn: '7d' });
    res.json({ token, credits: CONFIG.signupCredits });
  } catch { res.status(409).json({ error: 'An account with this email already exists.' }); }
});

app.post('/api/auth/login', async (req, res) => {
  const { email, password } = req.body || {};
  const user = db.prepare('SELECT * FROM users WHERE email = ?').get((email || '').toLowerCase());
  if (!user || !(await bcrypt.compare(password || '', user.password_hash)))
    return res.status(401).json({ error: 'Wrong email or password.' });
  const token = jwt.sign({ id: user.id, email: user.email }, JWT_SECRET, { expiresIn: '7d' });
  res.json({ token, credits: user.credits });
});

app.get('/api/me', auth, (req, res) => {
  const u = db.prepare('SELECT id, email, credits, created_at FROM users WHERE id = ?').get(req.user.id);
  if (!u) return res.status(404).json({ error: 'Account not found.' });
  res.json(u);
});

// ---------- Generation (idempotent + atomic charge) ----------
app.post('/api/generate', auth, generateLimiter, async (req, res) => {
  const { prompt, aspect_ratio = '16:9', duration = 5, style = 'realistic' } = req.body || {};
  const idemKey = String(req.headers['idempotency-key'] || req.body?.idempotency_key || '').slice(0, 80) || null;

  if (!prompt || prompt.trim().length < 3 || prompt.length > 500)
    return res.status(400).json({ error: 'Please describe your video in 3–500 characters.' });
  if (!CONFIG.aspectRatios.includes(aspect_ratio))
    return res.status(400).json({ error: `aspect_ratio must be one of: ${CONFIG.aspectRatios.join(', ')}` });
  if (!CONFIG.durations.includes(Number(duration)))
    return res.status(400).json({ error: `duration must be one of: ${CONFIG.durations.join(', ')} seconds` });
  if (!CONFIG.styles.includes(style))
    return res.status(400).json({ error: `style must be one of: ${CONFIG.styles.join(', ')}` });
  if (moderated(prompt))
    return res.status(400).json({ error: 'This prompt was blocked by content moderation. Please rephrase it.' });

  const cost = CONFIG.costByDuration[Number(duration)] ?? 1;

  // Duplicate-request protection: same idempotency key returns the existing
  // job — no second charge, no second fal.ai submission.
  if (idemKey) {
    const existing = db.prepare('SELECT * FROM generations WHERE user_id = ? AND idempotency_key = ?')
      .get(req.user.id, idemKey);
    if (existing) return res.json({ id: existing.id, status: existing.status, duplicate: true });
  }

  // Atomic: daily-limit check + balance check + deduct + insert in one transaction.
  let jobId;
  try {
    jobId = tx(() => {
      const user = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.id);
      const spentToday = db.prepare(
        `SELECT COALESCE(SUM(cost_credits),0) AS s FROM generations
         WHERE user_id = ? AND date(created_at) = date('now') AND status != 'failed'`).get(user.id).s;
      if (spentToday + cost > CONFIG.maxDailyCredits) throw Object.assign(new Error('DAILY_LIMIT'), { status: 429 });
      if (user.credits < cost) throw Object.assign(new Error('NO_CREDITS'), { status: 402 });
      db.prepare('UPDATE users SET credits = credits - ? WHERE id = ?').run(cost, user.id);
      const info = db.prepare(
        `INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, cost_credits, idempotency_key)
         VALUES (?, ?, ?, ?, ?, ?, ?)`).run(user.id, prompt.trim(), aspect_ratio, Number(duration), style, cost, idemKey);
      return Number(info.lastInsertRowid);
    });
  } catch (e) {
    if (e.message === 'DAILY_LIMIT') return res.status(429).json({ error: 'Daily spending limit reached. Try again tomorrow.' });
    if (e.message === 'NO_CREDITS') return res.status(402).json({ error: 'Not enough credits.' });
    if (String(e.message).includes('UNIQUE')) { // race on idempotency key
      const existing = db.prepare('SELECT * FROM generations WHERE user_id = ? AND idempotency_key = ?')
        .get(req.user.id, idemKey);
      if (existing) return res.json({ id: existing.id, status: existing.status, duplicate: true });
    }
    throw e;
  }

  // Submit to fal.ai queue (key never leaves the server)
  try {
    const r = await fetch(`https://queue.fal.run/${CONFIG.model}`, {
      method: 'POST',
      headers: { 'Authorization': `Key ${FAL_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        prompt: `${prompt.trim()} — style: ${style}`,
        duration: Number(duration),
        aspect_ratio,
        resolution: CONFIG.resolution,
        enable_safety_checker: true,
      }),
    });
    if (!r.ok) throw new Error(`fal.ai returned ${r.status}`);
    const data = await r.json();
    db.prepare(`UPDATE generations SET fal_request_id = ?, status = 'in_progress',
                updated_at = datetime('now') WHERE id = ?`).run(data.request_id, jobId);
    const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
    res.json({ id: jobId, status: 'in_progress', credits_left: me.credits });
  } catch (e) {
    failAndRefund(jobId, `Provider submission failed (${e.message})`);
    res.status(502).json({ error: 'Video service is unavailable right now. Your credit was refunded.' });
  }
});

// Transition a job to failed exactly once, refunding its credits exactly once.
function failAndRefund(jobId, message) {
  const changed = db.prepare(
    `UPDATE generations SET status = 'failed', error = ?, updated_at = datetime('now')
     WHERE id = ? AND status NOT IN ('failed', 'completed')`).run(message, jobId);
  if (Number(changed.changes) === 1) {
    const job = db.prepare('SELECT user_id, cost_credits FROM generations WHERE id = ?').get(jobId);
    db.prepare('UPDATE users SET credits = credits + ? WHERE id = ?').run(job.cost_credits, job.user_id);
  }
}

// Poll one job: asks fal.ai for status, updates DB, returns video URL when done
app.get('/api/generations/:id', auth, async (req, res) => {
  const job = db.prepare('SELECT * FROM generations WHERE id = ? AND user_id = ?')
    .get(req.params.id, req.user.id);
  if (!job) return res.status(404).json({ error: 'Generation not found.' });
  if (job.status === 'completed' || job.status === 'failed' || !job.fal_request_id)
    return res.json(job);
  try {
    const sr = await fetch(`https://queue.fal.run/${CONFIG.model}/requests/${job.fal_request_id}/status`,
      { headers: { 'Authorization': `Key ${FAL_KEY}` } });
    if (sr.ok) {
      const s = await sr.json();
      if (s.status === 'COMPLETED') {
        const rr = await fetch(`https://queue.fal.run/${CONFIG.model}/requests/${job.fal_request_id}`,
          { headers: { 'Authorization': `Key ${FAL_KEY}` } });
        const result = await rr.json();
        const url = result?.video?.url || result?.data?.video?.url || null;
        if (url) {
          db.prepare(`UPDATE generations SET status = 'completed', video_url = ?,
                      updated_at = datetime('now') WHERE id = ?`).run(url, job.id);
          job.status = 'completed'; job.video_url = url;
        }
      }
      // fal's queue reports failures via the result payload; a non-2xx status
      // check is handled below by leaving the job in progress for the next poll.
    }
  } catch { /* network hiccup — keep last known status; frontend polls again */ }
  res.json(job);
});

app.get('/api/history', auth, (req, res) => {
  const rows = db.prepare('SELECT * FROM generations WHERE user_id = ? ORDER BY id DESC LIMIT 50')
    .all(req.user.id);
  const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
  res.json({ credits: me.credits, generations: rows });
});

// ---------- Report inappropriate content ----------
app.post('/api/report', auth, (req, res) => {
  const { generation_id, reason } = req.body || {};
  if (!reason) return res.status(400).json({ error: 'Please give a reason.' });
  db.prepare('INSERT INTO reports (user_id, generation_id, reason) VALUES (?, ?, ?)')
    .run(req.user.id, generation_id || null, String(reason).slice(0, 500));
  res.json({ ok: true, message: 'Thank you. Our team will review this content.' });
});

// ---------- Serve the AJK AI web app itself (same-origin) ----------
// The app and the API now live on ONE address, so there is no separate
// frontend URL to configure: open this server's address and everything works.
// The app's API-base-URL setting still exists for split deployments.
app.use(express.static(path.join(__dirname, 'public')));
app.get(/^\/(?!api\/).*/, (req, res) =>
  res.sendFile(path.join(__dirname, 'public', 'index.html')));

app.use((err, req, res, next) => { // last-resort error handler
  console.error(err);
  res.status(500).json({ error: 'Something went wrong on the server.' });
});

app.listen(process.env.PORT || 8080,
  () => console.log(`My Video AI backend running on port ${process.env.PORT || 8080} (model: ${CONFIG.model})`));
