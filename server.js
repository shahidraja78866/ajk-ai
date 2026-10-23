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
// Generation rate card (owner pricing v9, 2026-10-23): credits are charged
// by the ROUTED quality of the job and its duration — there is no separate
// "4K costs double" rule anymore; each quality has its own row. Charged on
// submit, automatically refunded if the provider fails the job.
const COST_BY_QUALITY = {
  '768P': { 5: 10, 10: 20 },
  '2K':   { 5: 15, 10: 30 },
  '4K':   { 5: 40, 10: 80 },
};
function generationCost(resolution, duration) {
  const table = COST_BY_QUALITY[resolution] || COST_BY_QUALITY['768P'];
  return table[Number(duration)] ?? COST_BY_QUALITY['768P'][Number(duration)] ?? 1;
}

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
  // The full per-quality rate card (see COST_BY_QUALITY above).
  // costByDuration stays as the 768P row for backward compatibility.
  costByQuality: COST_BY_QUALITY,
  costByDuration: COST_BY_QUALITY['768P'],
  signupCredits: Number(process.env.SIGNUP_CREDITS || 100),
  maxDailyCredits: Number(process.env.MAX_DAILY_CREDITS || 400),
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
  // --- fal.ai base URLs -----------------------------------------------------
  // Split so tests can point BOTH at one local stub (test-fal-stub.js) and
  // the suite never makes a real provider call. Production defaults are
  // fal's real hosts: the queue API for async jobs and the sync API host
  // for text-to-speech.
  falQueueBase: (process.env.FAL_QUEUE_BASE_URL || 'https://queue.fal.run').replace(/\/+$/, ''),
  falApiBase: (process.env.FAL_API_BASE_URL || 'https://fal.run').replace(/\/+$/, ''),
  falPollMs: Number(process.env.FAL_POLL_INTERVAL_MS || 3000),
  // --- Voice system (Phase B: TTS + lip-sync + voiceover) -------------------
  // Synthesized audio files live here and are served from /files/voice/.
  voiceDir: process.env.VOICE_DIR || path.join(__dirname, 'data', 'voice'),
  // Which TTS providers are enabled. Empty list = every provider whose
  // credentials exist. Set TTS_PROVIDERS=none (or a comma list like
  // "gemini,azure") to restrict — with NO provider enabled the voice
  // endpoints fail closed with 503 and charge nothing.
  ttsProviders: (process.env.TTS_PROVIDERS || '').split(',')
    .map(s => s.trim().toLowerCase()).filter(Boolean),
  // Preferred provider when a request doesn't choose one. Default order:
  // gemini (fal) -> elevenlabs (fal) -> azure.
  ttsDefaultProvider: (process.env.TTS_DEFAULT_PROVIDER || '').trim().toLowerCase(),
  // Azure Speech (the only provider with dedicated Pakistani Urdu voices,
  // ur-PK-UzmaNeural / ur-PK-AsadNeural). Activates ONLY when BOTH the key
  // and region are set — the key is the OWNER's own Azure key.
  azureSpeechKey: (process.env.AZURE_SPEECH_KEY || '').trim(),
  azureSpeechRegion: (process.env.AZURE_SPEECH_REGION || '').trim(),
  azureSpeechBase: (process.env.AZURE_SPEECH_BASE_URL || '').trim().replace(/\/+$/, ''),
  // Lip-sync endpoints on fal (verified against fal's API docs 2026-10-23):
  // image route takes image_url + audio_url; video route (LatentSync)
  // takes video_url + audio_url. Both env-overridable.
  lipsyncImageModel: (process.env.FAL_LIPSYNC_IMAGE_MODEL || 'minimax/h3-max/lip-sync/image-to-video').trim(),
  lipsyncVideoModel: (process.env.FAL_LIPSYNC_VIDEO_MODEL || 'fal-ai/latentsync').trim(),
  // Locked owner rates for the voice add-ons (credits).
  lipsyncCost: 30,
  voiceoverCost: 10,
  // Voice previews are free but rate-limited: per user per day, plus a
  // global daily guard so previews can't run up provider cost.
  voicePreviewDailyCap: Number(process.env.VOICE_PREVIEW_DAILY_CAP || 5),
  voicePreviewGlobalDailyCap: Number(process.env.VOICE_PREVIEW_GLOBAL_DAILY_CAP || 500),
  // --- Sound system (Phase B2: auto sync sound, SFX, music) ----------------
  // Standalone generated audio files live here, served from /files/sounds/.
  soundsDir: process.env.SOUNDS_DIR || path.join(__dirname, 'data', 'sounds'),
  // Sound engines on fal (schemas verified against fal's API docs
  // 2026-10-23 — see the sound-system section below). All env-overridable.
  soundSyncModel: (process.env.SOUND_SYNC_MODEL || 'fal-ai/mmaudio-v2').trim(),
  soundSyncPremiumModel: (process.env.SOUND_SYNC_PREMIUM_MODEL || 'mirelo-ai/sfx2.0/video-to-audio').trim(),
  soundSfxModel: (process.env.SOUND_SFX_MODEL || 'fal-ai/elevenlabs/sound-effects/v2').trim(),
  soundMusicModel: (process.env.SOUND_MUSIC_MODEL || 'cassetteai/music-generator').trim(),
  // Locked owner rates for the sound add-ons (credits).
  soundCosts: { sync: 10, premium_sync: 25, sfx: 5, music: 5 },
  // Master switch: SOUND_ENABLED=0 turns the whole sound system off (the
  // endpoints then fail closed with 503 and charge nothing). The engines
  // all ride the FAL_KEY, so no key also means not configured.
  soundEnabled: process.env.SOUND_ENABLED !== '0',
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

