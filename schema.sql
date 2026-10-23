-- My Video AI database schema (SQLite for v1 — free, no separate DB server).
-- server.js creates these tables automatically on first run.
-- To move later: the same schema works on PostgreSQL with minor type changes.

CREATE TABLE IF NOT EXISTS users (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  email         TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  credits       INTEGER NOT NULL DEFAULT 10,
  created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS generations (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id       INTEGER NOT NULL REFERENCES users(id),
  fal_request_id TEXT,                          -- id returned by fal.ai queue
  prompt        TEXT NOT NULL,
  aspect_ratio  TEXT NOT NULL DEFAULT '16:9',
  duration      INTEGER NOT NULL DEFAULT 5,     -- seconds
  style         TEXT NOT NULL DEFAULT 'realistic',
  status        TEXT NOT NULL DEFAULT 'queued', -- queued | in_progress | completed | failed
  video_url     TEXT,                           -- set when status = completed
  error         TEXT,                           -- set when status = failed
  cost_credits  INTEGER NOT NULL DEFAULT 1,
  created_at    TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS reports (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id       INTEGER REFERENCES users(id),
  generation_id INTEGER REFERENCES generations(id),
  reason        TEXT NOT NULL,
  created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);

-- === Monetization (migration v3, applied automatically by server.js) ===
-- users gains: is_admin, free_credits, plan_credits
--   (users.credits always equals free_credits + plan_credits)
-- generations gains: resolution, model (the routed quality for the job)
--
-- === Prompt languages (migration v4, applied automatically by server.js) ===
-- generations gains: prompt_language (code the user wrote the prompt in),
-- translated_prompt (English text sent to the model for the auto-translated
-- languages ur/ks/ar/fa/hi; NULL for en/zh). `prompt` keeps the original.

CREATE TABLE IF NOT EXISTS plans (
  id              TEXT PRIMARY KEY,               -- weekly | normal | pro | extrapro
  name            TEXT NOT NULL,
  price_monthly   INTEGER NOT NULL,               -- PKR
  price_yearly    INTEGER NOT NULL,               -- PKR
  currency        TEXT NOT NULL DEFAULT 'PKR',
  credits_monthly INTEGER NOT NULL,
  quality         TEXT NOT NULL,                  -- 768P | 2K | 4K
  quality_label   TEXT NOT NULL,                  -- shown in the UI
  resolution      TEXT NOT NULL,                  -- fal resolution for this plan
  model           TEXT NOT NULL,                  -- fal model for this plan
  is_active       INTEGER NOT NULL DEFAULT 1,
  sort_order      INTEGER NOT NULL DEFAULT 0,
  updated_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS payments (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id         INTEGER NOT NULL REFERENCES users(id),
  plan_id         TEXT REFERENCES plans(id),
  amount          INTEGER NOT NULL,               -- PKR
  currency        TEXT NOT NULL DEFAULT 'PKR',
  provider        TEXT NOT NULL DEFAULT 'manual_test', -- manual_test | google_play (Phase 3)
  provider_txn_id TEXT UNIQUE,
  status          TEXT NOT NULL DEFAULT 'succeeded',   -- succeeded | failed | refunded | pending
  period          TEXT,                                -- monthly | yearly
  note            TEXT,
  created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS subscriptions (
  id                   INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id              INTEGER NOT NULL REFERENCES users(id),
  plan_id              TEXT NOT NULL REFERENCES plans(id),
  status               TEXT NOT NULL DEFAULT 'active', -- active | grace | canceled | expired
  period               TEXT NOT NULL DEFAULT 'monthly',
  started_at           TEXT NOT NULL DEFAULT (datetime('now')),
  current_period_start TEXT,
  current_period_end   TEXT,
  last_grant_at        TEXT,
  payment_id           INTEGER REFERENCES payments(id),
  created_at           TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at           TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Migration v5: credit rescale (one-time UPDATE of plans.credits:
-- normal=100, pro=120, extrapro=120 — prices untouched) plus credit packs.
CREATE TABLE IF NOT EXISTS credit_packs (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  credits    INTEGER NOT NULL,
  price_pkr  INTEGER NOT NULL,
  is_active  INTEGER NOT NULL DEFAULT 1,
  sort_order INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT (datetime('now')),
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
-- Seeded on boot when empty: 50 credits Rs 899; 100 credits Rs 1,499;
-- 250 credits Rs 3,499. Admin-editable via /api/admin/packs.

CREATE TABLE IF NOT EXISTS pack_purchases (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id         INTEGER NOT NULL REFERENCES users(id),
  pack_id         INTEGER NOT NULL REFERENCES credit_packs(id),
  credits         INTEGER NOT NULL,  -- snapshot at purchase time
  amount_pkr      INTEGER NOT NULL,  -- snapshot at purchase time
  method          TEXT NOT NULL,     -- easypaisa | jazzcash | bank | nayapay | other
  transaction_ref TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'pending', -- pending | approved | rejected
  admin_note      TEXT,
  created_at      TEXT NOT NULL DEFAULT (datetime('now')),
  decided_at      TEXT,
  decided_by      INTEGER REFERENCES users(id)
);

-- === Automatic payments (migration v6, applied automatically by server.js) ===
-- plans gains:        play_product_monthly, play_product_yearly
--                     (Google Play subscription product ids; defaults
--                      ajk_<plan>_monthly / ajk_<plan>_yearly, admin-editable)
-- credit_packs gains: play_product_id (defaults credits_50/100/250)
-- users gains:        credit_deficit (credits a refund clawback could not
--                     recover because they were already spent)
-- payments gains:     pack_id (set for pack payments — plan_id stays NULL),
--                     credits_granted (exactly what the payment granted,
--                     so a refund can claw back the same amount from the
--                     same bucket). provider values now also include
--                     'google_play' and 'payfast'.
--
-- === Video modes, image-to-video, watermarks (migration v7) ===
-- generations gains:  mode ('realistic' | 'cartoon', default 'realistic'),
--                     source_image_path (the uploader-owned image under
--                     data/uploads/<userId>/ that the job animated, if any),
--                     watermark_text (optional user-supplied overlay text),
--                     watermark_status ('none' | 'pending' | 'applied' |
--                     'failed' — the honest post-processing outcome).
--
-- === Normal plan price change (migration v8) ===
-- One-time UPDATE of the 'normal' plan row only: price_monthly 1999,
-- price_yearly 19990, credits_monthly 150 (owner decision 2026-10-23).
-- Pro / Extra Pro unchanged; fresh DBs seed the same values.
--
-- === Final pricing + Weekly plan (migration v9) ===
-- plans gains: price_weekly / credits_weekly (NULL on monthly plans; the
--   Weekly plan is weekly-only — its monthly/yearly columns stay 0 and
--   the API reports them as null), play_product_weekly (Google Play
--   weekly base-plan product id, default 'ajk_weekly' — Play supports
--   weekly base plans), can_veo / can_lipsync (entitlement flags for the
--   Phase B Veo / lip-sync engines; flags only, no generation behavior).
-- One-time UPDATEs set the owner's FINAL prices (2026-10-23): normal
--   5600/mo + 400 credits; pro 9500/mo + 500 credits + both flags;
--   extrapro 14000/mo + 600 credits + both flags; and the weekly plan row
--   is inserted (Rs 1,800/week, 80 credits/week, 768P). Subscriptions gain
--   nothing new: their period column now also accepts 'weekly' (period
--   end = start + 7 days; grant = credits_weekly, once per period).
--
-- === Voice system (migration v10, applied automatically by server.js) ===
-- generations gains:  kind ('video' | 'lipsync' | 'voiceover'),
--                     voice_audio_path (the synthesized voice track a
--                     job used, /files/voice/<file>), source_generation_id
--                     (the finished video a lipsync/voiceover derived from).
--
-- === Sound system (migration v11, applied automatically by server.js) ===
-- generations gains:  sound_mode ('sync' | 'premium_sync' | 'sfx' |
--                     'music'; NULL when no sound was requested),
--                     sound_status ('none' | 'pending' | 'processing' |
--                     'applied' | 'failed_refunded'), sound_prompt (the
--                     English text sent to the sound engine),
--                     sound_volume (10–100), sound_cost (the add-on
--                     credits charged for the sound step — refunded on
--                     its own when only that step fails). Standalone
--                     sound jobs are generations rows with kind='sound';
--                     audio-only jobs keep their /files/sounds/ path in
--                     video_url and have no source_generation_id.
CREATE TABLE IF NOT EXISTS voice_jobs (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id       INTEGER NOT NULL REFERENCES users(id),
  kind          TEXT NOT NULL,  -- preview | lipsync | voiceover
  provider      TEXT,           -- gemini | elevenlabs | azure
  voice         TEXT,           -- provider voice id used
  language      TEXT,           -- ur | hi | en (spoken language)
  script_mode   TEXT,           -- native | roman (roman is transliterated server-side)
  style         TEXT,           -- narration | conversation | news | energetic | emotional
  speed         TEXT,           -- slow | normal | fast
  script_text   TEXT,           -- text actually synthesized (post-transliteration)
  char_count    INTEGER NOT NULL DEFAULT 0,
  audio_path    TEXT,           -- /files/voice/<file> when audio was produced
  generation_id INTEGER REFERENCES generations(id),
  status        TEXT NOT NULL DEFAULT 'completed', -- processing | completed | failed
  error         TEXT,
  created_at    TEXT NOT NULL DEFAULT (datetime('now'))
);
