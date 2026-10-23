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
//
// Native-4K endpoint verified against fal.ai's official API docs (2026-10-22):
//   model id : fal-ai/kling-video/o3/4k/text-to-video
//   inputs   : prompt (string, required), duration (DurationEnum as string,
//              "3"-"15", e.g. "5"), aspect_ratio ("16:9" | "9:16" | "1:1"),
//              generate_audio (boolean), enable_safety_checker (boolean,
//              default true)
//   note     : NO `resolution` input — 4K output is fixed by the endpoint
//              (genuine native 4K, no upscaling stage); 4K is served from
//              fal's Singapore region only; flat $0.42/second with audio
//              bundled at no extra cost (durations 3-15s)
//   output   : { video: { url, content_type, file_name, file_size } }
//   docs     : https://fal.ai/models/fal-ai/kling-video/o3/4k/text-to-video/api

import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import jwt from 'jsonwebtoken';
import bcrypt from 'bcryptjs';
import rateLimit from 'express-rate-limit';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import { randomUUID, createSign, createHash, timingSafeEqual } from 'node:crypto';
import { execFile } from 'node:child_process';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite'; // built into Node 22.5+/24 — no native build step
import ffmpegStatic from 'ffmpeg-static'; // pinned binary for clip joining

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const { FAL_KEY, JWT_SECRET, FRONTEND_ORIGIN } = process.env;
if (!FAL_KEY || !JWT_SECRET) {
  console.error('Missing FAL_KEY or JWT_SECRET in .env — see .env.example');
  process.exit(1);
}

// ---------- Public configuration (safe to expose via /api/config) ----------
const CONFIG = {
  model: process.env.FAL_MODEL || 'minimax/h3/text-to-video',
  // Model used for native-4K generations (Extra Pro plan). Verified against
  // fal.ai's official API docs (2026-10-22): fal-ai/kling-video/o3/4k/text-to-video
  // is genuine native 4K (no upscaling stage), flat $0.42/second, aspect
  // ratios 16:9/9:16/1:1. Override with FAL_MODEL_4K only if the provider
  // changes the endpoint id.
  model4k: process.env.FAL_MODEL_4K || 'fal-ai/kling-video/o3/4k/text-to-video',
  // Image-to-video endpoint verified against fal.ai's official API docs
  // (2026-10-23): minimax/h3/image-to-video animates a supplied image as
  // the opening frame and takes it in the documented `image_url` field.
  // H3 generates native stereo audio (score, dialogue and foley) itself;
  // its schema has NO generate_audio toggle, so none is ever sent for H3.
  modelI2V: (process.env.FAL_MODEL_I2V || 'minimax/h3/image-to-video').trim(),
  resolution: process.env.FAL_RESOLUTION || '768P',
  aspectRatios: ['16:9', '9:16', '1:1', '4:3', '3:4', '21:9'],
  durations: [5, 10],                       // seconds offered in the UI
  styles: ['realistic', 'cinematic', 'cartoon', 'anime'],
  // Credits charged per generation, by duration (owner's rescaled system:
  // bigger numbers, same shape — 10s costs twice a 5s). Charged on submit,
  // automatically refunded if the provider fails the job.
  costByDuration: { 5: 10, 10: 20 },
  // Native-4K generations cost double credits (Extra Pro plan quality).
  costMultiplier4k: 2,
  signupCredits: Number(process.env.SIGNUP_CREDITS || 100),
  maxDailyCredits: Number(process.env.MAX_DAILY_CREDITS || 200),
  // Bootstrap admin: the account with this email gets the admin flag
  // (at registration, at login, and for existing accounts at boot).
  adminEmail: (process.env.ADMIN_EMAIL || '').trim().toLowerCase(),
  // Base URL for server-side prompt translation (Google Translate "gtx" web
  // endpoint). Overridable via TRANSLATE_API_BASE — tests point it at a
  // local stub so the suite never calls the real endpoint.
  translateBase: (process.env.TRANSLATE_API_BASE || 'https://translate.googleapis.com').replace(/\/+$/, ''),
  // Manual payment destinations for credit-pack purchases, shown to buyers
  // on the Buy Credits page. Only the methods actually set in the
  // environment are exposed (via /api/config as payment_methods).
  paymentMethods: {
    ...((process.env.PAYMENT_EASYPAISA || '').trim() ? { easypaisa: process.env.PAYMENT_EASYPAISA.trim() } : {}),
    ...((process.env.PAYMENT_JAZZCASH || '').trim() ? { jazzcash: process.env.PAYMENT_JAZZCASH.trim() } : {}),
    ...((process.env.PAYMENT_BANK || '').trim() ? { bank: process.env.PAYMENT_BANK.trim() } : {}),
    ...((process.env.PAYMENT_NAYAPAY || '').trim() ? { nayapay: process.env.PAYMENT_NAYAPAY.trim() } : {}),
  },
  // Where joined videos are written and served from (/files/joined/...).
  // NOTE: local disk — on ephemeral hosting (Render free tier) these files
  // disappear when the instance restarts or redeploys.
  joinedDir: process.env.JOINED_DIR || path.join(__dirname, 'data', 'joined'),
  // User-uploaded source images for image-to-video (one folder per user)
  // and locally post-processed (watermarked) generations.
  uploadsDir: path.join(__dirname, 'data', 'uploads'),
  generatedDir: process.env.GENERATED_DIR || path.join(__dirname, 'data', 'generated'),
  // Public base URL of this server (used to build gateway redirect/callback
  // URLs). Derived from the request when unset.
  publicBaseUrl: (process.env.PUBLIC_BASE_URL || '').trim().replace(/\/+$/, ''),
  // --- Google Play Billing (Phase 3) ---------------------------------------
  // FAILS CLOSED: until PLAY_PACKAGE_NAME and GOOGLE_PLAY_CREDENTIALS are
  // both set, the Play verify endpoint answers 503 and grants nothing.
  // GOOGLE_PLAY_CREDENTIALS is a service-account JSON — either a path to
  // the file or the JSON itself inline (server-side only, never shipped
  // to the client). PLAY_TEST_MODE=1 swaps in the token-keyed mock
  // verifier used by test.sh — test environments ONLY, never production.
  playPackageName: (process.env.PLAY_PACKAGE_NAME || '').trim(),
  playCredentials: (process.env.GOOGLE_PLAY_CREDENTIALS || '').trim(),
  playRtdnSecret: (process.env.PLAY_RTDN_SECRET || '').trim(),
  playTestMode: process.env.PLAY_TEST_MODE === '1',
  // --- Payment gateway (PayFast — Easypaisa / JazzCash / cards / bank) -----
  // FAILS CLOSED: until GATEWAY_PROVIDER=payfast and the merchant id +
  // secured key are set, gateway checkout answers 503 and webhooks grant
  // nothing. GATEWAY_TEST_MODE=1 (tests only) skips the token-mint HTTP
  // call to the real gateway; IPN signature verification still runs.
  // PAYFAST_BASE_URL defaults to the UAT host — switch to the production
  // host given in the merchant dashboard at go-live.
  gatewayProvider: (process.env.GATEWAY_PROVIDER || '').trim().toLowerCase(),
  gatewayTestMode: process.env.GATEWAY_TEST_MODE === '1',
  payfast: {
    merchantId: (process.env.PAYFAST_MERCHANT_ID || '').trim(),
    merchantName: (process.env.PAYFAST_MERCHANT_NAME || '').trim(),
    securedKey: (process.env.PAYFAST_SECURED_KEY || '').trim(),
    baseUrl: (process.env.PAYFAST_BASE_URL || 'https://ipguat.apps.net.pk').replace(/\/+$/, ''),
  },
};

// ---------- Prompt languages ----------
// Users may write prompts in 7 languages. English and Chinese are natively
// understood by the video models and are sent exactly as written. Urdu,
// Kashmiri, Arabic, Persian and Hindi prompts are translated to English on
// the server BEFORE any credit is charged — a failed translation charges
// nothing and creates no job.
const PROMPT_LANGUAGES = [
  { code: 'en', name: 'English' },
  { code: 'ur', name: 'Urdu' },
  { code: 'ks', name: 'Kashmiri' },
  { code: 'ar', name: 'Arabic' },
  { code: 'fa', name: 'Persian' },
  { code: 'hi', name: 'Hindi' },
  { code: 'zh', name: 'Chinese' },
];
const TRANSLATED_LANGUAGES = new Set(['ur', 'ks', 'ar', 'fa', 'hi']);

// ---------- Video modes ----------
// Two clearly separated generation experiences. Each mode permits only
// its own styles; the server validates the pairing on every request.
const VIDEO_MODES = {
  realistic: ['realistic', 'cinematic'],
  cartoon: ['cartoon', 'anime'],
};
const MODE_LIST = Object.entries(VIDEO_MODES).map(([id, styles]) => ({ id, styles }));

// Translate a prompt to English via Google Translate's free web endpoint
// (client=gtx). The response is nested arrays: data[0] is the list of
// translated segments and each segment's [0] is its text — join them all.
// Throws on any HTTP error, malformed body, or empty result.
async function translatePrompt(text, fromCode) {
  const url = `${CONFIG.translateBase}/translate_a/single?client=gtx&sl=${encodeURIComponent(fromCode)}&tl=en&dt=t&q=${encodeURIComponent(text)}`;
  const r = await fetch(url, { signal: AbortSignal.timeout(10000) });
  if (!r.ok) throw new Error(`translate returned ${r.status}`);
  const data = await r.json();
  const segments = Array.isArray(data?.[0]) ? data[0] : [];
  const out = segments.map(s => (Array.isArray(s) ? String(s[0] ?? '') : '')).join('').trim();
  if (!out) throw new Error('translate returned empty text');
  return out;
}

// Resolutions the model API accepts, cheapest → most expensive.
const RESOLUTIONS = ['480P', '768P', '2K', '4K'];

// Aspect ratios the native-4K endpoint supports (fal.ai o3/4k schema,
// verified 2026-10-22). Requests at other ratios are routed to the H3 model
// at 2K with the standard credit rate — they are not native 4K, so they are
// never charged or recorded as 4K.
const FOUR_K_ASPECTS = ['16:9', '9:16', '1:1'];

// Subscription plan catalogue. Prices/credits are seeded into the `plans`
// table on first boot and are afterwards editable in the admin panel — boot
// only re-syncs the structural fields (name, quality, resolution, model) and
// never overwrites prices or credit amounts an admin has changed.
const PLAN_DEFAULTS = [
  { id: 'normal',   name: 'Normal',    price_monthly: 1999, price_yearly: 19990,
    credits_monthly: 150, quality: '768P', quality_label: '768P',      resolution: '768P', model: CONFIG.model,   sort_order: 1,
    play_product_monthly: 'ajk_normal_monthly',   play_product_yearly: 'ajk_normal_yearly' },
  { id: 'pro',      name: 'Pro',       price_monthly: 3000, price_yearly: 30000,
    credits_monthly: 120, quality: '2K',   quality_label: '2K',        resolution: '2K',   model: CONFIG.model,   sort_order: 2,
    play_product_monthly: 'ajk_pro_monthly',      play_product_yearly: 'ajk_pro_yearly' },
  { id: 'extrapro', name: 'Extra Pro', price_monthly: 5000, price_yearly: 50000,
    credits_monthly: 120, quality: '4K',   quality_label: 'Native 4K', resolution: '4K',   model: CONFIG.model4k, sort_order: 3,
    play_product_monthly: 'ajk_extrapro_monthly', play_product_yearly: 'ajk_extrapro_yearly' },
];