// Subscription plan catalogue (owner pricing v9, 2026-10-23). Prices/credits
// are seeded into the `plans` table on first boot and are afterwards editable
// in the admin panel — boot only re-syncs the structural fields (name,
// quality, resolution, model, feature flags) and never overwrites prices or
// credit amounts an admin has changed. The Weekly plan is weekly-ONLY: its
// price/credits live in price_weekly/credits_weekly and it has no monthly or
// yearly cycle (the monthly/yearly columns stay 0 and the API reports them
// as null). Feature flags (can_veo / can_lipsync) are entitlements only in
// this wave — the Veo and lip-sync generation engines are Phase B.
const PLAN_DEFAULTS = [
  { id: 'weekly',   name: 'Weekly',    price_monthly: 0,    price_yearly: 0,
    credits_monthly: 0, price_weekly: 1800, credits_weekly: 80,
    quality: '768P', quality_label: '768P',      resolution: '768P', model: CONFIG.model,   sort_order: 0,
    can_veo: 0, can_lipsync: 0,
    play_product_monthly: null, play_product_yearly: null, play_product_weekly: 'ajk_weekly' },
  { id: 'normal',   name: 'Normal',    price_monthly: 5600, price_yearly: 56000,
    credits_monthly: 400, price_weekly: null, credits_weekly: null,
    quality: '768P', quality_label: '768P',      resolution: '768P', model: CONFIG.model,   sort_order: 1,
    can_veo: 0, can_lipsync: 0,
    play_product_monthly: 'ajk_normal_monthly',   play_product_yearly: 'ajk_normal_yearly',   play_product_weekly: null },
  { id: 'pro',      name: 'Pro',       price_monthly: 9500, price_yearly: 95000,
    credits_monthly: 500, price_weekly: null, credits_weekly: null,
    quality: '2K',   quality_label: '2K',        resolution: '2K',   model: CONFIG.model,   sort_order: 2,
    can_veo: 1, can_lipsync: 1,
    play_product_monthly: 'ajk_pro_monthly',      play_product_yearly: 'ajk_pro_yearly',      play_product_weekly: null },
  { id: 'extrapro', name: 'Extra Pro', price_monthly: 14000, price_yearly: 140000,
    credits_monthly: 600, price_weekly: null, credits_weekly: null,
    quality: '4K',   quality_label: 'Native 4K', resolution: '4K',   model: CONFIG.model4k, sort_order: 3,
    can_veo: 1, can_lipsync: 1,
    play_product_monthly: 'ajk_extrapro_monthly', play_product_yearly: 'ajk_extrapro_yearly', play_product_weekly: null },
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
  // v9 — owner FINAL pricing (2026-10-23, supersedes all earlier prices)
  // plus the Weekly plan and the per-quality rate-card groundwork:
  //   weekly   Rs 1,800/week,  80 credits/week,  768P (new plan)
  //   normal   Rs 5,600/mo,   400 credits/mo,    768P
  //   pro      Rs 9,500/mo,   500 credits/mo,    2K   + Veo/lip-sync flags
  //   extrapro Rs 14,000/mo,  600 credits/mo,    native 4K + all flags
  // Plans gain price_weekly/credits_weekly (NULL on monthly plans),
  // play_product_weekly and the entitlement flags can_veo/can_lipsync
  // (flags only in this wave — the engines are Phase B). One-time and
  // version-gated like v5/v8, so later admin edits are respected. The
  // weekly INSERT uses INSERT OR IGNORE: on a fresh DB the row is seeded
  // by PLAN_DEFAULTS instead and this is a no-op.
  { version: 9, up: `
    ALTER TABLE plans ADD COLUMN price_weekly INTEGER;
    ALTER TABLE plans ADD COLUMN credits_weekly INTEGER;
    ALTER TABLE plans ADD COLUMN play_product_weekly TEXT;
    ALTER TABLE plans ADD COLUMN can_veo INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE plans ADD COLUMN can_lipsync INTEGER NOT NULL DEFAULT 0;
    UPDATE plans SET price_monthly = 5600, price_yearly = 56000,
      credits_monthly = 400 WHERE id = 'normal';
    UPDATE plans SET price_monthly = 9500, price_yearly = 95000,
      credits_monthly = 500, can_veo = 1, can_lipsync = 1 WHERE id = 'pro';
    UPDATE plans SET price_monthly = 14000, price_yearly = 140000,
      credits_monthly = 600, can_veo = 1, can_lipsync = 1 WHERE id = 'extrapro';
    INSERT OR IGNORE INTO plans (id, name, price_monthly, price_yearly, currency,
        credits_monthly, quality, quality_label, resolution, model, is_active,
        sort_order, price_weekly, credits_weekly, play_product_weekly)
      VALUES ('weekly', 'Weekly', 0, 0, 'PKR', 0, '768P', '768P', '768P',
        '${CONFIG.model}', 1, 0, 1800, 80, 'ajk_weekly');` },
  // v10 — voice system (Phase B): generations gain a `kind` discriminator
  // ('video' for normal generations, 'lipsync' for talking-character jobs,
  // 'voiceover' for re-voiced videos), the path of the synthesized voice
  // track a job used, and the source generation it derived from. voice_jobs
  // records every voice operation (including free previews, which are NOT
  // generations) for quota accounting and debugging.
  { version: 10, up: `
    ALTER TABLE generations ADD COLUMN kind TEXT NOT NULL DEFAULT 'video';
    ALTER TABLE generations ADD COLUMN voice_audio_path TEXT;
    ALTER TABLE generations ADD COLUMN source_generation_id INTEGER;
    CREATE TABLE IF NOT EXISTS voice_jobs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id),
      kind TEXT NOT NULL,
      provider TEXT,
      voice TEXT,
      language TEXT,
      script_mode TEXT,
      style TEXT,
      speed TEXT,
      script_text TEXT,
      char_count INTEGER NOT NULL DEFAULT 0,
      audio_path TEXT,
      generation_id INTEGER REFERENCES generations(id),
      status TEXT NOT NULL DEFAULT 'completed',
      error TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );` },
  // v11 — sound system (Phase B2): generations gain the sound add-on
  // bookkeeping. sound_mode is the engine the user picked ('sync' |
  // 'premium_sync' | 'sfx' | 'music'; NULL when no sound was requested);
  // sound_status tracks the honest outcome: 'none' (no sound) |
  // 'pending' (video not finished yet — the sound step runs when it
  // completes) | 'processing' (a standalone sound job is running) |
  // 'applied' | 'failed_refunded' (the sound step failed, the video was
  // still delivered and the add-on was refunded). sound_prompt is the
  // English text actually sent to the sound engine, sound_volume the
  // 10–100 level, and sound_cost the add-on credits charged for the step
  // (kept separate from cost_credits so a failed sound step can refund
  // exactly the add-on and nothing more).
  { version: 11, up: `
    ALTER TABLE generations ADD COLUMN sound_mode TEXT;
    ALTER TABLE generations ADD COLUMN sound_status TEXT NOT NULL DEFAULT 'none';
    ALTER TABLE generations ADD COLUMN sound_prompt TEXT;
    ALTER TABLE generations ADD COLUMN sound_volume INTEGER;
    ALTER TABLE generations ADD COLUMN sound_cost INTEGER NOT NULL DEFAULT 0;` },
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
                play_product_monthly, play_product_yearly,
                price_weekly, credits_weekly, play_product_weekly, can_veo, can_lipsync)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(p.id, p.name, p.price_monthly, p.price_yearly, p.credits_monthly,
           p.quality, p.quality_label, p.resolution, p.model, p.sort_order,
           p.play_product_monthly, p.play_product_yearly,
           p.price_weekly, p.credits_weekly, p.play_product_weekly,
           p.can_veo, p.can_lipsync);
  } else {
    // Play product ids are backfilled only when unset (COALESCE) — an
    // admin's edits in the Admin Panel always win over these defaults.
    // Feature flags are structural (they define the tier) and re-sync
    // like quality/model; prices and credit amounts never re-sync.
    db.prepare(`UPDATE plans SET name = ?, quality = ?, quality_label = ?,
                resolution = ?, model = ?, sort_order = ?,
                can_veo = ?, can_lipsync = ?,
                play_product_monthly = COALESCE(play_product_monthly, ?),
                play_product_yearly = COALESCE(play_product_yearly, ?),
                play_product_weekly = COALESCE(play_product_weekly, ?) WHERE id = ?`)
      .run(p.name, p.quality, p.quality_label, p.resolution, p.model, p.sort_order,
           p.can_veo, p.can_lipsync,
           p.play_product_monthly, p.play_product_yearly, p.play_product_weekly, p.id);
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
function addDays(d, n) { const x = new Date(d); x.setUTCDate(x.getUTCDate() + n); return x; }
function isFuture(ts) { return !!ts && new Date(ts.replace(' ', 'T') + 'Z') > new Date(); }
// A plan is "weekly-only" when it carries a weekly price (only the Weekly
// plan does). Weekly-only plans have no monthly/yearly cycle and monthly
// plans have no weekly cycle — the two never mix.
function isWeeklyPlan(plan) {
  return !!plan && plan.price_weekly !== null && plan.price_weekly !== undefined;
}
// The credits a plan grants for one billing period of the given kind.
function planGrantFor(plan, period) {
  if (!plan) return 0;
  return period === 'weekly' ? (plan.credits_weekly ?? 0) : plan.credits_monthly;
}
// The price a plan charges for one billing period of the given kind.
function planPriceFor(plan, period) {
  if (!plan) return 0;
  if (period === 'weekly') return plan.price_weekly ?? 0;
  return period === 'yearly' ? plan.price_yearly : plan.price_monthly;
}

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
  return plan ? planGrantFor(plan, sub.period) : 0;
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
// the period end to the provider's expiry instead of a calendar period.
// Periods: monthly (+1 month), yearly (+12 months), weekly (+7 days,
// the Weekly plan's credits_weekly granted once per weekly period).
function activateSubscription(userId, plan, { period = 'monthly', paymentId = null, periodEnd = null } = {}) {
  return tx(() => {
    db.prepare(`UPDATE subscriptions SET status = 'expired', updated_at = datetime('now')
                WHERE user_id = ? AND status IN ('active', 'grace', 'canceled')`).run(userId);
    const now = new Date();
    const end = periodEnd ? new Date(periodEnd)
      : period === 'yearly' ? addMonths(now, 12)
      : period === 'weekly' ? addDays(now, 7)
      : addMonths(now, 1);
    const info = db.prepare(
      `INSERT INTO subscriptions (user_id, plan_id, status, period, started_at,
         current_period_start, current_period_end, last_grant_at, payment_id)
       VALUES (?, ?, 'active', ?, ?, ?, ?, ?, ?)`)
      .run(userId, plan.id, period, sqlTs(now), sqlTs(now), sqlTs(end), sqlTs(now), paymentId);
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    const b = creditBuckets(user);
    setBuckets(userId, b.free, planGrantFor(plan, period)); // reset — no rollover
    return Number(info.lastInsertRowid);
  });
}
// Renewal grant: plan credits reset to the plan's grant for the
// subscription's own period (monthly amount, or the weekly amount for a
// weekly subscription).
function grantMonthlyCredits(userId) {
  return tx(() => {
    const sub = latestSubscription(userId);
    if (!sub || !['active', 'grace'].includes(sub.status) || !subscriptionIsCurrent(sub))
      throw Object.assign(new Error('NO_ACTIVE_SUBSCRIPTION'), { status: 400 });
    const plan = getPlan(sub.plan_id);
    if (!plan) throw Object.assign(new Error('PLAN_NOT_FOUND'), { status: 400 });
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    const b = creditBuckets(user);
    setBuckets(userId, b.free, planGrantFor(plan, sub.period));
    db.prepare(`UPDATE subscriptions SET last_grant_at = ?, updated_at = datetime('now') WHERE id = ?`)
      .run(sqlTs(new Date()), sub.id);
    return sub.id;
  });
}
function publicPlan(p) {
  const weekly = isWeeklyPlan(p);
  return { id: p.id, name: p.name,
    // The Weekly plan is weekly-only: its monthly/yearly fields report
    // null (it cannot be bought monthly or yearly), and monthly plans
    // report null weekly fields.
    price_monthly: weekly ? null : p.price_monthly,
    price_yearly: weekly ? null : p.price_yearly,
    price_weekly: weekly ? p.price_weekly : null,
    currency: p.currency,
    credits_monthly: weekly ? null : p.credits_monthly,
    credits_weekly: weekly ? p.credits_weekly : null,
    quality: p.quality,
    quality_label: p.quality_label, resolution: p.resolution,
    // Entitlement descriptor. can_lipsync gates POST /api/voice/lipsync
    // (the talking-character engine, Phase B). can_veo is still an
    // entitlement flag only — the Veo talking-clip engine is not wired
    // yet and the UI must not present it as available. max_quality is
    // the plan's routed quality ceiling.
    features: { can_veo: !!p.can_veo, can_lipsync: !!p.can_lipsync,
      max_quality: p.quality },
    // Google Play subscription product ids (set in Play Console; editable
    // in the Admin Panel). Used by the app's Digital Goods purchase flow.
    // Play supports weekly base plans, so the Weekly plan maps to its own
    // weekly product id.
    play_product_id: { monthly: p.play_product_monthly || null,
      yearly: p.play_product_yearly || null,
      weekly: p.play_product_weekly || null } };
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
// Voice endpoints call paid TTS providers — limited per signed-in user on
// top of the preview-specific daily caps enforced in the handlers.
const voiceLimiter = rateLimit({ windowMs: 60 * 60 * 1000, max: 30,
  keyGenerator: (req) => String(req.user?.id || req.ip),
  message: { error: 'Rate limit: max 30 voice requests per hour.' } });
// Sound endpoints call paid audio providers — limited per signed-in user.
const soundLimiter = rateLimit({ windowMs: 60 * 60 * 1000, max: 30,
  keyGenerator: (req) => String(req.user?.id || req.ip),
  message: { error: 'Rate limit: max 30 sound requests per hour.' } });

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
  cost_by_quality: CONFIG.costByQuality,
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
  // Voice system (Phase B): which TTS providers are configured (booleans
  // only, never keys), the voice catalog for the CONFIGURED providers,
  // and the locked credit costs of the voice add-ons. When no provider is
  // configured the app shows a notice instead of dead buttons.
  voice: {
    providers: {
      gemini: voiceProviderAvailable('gemini'),
      elevenlabs: voiceProviderAvailable('elevenlabs'),
      azure: voiceProviderAvailable('azure'),
    },
    default_provider: defaultVoiceProvider(),
    languages: VOICE_LANGUAGES,
    scripts: ['native', 'roman'],
    styles: VOICE_STYLES,
    speeds: VOICE_SPEEDS,
    voices: publicVoiceCatalog(),
    costs: { lipsync_credits: CONFIG.lipsyncCost, voiceover_credits: CONFIG.voiceoverCost },
    preview: { max_chars: VOICE_PREVIEW_MAX_CHARS, daily_cap: CONFIG.voicePreviewDailyCap },
    lipsync_models: { image: CONFIG.lipsyncImageModel, video: CONFIG.lipsyncVideoModel },
  },
  // Sound system (Phase B2): whether the sound engines are configured
  // (booleans only, never keys), the locked credit costs of each sound
  // mode, and which modes each flow offers. When not configured the app
  // shows a notice instead of dead buttons and the endpoints answer 503.
  sound: {
    configured: soundConfigured(),
    costs: { sync: CONFIG.soundCosts.sync, premium_sync: CONFIG.soundCosts.premium_sync,
             sfx: CONFIG.soundCosts.sfx, music: CONFIG.soundCosts.music },
    modes: ['sync', 'premium_sync', 'sfx', 'music'],
    generate_modes: ['sync', 'sfx', 'music'],
    apply_modes: ['sync', 'premium_sync', 'sfx', 'music'],
    audio_only_kinds: ['sfx', 'music'],
    default_volume: SOUND_DEFAULT_VOLUME,
    models: { sync: CONFIG.soundSyncModel, premium_sync: CONFIG.soundSyncPremiumModel,
              sfx: CONFIG.soundSfxModel, music: CONFIG.soundMusicModel },
  },
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
  // Optional sound add-on (Phase B2): { mode: 'sync' | 'sfx' | 'music',
  // prompt?, volume? }. The sound step runs AFTER the video itself
  // succeeds (see ensureSoundApplied): sync replaces the video's audio
  // with an AI soundtrack generated from the finished video; sfx/music
  // are mixed UNDER the video's original audio at the chosen volume.
  // Validation, the configured check and prompt moderation all happen
  // here, and translation below — always BEFORE any credit is charged.
  let soundSpec = null;
  if (req.body?.sound !== undefined && req.body?.sound !== null) {
    const s = (typeof req.body.sound === 'object') ? req.body.sound : {};
    const smode = String(s.mode || '').toLowerCase();
    if (!SOUND_GENERATE_MODES.includes(smode))
      return res.status(400).json({ error: `sound.mode must be one of: ${SOUND_GENERATE_MODES.join(', ')}` });
    if (!soundConfigured())
      return res.status(503).json({ error: 'sound_not_configured', message: SOUND_NOT_CONFIGURED_MSG });
    let svol = SOUND_DEFAULT_VOLUME[smode];
    if (s.volume !== undefined && s.volume !== null && s.volume !== '') {
      svol = Number(s.volume);
      if (!Number.isFinite(svol) || svol < 10 || svol > 100)
        return res.status(400).json({ error: 'sound.volume must be between 10 and 100.' });
      svol = Math.round(svol);
    }
    let sPromptRaw = null;
    if (s.prompt !== undefined && s.prompt !== null && String(s.prompt).trim()) {
      sPromptRaw = String(s.prompt).trim();
      if (sPromptRaw.length > 500)
        return res.status(400).json({ error: 'sound.prompt must be at most 500 characters.' });
      if (moderated(sPromptRaw))
        return res.status(400).json({ error: 'The sound description was blocked by content moderation. Please rephrase it.' });
    }
    soundSpec = { mode: smode, volume: svol, promptRaw: sPromptRaw, prompt: null };
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

  // The sound description goes through the SAME translation step as the
  // video prompt (the sound engines are documented with English prompts)
  // — still before any charge, so a failed translation costs nothing.
  // With no description of its own, the sound step reuses the video's
  // effective (English) prompt.
  if (soundSpec) {
    if (soundSpec.promptRaw && TRANSLATED_LANGUAGES.has(languageCode)) {
      try {
        soundSpec.prompt = await translatePrompt(soundSpec.promptRaw, languageCode);
      } catch {
        return res.status(502).json({ error: 'We could not translate your sound description into English, so nothing was charged. Please try again.' });
      }
      if (moderated(soundSpec.prompt))
        return res.status(400).json({ error: 'The sound description was blocked by content moderation. Please rephrase it.' });
    } else {
      soundSpec.prompt = soundSpec.promptRaw || effectivePrompt;
    }
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
  // request at any other ratio falls back to the H3 model at 2K and is
  // charged at the 2K rate — it is not native 4K, so it must not be
  // charged or recorded as 4K.
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
  // Credit rules are unchanged — the same per-quality rate card below
  // applies whether or not a source image is attached.
  if (sourceImagePath) model = CONFIG.modelI2V;
  // Rate card (v9): the credit cost comes from the ROUTED quality's own
  // row — 768P 10/20, 2K 15/30, native 4K 40/80 for 5s/10s.
  const cost = generationCost(resolution, Number(duration));
  // The sound add-on is charged together with the video in the same
  // atomic transaction (exactly once). If the video fails, the whole
  // amount is refunded by failAndRefund; if only the sound step fails,
  // just the add-on is refunded (see ensureSoundApplied).
  const soundCost = soundSpec ? CONFIG.soundCosts[soundSpec.mode] : 0;
  const totalCost = cost + soundCost;

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
      if (spentToday + totalCost > CONFIG.maxDailyCredits) throw Object.assign(new Error('DAILY_LIMIT'), { status: 429 });
      if (creditBuckets(user).total < totalCost) throw Object.assign(new Error('NO_CREDITS'), { status: 402 });
      spendBuckets(user, totalCost); // plan credits first, then free credits
      const info = db.prepare(
        `INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, cost_credits, idempotency_key, resolution, model, prompt_language, translated_prompt, mode, source_image_path, watermark_text, watermark_status, sound_mode, sound_status, sound_prompt, sound_volume, sound_cost)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(user.id, prompt.trim(), aspect_ratio, Number(duration), style, totalCost, idemKey, resolution, model, languageCode, translatedPrompt, mode, sourceImagePath, watermarkText, watermarkStatus,
           soundSpec ? soundSpec.mode : null, soundSpec ? 'pending' : 'none',
           soundSpec ? soundSpec.prompt : null, soundSpec ? soundSpec.volume : null, soundCost);
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
    const r = await fetch(`${CONFIG.falQueueBase}/${model}`, {
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
               cost_credits: totalCost, resolution, model, prompt_language: languageCode,
               mode, source_image_path: sourceImagePath,
               watermark_status: watermarkStatus,
               ...(soundSpec ? { sound_mode: soundSpec.mode, sound_status: 'pending',
                                 sound_cost_credits: soundCost } : {}),
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
  if (job.status === 'completed') {
    // A pending sound step (e.g. the completing poll was interrupted)
    // still runs — before the watermark, so both can apply to one video.
    if (job.sound_status === 'pending')
      await ensureSoundApplied(job, CONFIG.publicBaseUrl || `${req.protocol}://${req.get('host')}`);
    return res.json(await ensureWatermarkApplied(job));
  }
  if (job.status === 'failed' || !job.fal_request_id)
    return res.json(job);
  const jobModel = job.model || CONFIG.model; // jobs remember their routed model
  try {
    const sr = await fetch(`${CONFIG.falQueueBase}/${jobModel}/requests/${job.fal_request_id}/status`,
      { headers: { 'Authorization': `Key ${FAL_KEY}` } });
    if (sr.ok) {
      const s = await sr.json();
      if (s.status === 'COMPLETED') {
        const rr = await fetch(`${CONFIG.falQueueBase}/${jobModel}/requests/${job.fal_request_id}`,
          { headers: { 'Authorization': `Key ${FAL_KEY}` } });
        const result = await rr.json();
        const url = result?.video?.url || result?.data?.video?.url || null;
        if (url) {
          db.prepare(`UPDATE generations SET status = 'completed', video_url = ?,
                      updated_at = datetime('now') WHERE id = ?`).run(url, job.id);
          job.status = 'completed'; job.video_url = url;
          // If this job asked for sound, run the sound step BEFORE the
          // client sees the completed video: applied, or honestly marked
          // failed_refunded with the video still delivered (the add-on
          // is refunded inside ensureSoundApplied).
          if (job.sound_status === 'pending')
            await ensureSoundApplied(job, CONFIG.publicBaseUrl || `${req.protocol}://${req.get('host')}`);
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

// ==========================================================================
// Voice system (Phase B) — TTS providers, voice preview, lip-sync, voiceover
// ==========================================================================
// Providers (all server-side; keys never leave the server):
//   gemini     — Gemini 3.1 Flash TTS on fal (fal-ai/gemini-3.1-flash-tts).
//                Schema verified against fal's API docs 2026-10-23:
//                { prompt, style_instructions, voice, language_code,
//                output_format } -> { audio: { url } }. language_code uses
//                fal's documented names ("Urdu (Pakistan)", ...). There
//                is NO speed parameter — pace is steered through the
//                natural-language style_instructions, as documented.
//   elevenlabs — ElevenLabs v3 on fal (fal-ai/elevenlabs/tts/eleven-v3),
//                the premium option. Verified schema: { text, voice,
//                stability, language_code (ISO 639-1),
//                apply_text_normalization } -> { audio: { url } }. The v3
//                schema has NO speed control: speed is accepted and
//                noted, not faked (see README). Style maps to stability.
//   azure      — Azure Speech REST (direct). The ONLY provider with
//                dedicated Pakistani Urdu voices (ur-PK-UzmaNeural F /
//                ur-PK-AsadNeural M). Active ONLY when the owner's own
//                AZURE_SPEECH_KEY + AZURE_SPEECH_REGION are set.
// FAIL CLOSED: when no provider is enabled the voice endpoints answer 503
// and charge nothing.
const VOICE_LANGUAGES = [
  { code: 'ur', name: 'Urdu' },
  { code: 'hi', name: 'Hindi' },
  { code: 'en', name: 'English' },
];
const VOICE_STYLES = ['narration', 'conversation', 'news', 'energetic', 'emotional'];
const VOICE_SPEEDS = ['slow', 'normal', 'fast'];
const VOICE_PREVIEW_MAX_CHARS = 150;
const VOICE_SCRIPT_MAX_CHARS = 6000;
const TTS_CHUNK_MAX_CHARS = 3000; // per-request cap; longer scripts chunk

const VOICE_CATALOG = {
  gemini: {
    label: 'Gemini 3.1 Flash TTS (via fal.ai)',
    premium: false,
    model: 'fal-ai/gemini-3.1-flash-tts',
    // fal's documented language_code enum values for our three languages.
    languageNames: { ur: 'Urdu (Pakistan)', hi: 'Hindi (India)', en: 'English (US)' },
    // One voice set serves every language (the model is multilingual).
    voices: [
      { id: 'Kore', gender: 'female' }, { id: 'Zephyr', gender: 'female' },
      { id: 'Aoede', gender: 'female' }, { id: 'Leda', gender: 'female' },
      { id: 'Callirrhoe', gender: 'female' }, { id: 'Charon', gender: 'male' },
      { id: 'Puck', gender: 'male' }, { id: 'Fenrir', gender: 'male' },
      { id: 'Orus', gender: 'male' }, { id: 'Iapetus', gender: 'male' },
    ],
    defaultVoice: 'Kore',
  },
  elevenlabs: {
    label: 'ElevenLabs v3 (via fal.ai) — premium',
    premium: true,
    model: 'fal-ai/elevenlabs/tts/eleven-v3',
    languageNames: { ur: 'ur', hi: 'hi', en: 'en' }, // ISO 639-1 per schema
    voices: [
      { id: 'Rachel', gender: 'female' }, { id: 'Sarah', gender: 'female' },
      { id: 'Charlotte', gender: 'female' }, { id: 'Alice', gender: 'female' },
      { id: 'George', gender: 'male' }, { id: 'Brian', gender: 'male' },
      { id: 'Liam', gender: 'male' }, { id: 'Eric', gender: 'male' },
    ],
    defaultVoice: 'Rachel',
  },
  azure: {
    label: 'Azure Speech (dedicated Pakistani Urdu voices)',
    premium: false,
    // Voices are per-language on Azure (named neural voices per locale).
    locales: { ur: 'ur-PK', hi: 'hi-IN', en: 'en-US' },
    voicesByLanguage: {
      ur: [ { id: 'ur-PK-UzmaNeural', gender: 'female' },
            { id: 'ur-PK-AsadNeural', gender: 'male' } ],
      hi: [ { id: 'hi-IN-SwaraNeural', gender: 'female' },
            { id: 'hi-IN-MadhurNeural', gender: 'male' } ],
      en: [ { id: 'en-US-JennyNeural', gender: 'female' },
            { id: 'en-US-GuyNeural', gender: 'male' } ],
    },
  },
};

function voiceProviderAvailable(id) {
  if (!VOICE_CATALOG[id]) return false;
  if (CONFIG.ttsProviders.length && !CONFIG.ttsProviders.includes(id)) return false;
  if (id === 'azure') return !!CONFIG.azureSpeechKey && !!CONFIG.azureSpeechRegion;
  return !!FAL_KEY; // the fal-routed providers ride the server's fal key
}
function defaultVoiceProvider() {
  if (CONFIG.ttsDefaultProvider && voiceProviderAvailable(CONFIG.ttsDefaultProvider))
    return CONFIG.ttsDefaultProvider;
  for (const id of ['gemini', 'elevenlabs', 'azure'])
    if (voiceProviderAvailable(id)) return id;
  return null;
}
// The provider's voices for one spoken language (azure is per-language;
// the fal providers share one multilingual set).
function providerVoicesFor(providerId, language) {
  const cat = VOICE_CATALOG[providerId];
  if (!cat) return [];
  if (cat.voicesByLanguage) return cat.voicesByLanguage[language] || [];
  return cat.voices || [];
}
function defaultVoiceFor(providerId, language) {
  const cat = VOICE_CATALOG[providerId];
  if (cat.voicesByLanguage) return (cat.voicesByLanguage[language] || [])[0] || null;
  return (cat.voices || []).find(v => v.id === cat.defaultVoice) || (cat.voices || [])[0] || null;
}
function publicVoiceCatalog() {
  const out = [];
  for (const [providerId, cat] of Object.entries(VOICE_CATALOG)) {
    if (!voiceProviderAvailable(providerId)) continue;
    const voices = [];
    for (const lang of VOICE_LANGUAGES.map(l => l.code)) {
      for (const v of providerVoicesFor(providerId, lang)) {
        const existing = voices.find(x => x.id === v.id);
        if (existing) { if (!existing.languages.includes(lang)) existing.languages.push(lang); }
        else voices.push({ id: v.id, label: v.id.replace(/^(ur-PK|hi-IN|en-US)-/, '').replace(/Neural$/, ''),
                           gender: v.gender, languages: [lang] });
      }
    }
    out.push({ provider: providerId, label: cat.label, premium: !!cat.premium, voices });
  }
  return out;
}

// ---------- Roman -> native script transliteration -----------------------
// No commercial TTS provider documents Roman Urdu / Roman Hindi input, so
// Roman scripts are transliterated to the native script on the server
// BEFORE synthesis — the spoken language never changes with the script
// choice. This is a conservative, deterministic best-effort converter:
// a dictionary of common words first, then a character mapping fallback.
// It is NOT a linguistic transliterator — native script is always the
// recommended input (see README).
const ROMAN_URDU_WORDS = {
  mera: 'میرا', meri: 'میری', mere: 'میرے', naam: 'نام', hai: 'ہے', hain: 'ہیں',
  mein: 'میں', main: 'میں', aur: 'اور', ka: 'کا', ki: 'کی', ke: 'کے', ko: 'کو',
  se: 'سے', ne: 'نے', par: 'پر', bhi: 'بھی', nahin: 'نہیں', nahi: 'نہیں',
  aap: 'آپ', tum: 'تم', yeh: 'یہ', ye: 'یہ', woh: 'وہ', wo: 'وہ', kya: 'کیا',
  kyun: 'کیوں', kyunki: 'کیونکہ', kaise: 'کیسے', kahan: 'کہاں', kab: 'کب',
  ahmed: 'احمد', ali: 'علی', salam: 'سلام', alaikum: 'علیکم', shukriya: 'شکریہ',
  khuda: 'خدا', hafiz: 'حافظ', allah: 'اللہ', pakistan: 'پاکستان', urdu: 'اردو',
  hindi: 'ہندی', acha: 'اچھا', theek: 'ٹھیک', bahut: 'بہت', dost: 'دوست',
  ghar: 'گھر', pani: 'پانی', khana: 'کھانا', aaj: 'آج', kal: 'کل', subah: 'صبح',
  raat: 'رات', din: 'دن', log: 'لوگ', admi: 'آدمی', aurat: 'عورت', bacha: 'بچہ',
  larka: 'لڑکا', larki: 'لڑکی', gaya: 'گیا', gayi: 'گئی', raha: 'رہا', rahi: 'رہی',
  hota: 'ہوتا', hoti: 'ہوتی', chahiye: 'چاہیے', apna: 'اپنا', apni: 'اپنی',
  us: 'اس', is: 'اس', ek: 'ایک', do: 'دو', teen: 'تین', koi: 'کوئی',
  sab: 'سب', boht: 'بہت', zindagi: 'زندگی', mohabbat: 'محبت', dil: 'دل',
  waqt: 'وقت', saal: 'سال', film: 'فلم', video: 'ویڈیو', kahani: 'کہانی',
};
const ROMAN_HINDI_WORDS = {
  mera: 'मेरा', meri: 'मेरी', mere: 'मेरे', naam: 'नाम', hai: 'है', hain: 'हैं',
  mein: 'में', main: 'मैं', aur: 'और', ka: 'का', ki: 'की', ke: 'के', ko: 'को',
  se: 'से', ne: 'ने', par: 'पर', bhi: 'भी', nahin: 'नहीं', nahi: 'नहीं',
  aap: 'आप', tum: 'तुम', yeh: 'यह', ye: 'यह', woh: 'वह', wo: 'वह', kya: 'क्या',
  kyun: 'क्यों', kaise: 'कैसे', kahan: 'कहाँ', kab: 'कब', ram: 'राम',
  namaste: 'नमस्ते', shukriya: 'शुक्रिया', dhanyavad: 'धन्यवाद', khuda: 'खुदा',
  pakistan: 'पाकिस्तान', bharat: 'भारत', hindi: 'हिन्दी', urdu: 'उर्दू',
  acha: 'अच्छा', theek: 'ठीक', bahut: 'बहुत', dost: 'दोस्त', ghar: 'घर',
  pani: 'पानी', khana: 'खाना', aaj: 'आज', kal: 'कल', subah: 'सुबह', raat: 'रात',
  din: 'दिन', log: 'लोग', admi: 'आदमी', aurat: 'औरत', bacha: 'बच्चा',
  ladka: 'लड़का', ladki: 'लड़की', gaya: 'गया', gayi: 'गई', raha: 'रहा',
  rahi: 'रही', hota: 'होता', hoti: 'होती', chahiye: 'चाहिए', apna: 'अपना',
  apni: 'अपनी', us: 'उस', is: 'इस', ek: 'एक', do: 'दो', teen: 'तीन',
  koi: 'कोई', sab: 'सब', zindagi: 'ज़िंदगी', mohabbat: 'मोहब्बत', dil: 'दिल',
  waqt: 'वक़्त', saal: 'साल', film: 'फ़िल्म', video: 'वीडियो', kahani: 'कहानी',
  duniya: 'दुनिया',
};
// Urdu character fallback (greedy longest match, applied per word).
const URDU_DIGRAPHS = { kh: 'کھ', gh: 'گھ', ch: 'چ', jh: 'جھ', sh: 'ش', zh: 'ژ',
  th: 'تھ', ph: 'پھ', bh: 'بھ', dh: 'دھ', aa: 'ا', ee: 'ی', oo: 'و', ai: 'ے', au: 'و' };
const URDU_SINGLES = { a: 'ا', b: 'ب', p: 'پ', t: 'ت', d: 'د', r: 'ر', z: 'ز',
  s: 'س', j: 'ج', f: 'ف', q: 'ق', k: 'ک', g: 'گ', l: 'ل', m: 'م', n: 'ن',
  w: 'و', v: 'و', o: 'و', u: 'و', i: 'ی', e: 'ے', y: 'ی', h: 'ہ', c: 'ک', x: 'کس' };
function urduWordFallback(word) {
  let out = '', i = 0;
  while (i < word.length) {
    const two = word.slice(i, i + 2);
    if (URDU_DIGRAPHS[two]) { out += URDU_DIGRAPHS[two]; i += 2; continue; }
    out += URDU_SINGLES[word[i]] || word[i];
    i += 1;
  }
  return out;
}
// Hindi (Devanagari) syllabic fallback: consonant tokens take the inherent
// vowel unless a vowel token follows (which becomes its matra); a consonant
// before another consonant takes a halant; word-initial vowels are
// independent forms.
const HINDI_CONSONANTS = { kh: 'ख', gh: 'घ', ch: 'च', jh: 'झ', th: 'थ', dh: 'ध',
  ph: 'फ', bh: 'भ', sh: 'श', k: 'क', g: 'ग', j: 'ज', t: 'त', d: 'द', n: 'न',
  p: 'प', f: 'फ', b: 'ब', m: 'म', y: 'य', r: 'र', l: 'ल', v: 'व', w: 'व',
  s: 'स', h: 'ह', z: 'ज', q: 'क', c: 'क' };
const HINDI_VOWELS = { aa: ['आ', 'ा'], ee: ['ई', 'ी'], oo: ['ऊ', 'ू'], ai: ['ऐ', 'ै'],
  au: ['औ', 'ौ'], a: ['अ', ''], i: ['इ', 'ि'], u: ['उ', 'ु'], e: ['ए', 'े'], o: ['ओ', 'ो'] };
function hindiWordFallback(word) {
  const tokens = [];
  let i = 0;
  while (i < word.length) {
    const two = word.slice(i, i + 2), one = word[i];
    if (HINDI_CONSONANTS[two]) { tokens.push({ c: HINDI_CONSONANTS[two] }); i += 2; }
    else if (HINDI_VOWELS[two]) { tokens.push({ v: HINDI_VOWELS[two] }); i += 2; }
    else if (HINDI_CONSONANTS[one]) { tokens.push({ c: HINDI_CONSONANTS[one] }); i += 1; }
    else if (HINDI_VOWELS[one]) { tokens.push({ v: HINDI_VOWELS[one] }); i += 1; }
    else { tokens.push({ raw: one }); i += 1; }
  }
  let out = '';
  for (let k = 0; k < tokens.length; k++) {
    const tok = tokens[k], next = tokens[k + 1];
    if (tok.raw) { out += tok.raw; continue; }
    if (tok.v) { out += tok.v[0]; continue; } // independent vowel form
    if (next && next.v) { out += tok.c + next.v[1]; k++; continue; } // matra
    if (next && next.c) { out += tok.c + '्'; continue; } // cluster halant
    out += tok.c; // word-final consonant keeps the inherent vowel
  }
  return out;
}
function transliterateRoman(text, language) {
  const dict = language === 'hi' ? ROMAN_HINDI_WORDS : ROMAN_URDU_WORDS;
  const fallback = language === 'hi' ? hindiWordFallback : urduWordFallback;
  return String(text).replace(/[A-Za-z]+/g, (w) => {
    const lower = w.toLowerCase();
    return dict[lower] || fallback(lower);
  });
}

// ---------- Script preparation & chunking --------------------------------
function chunkScript(text, maxChars = TTS_CHUNK_MAX_CHARS) {
  const clean = String(text).replace(/\s+/g, ' ').trim();
  if (clean.length <= maxChars) return clean ? [clean] : [];
  const sentences = clean.match(/[^.!?।۔\n]+[.!?।۔]*\s*/g) || [clean];
  const chunks = [];
  let cur = '';
  for (const s of sentences) {
    if (s.length > maxChars) {
      if (cur.trim()) { chunks.push(cur.trim()); cur = ''; }
      let rest = s.trim();
      while (rest.length > maxChars) {
        let cut = rest.lastIndexOf(' ', maxChars);
        if (cut < maxChars * 0.5) cut = maxChars;
        chunks.push(rest.slice(0, cut).trim());
        rest = rest.slice(cut).trim();
      }
      cur = rest;
    } else if ((cur + s).length > maxChars) {
      chunks.push(cur.trim()); cur = s;
    } else cur += s;
  }
  if (cur.trim()) chunks.push(cur.trim());
  return chunks.filter(Boolean);
}

// Validate + normalize a voice request body into synthesis settings.
// Throws { status, error } on bad input. `provider: null` in the result
// means NO provider is configured — callers answer 503 before charging.
function parseVoiceSettings(body, { scriptRequired = true } = {}) {
  const bad = (msg) => Object.assign(new Error(msg), { status: 400 });
  const language = String(body?.spoken_language || 'ur').toLowerCase();
  if (!VOICE_LANGUAGES.some(l => l.code === language))
    throw bad(`spoken_language must be one of: ${VOICE_LANGUAGES.map(l => l.code).join(', ')}`);
  const scriptMode = String(body?.script_mode || body?.script_type || 'native').toLowerCase();
  if (!['native', 'roman'].includes(scriptMode))
    throw bad('script_mode must be "native" or "roman"');
  const style = String(body?.style || 'conversation').toLowerCase();
  if (!VOICE_STYLES.includes(style))
    throw bad(`style must be one of: ${VOICE_STYLES.join(', ')}`);
  const speed = String(body?.speed || 'normal').toLowerCase();
  if (!VOICE_SPEEDS.includes(speed))
    throw bad(`speed must be one of: ${VOICE_SPEEDS.join(', ')}`);
  let provider = null;
  const requested = String(body?.provider || '').toLowerCase();
  if (requested) {
    if (!VOICE_CATALOG[requested])
      throw bad(`provider must be one of: ${Object.keys(VOICE_CATALOG).join(', ')}`);
    if (!voiceProviderAvailable(requested))
      throw bad(`The "${requested}" voice provider is not configured on this server.`);
    provider = requested;
  } else provider = defaultVoiceProvider();
  let voice = null;
  if (provider) {
    if (body?.voice) {
      voice = providerVoicesFor(provider, language).find(v => v.id === String(body.voice)) || null;
      if (!voice) throw bad(`voice "${body.voice}" is not available for ${provider} / ${language}.`);
    } else voice = defaultVoiceFor(provider, language);
  }
  const rawScript = body?.script === undefined || body?.script === null ? '' : String(body.script);
  if (scriptRequired && (rawScript.trim().length < 1 || rawScript.length > VOICE_SCRIPT_MAX_CHARS))
    throw bad(`script must be 1–${VOICE_SCRIPT_MAX_CHARS} characters.`);
  const text = scriptMode === 'roman' && rawScript
    ? transliterateRoman(rawScript, language) : rawScript;
  return { language, scriptMode, style, speed, provider,
           voiceId: voice ? voice.id : null, rawScript, text };
}

// ---------- Provider calls -------------------------------------------------
// Test hook: with TEST_RECORD_FAL_BODY=1 every outgoing voice-provider and
// lip-sync request body is recorded so test.sh can assert the exact shapes
// without a real provider call (same pattern as /api/_test/fal-body).
const voiceCallLog = [];
function recordVoiceCall(entry) {
  if (process.env.TEST_RECORD_FAL_BODY === '1') voiceCallLog.push(entry);
}
if (process.env.TEST_RECORD_FAL_BODY === '1') {
  app.get('/api/_test/voice-calls', (req, res) => res.json({ calls: voiceCallLog }));
}

const GEMINI_STYLE_TEXT = {
  narration: 'Read this as a calm, clear narration.',
  conversation: 'Say this in a warm, natural conversational tone.',
  news: 'Read this as a professional television news broadcast, with gravitas.',
  energetic: 'Say this energetically and cheerfully.',
  emotional: 'Say this with heartfelt emotion.',
};
const ELEVEN_STABILITY = { narration: 0.6, conversation: 0.5, news: 0.75, energetic: 0.4, emotional: 0.3 };
const AZURE_PROSODY_RATE = { slow: '0.85', normal: '1', fast: '1.15' };
function escapeXml(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&apos;');
}

// Synthesize ONE chunk (<= TTS_CHUNK_MAX_CHARS) with the chosen provider.
// Returns the audio bytes (MP3 from every provider).
async function synthesizeChunkBytes({ provider, text, language, voiceId, style, speed }) {
  if (provider === 'azure') {
    const cat = VOICE_CATALOG.azure;
    const locale = cat.locales[language];
    const ssml = `<speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="${locale}">` +
      `<voice name="${voiceId}"><prosody rate="${AZURE_PROSODY_RATE[speed] || '1'}">${escapeXml(text)}</prosody></voice></speak>`;
    recordVoiceCall({ kind: 'tts', provider, model: 'azure-speech', body: { ssml } });
    const base = CONFIG.azureSpeechBase ||
      `https://${CONFIG.azureSpeechRegion}.tts.speech.microsoft.com`;
    const r = await fetch(`${base}/cognitiveservices/v1`, {
      method: 'POST',
      headers: { 'Ocp-Apim-Subscription-Key': CONFIG.azureSpeechKey,
                 'Content-Type': 'application/ssml+xml',
                 'X-Microsoft-OutputFormat': 'audio-24khz-96kbitrate-mono-mp3' },
      body: ssml, signal: AbortSignal.timeout(60000),
    });
    if (!r.ok) throw new Error(`Azure Speech returned ${r.status}`);
    return Buffer.from(await r.arrayBuffer());
  }
  const cat = VOICE_CATALOG[provider];
  let body;
  if (provider === 'gemini') {
    // Documented schema: pace/style are natural-language instructions —
    // speed rides style_instructions (there is no numeric speed field).
    let instructions = GEMINI_STYLE_TEXT[style] || GEMINI_STYLE_TEXT.conversation;
    if (speed === 'slow') instructions += ' Speak slowly and clearly.';
    if (speed === 'fast') instructions += ' Speak at a brisk, fast pace.';
    body = { prompt: text, voice: voiceId,
             language_code: cat.languageNames[language],
             style_instructions: instructions, output_format: 'mp3' };
  } else { // elevenlabs — v3 schema: no speed field (accepted, noted); style -> stability
    body = { text, voice: voiceId, language_code: cat.languageNames[language],
             stability: ELEVEN_STABILITY[style] ?? 0.5,
             apply_text_normalization: 'auto' };
  }
  recordVoiceCall({ kind: 'tts', provider, model: cat.model, body });
  const r = await fetch(`${CONFIG.falApiBase}/${cat.model}`, {
    method: 'POST',
    headers: { 'Authorization': `Key ${FAL_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body), signal: AbortSignal.timeout(120000),
  });
  if (!r.ok) throw new Error(`TTS provider returned ${r.status}`);
  const data = await r.json();
  const url = data?.audio?.url;
  if (!url) throw new Error('TTS provider returned no audio');
  const ar = await fetch(url, { signal: AbortSignal.timeout(60000) });
  if (!ar.ok) throw new Error('Could not download the synthesized audio');
  return Buffer.from(await ar.arrayBuffer());
}

// Synthesize a full script: chunk at sentence boundaries (consistent voice
// on every chunk), synthesize in order, and concatenate the parts into one
// MP3 under data/voice/. Returns { audioPath (public), absPath, parts }.
async function synthesizeScript(settings, fullText) {
  const chunks = chunkScript(fullText, TTS_CHUNK_MAX_CHARS);
  if (!chunks.length) throw new Error('Nothing to synthesize.');
  fs.mkdirSync(CONFIG.voiceDir, { recursive: true });
  const name = `${randomUUID()}.mp3`;
  const finalAbs = path.join(CONFIG.voiceDir, name);
  if (chunks.length === 1) {
    const bytes = await synthesizeChunkBytes({ ...settings, text: chunks[0] });
    fs.writeFileSync(finalAbs, bytes);
  } else {
    const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ajk-tts-'));
    try {
      const parts = [];
      for (let i = 0; i < chunks.length; i++) {
        const bytes = await synthesizeChunkBytes({ ...settings, text: chunks[i] });
        const p = path.join(work, `part${i}.mp3`);
        fs.writeFileSync(p, bytes);
        parts.push(p);
      }
      const listFile = path.join(work, 'list.txt');
      fs.writeFileSync(listFile, parts.map(p => `file '${p}'`).join('\n'));
      try {
        await runFfmpeg(['-y', '-f', 'concat', '-safe', '0', '-i', listFile,
                         '-c:a', 'libmp3lame', '-q:a', '4', finalAbs]);
      } catch {
        await runFfmpeg(['-y', '-f', 'concat', '-safe', '0', '-i', listFile,
                         '-c', 'copy', finalAbs]);
      }
    } finally { fs.rmSync(work, { recursive: true, force: true }); }
  }
  if (!fs.existsSync(finalAbs) || fs.statSync(finalAbs).size === 0)
    throw new Error('Synthesis produced no audio');
  return { audioPath: `/files/voice/${name}`, absPath: finalAbs, parts: chunks.length };
}

// Duration of an audio file, parsed from `ffmpeg -i` (no ffprobe binary).
async function probeAudioDuration(file) {
  const info = await new Promise((resolve) => {
    execFile(ffmpegStatic, ['-i', file], { timeout: 30000 },
      (_err, _stdout, stderr) => resolve(String(stderr || '')));
  });
  const dur = info.match(/Duration:\s*(\d+):(\d+):([\d.]+)/);
  return dur ? Number(dur[1]) * 3600 + Number(dur[2]) * 60 + Number(dur[3]) : 0;
}

function recordVoiceJob({ userId, kind, settings, text, status, audioPath = null, generationId = null, error = null }) {
  const info = db.prepare(
    `INSERT INTO voice_jobs (user_id, kind, provider, voice, language, script_mode,
       style, speed, script_text, char_count, audio_path, generation_id, status, error)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    .run(userId, kind, settings?.provider || null, settings?.voiceId || null,
         settings?.language || null, settings?.scriptMode || null,
         settings?.style || null, settings?.speed || null,
         text || null, (text || '').length, audioPath, generationId, status, error);
  return Number(info.lastInsertRowid);
}

// Charge + insert a generations row atomically (same rules as /api/generate:
// daily cap, balance check, plan-bucket-first spend). Throws {status,error}.
function chargeVoiceGeneration(userId, { cost, prompt, aspectRatio, duration, style, model, kind, sourceGenerationId = null, sourceImagePath = null, promptLanguage = null, translatedPrompt = null }) {
  return tx(() => {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    if (!user) throw Object.assign(new Error('Account not found.'), { status: 404 });
    const spentToday = db.prepare(
      `SELECT COALESCE(SUM(cost_credits),0) AS s FROM generations
       WHERE user_id = ? AND date(created_at) = date('now') AND status != 'failed'`).get(userId).s;
    if (spentToday + cost > CONFIG.maxDailyCredits)
      throw Object.assign(new Error('Daily spending limit reached. Try again tomorrow.'), { status: 429 });
    if (creditBuckets(user).total < cost)
      throw Object.assign(new Error('Not enough credits.'), { status: 402 });
    spendBuckets(user, cost);
    const info = db.prepare(
      `INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status,
         cost_credits, resolution, model, prompt_language, translated_prompt,
         mode, source_image_path, kind, source_generation_id)
       VALUES (?, ?, ?, ?, ?, 'in_progress', ?, '768P', ?, ?, ?, 'realistic', ?, ?, ?)`)
      .run(userId, prompt, aspectRatio, duration, style, cost, model,
           promptLanguage, translatedPrompt, sourceImagePath, kind, sourceGenerationId);
    return Number(info.lastInsertRowid);
  });
}

// Submit a job to a fal queue endpoint and poll until it completes —
// the same queue contract the video poller uses, driven synchronously
// (like clip joining) so failures can refund inside the same request.
async function runFalQueueJob(model, body, timeoutMs = 600000) {
  recordVoiceCall({ kind: 'queue', model, body });
  lastFalBody = body; // shared test hook, as with /api/generate
  const submit = await fetch(`${CONFIG.falQueueBase}/${model}`, {
    method: 'POST',
    headers: { 'Authorization': `Key ${FAL_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body), signal: AbortSignal.timeout(30000),
  });
  if (!submit.ok) throw new Error(`fal.ai returned ${submit.status}`);
  const sd = await submit.json();
  const requestId = sd?.request_id;
  if (!requestId) throw new Error('fal.ai did not return a request id');
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    await new Promise(r => setTimeout(r, CONFIG.falPollMs));
    const sr = await fetch(`${CONFIG.falQueueBase}/${model}/requests/${requestId}/status`,
      { headers: { 'Authorization': `Key ${FAL_KEY}` }, signal: AbortSignal.timeout(15000) });
    if (!sr.ok) continue;
    const s = await sr.json();
    if (s.status === 'COMPLETED') {
      const rr = await fetch(`${CONFIG.falQueueBase}/${model}/requests/${requestId}`,
        { headers: { 'Authorization': `Key ${FAL_KEY}` }, signal: AbortSignal.timeout(30000) });
      if (!rr.ok) throw new Error(`fal.ai result returned ${rr.status}`);
      return await rr.json();
    }
    if (s.status === 'FAILED' || s.status === 'ERROR')
      throw new Error('fal.ai reported the job as failed');
  }
  throw new Error('fal.ai job timed out');
}

const VOICE_NOT_CONFIGURED_MSG =
  'Voice features are not configured on this server yet — no voice provider is available, so nothing was charged.';

// ---------- Voice preview (free, capped, never a generation) --------------
app.post('/api/voice/preview', auth, voiceLimiter, async (req, res) => {
  let settings;
  try { settings = parseVoiceSettings(req.body || {}); }
  catch (e) { return res.status(e.status || 400).json({ error: e.message }); }
  if (!settings.provider)
    return res.status(503).json({ error: 'voice_not_configured', message: VOICE_NOT_CONFIGURED_MSG });
  if (moderated(settings.rawScript))
    return res.status(400).json({ error: 'This script was blocked by content moderation. Please rephrase it.' });
  const mine = db.prepare(
    `SELECT COUNT(*) AS c FROM voice_jobs WHERE user_id = ? AND kind = 'preview'
     AND date(created_at) = date('now')`).get(req.user.id).c;
  if (Number(mine) >= CONFIG.voicePreviewDailyCap)
    return res.status(429).json({ error: `Voice preview limit reached (${CONFIG.voicePreviewDailyCap} per day). Previews reset tomorrow.` });
  const globalCount = db.prepare(
    `SELECT COUNT(*) AS c FROM voice_jobs WHERE kind = 'preview'
     AND date(created_at) = date('now')`).get().c;
  if (Number(globalCount) >= CONFIG.voicePreviewGlobalDailyCap)
    return res.status(429).json({ error: 'Voice previews are busy right now — please try again later.' });
  const text = settings.text.slice(0, VOICE_PREVIEW_MAX_CHARS);
  try {
    const out = await synthesizeScript(settings, text);
    recordVoiceJob({ userId: req.user.id, kind: 'preview', settings, text,
                     status: 'completed', audioPath: out.audioPath });
    const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
    res.json({ audio_url: out.audioPath, provider: settings.provider,
               voice: settings.voiceId, language: settings.language,
               script_mode: settings.scriptMode, synthesized_text: text,
               chars: text.length, credits_left: me.credits });
  } catch (e) {
    recordVoiceJob({ userId: req.user.id, kind: 'preview', settings, text,
                     status: 'failed', error: e.message });
    res.status(502).json({ error: `Voice preview failed (${e.message}). No credits were charged.` });
  }
});

// ---------- Talking character / lip-sync (Pro+ plans, +30 credits) ---------
app.post('/api/voice/lipsync', auth, voiceLimiter, async (req, res) => {
  const b = req.body || {};
  // Entitlement first: the existing plan flag gates the feature.
  refreshSubscriptionState(req.user.id);
  const sub = currentSubscription(req.user.id);
  const plan = sub ? getPlan(sub.plan_id) : null;
  if (!plan || !plan.can_lipsync)
    return res.status(403).json({ error: 'Talking / Lip-Sync videos need the Pro or Extra Pro plan. Upgrade your plan to create a talking character.' });
  // Exactly one visual source: an owned uploaded image OR a completed
  // generation's video.
  const hasImage = b.image_path !== undefined && b.image_path !== null && b.image_path !== '';
  const hasGen = b.generation_id !== undefined && b.generation_id !== null && b.generation_id !== '';
  if (hasImage === hasGen)
    return res.status(400).json({ error: 'Provide exactly one of image_path (an uploaded image) or generation_id (a finished video).' });
  let owned = null, sourceGen = null;
  if (hasImage) {
    owned = resolveOwnedUpload(req.user.id, b.image_path);
    if (!owned)
      return res.status(400).json({ error: 'image_path must be an image you uploaded (POST /api/uploads/image).' });
  } else {
    sourceGen = db.prepare('SELECT * FROM generations WHERE id = ? AND user_id = ?')
      .get(Number(b.generation_id), req.user.id);
    if (!sourceGen) return res.status(404).json({ error: 'Generation not found.' });
    if (sourceGen.status !== 'completed' || !sourceGen.video_url)
      return res.status(400).json({ error: 'Only a completed video can be lip-synced.' });
  }
  // Audio source: a fresh script (synthesized now) or a previous voice job.
  let settings = null, audioJob = null;
  if (b.voice_job_id !== undefined && b.voice_job_id !== null && b.voice_job_id !== '') {
    audioJob = db.prepare(
      `SELECT * FROM voice_jobs WHERE id = ? AND user_id = ? AND status = 'completed' AND audio_path IS NOT NULL`)
      .get(Number(b.voice_job_id), req.user.id);
    if (!audioJob) return res.status(400).json({ error: 'voice_job_id must be one of your completed voice jobs.' });
  } else {
    try { settings = parseVoiceSettings(b); }
    catch (e) { return res.status(e.status || 400).json({ error: e.message }); }
    if (!settings.provider)
      return res.status(503).json({ error: 'voice_not_configured', message: VOICE_NOT_CONFIGURED_MSG });
    if (moderated(settings.rawScript))
      return res.status(400).json({ error: 'This script was blocked by content moderation. Please rephrase it.' });
  }
  const model = hasImage ? CONFIG.lipsyncImageModel : CONFIG.lipsyncVideoModel;
  let jobId;
  try {
    jobId = chargeVoiceGeneration(req.user.id, {
      cost: CONFIG.lipsyncCost,
      prompt: (settings ? settings.rawScript : 'Talking / Lip-Sync').slice(0, 500),
      aspectRatio: sourceGen ? sourceGen.aspect_ratio : '16:9',
      duration: sourceGen ? sourceGen.duration : 5,
      style: 'realistic', model, kind: 'lipsync',
      sourceGenerationId: sourceGen ? sourceGen.id : null,
      sourceImagePath: hasImage ? String(b.image_path).replace(/\\/g, '/').replace(/^\.\//, '') : null,
      promptLanguage: settings ? settings.language : (audioJob ? audioJob.language : null),
      translatedPrompt: settings && settings.scriptMode === 'roman' ? settings.text : null,
    });
  } catch (e) { return res.status(e.status || 500).json({ error: e.message }); }
  const voiceJobId = recordVoiceJob({ userId: req.user.id, kind: 'lipsync',
    settings: settings || { provider: audioJob.provider, voiceId: audioJob.voice,
      language: audioJob.language, scriptMode: audioJob.script_mode,
      style: audioJob.style, speed: audioJob.speed },
    text: settings ? settings.text : audioJob.script_text,
    status: 'processing', generationId: jobId });
  try {
    let audioAbs, audioPublicPath;
    if (audioJob) {
      audioPublicPath = audioJob.audio_path;
      audioAbs = path.join(CONFIG.voiceDir, path.basename(audioJob.audio_path));
      if (!fs.existsSync(audioAbs)) throw new Error('The referenced voice audio no longer exists.');
    } else {
      const out = await synthesizeScript(settings, settings.text);
      audioAbs = out.absPath; audioPublicPath = out.audioPath;
      db.prepare('UPDATE generations SET voice_audio_path = ? WHERE id = ?').run(audioPublicPath, jobId);
    }
    // fal fetches the audio itself, so it needs a public URL for it.
    const base = CONFIG.publicBaseUrl || `${req.protocol}://${req.get('host')}`;
    const audioUrl = `${base}${audioPublicPath}`;
    let falBody;
    if (hasImage) {
      // Verified schema (minimax/h3-max/lip-sync/image-to-video):
      // image_url + audio_url required; resolution optional.
      falBody = { image_url: owned.dataUri, audio_url: audioUrl,
                  resolution: '768P', enable_safety_checker: true };
    } else {
      // Verified schema (fal-ai/latentsync): video_url + audio_url.
      const videoUrl = /^https?:\/\//i.test(sourceGen.video_url)
        ? sourceGen.video_url : `${base}${sourceGen.video_url}`;
      falBody = { video_url: videoUrl, audio_url: audioUrl, enable_safety_checker: true };
    }
    const result = await runFalQueueJob(model, falBody);
    const videoUrl = result?.video?.url || result?.data?.video?.url || null;
    if (!videoUrl) throw new Error('Lip-sync provider returned no video');
    const audioSecs = await probeAudioDuration(audioAbs).catch(() => 0);
    const duration = Math.max(1, Math.round(Number(result.duration) || audioSecs || 5));
    db.prepare(`UPDATE generations SET status = 'completed', video_url = ?, duration = ?,
                updated_at = datetime('now') WHERE id = ?`).run(videoUrl, duration, jobId);
    db.prepare(`UPDATE voice_jobs SET status = 'completed', audio_path = ? WHERE id = ?`)
      .run(audioPublicPath, voiceJobId);
    const row = db.prepare('SELECT * FROM generations WHERE id = ?').get(jobId);
    const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
    res.status(201).json({ generation: row, credits_left: me.credits, cost_credits: CONFIG.lipsyncCost });
  } catch (e) {
    failAndRefund(jobId, `Lip-sync failed (${e.message})`);
    db.prepare(`UPDATE voice_jobs SET status = 'failed', error = ? WHERE id = ?`).run(e.message, voiceJobId);
    res.status(502).json({ error: `Lip-sync failed (${e.message}). Your ${CONFIG.lipsyncCost} credits were refunded.` });
  }
});

// ---------- Voiceover (all plans, +10 credits) ------------------------------
// Synthesizes the script and muxes it over a finished video, REPLACING the
// video's original audio track (the model's native audio is not kept).
app.post('/api/voice/voiceover', auth, voiceLimiter, async (req, res) => {
  const b = req.body || {};
  const sourceGen = db.prepare('SELECT * FROM generations WHERE id = ? AND user_id = ?')
    .get(Number(b.generation_id), req.user.id);
  if (!sourceGen) return res.status(404).json({ error: 'Generation not found.' });
  if (sourceGen.status !== 'completed' || !sourceGen.video_url)
    return res.status(400).json({ error: 'Only a completed video can get a voiceover.' });
  let settings;
  try { settings = parseVoiceSettings(b); }
  catch (e) { return res.status(e.status || 400).json({ error: e.message }); }
  if (!settings.provider)
    return res.status(503).json({ error: 'voice_not_configured', message: VOICE_NOT_CONFIGURED_MSG });
  if (moderated(settings.rawScript))
    return res.status(400).json({ error: 'This script was blocked by content moderation. Please rephrase it.' });
  let jobId;
  try {
    jobId = chargeVoiceGeneration(req.user.id, {
      cost: CONFIG.voiceoverCost,
      prompt: `Voiceover: ${sourceGen.prompt}`.slice(0, 500),
      aspectRatio: sourceGen.aspect_ratio, duration: sourceGen.duration,
      style: sourceGen.style, model: 'voiceover', kind: 'voiceover',
      sourceGenerationId: sourceGen.id,
      promptLanguage: settings.language,
      translatedPrompt: settings.scriptMode === 'roman' ? settings.text : null,
    });
  } catch (e) { return res.status(e.status || 500).json({ error: e.message }); }
  const voiceJobId = recordVoiceJob({ userId: req.user.id, kind: 'voiceover', settings,
    text: settings.text, status: 'processing', generationId: jobId });
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ajk-vo-'));
  try {
    const out = await synthesizeScript(settings, settings.text);
    db.prepare('UPDATE generations SET voice_audio_path = ? WHERE id = ?').run(out.audioPath, jobId);
    const srcFile = path.join(work, 'source.mp4');
    await downloadClip(sourceGen.video_url, srcFile, { left: JOIN_MAX_BYTES });
    fs.mkdirSync(CONFIG.generatedDir, { recursive: true });
    const name = `${randomUUID()}.mp4`;
    const output = path.join(CONFIG.generatedDir, name);
    const muxArgs = ['-y', '-i', srcFile, '-i', out.absPath,
                     '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'copy',
                     '-c:a', 'aac', '-shortest', output];
    try { await runFfmpeg(muxArgs); }
    catch { // stream copy can fail on exotic source codecs — re-encode
      await runFfmpeg(['-y', '-i', srcFile, '-i', out.absPath,
                       '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'libx264',
                       '-preset', 'veryfast', '-crf', '20', '-c:a', 'aac',
                       '-shortest', output]);
    }
    const probe = await probeMedia(output);
    if (!probe.hasAudio) throw new Error('Voiceover render produced no audio track');
    db.prepare(`UPDATE generations SET status = 'completed', video_url = ?,
                updated_at = datetime('now') WHERE id = ?`).run(`/files/generated/${name}`, jobId);
    db.prepare(`UPDATE voice_jobs SET status = 'completed', audio_path = ? WHERE id = ?`)
      .run(out.audioPath, voiceJobId);
    const row = db.prepare('SELECT * FROM generations WHERE id = ?').get(jobId);
    const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
    res.status(201).json({ generation: row, credits_left: me.credits, cost_credits: CONFIG.voiceoverCost });
  } catch (e) {
    failAndRefund(jobId, `Voiceover failed (${e.message})`);
    db.prepare(`UPDATE voice_jobs SET status = 'failed', error = ? WHERE id = ?`).run(e.message, voiceJobId);
    res.status(502).json({ error: `Voiceover failed (${e.message}). Your ${CONFIG.voiceoverCost} credits were refunded.` });
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

// ==========================================================================
// Sound system (Phase B2) — auto sync sound, sound effects, music beds
// ==========================================================================
// Engines (all on fal, all server-side; schemas verified against fal's
// own API docs / llms.txt on 2026-10-23):
//   sync (MMAudio V2, fal-ai/mmaudio-v2, $0.001/s) — video-to-video:
//     inputs video_url + prompt (both required), duration (float 1–30);
//     returns { video: { url } } — a finished MP4 whose audio track IS
//     the generated soundtrack (it REPLACES the video's original audio).
//   premium_sync (Mirelo SFX 2.0, mirelo-ai/sfx2.0/video-to-audio,
//     $0.010/s promo until 2026-12-13, then $0.015/s) — inputs video_url
//     (required), text_prompt (optional), preserve_speech (bool, default
//     true — the existing speech is kept inside the model's output),
//     num_samples (pinned to 1; each sample is billed), duration (1–600);
//     returns { audio: [{ url }] } — audio only, muxed here as the
//     video's audio track. Pro / Extra Pro plans only.
//   sfx (ElevenLabs Sound Effects v2, fal-ai/elevenlabs/sound-effects/v2,
//     $0.002/s) — inputs text (required; the field is literally `text`),
//     duration_seconds (0.5–22), loop, prompt_influence; returns
//     { audio: { url } } (MP3).
//   music (CassetteAI Music Generator, cassetteai/music-generator,
//     $0.02 per output minute) — inputs prompt + duration (int 10–180);
//     returns { audio_file: { url } } (WAV). The prompt is suffixed with
//     "instrumental, no vocals" server-side: beds must not sing over the
//     user's video.
// HONEST LIMITS: no engine accepts a timestamped event list, so event
// timing is the model's own estimate — never guaranteed. Sync modes
// replace the original audio (premium preserves speech by design); sfx
// and music are mixed UNDER the original audio at the chosen volume.
// Commercial licensing terms are not stated on fal's model pages.
// FAIL CLOSED: with no FAL_KEY (or SOUND_ENABLED=0) the sound endpoints
// answer 503 (sound_not_configured) and charge nothing.
const SOUND_GENERATE_MODES = ['sync', 'sfx', 'music'];
const SOUND_APPLY_MODES = ['sync', 'premium_sync', 'sfx', 'music'];
const SOUND_DEFAULT_VOLUME = { sync: 100, premium_sync: 100, sfx: 60, music: 30 };
const SOUND_NOT_CONFIGURED_MSG =
  'Sound features are not configured on this server yet — the sound engines are unavailable, so nothing was charged.';

function soundConfigured() {
  return !!FAL_KEY && CONFIG.soundEnabled;
}

// Test hook: with TEST_RECORD_FAL_BODY=1 every outgoing sync-API sound
// request (SFX / music) is recorded here so test.sh can assert the exact
// shapes without a real provider call. Queue-based engines (sync /
// premium sync) are recorded by runFalQueueJob into the voice-call log,
// exactly like the lip-sync jobs.
const soundCallLog = [];
function recordSoundCall(entry) {
  if (process.env.TEST_RECORD_FAL_BODY === '1') soundCallLog.push(entry);
}
if (process.env.TEST_RECORD_FAL_BODY === '1') {
  app.get('/api/_test/sound-calls', (req, res) => res.json({ calls: soundCallLog }));
}

// Generate ONE sound audio file with the SFX or music engine (sync fal
// API, like the TTS providers) and return its URL.
async function generateSoundAudioUrl(kind, prompt, durationSeconds) {
  let model, body;
  if (kind === 'sfx') {
    model = CONFIG.soundSfxModel;
    body = { text: prompt, duration_seconds: durationSeconds, loop: false };
  } else {
    model = CONFIG.soundMusicModel;
    body = { prompt: `${prompt} — instrumental, no vocals`,
             duration: Math.round(durationSeconds) };
  }
  recordSoundCall({ kind: 'sound', engine: kind, model, body });
  const r = await fetch(`${CONFIG.falApiBase}/${model}`, {
    method: 'POST',
    headers: { 'Authorization': `Key ${FAL_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body), signal: AbortSignal.timeout(120000),
  });
  if (!r.ok) throw new Error(`Sound provider returned ${r.status}`);
  const data = await r.json();
  const url = kind === 'sfx' ? data?.audio?.url : data?.audio_file?.url;
  if (!url) throw new Error('Sound provider returned no audio');
  return url;
}

async function downloadAudioToFile(url, dest) {
  const r = await fetch(url, { signal: AbortSignal.timeout(60000) });
  if (!r.ok) throw new Error('Could not download the generated audio');
  const buf = Buffer.from(await r.arrayBuffer());
  if (buf.length === 0) throw new Error('The generated audio was empty');
  fs.writeFileSync(dest, buf);
}

// fal fetches media itself, so engine inputs must be absolute URLs: fal
// CDN URLs pass through; our own /files/... paths get the public base.
function absoluteMediaUrl(url, baseUrl) {
  if (/^https?:\/\//i.test(url)) return url;
  return `${baseUrl}${url.startsWith('/') ? '' : '/'}${url}`;
}

// Run the sound step for one video and return { videoUrl } of the
// sounded version. Throws on any failure — callers decide the refund.
//   sync / premium_sync REPLACE the audio track (see the header notes);
//   sfx / music mix the generated audio UNDER the original track.
async function produceSoundedVideo({ sourceUrl, duration, mode, prompt, volume, baseUrl }) {
  const vol = Math.min(100, Math.max(10, Number(volume) || 100));
  const vf = String(vol / 100);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ajk-sound-'));
  try {
    if (mode === 'sync') {
      const result = await runFalQueueJob(CONFIG.soundSyncModel, {
        video_url: absoluteMediaUrl(sourceUrl, baseUrl),
        prompt, duration: Math.min(30, Math.max(1, Number(duration) || 5)),
      });
      const outUrl = result?.video?.url || result?.data?.video?.url || null;
      if (!outUrl) throw new Error('Sync sound provider returned no video');
      if (vol === 100) return { videoUrl: outUrl };
      // Below full volume the soundtrack gets an ffmpeg gain pass.
      const inFile = path.join(work, 'sync-in.mp4');
      await downloadClip(outUrl, inFile, { left: JOIN_MAX_BYTES });
      const probe = await probeMedia(inFile);
      if (!probe.hasAudio) return { videoUrl: outUrl }; // nothing to attenuate
      fs.mkdirSync(CONFIG.generatedDir, { recursive: true });
      const name = `${randomUUID()}.mp4`;
      const outFile = path.join(CONFIG.generatedDir, name);
      try {
        await runFfmpeg(['-y', '-i', inFile, '-map', '0:v:0', '-map', '0:a:0',
                         '-c:v', 'copy', '-af', `volume=${vf}`, '-c:a', 'aac', outFile]);
      } catch { // stream copy can fail on exotic codecs — re-encode
        await runFfmpeg(['-y', '-i', inFile, '-map', '0:v:0', '-map', '0:a:0',
                         '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
                         '-af', `volume=${vf}`, '-c:a', 'aac', outFile]);
      }
      return { videoUrl: `/files/generated/${name}` };
    }
    if (mode === 'premium_sync') {
      const body = { video_url: absoluteMediaUrl(sourceUrl, baseUrl),
                     preserve_speech: true, num_samples: 1,
                     duration: Math.min(600, Math.max(1, Number(duration) || 10)) };
      if (prompt) body.text_prompt = prompt;
      const result = await runFalQueueJob(CONFIG.soundSyncPremiumModel, body);
      const audioUrl = result?.audio?.[0]?.url || result?.data?.audio?.[0]?.url || null;
      if (!audioUrl) throw new Error('Premium sync provider returned no audio');
      const srcFile = path.join(work, 'source.mp4');
      await downloadClip(sourceUrl, srcFile, { left: JOIN_MAX_BYTES });
      const audFile = path.join(work, 'premium-audio');
      await downloadAudioToFile(audioUrl, audFile);
      fs.mkdirSync(CONFIG.generatedDir, { recursive: true });
      const name = `${randomUUID()}.mp4`;
      const outFile = path.join(CONFIG.generatedDir, name);
      const gain = vol !== 100 ? ['-af', `volume=${vf}`] : [];
      try {
        await runFfmpeg(['-y', '-i', srcFile, '-i', audFile,
                         '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'copy',
                         ...gain, '-c:a', 'aac', '-shortest', outFile]);
      } catch {
        await runFfmpeg(['-y', '-i', srcFile, '-i', audFile,
                         '-map', '0:v:0', '-map', '1:a:0', '-c:v', 'libx264',
                         '-preset', 'veryfast', '-crf', '20',
                         ...gain, '-c:a', 'aac', '-shortest', outFile]);
      }
      const probe = await probeMedia(outFile);
      if (!probe.hasAudio) throw new Error('Premium sync render produced no audio track');
      return { videoUrl: `/files/generated/${name}` };
    }
    // sfx | music — mix under the original audio.
    const reqDur = mode === 'sfx'
      ? Math.min(22, Math.max(0.5, Number(duration) || 10))
      : Math.min(180, Math.max(10, Math.round(Number(duration) || 10)));
    const audioUrl = await generateSoundAudioUrl(mode, prompt, reqDur);
    const srcFile = path.join(work, 'source.mp4');
    await downloadClip(sourceUrl, srcFile, { left: JOIN_MAX_BYTES });
    const audFile = path.join(work, mode === 'sfx' ? 'sfx.mp3' : 'music.wav');
    await downloadAudioToFile(audioUrl, audFile);
    const probe = await probeMedia(srcFile);
    const dur = probe.duration;
    // The generated track is gained to the chosen volume, padded/trimmed
    // to the video's length, and (when the video has a track) mixed under
    // the original at full level — amix normalize=0 keeps the original
    // untouched. A silent video (e.g. the native-4K route) simply gains
    // the new track as its audio.
    const mixFilter = probe.hasAudio
      ? `[0:a]volume=1[a0];[1:a]volume=${vf},apad,atrim=0:${dur}[a1];[a0][a1]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]`
      : `[1:a]volume=${vf},apad,atrim=0:${dur}[aout]`;
    fs.mkdirSync(CONFIG.generatedDir, { recursive: true });
    const name = `${randomUUID()}.mp4`;
    const outFile = path.join(CONFIG.generatedDir, name);
    try {
      await runFfmpeg(['-y', '-i', srcFile, '-i', audFile,
                       '-filter_complex', mixFilter,
                       '-map', '0:v:0', '-map', '[aout]', '-c:v', 'copy', '-c:a', 'aac', outFile]);
    } catch {
      await runFfmpeg(['-y', '-i', srcFile, '-i', audFile,
                       '-filter_complex', mixFilter,
                       '-map', '0:v:0', '-map', '[aout]', '-c:v', 'libx264',
                       '-preset', 'veryfast', '-crf', '20', '-c:a', 'aac', outFile]);
    }
    const outProbe = await probeMedia(outFile);
    if (!outProbe.hasAudio) throw new Error('Sound mix produced no audio track');
    return { videoUrl: `/files/generated/${name}` };
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

// ---------- Generate-time sound post-processing ---------------------------
// Mirrors ensureWatermarkApplied: when a generation that asked for sound
// completes, the sound step runs before the client sees the video. If
// the step fails, the VIDEO IS STILL DELIVERED exactly as generated —
// only the sound add-on is refunded (exactly once: the refund happens
// only in the UPDATE that flips sound_status away from 'pending') and
// the row is honestly marked sound_status='failed_refunded'.
const soundInFlight = new Set();
async function ensureSoundApplied(job, baseUrl) {
  if (!job || job.status !== 'completed' || !job.video_url) return job;
  if (job.sound_status !== 'pending' || !job.sound_mode) return job;
  if (soundInFlight.has(job.id)) return job;
  soundInFlight.add(job.id);
  try {
    const out = await produceSoundedVideo({
      sourceUrl: job.video_url, duration: job.duration, mode: job.sound_mode,
      prompt: job.sound_prompt || job.translated_prompt || job.prompt,
      volume: job.sound_volume ?? SOUND_DEFAULT_VOLUME[job.sound_mode] ?? 100,
      baseUrl,
    });
    db.prepare(`UPDATE generations SET video_url = ?, sound_status = 'applied',
                updated_at = datetime('now') WHERE id = ? AND sound_status = 'pending'`)
      .run(out.videoUrl, job.id);
  } catch (e) {
    console.error(`sound step failed for generation ${job.id}:`, e.message);
    const sc = Number(job.sound_cost) || 0;
    const changed = db.prepare(`UPDATE generations SET sound_status = 'failed_refunded',
                  cost_credits = cost_credits - ?, updated_at = datetime('now')
                  WHERE id = ? AND sound_status = 'pending'`).run(sc, job.id);
    if (Number(changed.changes) === 1 && sc > 0)
      tx(() => refundBuckets(job.user_id, sc));
  } finally {
    soundInFlight.delete(job.id);
  }
  const fresh = db.prepare('SELECT * FROM generations WHERE id = ?').get(job.id);
  if (fresh) Object.assign(job, fresh);
  return job;
}

// ---------- Shared request parsing for the sound endpoints ----------------
function parseSoundVolume(value, mode) {
  if (value === undefined || value === null || value === '')
    return SOUND_DEFAULT_VOLUME[mode] ?? 100;
  const v = Number(value);
  if (!Number.isFinite(v) || v < 10 || v > 100)
    throw Object.assign(new Error('volume must be between 10 and 100.'), { status: 400 });
  return Math.round(v);
}
// Validate + (when needed) translate a sound description BEFORE charging,
// exactly like generation prompts: the description may be written in any
// of the 7 prompt languages; the engines are fed English. `fallback` is
// used when no description was given (may itself be null for premium
// sync, whose text guidance is optional). Throws { status, error }.
async function resolveSoundPrompt({ rawPrompt, language, fallback }) {
  const languageCode = String(language || 'en').toLowerCase();
  if (!PROMPT_LANGUAGES.some(l => l.code === languageCode))
    throw Object.assign(new Error(`language must be one of: ${PROMPT_LANGUAGES.map(l => l.code).join(', ')}`), { status: 400 });
  const raw = rawPrompt !== undefined && rawPrompt !== null && String(rawPrompt).trim()
    ? String(rawPrompt).trim() : null;
  if (raw && raw.length > 500)
    throw Object.assign(new Error('The sound description must be at most 500 characters.'), { status: 400 });
  if (raw && moderated(raw))
    throw Object.assign(new Error('The sound description was blocked by content moderation. Please rephrase it.'), { status: 400 });
  if (!raw) return { prompt: fallback || null, translated: null, languageCode, raw: null };
  if (TRANSLATED_LANGUAGES.has(languageCode)) {
    let translated;
    try { translated = await translatePrompt(raw, languageCode); }
    catch { throw Object.assign(new Error('We could not translate your sound description into English, so nothing was charged. Please try again.'), { status: 502 }); }
    if (moderated(translated))
      throw Object.assign(new Error('The sound description was blocked by content moderation. Please rephrase it.'), { status: 400 });
    return { prompt: translated, translated, languageCode, raw };
  }
  return { prompt: raw, translated: null, languageCode, raw };
}
function soundEngineModel(mode) {
  return mode === 'sync' ? CONFIG.soundSyncModel
    : mode === 'premium_sync' ? CONFIG.soundSyncPremiumModel
    : mode === 'sfx' ? CONFIG.soundSfxModel : CONFIG.soundMusicModel;
}

// ---------- Apply sound to a finished video -------------------------------
// Same engines/mixing as generate-time sound. sync and premium_sync
// REPLACE the video's audio track (premium keeps the dialogue inside
// the model output); sfx/music mix under it. The result is a NEW
// History entry (kind 'sound') linked to the source generation.
app.post('/api/sound/apply', auth, soundLimiter, async (req, res) => {
  const b = req.body || {};
  if (!soundConfigured())
    return res.status(503).json({ error: 'sound_not_configured', message: SOUND_NOT_CONFIGURED_MSG });
  const sourceGen = db.prepare('SELECT * FROM generations WHERE id = ? AND user_id = ?')
    .get(Number(b.generation_id), req.user.id);
  if (!sourceGen) return res.status(404).json({ error: 'Generation not found.' });
  if (sourceGen.status !== 'completed' || !sourceGen.video_url)
    return res.status(400).json({ error: 'Only a completed video can get sound.' });
  if (sourceGen.kind === 'sound' && !sourceGen.source_generation_id)
    return res.status(400).json({ error: 'That history entry is an audio file, not a video — sound can only be applied to a video.' });
  const mode = String(b.mode || '').toLowerCase();
  if (!SOUND_APPLY_MODES.includes(mode))
    return res.status(400).json({ error: `mode must be one of: ${SOUND_APPLY_MODES.join(', ')}` });
  if (mode === 'premium_sync') {
    refreshSubscriptionState(req.user.id);
    const sub = currentSubscription(req.user.id);
    const plan = sub ? getPlan(sub.plan_id) : null;
    if (!plan || !['pro', 'extrapro'].includes(plan.id))
      return res.status(403).json({ error: 'Premium sync sound needs the Pro or Extra Pro plan. Upgrade your plan to keep the dialogue and add a premium soundtrack.' });
  }
  let volume, resolved;
  try {
    volume = parseSoundVolume(b.volume, mode);
    resolved = await resolveSoundPrompt({
      rawPrompt: b.prompt, language: b.language,
      fallback: mode === 'sync' ? (sourceGen.translated_prompt || sourceGen.prompt) : null,
    });
  } catch (e) { return res.status(e.status || 400).json({ error: e.message }); }
  // sfx/music always need a description: fall back to the source prompt.
  const effectivePrompt = resolved.prompt || sourceGen.translated_prompt || sourceGen.prompt;
  const cost = CONFIG.soundCosts[mode];
  let jobId;
  try {
    jobId = chargeVoiceGeneration(req.user.id, {
      cost,
      prompt: `Sound (${mode}): ${resolved.raw || effectivePrompt}`.slice(0, 500),
      aspectRatio: sourceGen.aspect_ratio, duration: sourceGen.duration,
      style: sourceGen.style, model: soundEngineModel(mode), kind: 'sound',
      sourceGenerationId: sourceGen.id,
      promptLanguage: resolved.languageCode,
      translatedPrompt: resolved.translated,
    });
  } catch (e) { return res.status(e.status || 500).json({ error: e.message }); }
  db.prepare(`UPDATE generations SET sound_mode = ?, sound_prompt = ?, sound_volume = ?,
              sound_status = 'processing', sound_cost = ? WHERE id = ?`)
    .run(mode, effectivePrompt, volume, cost, jobId);
  try {
    const base = CONFIG.publicBaseUrl || `${req.protocol}://${req.get('host')}`;
    const out = await produceSoundedVideo({
      sourceUrl: sourceGen.video_url, duration: sourceGen.duration, mode,
      // Premium sync's text guidance is optional: pass only what was given.
      prompt: mode === 'premium_sync' ? resolved.prompt : effectivePrompt,
      volume, baseUrl: base,
    });
    db.prepare(`UPDATE generations SET status = 'completed', video_url = ?,
                sound_status = 'applied', updated_at = datetime('now') WHERE id = ?`)
      .run(out.videoUrl, jobId);
    const row = db.prepare('SELECT * FROM generations WHERE id = ?').get(jobId);
    const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
    res.status(201).json({ generation: row, credits_left: me.credits, cost_credits: cost });
  } catch (e) {
    failAndRefund(jobId, `Sound failed (${e.message})`);
    db.prepare('UPDATE generations SET sound_status = ? WHERE id = ?').run('failed_refunded', jobId);
    res.status(502).json({ error: `Sound failed (${e.message}). Your ${cost} credits were refunded.` });
  }
});

// ---------- Audio only: generate a sound file, no video -------------------
// kind 'sfx' (1–22s) or 'music' (10–60s). The audio file is stored under
// data/sounds/ and served at /files/sounds/; the History entry is a
// kind 'sound' generation with no source video, rendered by the app as
// an audio player with a download.
app.post('/api/sound/generate', auth, soundLimiter, async (req, res) => {
  const b = req.body || {};
  if (!soundConfigured())
    return res.status(503).json({ error: 'sound_not_configured', message: SOUND_NOT_CONFIGURED_MSG });
  const kind = String(b.kind || '').toLowerCase();
  if (!['sfx', 'music'].includes(kind))
    return res.status(400).json({ error: 'kind must be one of: sfx, music' });
  const rawPromptInput = b.prompt !== undefined && b.prompt !== null ? String(b.prompt).trim() : '';
  if (rawPromptInput.length < 3 || rawPromptInput.length > 500)
    return res.status(400).json({ error: 'Please describe the sound in 3–500 characters.' });
  let durationSeconds = kind === 'sfx' ? 10 : 30;
  if (b.duration_seconds !== undefined && b.duration_seconds !== null && b.duration_seconds !== '') {
    durationSeconds = Number(b.duration_seconds);
    if (!Number.isFinite(durationSeconds))
      return res.status(400).json({ error: 'duration_seconds must be a number.' });
    if (kind === 'sfx' && (durationSeconds < 1 || durationSeconds > 22))
      return res.status(400).json({ error: 'duration_seconds for sfx must be between 1 and 22.' });
    if (kind === 'music' && (durationSeconds < 10 || durationSeconds > 60))
      return res.status(400).json({ error: 'duration_seconds for music must be between 10 and 60.' });
  }
  let resolved;
  try {
    resolved = await resolveSoundPrompt({ rawPrompt: rawPromptInput, language: b.language, fallback: null });
  } catch (e) { return res.status(e.status || 400).json({ error: e.message }); }
  const cost = CONFIG.soundCosts[kind];
  let jobId;
  try {
    jobId = chargeVoiceGeneration(req.user.id, {
      cost, prompt: rawPromptInput, aspectRatio: '16:9',
      duration: Math.round(durationSeconds), style: 'realistic',
      model: soundEngineModel(kind), kind: 'sound', sourceGenerationId: null,
      promptLanguage: resolved.languageCode,
      translatedPrompt: resolved.translated,
    });
  } catch (e) { return res.status(e.status || 500).json({ error: e.message }); }
  db.prepare(`UPDATE generations SET sound_mode = ?, sound_prompt = ?,
              sound_status = 'processing', sound_cost = ? WHERE id = ?`)
    .run(kind, resolved.prompt, cost, jobId);
  try {
    const audioUrl = await generateSoundAudioUrl(kind, resolved.prompt, durationSeconds);
    fs.mkdirSync(CONFIG.soundsDir, { recursive: true });
    const name = `${randomUUID()}${kind === 'sfx' ? '.mp3' : '.wav'}`;
    await downloadAudioToFile(audioUrl, path.join(CONFIG.soundsDir, name));
    const publicPath = `/files/sounds/${name}`;
    db.prepare(`UPDATE generations SET status = 'completed', video_url = ?,
                sound_status = 'applied', updated_at = datetime('now') WHERE id = ?`)
      .run(publicPath, jobId);
    const row = db.prepare('SELECT * FROM generations WHERE id = ?').get(jobId);
    const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
    res.status(201).json({ generation: row, audio_url: publicPath,
                           credits_left: me.credits, cost_credits: cost });
  } catch (e) {
    failAndRefund(jobId, `Sound generation failed (${e.message})`);
    db.prepare('UPDATE generations SET sound_status = ? WHERE id = ?').run('failed_refunded', jobId);
    res.status(502).json({ error: `Sound generation failed (${e.message}). Your ${cost} credits were refunded.` });
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
      if (row.play_product_weekly === productId) return { plan: row, period: 'weekly' };
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
    : planPriceFor(found.plan, found.period);
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
           found.pack ? found.pack.credits : planGrantFor(found.plan, found.period)).lastInsertRowid);
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
// to new payments, credits (monthly or weekly) to the next
// activation/renewal grant, resolution/model to the next generation.
// price_weekly/credits_weekly are nullable (null = the plan has no weekly
// period); can_veo/can_lipsync are the Phase B entitlement flags.
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
  // Nullable integer: an explicit null clears the field (e.g. removing a
  // weekly period); a number must be a non-negative integer.
  const optIntField = (name) => {
    if (b[name] === undefined) return plan[name];
    if (b[name] === null) return null;
    const v = Number(b[name]);
    if (!Number.isInteger(v) || v < 0) throw Object.assign(new Error(`BAD_${name}`), { status: 400 });
    return v;
  };
  const boolField = (name) => {
    if (b[name] === undefined) return plan[name];
    return b[name] ? 1 : 0;
  };
  try {
    const updated = {
      price_monthly: intField('price_monthly'),
      price_yearly: intField('price_yearly'),
      credits_monthly: intField('credits_monthly'),
      price_weekly: optIntField('price_weekly'),
      credits_weekly: optIntField('credits_weekly'),
      quality_label: b.quality_label !== undefined ? String(b.quality_label).slice(0, 40) : plan.quality_label,
      quality: b.quality !== undefined ? String(b.quality).slice(0, 20) : plan.quality,
      resolution: b.resolution !== undefined ? String(b.resolution).toUpperCase() : plan.resolution,
      model: b.model !== undefined ? String(b.model).slice(0, 120) : plan.model,
      is_active: b.is_active !== undefined ? (b.is_active ? 1 : 0) : plan.is_active,
      can_veo: boolField('can_veo'),
      can_lipsync: boolField('can_lipsync'),
      // Google Play subscription product ids (must match Play Console).
      play_product_monthly: b.play_product_monthly !== undefined
        ? (String(b.play_product_monthly).trim().slice(0, 120) || null) : plan.play_product_monthly,
      play_product_yearly: b.play_product_yearly !== undefined
        ? (String(b.play_product_yearly).trim().slice(0, 120) || null) : plan.play_product_yearly,
      play_product_weekly: b.play_product_weekly !== undefined
        ? (String(b.play_product_weekly).trim().slice(0, 120) || null) : plan.play_product_weekly,
    };
    if (!RESOLUTIONS.includes(updated.resolution))
      return res.status(400).json({ error: `resolution must be one of: ${RESOLUTIONS.join(', ')}` });
    db.prepare(`UPDATE plans SET price_monthly = ?, price_yearly = ?, credits_monthly = ?,
                price_weekly = ?, credits_weekly = ?,
                quality_label = ?, quality = ?, resolution = ?, model = ?, is_active = ?,
                can_veo = ?, can_lipsync = ?,
                play_product_monthly = ?, play_product_yearly = ?, play_product_weekly = ?,
                updated_at = datetime('now') WHERE id = ?`)
      .run(updated.price_monthly, updated.price_yearly, updated.credits_monthly,
           updated.price_weekly, updated.credits_weekly,
           updated.quality_label, updated.quality, updated.resolution, updated.model,
           updated.is_active, updated.can_veo, updated.can_lipsync,
           updated.play_product_monthly, updated.play_product_yearly, updated.play_product_weekly, plan.id);
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
function validPeriod(b) { return ['weekly', 'monthly', 'yearly'].includes(b.period) ? b.period : null; }
// A period must exist on the plan: the Weekly plan is weekly-only (buying
// it monthly/yearly is a 400), and monthly plans have no weekly cycle.
function periodFitsPlan(plan, period) {
  if (!plan || !period) return false;
  return period === 'weekly' ? isWeeklyPlan(plan) : !isWeeklyPlan(plan);
}

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
  if (!period) return res.status(400).json({ error: 'period must be "weekly", "monthly" or "yearly".' });
  if (!periodFitsPlan(plan, period))
    return res.status(400).json({ error: isWeeklyPlan(plan)
      ? 'The Weekly plan is billed weekly only — it has no monthly or yearly price.'
      : 'This plan has no weekly billing period.' });
  const amount = planPriceFor(plan, period);
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
  if (!period) return res.status(400).json({ error: 'period must be "weekly", "monthly" or "yearly".' });
  if (!periodFitsPlan(plan, period))
    return res.status(400).json({ error: isWeeklyPlan(plan)
      ? 'The Weekly plan is billed weekly only — it has no monthly or yearly price.'
      : 'This plan has no weekly billing period.' });
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
fs.mkdirSync(CONFIG.voiceDir, { recursive: true });
fs.mkdirSync(CONFIG.soundsDir, { recursive: true });
app.use('/files/joined', express.static(CONFIG.joinedDir));
app.use('/files/generated', express.static(CONFIG.generatedDir));
app.use('/files/voice', express.static(CONFIG.voiceDir));
app.use('/files/sounds', express.static(CONFIG.soundsDir));
app.use(express.static(path.join(__dirname, 'public')));
app.get(/^\/(?!api\/).*/, (req, res) =>
  res.sendFile(path.join(__dirname, 'public', 'index.html')));

app.use((err, req, res, next) => { // last-resort error handler
  console.error(err);
  res.status(500).json({ error: 'Something went wrong on the server.' });
});

app.listen(process.env.PORT || 8080,
  () => console.log(`My Video AI backend running on port ${process.env.PORT || 8080} (model: ${CONFIG.model})`));