// One-time credit packs (top-ups bought outside subscriptions). Seeded into
// the `credit_packs` table on first boot; afterwards editable in the admin
// panel — boot never overwrites an admin's edits.
const PACK_DEFAULTS = [
  { credits: 50,  price_pkr: 899,  sort_order: 1, play_product_id: 'credits_50' },
  { credits: 100, price_pkr: 1499, sort_order: 2, play_product_id: 'credits_100' },
  { credits: 250, price_pkr: 3499, sort_order: 3, play_product_id: 'credits_250' },
];
const PACK_METHODS = ['easypaisa', 'jazzcash', 'bank', 'nayapay', 'other'];

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
  // v3 — monetization (Phase 1): plans, subscriptions, payments, admin flag,
  // and a two-bucket credit balance. users.credits stays as the cached TOTAL
  // (free_credits + plan_credits) so existing code paths keep working; the
  // buckets say where the credits came from. Plan credits reset every cycle
  // (no rollover); free signup credits never expire.
  { version: 3, up: `
    ALTER TABLE users ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE users ADD COLUMN free_credits INTEGER;
    UPDATE users SET free_credits = credits;
    ALTER TABLE users ADD COLUMN plan_credits INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE generations ADD COLUMN resolution TEXT;
    ALTER TABLE generations ADD COLUMN model TEXT;
    CREATE TABLE IF NOT EXISTS plans (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      price_monthly INTEGER NOT NULL,
      price_yearly INTEGER NOT NULL,
      currency TEXT NOT NULL DEFAULT 'PKR',
      credits_monthly INTEGER NOT NULL,
      quality TEXT NOT NULL,
      quality_label TEXT NOT NULL,
      resolution TEXT NOT NULL,
      model TEXT NOT NULL,
      is_active INTEGER NOT NULL DEFAULT 1,
      sort_order INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id),
      plan_id TEXT REFERENCES plans(id),
      amount INTEGER NOT NULL,
      currency TEXT NOT NULL DEFAULT 'PKR',
      provider TEXT NOT NULL DEFAULT 'manual_test',
      provider_txn_id TEXT UNIQUE,
      status TEXT NOT NULL DEFAULT 'succeeded',
      period TEXT,
      note TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS subscriptions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id),
      plan_id TEXT NOT NULL REFERENCES plans(id),
      status TEXT NOT NULL DEFAULT 'active',
      period TEXT NOT NULL DEFAULT 'monthly',
      started_at TEXT NOT NULL DEFAULT (datetime('now')),
      current_period_start TEXT,
      current_period_end TEXT,
      last_grant_at TEXT,
      payment_id INTEGER REFERENCES payments(id),
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );` },
  // v4 — prompt languages: the language the user wrote the prompt in, and
  // (for the auto-translated languages) the English text actually sent to
  // fal.ai. The `prompt` column keeps the user's ORIGINAL text.
  { version: 4, up: `
    ALTER TABLE generations ADD COLUMN prompt_language TEXT;
    ALTER TABLE generations ADD COLUMN translated_prompt TEXT;` },
  // v5 — credit rescale + credit packs. The rescale (one-time UPDATE of the
  // plans' monthly credits to the owner's new 100/120/120 system; prices
  // untouched) runs exactly once because migrations are version-gated, so
  // any prices/credits an admin edits afterwards are respected. Fresh DBs
  // get the same values from PLAN_DEFAULTS. Also the credit-pack tables:
  // packs are one-time top-up purchases paid manually (easypaisa / jazzcash
  // / bank transfer) and granted by an admin after verifying payment.
  { version: 5, up: `
    UPDATE plans SET credits_monthly = 100 WHERE id = 'normal';
    UPDATE plans SET credits_monthly = 120 WHERE id = 'pro';
    UPDATE plans SET credits_monthly = 120 WHERE id = 'extrapro';
    CREATE TABLE IF NOT EXISTS credit_packs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      credits INTEGER NOT NULL,
      price_pkr INTEGER NOT NULL,
      is_active INTEGER NOT NULL DEFAULT 1,
      sort_order INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE TABLE IF NOT EXISTS pack_purchases (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id),
      pack_id INTEGER NOT NULL REFERENCES credit_packs(id),
      credits INTEGER NOT NULL,
      amount_pkr INTEGER NOT NULL,
      method TEXT NOT NULL,
      transaction_ref TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending',
      admin_note TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      decided_at TEXT,
      decided_by INTEGER REFERENCES users(id)
    );` },
  // v6 — automatic payments (Phase 3): Google Play product mapping on
  // plans/packs, payments gain pack_id + credits_granted (needed to claw
  // back exactly what a payment granted, from the right bucket), and users
  // gain credit_deficit — the unrecovered remainder when a refund clawback
  // can't take back credits the user already spent.
  { version: 6, up: `
    ALTER TABLE plans ADD COLUMN play_product_monthly TEXT;
    ALTER TABLE plans ADD COLUMN play_product_yearly TEXT;
    UPDATE plans SET play_product_monthly = 'ajk_normal_monthly', play_product_yearly = 'ajk_normal_yearly' WHERE id = 'normal';
    UPDATE plans SET play_product_monthly = 'ajk_pro_monthly', play_product_yearly = 'ajk_pro_yearly' WHERE id = 'pro';
    UPDATE plans SET play_product_monthly = 'ajk_extrapro_monthly', play_product_yearly = 'ajk_extrapro_yearly' WHERE id = 'extrapro';
    ALTER TABLE credit_packs ADD COLUMN play_product_id TEXT;
    UPDATE credit_packs SET play_product_id = 'credits_' || credits WHERE play_product_id IS NULL;
    ALTER TABLE users ADD COLUMN credit_deficit INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE payments ADD COLUMN pack_id INTEGER;
    ALTER TABLE payments ADD COLUMN credits_granted INTEGER NOT NULL DEFAULT 0;` },
  // v7 — video modes, image-to-video and watermarks. `mode` separates the
  // Realistic Human and Cartoon/Animation experiences (existing rows are
  // realistic by default). source_image_path records the uploader-owned
  // image a generation was animated from; watermark_text is the optional
  // user-supplied overlay text and watermark_status tracks the honest
  // outcome of post-processing: none | pending | applied | failed.
  { version: 7, up: `
    ALTER TABLE generations ADD COLUMN mode TEXT NOT NULL DEFAULT 'realistic';
    ALTER TABLE generations ADD COLUMN source_image_path TEXT;
    ALTER TABLE generations ADD COLUMN watermark_text TEXT;
    ALTER TABLE generations ADD COLUMN watermark_status TEXT NOT NULL DEFAULT 'none';` },
  // v8 — owner price decision (2026-10-23, "Option 2"): the Normal plan
  // moves to Rs 1,999/month, Rs 19,990/year and 150 credits/month. Like
  // the v5 rescale it is a one-time, version-gated UPDATE of the normal
  // row only, so later admin edits are respected and Pro/Extra Pro are
  // untouched. No grandfathering is needed: no live subscribers exist
  // yet. Fresh DBs get the same values from PLAN_DEFAULTS.
  { version: 8, up: `
    UPDATE plans SET price_monthly = 1999, price_yearly = 19990,
      credits_monthly = 150 WHERE id = 'normal';` },
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

// ---------- Monetization: plans, subscriptions, payments ----------
// Seed the plan catalogue. Existing rows keep the prices/credits an admin
// may have edited; only structural fields are re-synced from PLAN_DEFAULTS.
for (const p of PLAN_DEFAULTS) {
  const existing = db.prepare('SELECT id FROM plans WHERE id = ?').get(p.id);
  if (!existing) {
    db.prepare(`INSERT INTO plans (id, name, price_monthly, price_yearly, credits_monthly,
                quality, quality_label, resolution, model, sort_order,
                play_product_monthly, play_product_yearly)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(p.id, p.name, p.price_monthly, p.price_yearly, p.credits_monthly,
           p.quality, p.quality_label, p.resolution, p.model, p.sort_order,
           p.play_product_monthly, p.play_product_yearly);
  } else {
    // Play product ids are backfilled only when unset (COALESCE) — an
    // admin's edits in the Admin Panel always win over these defaults.
    db.prepare(`UPDATE plans SET name = ?, quality = ?, quality_label = ?,
                resolution = ?, model = ?, sort_order = ?,
                play_product_monthly = COALESCE(play_product_monthly, ?),
                play_product_yearly = COALESCE(play_product_yearly, ?) WHERE id = ?`)
      .run(p.name, p.quality, p.quality_label, p.resolution, p.model, p.sort_order,
           p.play_product_monthly, p.play_product_yearly, p.id);
  }
}
// Seed the credit-pack catalogue on first boot only (when the table is
// empty). After that the admin panel owns the rows — boot never re-seeds or
// overwrites prices/credits an admin has changed.
{
  const { c } = db.prepare('SELECT COUNT(*) AS c FROM credit_packs').get();
  if (Number(c) === 0) {
    for (const p of PACK_DEFAULTS) {
      db.prepare('INSERT INTO credit_packs (credits, price_pkr, sort_order, play_product_id) VALUES (?, ?, ?, ?)')
        .run(p.credits, p.price_pkr, p.sort_order, p.play_product_id);
    }
  }
  // Backfill Play product ids for packs that predate them (deterministic
  // default 'credits_<n>'); an admin's own value is never overwritten.
  db.prepare(`UPDATE credit_packs SET play_product_id = 'credits_' || credits
              WHERE play_product_id IS NULL OR play_product_id = ''`).run();
}
// Bootstrap admin for an already-registered account (see also register/login).
if (CONFIG.adminEmail) {
  db.prepare('UPDATE users SET is_admin = 1 WHERE email = ?').run(CONFIG.adminEmail);
}

function getPlan(planId) {
  return db.prepare('SELECT * FROM plans WHERE id = ?').get(planId) || null;
}
function sqlTs(d) { return d.toISOString().slice(0, 19).replace('T', ' '); } // UTC, SQLite format
function addMonths(d, n) { const x = new Date(d); x.setUTCMonth(x.getUTCMonth() + n); return x; }
function isFuture(ts) { return !!ts && new Date(ts.replace(' ', 'T') + 'Z') > new Date(); }

// --- Credit buckets -------------------------------------------------------
// users.credits is always kept equal to free_credits + plan_credits.
function creditBuckets(user) {
  const free = user.free_credits ?? user.credits ?? 0; // ?? covers pre-v3 rows
  const plan = user.plan_credits ?? 0;
  return { free, plan, total: free + plan };
}
function setBuckets(userId, free, plan) {
  db.prepare('UPDATE users SET free_credits = ?, plan_credits = ?, credits = ? WHERE id = ?')
    .run(free, plan, free + plan, userId);
}
// Spend plan credits first so they never linger unused while free credits burn.
function spendBuckets(user, cost) {
  const b = creditBuckets(user);
  const fromPlan = Math.min(b.plan, cost);
  setBuckets(user.id, b.free - (cost - fromPlan), b.plan - fromPlan);
}
// Refund into plan bucket first, capped at the plan's monthly grant; the
// rest goes back to free credits. Keeps a refund from inflating plan credits.
function refundBuckets(userId, amount) {
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
  if (!user) return;
  const b = creditBuckets(user);
  const cap = planGrantCap(userId);
  const toPlan = Math.max(0, Math.min(cap - b.plan, amount));
  setBuckets(userId, b.free + (amount - toPlan), b.plan + toPlan);
}
function planGrantCap(userId) {
  const sub = latestSubscription(userId);
  if (!sub || !['active', 'grace', 'canceled'].includes(sub.status)) return 0;
  const plan = getPlan(sub.plan_id);
  return plan ? plan.credits_monthly : 0;
}

// --- Subscription lifecycle ----------------------------------------------
function latestSubscription(userId) {
  return db.prepare('SELECT * FROM subscriptions WHERE user_id = ? ORDER BY id DESC LIMIT 1')
    .get(userId) || null;
}
// A subscription is "current" (plan benefits apply) while active/grace, or
// canceled but still inside its paid period.
function subscriptionIsCurrent(sub) {
  if (!sub) return false;
  if (sub.status === 'active' || sub.status === 'grace') return isFuture(sub.current_period_end) || !sub.current_period_end;
  if (sub.status === 'canceled') return isFuture(sub.current_period_end);
  return false;
}
function currentSubscription(userId) {
  const sub = latestSubscription(userId);
  return subscriptionIsCurrent(sub) ? sub : null;
}
// Lazy expiry: a current-status subscription whose period has ended becomes
// 'expired' and its unused plan credits are removed (no rollover).
function refreshSubscriptionState(userId) {
  const sub = latestSubscription(userId);
  if (sub && ['active', 'grace', 'canceled'].includes(sub.status) &&
      sub.current_period_end && !isFuture(sub.current_period_end)) {
    tx(() => {
      db.prepare(`UPDATE subscriptions SET status = 'expired', updated_at = datetime('now') WHERE id = ?`).run(sub.id);
      const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
      if (user) { const b = creditBuckets(user); setBuckets(userId, b.free, 0); }
    });
    return latestSubscription(userId);
  }
  return sub;
}
// Activate (or replace) a subscription and grant this cycle's plan credits.
// The ONLY ways in are a succeeded payment record or an admin action —
// both funnel through here, so plan credits can never appear without a
// subscription row behind them. `periodEnd` (Google Play purchases) pins
// the period end to the provider's expiry instead of a calendar month.
function activateSubscription(userId, plan, { period = 'monthly', paymentId = null, periodEnd = null } = {}) {
  return tx(() => {
    db.prepare(`UPDATE subscriptions SET status = 'expired', updated_at = datetime('now')
                WHERE user_id = ? AND status IN ('active', 'grace', 'canceled')`).run(userId);
    const now = new Date();
    const end = periodEnd ? new Date(periodEnd) : addMonths(now, period === 'yearly' ? 12 : 1);
    const info = db.prepare(
      `INSERT INTO subscriptions (user_id, plan_id, status, period, started_at,
         current_period_start, current_period_end, last_grant_at, payment_id)
       VALUES (?, ?, 'active', ?, ?, ?, ?, ?, ?)`)
      .run(userId, plan.id, period, sqlTs(now), sqlTs(now), sqlTs(end), sqlTs(now), paymentId);
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    const b = creditBuckets(user);
    setBuckets(userId, b.free, plan.credits_monthly); // reset — no rollover
    return Number(info.lastInsertRowid);
  });
}
// Monthly renewal grant: plan credits reset to the plan's monthly amount.
function grantMonthlyCredits(userId) {
  return tx(() => {
    const sub = latestSubscription(userId);
    if (!sub || !['active', 'grace'].includes(sub.status) || !subscriptionIsCurrent(sub))
      throw Object.assign(new Error('NO_ACTIVE_SUBSCRIPTION'), { status: 400 });
    const plan = getPlan(sub.plan_id);
    if (!plan) throw Object.assign(new Error('PLAN_NOT_FOUND'), { status: 400 });
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    const b = creditBuckets(user);
    setBuckets(userId, b.free, plan.credits_monthly);
    db.prepare(`UPDATE subscriptions SET last_grant_at = ?, updated_at = datetime('now') WHERE id = ?`)
      .run(sqlTs(new Date()), sub.id);
    return sub.id;
  });
}
function publicPlan(p) {
  return { id: p.id, name: p.name, price_monthly: p.price_monthly, price_yearly: p.price_yearly,
    currency: p.currency, credits_monthly: p.credits_monthly, quality: p.quality,
    quality_label: p.quality_label, resolution: p.resolution,
    // Google Play subscription product ids (set in Play Console; editable
    // in the Admin Panel). Used by the app's Digital Goods purchase flow.
    play_product_id: { monthly: p.play_product_monthly || null, yearly: p.play_product_yearly || null } };
}
function publicPack(p) {
  return { id: p.id, credits: p.credits, price_pkr: p.price_pkr, currency: 'PKR',
    is_active: !!p.is_active, play_product_id: p.play_product_id || null };
}
function subscriptionView(sub) {
  if (!sub) return null;
  const plan = getPlan(sub.plan_id);
  return { id: sub.id, plan_id: sub.plan_id, plan_name: plan ? plan.name : sub.plan_id,
    status: sub.status, period: sub.period, current: subscriptionIsCurrent(sub),
    current_period_start: sub.current_period_start, current_period_end: sub.current_period_end,
    last_grant_at: sub.last_grant_at };
}

// ---------- App ----------
const app = express();
app.use(cors({ origin: FRONTEND_ORIGIN || true }));
// JSON bodies are capped at 100kb — except the image-upload route, whose
// base64 payload needs its own larger parser (mounted on the route; the
// global parser is skipped for that exact path).
const jsonParser = express.json({ limit: '100kb' });
app.use((req, res, next) => req.path === '/api/uploads/image' ? next() : jsonParser(req, res, next));
// Payment gateways post their IPN/webhook callbacks as form data.
app.use(express.urlencoded({ extended: false, limit: '100kb' }));
app.use(rateLimit({ windowMs: 15 * 60 * 1000, max: 300 }));
const generateLimiter = rateLimit({ windowMs: 60 * 60 * 1000, max: 10,
  message: { error: 'Rate limit: max 10 generations per hour.' } });
// Clip joining is CPU-heavy (ffmpeg) — separately limited per signed-in user.
const joinLimiter = rateLimit({ windowMs: 60 * 60 * 1000, max: 10,
  keyGenerator: (req) => String(req.user?.id || req.ip),
  message: { error: 'Rate limit: max 10 joins per hour.' } });

function auth(req, res, next) {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  try { req.user = jwt.verify(token, JWT_SECRET); next(); }
  catch { res.status(401).json({ error: 'Please sign in again.' }); }
}

// Admin gate: the is_admin flag lives on the user row (bootstrapped from
// ADMIN_EMAIL). The flag is re-read from the DB on every request, so
// revoking it takes effect immediately.
function requireAdmin(req, res, next) {
  const u = db.prepare('SELECT id, is_admin FROM users WHERE id = ?').get(req.user.id);
  if (!u) return res.status(401).json({ error: 'Please sign in again.' });
  if (!u.is_admin) return res.status(403).json({ error: 'Admin access required.' });
  req.adminUser = u;
  next();
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
  modes: MODE_LIST,
  prompt_languages: PROMPT_LANGUAGES,
  cost_by_duration: CONFIG.costByDuration,
  signup_credits: CONFIG.signupCredits,
  max_daily_credits: CONFIG.maxDailyCredits,
  // Manual payment destinations for credit packs — only the methods the
  // owner configured in the environment are listed (may be empty).
  payment_methods: CONFIG.paymentMethods,
  // Automatic-payment availability (flags only, never secrets): the app
  // shows Google Play purchase buttons when Play Billing is configured
  // server-side, and the gateway "Instant" buttons when a payment gateway
  // is configured. Both stay false until the owner's accounts exist.
  play_billing_configured: playBillingConfigured(),
  gateway_configured: gatewayConfigured(),
}));
app.get('/api/health', (req, res) => res.json({ ok: true, model: CONFIG.model }));

// ---------- Plans & payments (user-facing) ----------
app.get('/api/plans', (req, res) => {
  const plans = db.prepare('SELECT * FROM plans WHERE is_active = 1 ORDER BY sort_order').all();
  res.json({ plans: plans.map(publicPlan), currency: 'PKR' });
});

// The signed-in user's own payment history — never anyone else's.
app.get('/api/payments', auth, (req, res) => {
  const rows = db.prepare('SELECT * FROM payments WHERE user_id = ? ORDER BY id DESC LIMIT 100')
    .all(req.user.id);
  res.json({ payments: rows });
});

// ---------- Credit packs (one-time top-ups, manual payment + admin approval) ----------
// Flow: the user sends money to one of the owner's published destinations
// (easypaisa / jazzcash / bank — see payment_methods in /api/config), then
// submits the transaction reference here. That creates a PENDING purchase
// and grants NOTHING. An admin verifies the payment in the Admin Panel and
// approves (credits land in the user's free_credits bucket, exactly once)
// or rejects it. There is deliberately no user-facing approval route.
app.get('/api/packs', (req, res) => {
  const packs = db.prepare('SELECT * FROM credit_packs WHERE is_active = 1 ORDER BY sort_order, id').all();
  res.json({ packs: packs.map(publicPack), currency: 'PKR' });
});

app.post('/api/packs/:id/purchase', auth, (req, res) => {
  const pack = db.prepare('SELECT * FROM credit_packs WHERE id = ?').get(req.params.id);
  if (!pack || !pack.is_active)
    return res.status(404).json({ error: 'That credit pack is not available.' });
  const b = req.body || {};
  const method = String(b.method || '').toLowerCase();
  if (!PACK_METHODS.includes(method))
    return res.status(400).json({ error: `method must be one of: ${PACK_METHODS.join(', ')}` });
  const ref = String(b.transaction_ref || '').trim();
  if (ref.length < 6)
    return res.status(400).json({ error: 'Please enter the payment transaction ID (at least 6 characters).' });
  const info = db.prepare(
    `INSERT INTO pack_purchases (user_id, pack_id, credits, amount_pkr, method, transaction_ref, status)
     VALUES (?, ?, ?, ?, ?, ?, 'pending')`)
    .run(req.user.id, pack.id, pack.credits, pack.price_pkr, method, ref.slice(0, 120));
  const row = db.prepare('SELECT * FROM pack_purchases WHERE id = ?').get(Number(info.lastInsertRowid));
  res.status(201).json({ purchase: row });
});

app.get('/api/my/pack-purchases', auth, (req, res) => {
  const rows = db.prepare('SELECT * FROM pack_purchases WHERE user_id = ? ORDER BY id DESC LIMIT 100')
    .all(req.user.id);
  res.json({ purchases: rows });
});

// ---------- Auth ----------
app.post('/api/auth/register', async (req, res) => {
  const { email, password } = req.body || {};
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !password || password.length < 8)
    return res.status(400).json({ error: 'A valid email and a password of 8+ characters are required.' });
  const hash = await bcrypt.hash(password, 10);
  try {
    const emailLc = email.toLowerCase();
    const isAdmin = CONFIG.adminEmail && emailLc === CONFIG.adminEmail ? 1 : 0;
    const info = db.prepare(
      'INSERT INTO users (email, password_hash, credits, free_credits, plan_credits, is_admin) VALUES (?, ?, ?, ?, 0, ?)')
      .run(emailLc, hash, CONFIG.signupCredits, CONFIG.signupCredits, isAdmin);
    const token = jwt.sign({ id: Number(info.lastInsertRowid), email: emailLc }, JWT_SECRET, { expiresIn: '7d' });
    res.json({ token, credits: CONFIG.signupCredits });
  } catch { res.status(409).json({ error: 'An account with this email already exists.' }); }
});

app.post('/api/auth/login', async (req, res) => {
  const { email, password } = req.body || {};
  const user = db.prepare('SELECT * FROM users WHERE email = ?').get((email || '').toLowerCase());
  if (!user || !(await bcrypt.compare(password || '', user.password_hash)))
    return res.status(401).json({ error: 'Wrong email or password.' });
  // Bootstrap admin also applies to accounts registered before ADMIN_EMAIL
  // was configured.
  if (CONFIG.adminEmail && user.email === CONFIG.adminEmail && !user.is_admin)
    db.prepare('UPDATE users SET is_admin = 1 WHERE id = ?').run(user.id);
  const token = jwt.sign({ id: user.id, email: user.email }, JWT_SECRET, { expiresIn: '7d' });
  res.json({ token, credits: user.credits });
});

app.get('/api/me', auth, (req, res) => {
  refreshSubscriptionState(req.user.id);
  const u = db.prepare('SELECT id, email, credits, free_credits, plan_credits, credit_deficit, is_admin, created_at FROM users WHERE id = ?').get(req.user.id);
  if (!u) return res.status(404).json({ error: 'Account not found.' });
  const sub = currentSubscription(u.id);
  const plan = sub ? getPlan(sub.plan_id) : null;
  res.json({ ...u, plan: plan ? publicPlan(plan) : null,
    subscription: subscriptionView(latestSubscription(u.id)) });
});

// ---------- Image uploads (source images for image-to-video) ----------
// The client sends the image as base64 JSON. The declared content_type is
// NEVER trusted: the real type is sniffed from the magic bytes, and only
// PNG / JPEG / WebP are accepted. Files land under data/uploads/<userId>/
// — the owner segment in the path is what later proves ownership when a
// generation references the image. Decoded size is capped at 5 MB.
const IMAGE_UPLOAD_MAX_BYTES = 5 * 1024 * 1024;
const IMAGE_TYPES = [
  { contentType: 'image/png', ext: 'png',
    match: b => b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47 &&
                b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a },
  { contentType: 'image/jpeg', ext: 'jpg',
    match: b => b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff },
  { contentType: 'image/webp', ext: 'webp',
    match: b => b.length >= 12 && b.toString('ascii', 0, 4) === 'RIFF' && b.toString('ascii', 8, 12) === 'WEBP' },
];
function sniffImageType(buf) { return IMAGE_TYPES.find(t => t.match(buf)) || null; }

app.post('/api/uploads/image', auth, express.json({ limit: '8mb' }), (req, res) => {
  const raw = String(req.body?.image_base64 || '').trim();
  if (!raw) return res.status(400).json({ error: 'image_base64 is required.' });
  const base64 = raw.startsWith('data:') ? (raw.split(',', 2)[1] || '') : raw;
  if (!/^[A-Za-z0-9+/=\s]+$/.test(base64))
    return res.status(400).json({ error: 'image_base64 is not valid base64.' });
  const buf = Buffer.from(base64, 'base64');
  if (buf.length === 0) return res.status(400).json({ error: 'The uploaded image is empty.' });
  if (buf.length > IMAGE_UPLOAD_MAX_BYTES)
    return res.status(413).json({ error: 'Image is too large — the limit is 5 MB.' });
  const type = sniffImageType(buf);
  if (!type)
    return res.status(415).json({ error: 'Only PNG, JPEG and WebP images are supported.' });
  const dir = path.join(CONFIG.uploadsDir, String(req.user.id));
  fs.mkdirSync(dir, { recursive: true });
  const name = `${randomUUID()}.${type.ext}`;
  fs.writeFileSync(path.join(dir, name), buf);
  const imagePath = `data/uploads/${req.user.id}/${name}`;
  res.status(201).json({ image_path: imagePath, content_type: type.contentType,
    size_bytes: buf.length });
});

// Resolve a client-supplied image_path to a stored upload OWNED by this
// user. Returns { abs, contentType } or null — any path outside the
// caller's own upload folder (or a missing file) is rejected.
function resolveOwnedUpload(userId, imagePath) {
  if (!imagePath || typeof imagePath !== 'string') return null;
  const normalized = path.posix.normalize(imagePath.replace(/\\/g, '/').replace(/^\.\//, ''));
  const prefix = `data/uploads/${userId}/`;
  if (!normalized.startsWith(prefix) || normalized.split('/').includes('..')) return null;
  const abs = path.join(__dirname, ...normalized.split('/'));
  if (!abs.startsWith(path.join(CONFIG.uploadsDir, String(userId)) + path.sep)) return null;
  let buf;
  try { buf = fs.readFileSync(abs); } catch { return null; }
  const type = sniffImageType(buf);
  if (!type) return null;
  return { abs, contentType: type.contentType, dataUri: `data:${type.contentType};base64,${buf.toString('base64')}` };
}

// ---------- Generation (idempotent + atomic charge) ----------
app.post('/api/generate', auth, generateLimiter, async (req, res) => {
  const { prompt, aspect_ratio = '16:9', duration = 5, style = 'realistic', language = 'en' } = req.body || {};
  const mode = String(req.body?.mode || 'realistic').toLowerCase();
  const idemKey = String(req.headers['idempotency-key'] || req.body?.idempotency_key || '').slice(0, 80) || null;

  if (!prompt || prompt.trim().length < 3 || prompt.length > 500)
    return res.status(400).json({ error: 'Please describe your video in 3–500 characters.' });
  if (!CONFIG.aspectRatios.includes(aspect_ratio))
    return res.status(400).json({ error: `aspect_ratio must be one of: ${CONFIG.aspectRatios.join(', ')}` });
  if (!CONFIG.durations.includes(Number(duration)))
    return res.status(400).json({ error: `duration must be one of: ${CONFIG.durations.join(', ')} seconds` });
  if (!CONFIG.styles.includes(style))
    return res.status(400).json({ error: `style must be one of: ${CONFIG.styles.join(', ')}` });
  if (!Object.hasOwn(VIDEO_MODES, mode))
    return res.status(400).json({ error: `mode must be one of: ${Object.keys(VIDEO_MODES).join(', ')}` });
  if (!VIDEO_MODES[mode].includes(style))
    return res.status(400).json({ error: `style "${style}" is not available in ${mode} mode — use one of: ${VIDEO_MODES[mode].join(', ')}` });
  // Optional watermark: user-supplied overlay text, Latin printable ASCII
  // only (the renderer has no Urdu/Arabic shaping — non-Latin text would
  // come out wrong, so it is refused up front rather than faked).
  let watermarkText = null;
  let watermarkStatus = 'none';
  if (req.body?.watermark_text !== undefined && req.body?.watermark_text !== null &&
      String(req.body.watermark_text).length > 0) {
    const candidate = String(req.body.watermark_text);
    if (candidate.length > 30 || !/^[\x20-\x7E]+$/.test(candidate))
      return res.status(400).json({ error: 'watermark_text must be 1–30 printable ASCII (Latin) characters — Urdu/Arabic-script watermarks are not supported.' });
    watermarkText = candidate;
    watermarkStatus = 'pending';
  }
  // Optional image-to-video: the source image must be one of THIS user's
  // uploads (see POST /api/uploads/image). It is sent to the verified H3
  // image-to-video endpoint in its documented `image_url` field as a
  // base64 data URI (fal accepts data URIs for file inputs).
  let sourceImagePath = null;
  let sourceImageDataUri = null;
  if (req.body?.image_path !== undefined && req.body?.image_path !== null && req.body?.image_path !== '') {
    const owned = resolveOwnedUpload(req.user.id, req.body.image_path);
    if (!owned)
      return res.status(400).json({ error: 'image_path must be an image you uploaded (POST /api/uploads/image).' });
    sourceImagePath = String(req.body.image_path).replace(/\\/g, '/').replace(/^\.\//, '');
    sourceImageDataUri = owned.dataUri;
  }
  const languageCode = String(language).toLowerCase();
  if (!PROMPT_LANGUAGES.some(l => l.code === languageCode))
    return res.status(400).json({ error: `language must be one of: ${PROMPT_LANGUAGES.map(l => l.code).join(', ')}` });
  if (moderated(prompt))
    return res.status(400).json({ error: 'This prompt was blocked by content moderation. Please rephrase it.' });

  // --- Prompt language -----------------------------------------------------
  // English and Chinese go to the model exactly as written. The other
  // supported languages are translated to English here — BEFORE plan
  // routing, credit deduction and the fal call — so a failed translation
  // never costs a credit and never creates a job. The user's original text
  // is what gets stored in `prompt`; the translation is kept alongside it.
  let effectivePrompt = prompt.trim();
  let translatedPrompt = null;
  if (TRANSLATED_LANGUAGES.has(languageCode)) {
    try {
      translatedPrompt = await translatePrompt(prompt.trim(), languageCode);
    } catch {
      return res.status(502).json({ error: 'We could not translate your prompt into English, so nothing was charged. Please try again.' });
    }
    if (moderated(translatedPrompt))
      return res.status(400).json({ error: 'This prompt was blocked by content moderation. Please rephrase it.' });
    effectivePrompt = translatedPrompt;
  }

  // --- Plan routing -------------------------------------------------------
  // The user's current plan sets the maximum quality (resolution + model).
  // A lower resolution may be requested explicitly; a higher one is capped
  // at the plan's quality. Free users get the server default quality.
  refreshSubscriptionState(req.user.id);
  const sub = currentSubscription(req.user.id);
  const plan = sub ? getPlan(sub.plan_id) : null;
  const planResolution = plan ? plan.resolution : CONFIG.resolution;
  let resolution = planResolution;
  if (req.body.resolution !== undefined) {
    const wanted = String(req.body.resolution).toUpperCase();
    if (!RESOLUTIONS.includes(wanted))
      return res.status(400).json({ error: `resolution must be one of: ${RESOLUTIONS.join(', ')}` });
    if (RESOLUTIONS.indexOf(wanted) <= RESOLUTIONS.indexOf(planResolution)) resolution = wanted;
  }
  let model = resolution === '4K' ? (plan && plan.resolution === '4K' ? plan.model : CONFIG.model4k)
                                     : CONFIG.model;
  // The native-4K endpoint only renders 16:9, 9:16 and 1:1. A 4K-quality
  // request at any other ratio falls back to the H3 model at 2K with the
  // standard (non-doubled) credit rate — it is not native 4K, so it must
  // not be charged or recorded as 4K.
  let fallbackNote = null;
  if (resolution === '4K' && !FOUR_K_ASPECTS.includes(aspect_ratio)) {
    resolution = '2K';
    model = CONFIG.model;
    fallbackNote = 'Native 4K is only available for 16:9, 9:16 and 1:1 videos; ' +
                   'this video was generated at 2K instead.';
  }
  // Image-to-video overrides the model route: the verified H3
  // image-to-video endpoint animates the uploaded image as the opening
  // frame (its canvas follows the image, so no aspect_ratio is sent).
  // Credit rules are unchanged — the same duration/4K cost formula below
  // applies whether or not a source image is attached.
  if (sourceImagePath) model = CONFIG.modelI2V;
  // Native-4K generations cost double credits; everything else is the
  // standard per-duration rate.
  const cost = (CONFIG.costByDuration[Number(duration)] ?? 1) *
               (resolution === '4K' ? CONFIG.costMultiplier4k : 1);

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
      if (creditBuckets(user).total < cost) throw Object.assign(new Error('NO_CREDITS'), { status: 402 });
      spendBuckets(user, cost); // plan credits first, then free credits
      const info = db.prepare(
        `INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, cost_credits, idempotency_key, resolution, model, prompt_language, translated_prompt, mode, source_image_path, watermark_text, watermark_status)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(user.id, prompt.trim(), aspect_ratio, Number(duration), style, cost, idemKey, resolution, model, languageCode, translatedPrompt, mode, sourceImagePath, watermarkText, watermarkStatus);
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

  // Submit to fal.ai queue (key never leaves the server) — routed to the
  // model + resolution the user's plan entitles them to.
  // The Kling native-4K endpoint has no `resolution` parameter (4K is fixed
  // by the endpoint itself) and expects `duration` as a string enum
  // ("5"/"10" — fal.ai's official schema, verified 2026-10-22), and that
  // endpoint's own schema does accept generate_audio, which we pin false.
  // The H3 text/image-to-video schemas have NO generate_audio toggle —
  // H3 generates its native audio track itself — so no such field is
  // ever sent to them.
  const isNative4k = resolution === '4K' && model === CONFIG.model4k;
  const falBody = sourceImagePath
    ? { prompt: `${effectivePrompt} — style: ${style}`,
        duration: Number(duration), resolution,
        enable_safety_checker: true, image_url: sourceImageDataUri }
    : isNative4k
    ? { prompt: `${effectivePrompt} — style: ${style}`,
        duration: String(duration), aspect_ratio,
        generate_audio: false, enable_safety_checker: true }
    : { prompt: `${effectivePrompt} — style: ${style}`,
        duration: Number(duration), aspect_ratio, resolution,
        enable_safety_checker: true };
  lastFalBody = falBody; // test hook (recorded only, never sent anywhere else)
  try {
    const r = await fetch(`https://queue.fal.run/${model}`, {
      method: 'POST',
      headers: { 'Authorization': `Key ${FAL_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(falBody),
    });
    if (!r.ok) throw new Error(`fal.ai returned ${r.status}`);
    const data = await r.json();
    db.prepare(`UPDATE generations SET fal_request_id = ?, status = 'in_progress',
                updated_at = datetime('now') WHERE id = ?`).run(data.request_id, jobId);
    const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
    res.json({ id: jobId, status: 'in_progress', credits_left: me.credits,
               cost_credits: cost, resolution, model, prompt_language: languageCode,
               mode, source_image_path: sourceImagePath,
               watermark_status: watermarkStatus,
               ...(translatedPrompt ? { translated_prompt: translatedPrompt } : {}),
               ...(fallbackNote ? { note: fallbackNote } : {}) });
  } catch (e) {
    failAndRefund(jobId, `Provider submission failed (${e.message})`);
    res.status(502).json({ error: 'Video service is unavailable right now. Your credit was refunded.' });
  }
});

// ---------- Test hook: last fal request body (only when env-gated) ----------
// test.sh starts the server with TEST_RECORD_FAL_BODY=1 so the suite can
// assert the exact fal request shape without making a real provider call.
let lastFalBody = null;
if (process.env.TEST_RECORD_FAL_BODY === '1') {
  app.get('/api/_test/fal-body', (req, res) => res.json({ body: lastFalBody }));
}

// Transition a job to failed exactly once, refunding its credits exactly once.
function failAndRefund(jobId, message) {
  const changed = db.prepare(
    `UPDATE generations SET status = 'failed', error = ?, updated_at = datetime('now')
     WHERE id = ? AND status NOT IN ('failed', 'completed')`).run(message, jobId);
  if (Number(changed.changes) === 1) {
    const job = db.prepare('SELECT user_id, cost_credits FROM generations WHERE id = ?').get(jobId);
    tx(() => refundBuckets(job.user_id, job.cost_credits));
  }
}

// ---------- Watermark post-processing ----------
// NOTE on the renderer: the pinned ffmpeg-static 5.3.0 binary has NO
// drawtext filter (it was built without libfreetype), but it DOES ship
// libass (the `ass`/`subtitles` filters). The watermark is therefore
// rendered as a timed ASS subtitle — same visual contract: bottom-right,
// white at ~70% opacity, small. Claiming drawtext here would be false;
// the README documents this openly.
function assTimestamp(seconds) {
  const s = Math.max(0, Number(seconds) || 0);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
  const sec = Math.floor(s % 60), cs = Math.round((s - Math.floor(s)) * 100);
  return `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}.${String(cs).padStart(2, '0')}`;
}
function escapeAssText(text) {
  return String(text).replace(/\\/g, '\\\\').replace(/\{/g, '\\{').replace(/\}/g, '\\}')
    .replace(/\r?\n/g, ' ');
}
const watermarkInFlight = new Set();
async function ensureWatermarkApplied(job) {
  if (!job || job.status !== 'completed' || !job.watermark_text) return job;
  if (job.watermark_status !== 'pending') return job;
  if (watermarkInFlight.has(job.id)) return job;
  watermarkInFlight.add(job.id);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ajk-wm-'));
  try {
    if (!job.video_url) throw new Error('completed job has no video_url to watermark');
    const input = path.join(work, 'input.mp4');
    await downloadClip(job.video_url, input, { left: JOIN_MAX_BYTES });
    const probe = await probeMedia(input);
    const fontSize = Math.min(72, Math.max(14, Math.round(probe.height / 18)));
    const assPath = path.join(work, 'watermark.ass');
    const ass = [
      '[Script Info]',
      'ScriptType: v4.00+',
      `PlayResX: ${probe.width}`,
      `PlayResY: ${probe.height}`,
      '',
      '[V4+ Styles]',
      'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
      // Alignment 3 = bottom-right. PrimaryColour &H4DFFFFFF = white with
      // alpha 0x4D, i.e. ~70% opaque.
      `Style: Watermark,DejaVu Sans,${fontSize},&H4DFFFFFF,&H000000FF,&H80000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,3,16,16,16,1`,
      '',
      '[Events]',
      'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
      `Dialogue: 0,0:00:00.00,${assTimestamp(probe.duration + 0.5)},Watermark,,0,0,0,,${escapeAssText(job.watermark_text)}`,
      '',
    ].join('\n');
    fs.writeFileSync(assPath, ass);
    fs.mkdirSync(CONFIG.generatedDir, { recursive: true });
    const name = `${randomUUID()}.mp4`;
    const output = path.join(CONFIG.generatedDir, name);
    const filterPath = assPath.replace(/\\/g, '/').replace(/:/g, '\\:').replace(/'/g, "\\'");
    await runFfmpeg(['-y', '-i', input, '-vf', `ass=${filterPath}`,
                     '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
                     '-c:a', 'copy', output]);
    if (!fs.existsSync(output) || fs.statSync(output).size === 0)
      throw new Error('watermark render produced no output');
    db.prepare(`UPDATE generations SET video_url = ?, watermark_status = 'applied',
                updated_at = datetime('now') WHERE id = ?`).run(`/files/generated/${name}`, job.id);
  } catch (e) {
    // Honest failure: the unwatermarked video stays in place and the row
    // is marked watermark_status='failed' — never reported as applied.
    console.error(`watermark failed for generation ${job.id}:`, e.message);
    db.prepare(`UPDATE generations SET watermark_status = 'failed',
                updated_at = datetime('now') WHERE id = ?`).run(job.id);
  } finally {
    watermarkInFlight.delete(job.id);
    fs.rmSync(work, { recursive: true, force: true });
  }
  return db.prepare('SELECT * FROM generations WHERE id = ?').get(job.id) || job;
}

app.get('/api/generations/:id', auth, async (req, res) => {
  const job = db.prepare('SELECT * FROM generations WHERE id = ? AND user_id = ?')
    .get(req.params.id, req.user.id);
  if (!job) return res.status(404).json({ error: 'Generation not found.' });
  if (job.status === 'completed') return res.json(await ensureWatermarkApplied(job));
  if (job.status === 'failed' || !job.fal_request_id)
    return res.json(job);
  const jobModel = job.model || CONFIG.model; // jobs remember their routed model
  try {
    const sr = await fetch(`https://queue.fal.run/${jobModel}/requests/${job.fal_request_id}/status`,
      { headers: { 'Authorization': `Key ${FAL_KEY}` } });
    if (sr.ok) {
      const s = await sr.json();
      if (s.status === 'COMPLETED') {
        const rr = await fetch(`https://queue.fal.run/${jobModel}/requests/${job.fal_request_id}`,
          { headers: { 'Authorization': `Key ${FAL_KEY}` } });
        const result = await rr.json();
        const url = result?.video?.url || result?.data?.video?.url || null;
        if (url) {
          db.prepare(`UPDATE generations SET status = 'completed', video_url = ?,
                      updated_at = datetime('now') WHERE id = ?`).run(url, job.id);
          job.status = 'completed'; job.video_url = url;
          // If this job asked for a watermark, post-process BEFORE the
          // client sees the completed video (applied or honestly failed).
          if (job.watermark_text && job.watermark_status === 'pending')
            return res.json(await ensureWatermarkApplied(job));
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

// ---------- Clip joining (merge 2–6 of the user's own clips, free) ----------
// Uses the pinned ffmpeg-static binary. Each clip is downloaded, normalized
// to the FIRST clip's width/height/fps (scale + pad, H.264 + AAC — silent
// audio is generated for clips that have none), then concatenated. The
// result is stored on local disk and served from /files/joined/. Joining
// costs 0 credits and creates a normal completed generations row.
const JOIN_MAX_CLIPS = 6;
const JOIN_MAX_BYTES = 200 * 1024 * 1024; // total download cap across clips

function runFfmpeg(args, timeoutMs = 300000) {
  return new Promise((resolve, reject) => {
    execFile(ffmpegStatic, args, { timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 },
      (err, _stdout, stderr) => err
        ? reject(new Error(`ffmpeg failed: ${String(stderr || err.message).slice(-300)}`))
        : resolve());
  });
}
// Probe a media file by parsing `ffmpeg -i` output (ffmpeg-static ships no
// ffprobe binary). Throws when the file has no readable video stream.
async function probeMedia(file) {
  const info = await new Promise((resolve) => {
    execFile(ffmpegStatic, ['-i', file], { timeout: 30000 },
      (_err, _stdout, stderr) => resolve(String(stderr || '')));
  });
  const dur = info.match(/Duration:\s*(\d+):(\d+):([\d.]+)/);
  const dim = info.match(/[,\s](\d{2,5})x(\d{2,5})(?=[,\s\[])/);
  const fps = info.match(/([\d.]+)\s*fps/);
  if (!dur || !dim) throw new Error('Could not read one of the clips — it may not be a valid video file.');
  return {
    duration: Number(dur[1]) * 3600 + Number(dur[2]) * 60 + Number(dur[3]),
    width: Number(dim[1]), height: Number(dim[2]),
    fps: fps ? Number(fps[1]) : 30,
    hasAudio: /\bAudio:/.test(info),
  };
}
async function downloadClip(url, dest, budget) {
  // Our own joined files are referenced by path only — fetch them back from
  // this same server over loopback.
  const abs = /^https?:\/\//i.test(url) ? url
    : `http://127.0.0.1:${process.env.PORT || 8080}${url}`;
  const r = await fetch(abs, { redirect: 'follow', signal: AbortSignal.timeout(120000) });
  if (!r.ok || !r.body) throw new Error('Could not download one of the clips.');
  const declared = Number(r.headers.get('content-length') || 0);
  if (declared > budget.left) throw new Error('These clips are too large to join (200 MB total limit).');
  let seen = 0;
  const counter = new Transform({
    transform(chunk, _enc, cb) {
      seen += chunk.length;
      if (seen > budget.left) cb(new Error('These clips are too large to join (200 MB total limit).'));
      else cb(null, chunk);
    },
  });
  await pipeline(Readable.fromWeb(r.body), counter, fs.createWriteStream(dest));
  budget.left -= seen;
}

app.post('/api/generations/join', auth, joinLimiter, async (req, res) => {
  const ids = Array.isArray(req.body?.ids)
    ? req.body.ids.map(Number).filter(Number.isInteger) : [];
  if (ids.length < 2 || ids.length > JOIN_MAX_CLIPS)
    return res.status(400).json({ error: `Choose between 2 and ${JOIN_MAX_CLIPS} clips to join.` });
  const unique = [...new Set(ids)];
  const rows = db.prepare(
    `SELECT * FROM generations WHERE id IN (${unique.map(() => '?').join(',')}) AND user_id = ?`)
    .all(...unique, req.user.id);
  if (rows.length !== unique.length)
    return res.status(404).json({ error: 'One or more clips were not found.' });
  const byId = new Map(rows.map(r => [r.id, r]));
  const clips = unique.map(id => byId.get(id));
  if (clips.some(c => c.status !== 'completed' || !c.video_url))
    return res.status(400).json({ error: 'Only completed videos can be joined.' });

  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ajk-join-'));
  try {
    const budget = { left: JOIN_MAX_BYTES };
    const srcs = [];
    for (let i = 0; i < clips.length; i++) {
      const dest = path.join(work, `src${i}.mp4`);
      await downloadClip(clips[i].video_url, dest, budget);
      srcs.push(dest);
    }
    const probes = [];
    for (const s of srcs) probes.push(await probeMedia(s));
    const target = probes[0]; // normalize everything to the first clip
    const vf = `scale=${target.width}:${target.height}:force_original_aspect_ratio=decrease,` +
               `pad=${target.width}:${target.height}:(ow-iw)/2:(oh-ih)/2,` +
               `fps=${target.fps},setsar=1,format=yuv420p`;
    const norms = [];
    for (let i = 0; i < srcs.length; i++) {
      const out = path.join(work, `norm${i}.mp4`);
      const enc = ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
                   '-c:a', 'aac', '-ar', '48000', '-ac', '2'];
      if (probes[i].hasAudio) {
        await runFfmpeg(['-y', '-i', srcs[i], '-map', '0:v:0', '-map', '0:a:0',
                         '-vf', vf, ...enc, out]);
      } else {
        // No audio stream: add a silent track of the same length so every
        // intermediate has identical stream layout for the concat step.
        await runFfmpeg(['-y', '-i', srcs[i],
                         '-f', 'lavfi', '-t', String(probes[i].duration),
                         '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000',
                         '-map', '0:v:0', '-map', '1:a:0', '-vf', vf, ...enc,
                         '-shortest', out]);
      }
      norms.push(out);
    }
    const listFile = path.join(work, 'list.txt');
    fs.writeFileSync(listFile, norms.map(n => `file '${n}'`).join('\n'));
    const joinedTmp = path.join(work, 'joined.mp4');
    try {
      await runFfmpeg(['-y', '-f', 'concat', '-safe', '0', '-i', listFile, '-c', 'copy', joinedTmp]);
    } catch {
      await runFfmpeg(['-y', '-f', 'concat', '-safe', '0', '-i', listFile,
                       '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
                       '-c:a', 'aac', joinedTmp]);
    }
    fs.mkdirSync(CONFIG.joinedDir, { recursive: true });
    const name = `${randomUUID()}.mp4`;
    fs.copyFileSync(joinedTmp, path.join(CONFIG.joinedDir, name));

    const totalDuration = Math.max(1, Math.round(probes.reduce((s, p) => s + p.duration, 0)));
    const gcd = (a, b) => (b ? gcd(b, a % b) : a);
    const g = gcd(target.width, target.height) || 1;
    const info = db.prepare(
      `INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits)
       VALUES (?, ?, ?, ?, 'realistic', 'completed', ?, 0)`)
      .run(req.user.id, `Joined video (${clips.length} clips)`,
           `${target.width / g}:${target.height / g}`, totalDuration,
           `/files/joined/${name}`);
    const row = db.prepare('SELECT * FROM generations WHERE id = ?').get(Number(info.lastInsertRowid));
    res.status(201).json({ generation: row });
  } catch (e) {
    console.error('join failed:', e.message);
    res.status(500).json({ error: `Could not join those clips. ${e.message}` });
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

// ---------- Report inappropriate content ----------
app.post('/api/report', auth, (req, res) => {
  const { generation_id, reason } = req.body || {};
  if (!reason) return res.status(400).json({ error: 'Please give a reason.' });
  db.prepare('INSERT INTO reports (user_id, generation_id, reason) VALUES (?, ?, ?)')
    .run(req.user.id, generation_id || null, String(reason).slice(0, 500));
  res.json({ ok: true, message: 'Thank you. Our team will review this content.' });
});

// ==========================================================================
// Automatic payments (Phase 3) — Google Play Billing + PayFast gateway
// ==========================================================================
// Both pipelines obey the same two rules:
//   1. FAIL CLOSED — credits are granted ONLY after the provider verifies
//      the payment server-side (Google Play Developer API for Play; the
//      signed IPN for the gateway). Client claims, screenshots and
//      notification text alone never grant anything.
//   2. EXACTLY ONCE — every provider transaction is recorded in the
//      `payments` table under its unique provider_txn_id. Replays return
//      the recorded outcome and never grant twice. Refunds/voids from
//      either provider run through the SAME clawback helper below.

// ---------- Google Play: credentials, OAuth (RS256), verification --------
let _playCredsCache = null;
function loadPlayCredentials() {
  if (_playCredsCache) return _playCredsCache;
  const raw = CONFIG.playCredentials;
  if (!raw) return null;
  try {
    const json = raw.trim().startsWith('{') ? raw : fs.readFileSync(raw.trim(), 'utf8');
    const parsed = JSON.parse(json);
    if (!parsed.client_email || !parsed.private_key) return null;
    _playCredsCache = parsed;
    return parsed;
  } catch { return null; }
}
function playBillingConfigured() {
  if (CONFIG.playTestMode) return true;
  return !!CONFIG.playPackageName && !!loadPlayCredentials();
}
function base64url(input) {
  return Buffer.from(input).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
let _playTokenCache = { token: null, exp: 0 };
async function playAccessToken() {
  if (_playTokenCache.token && Date.now() < _playTokenCache.exp - 30000)
    return _playTokenCache.token;
  const creds = loadPlayCredentials();
  if (!creds) throw Object.assign(new Error('PLAY_NOT_CONFIGURED'), { status: 503 });
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claim = base64url(JSON.stringify({
    iss: creds.client_email,
    scope: 'https://www.googleapis.com/auth/androidpublisher',
    aud: 'https://oauth2.googleapis.com/token',
    iat: now, exp: now + 3600,
  }));
  const signer = createSign('RSA-SHA256');
  signer.update(`${header}.${claim}`);
  const signature = signer.sign(creds.private_key).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${header}.${claim}.${signature}`,
    }),
    signal: AbortSignal.timeout(15000),
  });
  if (!r.ok) throw Object.assign(new Error(`PLAY_OAUTH_${r.status}`), { status: 502 });
  const data = await r.json();
  _playTokenCache = { token: data.access_token,
    exp: Date.now() + (Number(data.expires_in) || 3600) * 1000 };
  return _playTokenCache.token;
}

// Mock verifier — TEST ONLY (PLAY_TEST_MODE=1, used by test.sh; production
// must never set it). Simulates Google's answers keyed by the purchase
// token string, in the same shape as the real API responses:
//   "valid-pack-*"  -> a paid one-time product purchase
//   "valid-sub-*"   -> a paid, active subscription (expiry 30 days out)
//   "voided-token"  -> a paid purchase that the voided list later reports
//   "pending-*"    -> a purchase NOT in a paid state
//   anything else   -> unknown to Google (verification error)
function mockPlayVerify(productId, purchaseToken) {
  const t = String(purchaseToken || '');
  if (t.startsWith('valid-pack-') || t === 'voided-token')
    return { purchaseState: 0, acknowledgementState: 1, orderId: `mock-${t}` };
  if (t.startsWith('valid-sub-'))
    return { paymentState: 1, autoRenewing: true, orderId: `mock-${t}`,
             expiryTimeMillis: Date.now() + 30 * 24 * 3600 * 1000,
             startTimeMillis: Date.now() };
  if (t.startsWith('pending-'))
    return { purchaseState: 1, orderId: `mock-${t}` };
  return null;
}
function normalizePlayResult(d) {
  // Subscription responses carry paymentState (0 pending, 1 received,
  // 2 free trial, 3 deferred) + expiryTimeMillis; product responses carry
  // purchaseState (0 purchased, 1 canceled). Both map to a single shape.
  if (d.paymentState !== undefined || d.expiryTimeMillis !== undefined) {
    return { kind: 'subscription',
      paid: d.paymentState === 1 || d.paymentState === 2,
      expiry: d.expiryTimeMillis ? new Date(Number(d.expiryTimeMillis)) : null,
      autoRenewing: !!d.autoRenewing };
  }
  return { kind: 'product', paid: d.purchaseState === 0, expiry: null,
    autoRenewing: false };
}

// Verify a purchase with the Google Play Developer API
// (androidpublisher v3). kind chooses the products vs subscriptions
// endpoint. Returns normalizePlayResult's shape.
async function verifyPlayPurchase({ productId, purchaseToken, kind }) {
  if (CONFIG.playTestMode) {
    const m = mockPlayVerify(productId, purchaseToken);
    if (!m) throw Object.assign(new Error('PLAY_TOKEN_UNKNOWN'), { status: 502 });
    return normalizePlayResult(m);
  }
  if (!playBillingConfigured())
    throw Object.assign(new Error('PLAY_NOT_CONFIGURED'), { status: 503 });
  const token = await playAccessToken();
  const base = 'https://androidpublisher.googleapis.com/androidpublisher/v3/applications/' +
    encodeURIComponent(CONFIG.playPackageName);
  const url = kind === 'subscription'
    ? `${base}/purchases/subscriptions/${encodeURIComponent(productId)}/tokens/${encodeURIComponent(purchaseToken)}`
    : `${base}/purchases/products/${encodeURIComponent(productId)}/tokens/${encodeURIComponent(purchaseToken)}`;
  const r = await fetch(url, { headers: { Authorization: `Bearer ${token}` },
    signal: AbortSignal.timeout(15000) });
  if (r.status === 404 || r.status === 410)
    throw Object.assign(new Error('PLAY_TOKEN_UNKNOWN'), { status: 502 });
  if (!r.ok) throw Object.assign(new Error(`PLAY_API_${r.status}`), { status: 502 });
  return normalizePlayResult(await r.json());
}

// Which purchase tokens has Google voided (refunded / revoked / charged
// back)? Pages through purchases/voidedpurchases. Mock mode reports the
// one token the mock treats as voided.
async function listVoidedPlayTokens() {
  if (CONFIG.playTestMode) return ['voided-token'];
  if (!playBillingConfigured())
    throw Object.assign(new Error('PLAY_NOT_CONFIGURED'), { status: 503 });
  const token = await playAccessToken();
  const out = [];
  let pageToken = '';
  do {
    const u = new URL('https://androidpublisher.googleapis.com/androidpublisher/v3/applications/' +
      encodeURIComponent(CONFIG.playPackageName) + '/purchases/voidedpurchases');
    u.searchParams.set('maxResults', '1000');
    if (pageToken) u.searchParams.set('token', pageToken);
    const r = await fetch(u, { headers: { Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(15000) });
    if (!r.ok) throw Object.assign(new Error(`PLAY_API_${r.status}`), { status: 502 });
    const data = await r.json();
    for (const v of data.voidedPurchases || [])
      if (v.purchaseToken) out.push(String(v.purchaseToken));
    pageToken = data.tokenPagination?.nextPageToken || '';
  } while (pageToken);
  return out;
}

// ---------- Shared refund clawback (Play + gateway) ----------------------
// Marks the payment refunded and takes back the credits it granted, from
// the bucket they went to (pack -> free, plan -> plan), floored at 0. Any
// unrecovered remainder (the user already spent those credits) is added
// to users.credit_deficit so the shortfall stays visible — in /api/me and
// the Admin Panel — instead of silently vanishing. A refunded plan
// payment also expires the subscription it paid for. Idempotent: an
// already-refunded payment is a no-op.
function clawbackPayment(payment, reason) {
  if (!payment || payment.status === 'refunded')
    return { clawed: 0, deficit: 0, already: true };
  return tx(() => {
    db.prepare(`UPDATE payments SET status = 'refunded', note = ? WHERE id = ?`)
      .run(`Clawback: ${String(reason || 'refunded by provider').slice(0, 200)}`, payment.id);
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(payment.user_id);
    let clawed = 0, deficit = 0;
    const granted = Number(payment.credits_granted || 0);
    if (user && granted > 0) {
      const b = creditBuckets(user);
      if (payment.pack_id) {
        clawed = Math.min(b.free, granted);
        deficit = granted - clawed;
        setBuckets(user.id, b.free - clawed, b.plan);
      } else {
        clawed = Math.min(b.plan, granted);
        deficit = granted - clawed;
        setBuckets(user.id, b.free, b.plan - clawed);
      }
      if (deficit > 0)
        db.prepare('UPDATE users SET credit_deficit = credit_deficit + ? WHERE id = ?')
          .run(deficit, user.id);
    }
    if (payment.plan_id) {
      db.prepare(`UPDATE subscriptions SET status = 'expired', updated_at = datetime('now')
                  WHERE payment_id = ? AND status IN ('active', 'grace', 'canceled')`)
        .run(payment.id);
    }
    return { clawed, deficit, already: false };
  });
}

// Claw back every succeeded google_play payment whose token the provider
// reports as voided. Driven by the RTDN webhook and by the admin sync
// endpoint below (which is also how test.sh exercises it — no real
// Google calls in tests).
function syncVoidedPurchases(tokens) {
  const results = [];
  for (const t of tokens || []) {
    const p = db.prepare(`SELECT * FROM payments WHERE provider = 'google_play' AND provider_txn_id = ?`)
      .get(String(t));
    if (!p) { results.push({ token: String(t), found: false }); continue; }
    const r = clawbackPayment(p, 'voided/refunded at Google Play');
    results.push({ token: String(t), found: true, payment_id: p.id, ...r });
  }
  return results;
}

// ---------- Play Billing endpoints ---------------------------------------
function findPlayProduct(kind, productId) {
  if (kind === 'pack') {
    const pack = db.prepare('SELECT * FROM credit_packs WHERE play_product_id = ? AND is_active = 1')
      .get(productId);
    return pack ? { pack } : null;
  }
  if (kind === 'subscription') {
    for (const row of db.prepare('SELECT * FROM plans WHERE is_active = 1').all()) {
      if (row.play_product_monthly === productId) return { plan: row, period: 'monthly' };
      if (row.play_product_yearly === productId) return { plan: row, period: 'yearly' };
    }
  }
  return null;
}
function playVerifyResult(req, payment, duplicate) {
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.id);
  return { ok: true, status: payment.status, payment_id: payment.id,
    ...(duplicate ? { duplicate: true } : {}),
    credits: user ? creditBuckets(user) : null };
}

app.post('/api/billing/play/verify', auth, async (req, res) => {
  if (!playBillingConfigured())
    return res.status(503).json({ error: 'billing_not_configured',
      message: 'Google Play Billing is not configured on this server yet. No credits were granted.' });
  const b = req.body || {};
  const kind = b.kind === 'subscription' ? 'subscription' : b.kind === 'pack' ? 'pack' : null;
  const productId = String(b.product_id || '').trim();
  const purchaseToken = String(b.purchase_token || '').trim();
  if (!kind || !productId || !purchaseToken)
    return res.status(400).json({ error: 'kind ("pack" | "subscription"), product_id and purchase_token are required.' });
  const found = findPlayProduct(kind, productId);
  if (!found) return res.status(400).json({ error: 'Unknown product_id for this app.' });

  // Idempotency + token binding: a purchase token belongs to the FIRST
  // user who verified it. That user's replay returns the recorded outcome
  // (no second grant); anyone else's attempt is refused.
  const existing = db.prepare(`SELECT * FROM payments WHERE provider = 'google_play' AND provider_txn_id = ?`)
    .get(purchaseToken);
  if (existing) {
    if (existing.user_id !== req.user.id)
      return res.status(409).json({ error: 'This purchase is already linked to another account.' });
    return res.json(playVerifyResult(req, existing, true));
  }

  let v;
  try { v = await verifyPlayPurchase({ productId, purchaseToken, kind }); }
  catch (e) {
    if (e.message === 'PLAY_NOT_CONFIGURED')
      return res.status(503).json({ error: 'billing_not_configured' });
    return res.status(502).json({ error: 'Google Play could not verify this purchase right now. No credits were granted.' });
  }

  const amount = found.pack ? found.pack.price_pkr
    : (found.period === 'yearly' ? found.plan.price_yearly : found.plan.price_monthly);
  const planId = found.plan ? found.plan.id : null;
  const packId = found.pack ? found.pack.id : null;

  if (!v.paid) {
    // Record the attempt (never a grant) so it shows in Billing history.
    try {
      db.prepare(`INSERT INTO payments (user_id, plan_id, pack_id, amount, currency, provider,
                    provider_txn_id, status, period, credits_granted, note)
                  VALUES (?, ?, ?, ?, 'PKR', 'google_play', ?, 'failed', ?, 0,
                    'Play verification: purchase not in a paid state')`)
        .run(req.user.id, planId, packId, amount, purchaseToken, found.period || null);
    } catch { /* a concurrent verify recorded it first — fine */ }
    return res.status(402).json({ error: 'This purchase is not in a paid state, so no credits were granted.' });
  }

  // Verified + paid: record the payment, then grant exactly once. The
  // UNIQUE provider_txn_id is the guard: if a concurrent request recorded
  // the token first, this request becomes a replay of that record.
  let paymentId;
  try {
    paymentId = Number(db.prepare(
      `INSERT INTO payments (user_id, plan_id, pack_id, amount, currency, provider,
         provider_txn_id, status, period, credits_granted, note)
       VALUES (?, ?, ?, ?, 'PKR', 'google_play', ?, 'succeeded', ?, ?, 'Verified with Google Play')`)
      .run(req.user.id, planId, packId, amount, purchaseToken, found.period || null,
           found.pack ? found.pack.credits : found.plan.credits_monthly).lastInsertRowid);
  } catch (e) {
    if (String(e.message).includes('UNIQUE')) {
      const row = db.prepare(`SELECT * FROM payments WHERE provider = 'google_play' AND provider_txn_id = ?`)
        .get(purchaseToken);
      if (row && row.user_id !== req.user.id)
        return res.status(409).json({ error: 'This purchase is already linked to another account.' });
      if (row) return res.json(playVerifyResult(req, row, true));
    }
    throw e;
  }

  if (found.pack) {
    tx(() => {
      const user = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.id);
      const bk = creditBuckets(user);
      setBuckets(req.user.id, bk.free + found.pack.credits, bk.plan);
    });
  } else {
    activateSubscription(req.user.id, found.plan,
      { period: found.period, paymentId, ...(v.expiry ? { periodEnd: v.expiry } : {}) });
  }
  const row = db.prepare('SELECT * FROM payments WHERE id = ?').get(paymentId);
  res.json(playVerifyResult(req, row, false));
});

// Real-Time Developer Notifications, delivered by Google Cloud Pub/Sub as
// a push envelope: { message: { data: <base64 JSON>, messageId }, ... }.
// When PLAY_RTDN_SECRET is set, the Pub/Sub push URL must carry it as
// ?secret=<value> (or the x-rtdn-secret header) — anything else is
// refused. Envelopes are ACKed (200) even for notification kinds we don't
// act on, so Pub/Sub doesn't retry them forever.
app.post('/api/billing/play/rtdn', (req, res) => {
  if (CONFIG.playRtdnSecret) {
    const given = String(req.query.secret || req.headers['x-rtdn-secret'] || '');
    const a = Buffer.from(given), c = Buffer.from(CONFIG.playRtdnSecret);
    if (a.length !== c.length || !timingSafeEqual(a, c))
      return res.status(401).json({ error: 'Invalid RTDN secret.' });
  }
  let note = null;
  try {
    const data = req.body?.message?.data;
    note = data ? JSON.parse(Buffer.from(String(data), 'base64').toString('utf8')) : req.body;
  } catch { return res.status(400).json({ error: 'Malformed RTDN envelope.' }); }
  const voided = note?.voidedPurchaseNotification;
  if (voided?.purchaseToken) {
    const p = db.prepare(`SELECT * FROM payments WHERE provider = 'google_play' AND provider_txn_id = ?`)
      .get(String(voided.purchaseToken));
    if (p) clawbackPayment(p, 'Google Play voided purchase (RTDN)');
  }
  // Other notification kinds (subscription renewed/canceled/…) need no
  // action here: entitlement expiry is enforced lazily by
  // refreshSubscriptionState, and renewals arrive as new verified
  // purchases through the verify endpoint.
  res.json({ ok: true });
});

// Admin-triggered reconcile: pull Google's voided-purchases list and claw
// back anything refunded. Also the hook test.sh drives (mocked list).
app.post('/api/admin/billing/sync-voided', auth, requireAdmin, async (req, res) => {
  try {
    const tokens = await listVoidedPlayTokens();
    res.json({ ok: true, checked: tokens.length, results: syncVoidedPurchases(tokens) });
  } catch (e) {
    if (e.message === 'PLAY_NOT_CONFIGURED')
      return res.status(503).json({ error: 'billing_not_configured' });
    return res.status(502).json({ error: 'Could not fetch voided purchases from Google Play.' });
  }
});

// ---------- Payment gateway: provider abstraction + PayFast adapter ------
// A gateway provider implements:
//   createCheckout({ basketId, amount, email, mobile, description,
//                    successUrl, failureUrl, callbackUrl })
//     -> { url, method, params }  (the browser is sent here to pay)
//   verifyWebhook(body) -> { verified, basketId, txnId, amount,
//                            status: 'success'|'failed'|'reversal'|'pending' }
// Adding another aggregator later = one more adapter in GATEWAY_PROVIDERS.
function payfastSignature(merchantId, merchantName, amount, basketId) {
  // PayFast (APPS) hosted-checkout signature, per the merchant
  // integration guide: MD5 hex of "MERCHANT_ID:MERCHANT_NAME:TXNAMT:BASKET_ID".
  return createHash('md5')
    .update(`${merchantId}:${merchantName}:${amount}:${basketId}`).digest('hex');
}
function gatewayConfigured() {
  return CONFIG.gatewayProvider === 'payfast' &&
    !!CONFIG.payfast.merchantId && !!CONFIG.payfast.securedKey;
}
const payfastAdapter = {
  // Hosted checkout: mint an access token (GetAccessToken), then hand the
  // browser the PostTransaction URL + form fields — PayFast hosts the
  // payment page itself (Easypaisa / JazzCash / cards / bank channels).
  async createCheckout({ basketId, amount, email, mobile, description,
                         successUrl, failureUrl, callbackUrl }) {
    const pf = CONFIG.payfast;
    let accessToken = 'mock-access-token';
    if (!CONFIG.gatewayTestMode) {
      const r = await fetch(`${pf.baseUrl}/Ecommerce/api/Transaction/GetAccessToken`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          MERCHANT_ID: pf.merchantId, SECURED_KEY: pf.securedKey,
          BASKET_ID: basketId, TXNAMT: String(amount),
        }),
        signal: AbortSignal.timeout(15000),
      });
      if (!r.ok) throw Object.assign(new Error(`PAYFAST_TOKEN_${r.status}`), { status: 502 });
      const data = await r.json().catch(() => null);
      accessToken = data?.ACCESS_TOKEN || data?.access_token || '';
      if (!accessToken) throw Object.assign(new Error('PAYFAST_TOKEN_MISSING'), { status: 502 });
    }
    return {
      url: `${pf.baseUrl}/Ecommerce/api/Transaction/PostTransaction`,
      method: 'POST',
      params: {
        MERCHANT_ID: pf.merchantId,
        MERCHANT_NAME: pf.merchantName,
        TOKEN: accessToken,
        PROCCODE: '00',
        TXNAMT: String(amount),
        CUSTOMER_MOBILE_NO: mobile || '',
        CUSTOMER_EMAIL_ADDRESS: email || '',
        SIGNATURE: payfastSignature(pf.merchantId, pf.merchantName, amount, basketId),
        VERSION: 'AJKAI-1.0',
        TXNDESC: description,
        SUCCESS_URL: successUrl,
        FAILURE_URL: failureUrl,
        BASKET_ID: basketId,
        ORDER_DATE: new Date().toISOString().slice(0, 19).replace('T', ' '),
        CHECKOUT_URL: callbackUrl,
      },
    };
  },
  // IPN verification. An IPN is trusted ONLY when its SIGNATURE matches
  // the documented MD5 construction recomputed with OUR configured
  // merchant id/name over the IPN's own amount + basket id — and the
  // caller additionally checks basket + amount against the pending
  // payment record we created at checkout.
  verifyWebhook(body) {
    const pf = CONFIG.payfast;
    const g = (...names) => {
      for (const n of names) {
        const val = body?.[n];
        if (val !== undefined && val !== null && String(val) !== '') return String(val);
      }
      return '';
    };
    const basketId = g('BASKET_ID', 'basket_id', 'ORDER_NO', 'order_no');
    const txnId = g('TRANSACTION_ID', 'transaction_id', 'TXN_ID');
    const amount = g('TXNAMT', 'TXN_AMOUNT', 'amount', 'AMOUNT');
    const rawStatus = g('RESPONSE_CODE', 'err_code', 'ERR_CODE', 'STATUS', 'status', 'code').toLowerCase();
    const signature = g('SIGNATURE', 'signature').toLowerCase();
    const expected = payfastSignature(pf.merchantId, pf.merchantName, amount, basketId);
    let verified = false;
    if (signature && basketId && amount) {
      const a = Buffer.from(signature), c = Buffer.from(expected);
      verified = a.length === c.length && timingSafeEqual(a, c);
    }
    let status = 'pending';
    if (['refunded', 'refund', 'reversed', 'reversal', 'chargeback', 'voided', 'void'].includes(rawStatus))
      status = 'reversal';
    else if (['00', '0', 'success', 'succeeded', 'completed', 'approved'].includes(rawStatus))
      status = 'success';
    else if (['failed', 'failure', 'cancelled', 'cancel', 'declined', 'error'].includes(rawStatus))
      status = 'failed';
    return { verified, basketId, txnId, status, amount: Number(amount) || 0 };
  },
};
const GATEWAY_PROVIDERS = { payfast: payfastAdapter };
function activeGateway() { return GATEWAY_PROVIDERS[CONFIG.gatewayProvider] || null; }

// Start a gateway checkout for a credit pack. Creates the payments row
// (status pending, provider_txn_id = our basket/order id) FIRST, so the
// webhook can be matched and made idempotent; grants nothing here.
app.post('/api/billing/gateway/checkout', auth, async (req, res) => {
  const gw = activeGateway();
  if (!gw || !gatewayConfigured())
    return res.status(503).json({ error: 'gateway_not_configured',
      message: 'The payment gateway is not configured on this server yet. No payment was started.' });
  const pack = db.prepare('SELECT * FROM credit_packs WHERE id = ?')
    .get(Number(req.body?.pack_id || 0));
  if (!pack || !pack.is_active)
    return res.status(404).json({ error: 'That credit pack is not available.' });
  const basketId = `AJK-${Date.now().toString(36)}-${randomUUID().slice(0, 8)}`.toUpperCase();
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.id);
  const paymentId = Number(db.prepare(
    `INSERT INTO payments (user_id, plan_id, pack_id, amount, currency, provider,
       provider_txn_id, status, period, credits_granted, note)
     VALUES (?, NULL, ?, ?, 'PKR', ?, ?, 'pending', NULL, 0,
       'Gateway checkout created — awaiting provider confirmation')`)
    .run(req.user.id, pack.id, pack.price_pkr, CONFIG.gatewayProvider, basketId).lastInsertRowid);
  const base = CONFIG.publicBaseUrl || `${req.protocol}://${req.get('host')}`;
  try {
    const checkout = await gw.createCheckout({
      basketId, amount: pack.price_pkr,
      email: user?.email || '', mobile: String(req.body?.mobile || ''),
      description: `AJK AI — ${pack.credits} credits pack`,
      successUrl: `${base}/?gateway=success`,
      failureUrl: `${base}/?gateway=failed`,
      callbackUrl: `${base}/api/billing/gateway/webhook`,
    });
    res.status(201).json({ ok: true, payment_id: paymentId, basket_id: basketId,
      provider: CONFIG.gatewayProvider, checkout_url: checkout.url,
      method: checkout.method, params: checkout.params });
  } catch (e) {
    db.prepare(`UPDATE payments SET status = 'failed', note = 'Gateway checkout failed to start' WHERE id = ?`)
      .run(paymentId);
    return res.status(502).json({ error: 'The payment gateway could not start this checkout. No payment was taken.' });
  }
});

// Gateway IPN/webhook. Grants ONLY on a signature-verified success for a
// basket we created, with a matching amount — exactly once (a replayed
// success on an already-succeeded payment is a no-op). Verified reversals
// run the shared clawback.
app.post('/api/billing/gateway/webhook', (req, res) => {
  const gw = activeGateway();
  if (!gw || !gatewayConfigured())
    return res.status(503).json({ error: 'gateway_not_configured' });
  const body = { ...(req.query || {}), ...(req.body || {}) };
  const v = gw.verifyWebhook(body);
  if (!v.verified || !v.basketId)
    return res.status(400).json({ error: 'Webhook signature verification failed.' });
  const payment = db.prepare(`SELECT * FROM payments WHERE provider = ? AND provider_txn_id = ?`)
    .get(CONFIG.gatewayProvider, v.basketId);
  if (!payment) return res.status(404).json({ error: 'Unknown basket/order id.' });
  if (Number(payment.amount) !== Number(v.amount))
    return res.status(400).json({ error: 'Webhook amount does not match the order.' });

  if (v.status === 'success') {
    if (payment.status === 'succeeded') return res.json({ ok: true, duplicate: true, granted: 0 });
    if (payment.status === 'refunded') return res.json({ ok: true, granted: 0, note: 'already refunded' });
    const pack = payment.pack_id
      ? db.prepare('SELECT * FROM credit_packs WHERE id = ?').get(payment.pack_id) : null;
    const grant = pack ? pack.credits : 0;
    tx(() => {
      db.prepare(`UPDATE payments SET status = 'succeeded', credits_granted = ?, note = ? WHERE id = ?`)
        .run(grant, `Gateway payment verified (txn ${v.txnId || 'n/a'})`, payment.id);
      if (grant > 0) {
        const user = db.prepare('SELECT * FROM users WHERE id = ?').get(payment.user_id);
        const bk = creditBuckets(user);
        setBuckets(payment.user_id, bk.free + grant, bk.plan);
      }
    });
    return res.json({ ok: true, granted: grant });
  }
  if (v.status === 'reversal') {
    if (payment.status === 'succeeded') {
      const r = clawbackPayment(payment, 'gateway reversal/refund');
      return res.json({ ok: true, clawed_back: r.clawed, deficit: r.deficit });
    }
    return res.json({ ok: true, note: 'nothing to claw back' });
  }
  if (v.status === 'failed') {
    if (payment.status === 'pending')
      db.prepare(`UPDATE payments SET status = 'failed', note = 'Gateway reported the payment failed' WHERE id = ?`)
        .run(payment.id);
    return res.json({ ok: true, granted: 0 });
  }
  return res.json({ ok: true, note: 'pending — nothing granted' });
});

// ---------- Admin API (all routes require the is_admin flag) ----------
app.get('/api/admin/users', auth, requireAdmin, (req, res) => {
  const users = db.prepare('SELECT id, email, credits, free_credits, plan_credits, credit_deficit, is_admin, created_at FROM users ORDER BY id').all();
  const subs = db.prepare('SELECT * FROM subscriptions WHERE id IN (SELECT MAX(id) FROM subscriptions GROUP BY user_id)').all();
  const byUser = new Map(subs.map(s => [s.user_id, s]));
  res.json({ users: users.map(u => ({ ...u, subscription: subscriptionView(byUser.get(u.id) || null) })) });
});

app.get('/api/admin/plans', auth, requireAdmin, (req, res) => {
  res.json({ plans: db.prepare('SELECT * FROM plans ORDER BY sort_order').all() });
});

// Edit what a plan costs and grants. Takes effect immediately: prices apply
// to new payments, credits_monthly to the next activation/renewal grant,
// resolution/model to the next generation.
app.put('/api/admin/plans/:id', auth, requireAdmin, (req, res) => {
  const plan = getPlan(req.params.id);
  if (!plan) return res.status(404).json({ error: 'Plan not found.' });
  const b = req.body || {};
  const intField = (name) => {
    if (b[name] === undefined) return plan[name];
    const v = Number(b[name]);
    if (!Number.isInteger(v) || v < 0) throw Object.assign(new Error(`BAD_${name}`), { status: 400 });
    return v;
  };
  try {
    const updated = {
      price_monthly: intField('price_monthly'),
      price_yearly: intField('price_yearly'),
      credits_monthly: intField('credits_monthly'),
      quality_label: b.quality_label !== undefined ? String(b.quality_label).slice(0, 40) : plan.quality_label,
      quality: b.quality !== undefined ? String(b.quality).slice(0, 20) : plan.quality,
      resolution: b.resolution !== undefined ? String(b.resolution).toUpperCase() : plan.resolution,
      model: b.model !== undefined ? String(b.model).slice(0, 120) : plan.model,
      is_active: b.is_active !== undefined ? (b.is_active ? 1 : 0) : plan.is_active,
      // Google Play subscription product ids (must match Play Console).
      play_product_monthly: b.play_product_monthly !== undefined
        ? (String(b.play_product_monthly).trim().slice(0, 120) || null) : plan.play_product_monthly,
      play_product_yearly: b.play_product_yearly !== undefined
        ? (String(b.play_product_yearly).trim().slice(0, 120) || null) : plan.play_product_yearly,
    };
    if (!RESOLUTIONS.includes(updated.resolution))
      return res.status(400).json({ error: `resolution must be one of: ${RESOLUTIONS.join(', ')}` });
    db.prepare(`UPDATE plans SET price_monthly = ?, price_yearly = ?, credits_monthly = ?,
                quality_label = ?, quality = ?, resolution = ?, model = ?, is_active = ?,
                play_product_monthly = ?, play_product_yearly = ?,
                updated_at = datetime('now') WHERE id = ?`)
      .run(updated.price_monthly, updated.price_yearly, updated.credits_monthly,
           updated.quality_label, updated.quality, updated.resolution, updated.model,
           updated.is_active, updated.play_product_monthly, updated.play_product_yearly, plan.id);
    res.json({ plan: getPlan(plan.id) });
  } catch (e) {
    if (e.status === 400) return res.status(400).json({ error: 'Prices and credits must be non-negative whole numbers.' });
    throw e;
  }
});

function adminTargetUser(req, res) {
  const u = db.prepare('SELECT * FROM users WHERE id = ?').get(req.params.id);
  if (!u) { res.status(404).json({ error: 'User not found.' }); return null; }
  return u;
}
function validPeriod(b) { return b.period === 'yearly' ? 'yearly' : b.period === 'monthly' ? 'monthly' : null; }

// TEST/MANUAL payment path — admin only. Records a succeeded payment with
// provider "manual_test" and activates the subscription from it. This is a
// stand-in for testing alongside the automatic Play Billing pipeline
// (Phase 3, /api/billing/play/*); it is NOT a checkout and end users
// cannot call it.
app.post('/api/admin/users/:id/manual-payment', auth, requireAdmin, (req, res) => {
  const u = adminTargetUser(req, res); if (!u) return;
  const b = req.body || {};
  const plan = getPlan(String(b.plan_id || ''));
  if (!plan || !plan.is_active) return res.status(400).json({ error: 'Unknown or inactive plan.' });
  const period = validPeriod(b);
  if (!period) return res.status(400).json({ error: 'period must be "monthly" or "yearly".' });
  const amount = period === 'yearly' ? plan.price_yearly : plan.price_monthly;
  const txn = b.provider_txn_id ? String(b.provider_txn_id).slice(0, 120)
    : `manual_${Date.now()}_${Math.random().toString(36).slice(2, 10)}`;
  try {
    const paymentId = Number(db.prepare(
      `INSERT INTO payments (user_id, plan_id, amount, currency, provider, provider_txn_id, status, period, note)
       VALUES (?, ?, ?, ?, 'manual_test', ?, 'succeeded', ?, 'Manual test activation by admin (Phase 1 — no real charge)')`)
      .run(u.id, plan.id, amount, plan.currency, txn, period).lastInsertRowid);
    const subId = activateSubscription(u.id, plan, { period, paymentId });
    const me = db.prepare('SELECT credits, free_credits, plan_credits FROM users WHERE id = ?').get(u.id);
    res.json({ ok: true, payment_id: paymentId, subscription_id: subId, user_credits: me });
  } catch (e) {
    if (String(e.message).includes('UNIQUE'))
      return res.status(409).json({ error: 'That provider_txn_id was already used.' });
    throw e;
  }
});

// Admin comp activation (no payment record) — e.g. for testers/reviewers.
app.post('/api/admin/users/:id/activate', auth, requireAdmin, (req, res) => {
  const u = adminTargetUser(req, res); if (!u) return;
  const b = req.body || {};
  const plan = getPlan(String(b.plan_id || ''));
  if (!plan || !plan.is_active) return res.status(400).json({ error: 'Unknown or inactive plan.' });
  const period = validPeriod(b);
  if (!period) return res.status(400).json({ error: 'period must be "monthly" or "yearly".' });
  const subId = activateSubscription(u.id, plan, { period, paymentId: null });
  const me = db.prepare('SELECT credits, free_credits, plan_credits FROM users WHERE id = ?').get(u.id);
  res.json({ ok: true, subscription_id: subId, user_credits: me });
});

// Monthly renewal grant (Phase 1: triggered manually; Phase 3 will call the
// same code from the Play Billing renewal notifications).
app.post('/api/admin/users/:id/grant-renewal', auth, requireAdmin, (req, res) => {
  const u = adminTargetUser(req, res); if (!u) return;
  refreshSubscriptionState(u.id);
  try {
    const subId = grantMonthlyCredits(u.id);
    const me = db.prepare('SELECT credits, free_credits, plan_credits FROM users WHERE id = ?').get(u.id);
    res.json({ ok: true, subscription_id: subId, user_credits: me });
  } catch (e) {
    if (e.message === 'NO_ACTIVE_SUBSCRIPTION')
      return res.status(400).json({ error: 'User has no active subscription to renew.' });
    throw e;
  }
});

app.post('/api/admin/users/:id/cancel-subscription', auth, requireAdmin, (req, res) => {
  const u = adminTargetUser(req, res); if (!u) return;
  const sub = latestSubscription(u.id);
  if (!sub || !['active', 'grace'].includes(sub.status))
    return res.status(400).json({ error: 'User has no active subscription to cancel.' });
  db.prepare(`UPDATE subscriptions SET status = 'canceled', updated_at = datetime('now') WHERE id = ?`).run(sub.id);
  res.json({ ok: true, subscription: subscriptionView(latestSubscription(u.id)) });
});

app.get('/api/admin/payments', auth, requireAdmin, (req, res) => {
  const rows = db.prepare(
    `SELECT p.*, u.email AS user_email FROM payments p JOIN users u ON u.id = p.user_id
     ORDER BY p.id DESC LIMIT 200`).all();
  res.json({ payments: rows });
});

// Revenue summary: succeeded payments only (money actually received).
app.get('/api/admin/revenue', auth, requireAdmin, (req, res) => {
  const total = db.prepare(
    `SELECT COALESCE(SUM(amount), 0) AS total, COUNT(*) AS count FROM payments WHERE status = 'succeeded'`).get();
  const byPlan = db.prepare(
    `SELECT p.plan_id, pl.name AS plan_name, COUNT(*) AS count, COALESCE(SUM(p.amount), 0) AS total
     FROM payments p LEFT JOIN plans pl ON pl.id = p.plan_id
     WHERE p.status = 'succeeded' GROUP BY p.plan_id ORDER BY total DESC`).all();
  const byStatus = db.prepare(
    `SELECT status, COUNT(*) AS count, COALESCE(SUM(amount), 0) AS total
     FROM payments GROUP BY status ORDER BY status`).all();
  const monthly = db.prepare(
    `SELECT substr(created_at, 1, 7) AS month, COUNT(*) AS count, COALESCE(SUM(amount), 0) AS total
     FROM payments WHERE status = 'succeeded' GROUP BY month ORDER BY month DESC LIMIT 12`).all();
  res.json({ currency: 'PKR', total_succeeded: total.total, total_succeeded_count: total.count,
             by_plan: byPlan, by_status: byStatus, monthly });
});

// ---------- Admin: credit packs & pack purchases ----------
app.get('/api/admin/packs', auth, requireAdmin, (req, res) => {
  res.json({ packs: db.prepare('SELECT * FROM credit_packs ORDER BY sort_order, id').all() });
});

app.put('/api/admin/packs/:id', auth, requireAdmin, (req, res) => {
  const pack = db.prepare('SELECT * FROM credit_packs WHERE id = ?').get(req.params.id);
  if (!pack) return res.status(404).json({ error: 'Pack not found.' });
  const b = req.body || {};
  const intField = (name) => {
    if (b[name] === undefined) return pack[name];
    const v = Number(b[name]);
    if (!Number.isInteger(v) || v < 0) throw Object.assign(new Error(`BAD_${name}`), { status: 400 });
    return v;
  };
  try {
    const credits = intField('credits');
    const price = intField('price_pkr');
    const active = b.is_active !== undefined ? (b.is_active ? 1 : 0) : pack.is_active;
    const playId = b.play_product_id !== undefined
      ? (String(b.play_product_id).trim().slice(0, 120) || null) : pack.play_product_id;
    db.prepare(`UPDATE credit_packs SET credits = ?, price_pkr = ?, is_active = ?, play_product_id = ?,
                updated_at = datetime('now') WHERE id = ?`).run(credits, price, active, playId, pack.id);
    res.json({ pack: db.prepare('SELECT * FROM credit_packs WHERE id = ?').get(pack.id) });
  } catch (e) {
    if (e.status === 400) return res.status(400).json({ error: 'Credits and price must be non-negative whole numbers.' });
    throw e;
  }
});

app.get('/api/admin/pack-purchases', auth, requireAdmin, (req, res) => {
  const status = String(req.query.status || '');
  const base = `SELECT pp.*, u.email AS user_email FROM pack_purchases pp
                JOIN users u ON u.id = pp.user_id`;
  const rows = ['pending', 'approved', 'rejected'].includes(status)
    ? db.prepare(`${base} WHERE pp.status = ? ORDER BY pp.id DESC LIMIT 200`).all(status)
    : db.prepare(`${base} ORDER BY pp.id DESC LIMIT 200`).all();
  res.json({ purchases: rows });
});

// Approve a pack purchase: grants the pack's credits (snapshot taken at
// purchase time) into the buyer's FREE bucket — exactly once. The status
// flip and the grant happen in one transaction, and approving an
// already-decided purchase is a 409 conflict, never a second grant.
app.post('/api/admin/pack-purchases/:id/approve', auth, requireAdmin, (req, res) => {
  const outcome = tx(() => {
    const p = db.prepare('SELECT * FROM pack_purchases WHERE id = ?').get(req.params.id);
    if (!p) return { code: 404 };
    if (p.status !== 'pending') return { code: 409, purchase: p };
    db.prepare(`UPDATE pack_purchases SET status = 'approved', decided_at = datetime('now'),
                decided_by = ? WHERE id = ?`).run(req.adminUser.id, p.id);
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(p.user_id);
    const b = creditBuckets(user);
    setBuckets(user.id, b.free + p.credits, b.plan);
    return { code: 200, purchase: db.prepare('SELECT * FROM pack_purchases WHERE id = ?').get(p.id) };
  });
  if (outcome.code === 404) return res.status(404).json({ error: 'Purchase not found.' });
  if (outcome.code === 409) return res.status(409).json({ error: 'That purchase was already decided.', purchase: outcome.purchase });
  const me = db.prepare('SELECT credits, free_credits, plan_credits FROM users WHERE id = ?').get(outcome.purchase.user_id);
  res.json({ ok: true, purchase: outcome.purchase, user_credits: me });
});

app.post('/api/admin/pack-purchases/:id/reject', auth, requireAdmin, (req, res) => {
  const note = req.body?.note !== undefined ? String(req.body.note).slice(0, 500) : null;
  const outcome = tx(() => {
    const p = db.prepare('SELECT * FROM pack_purchases WHERE id = ?').get(req.params.id);
    if (!p) return { code: 404 };
    if (p.status !== 'pending') return { code: 409, purchase: p };
    db.prepare(`UPDATE pack_purchases SET status = 'rejected', admin_note = ?, decided_at = datetime('now'),
                decided_by = ? WHERE id = ?`).run(note, req.adminUser.id, p.id);
    return { code: 200, purchase: db.prepare('SELECT * FROM pack_purchases WHERE id = ?').get(p.id) };
  });
  if (outcome.code === 404) return res.status(404).json({ error: 'Purchase not found.' });
  if (outcome.code === 409) return res.status(409).json({ error: 'That purchase was already decided.', purchase: outcome.purchase });
  res.json({ ok: true, purchase: outcome.purchase });
});

// ---------- Admin panel page ----------
app.get('/admin', (req, res) => res.sendFile(path.join(__dirname, 'public', 'admin.html')));

// ---------- Serve the AJK AI web app itself (same-origin) ----------
// The app and the API now live on ONE address, so there is no separate
// frontend URL to configure: open this server's address and everything works.
// The app's API-base-URL setting still exists for split deployments.
// Joined videos live on local disk (see CONFIG.joinedDir) and are served
// here — mounted before the SPA fallback so the files win over index.html.
fs.mkdirSync(CONFIG.joinedDir, { recursive: true });
fs.mkdirSync(CONFIG.generatedDir, { recursive: true });
app.use('/files/joined', express.static(CONFIG.joinedDir));
app.use('/files/generated', express.static(CONFIG.generatedDir));
app.use(express.static(path.join(__dirname, 'public')));
app.get(/^\/(?!api\/).*/, (req, res) =>
  res.sendFile(path.join(__dirname, 'public', 'index.html')));

app.use((err, req, res, next) => { // last-resort error handler
  console.error(err);
  res.status(500).json({ error: 'Something went wrong on the server.' });
});

app.listen(process.env.PORT || 8080,
  () => console.log(`My Video AI backend running on port ${process.env.PORT || 8080} (model: ${CONFIG.model})`));
