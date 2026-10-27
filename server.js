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
import { randomUUID, randomBytes, randomInt, createSign, createHash, timingSafeEqual } from 'node:crypto';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite'; // built into Node 22.5+/24 — default DB driver (engine gate below can select libsql/Turso instead)
import ffmpegStatic from 'ffmpeg-static'; // pinned binary for clip joining

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const { FAL_KEY, JWT_SECRET, FRONTEND_ORIGIN } = process.env;
if (!FAL_KEY || !JWT_SECRET) {
  console.error('Missing FAL_KEY or JWT_SECRET in .env — see .env.example');
  process.exit(1);
}

// ---------- Public configuration (safe to expose via /api/config) ----------
// Generation rate card (owner pricing v9, 2026-10-23; credit scale x10
// per the owner's 2026-10-26 rescale, migration v23): credits are charged
// by the ROUTED quality of the job and its duration — there is no separate
// "4K costs double" rule anymore; each quality has its own row. Charged on
// submit, automatically refunded if the provider fails the job. Rupee
// prices are unchanged by the rescale; only credit amounts moved. The 4K
// row is 450/900 — the corrected rate (the pre-rescale 40/80, i.e. 400/800
// at the new scale, was loss-making at the cheapest pack's Rs 1.40/credit
// floor against the Kling O3 route's flat $0.42/s). The 768P / 2K rows are
// the owner's FINAL Kling-aligned rates (2026-10-26): matched to Kling's
// per-second deductions converted at the Rs 1.40/credit floor and verified
// no-loss on every row (768P 120/240, 2K 180/360).
const COST_BY_QUALITY = {
  '768P': { 5: 120, 10: 240, 20: 480 },
  '2K':   { 5: 180, 10: 360, 20: 720 },
  '4K':   { 5: 450, 10: 900 },
};
function generationCost(resolution, duration) {
  const table = COST_BY_QUALITY[resolution] || COST_BY_QUALITY['768P'];
  return table[Number(duration)] ?? COST_BY_QUALITY['768P'][Number(duration)] ?? 120;
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
  // Reference-to-video endpoint for saved characters (Phase C2). Schema
  // AND price verified against fal.ai's official llms.txt for this model
  // (2026-10-23): inputs are prompt (required; refer to the references in
  // the text as "Image 1", "Video 1", ...), reference_image_urls
  // (list<string> — up to 9 subject/style images; images + videos + audio
  // together at most 12 files), reference_video_urls, reference_audio_urls,
  // duration (integer 5-15), resolution (480P | 768P | 2K | 4K — 480P/768P
  // native, 2K/4K upscale a 768P base), aspect_ratio (adaptive | 21:9 |
  // 16:9 | 4:3 | 1:1 | 3:4 | 9:16), enable_safety_checker,
  // prompt_expansion_mode, seed; output is { video: { url },
  // expanded_prompt }. Price is the standard H3 table — $0.05/s at 480P,
  // $0.06/s at 768P, $0.13/s at 2K, $0.16/s at 4K — and the first 5
  // reference images are free (each additional image $0.08; a character
  // always sends exactly ONE image, so there is never an image fee).
  // Because the price matches the standard rate card exactly, character
  // generations are charged the standard rate with NO surcharge.
  modelRef: (process.env.FAL_MODEL_REF || 'minimax/h3/reference-to-video').trim(),
  resolution: process.env.FAL_RESOLUTION || '768P',
  aspectRatios: ['16:9', '9:16', '1:1', '4:3', '3:4', '21:9'],
  durations: [5, 10],                       // seconds in ONE provider call (fal H3 schema cap)
  // 20s (owner request, 2026-10-27): offered on the standard H3 routes
  // only, as an automatic TWO-PART generation (10s + a chained 10s
  // extension, joined server-side — migration v25). The speaking engine
  // (schema max 10s) and the native-4K Kling route never accept it;
  // both reject pre-charge in /api/generate. Seedance keeps its own set.
  durations20: [5, 10, 20],
  styles: ['realistic', 'cinematic', 'cartoon', 'anime'],
  // The full per-quality rate card (see COST_BY_QUALITY above).
  // costByDuration stays as the 768P row for backward compatibility.
  costByQuality: COST_BY_QUALITY,
  costByDuration: COST_BY_QUALITY['768P'],
  signupCredits: Number(process.env.SIGNUP_CREDITS || 1000),
  maxDailyCredits: Number(process.env.MAX_DAILY_CREDITS || 4000),
  // Bootstrap admin: the account with this email gets the admin flag
  // (at registration, at login, and for existing accounts at boot).
  adminEmail: (process.env.ADMIN_EMAIL || '').trim().toLowerCase(),
  // App version marker (Phase I): stamped onto every feedback report
  // server-side (the client cannot forge it) and shown in the app's
  // Settings footer via /api/config, so tester reports from the Play
  // closed test can be tied to the build they were using. Bump
  // APP_VERSION per release.
  appVersion: (process.env.APP_VERSION || '1.0').trim() || '1.0',
  // Base URL for server-side prompt translation (Google Translate "gtx" web
  // endpoint). Overridable via TRANSLATE_API_BASE — tests point it at a
  // local stub so the suite never calls the real endpoint. When the override
  // is set it is the ONLY provider used (test determinism).
  translateBase: (process.env.TRANSLATE_API_BASE || 'https://translate.googleapis.com').replace(/\/+$/, ''),
  translateBaseOverridden: !!process.env.TRANSLATE_API_BASE,
  // Contact email sent to the MyMemory translation API (its `de` parameter).
  // MyMemory's free quota is far higher when a contact email is provided;
  // without it, shared/datacenter IPs exhaust the anonymous quota quickly.
  translateEmail: (process.env.TRANSLATE_EMAIL || 'Shahidraja78866@gmail.com').trim(),
  // Manual payment destinations for credit-pack purchases, shown to buyers
  // on the Buy Credits page. Only the methods actually set in the
  // environment are exposed (via /api/config as payment_methods).
  paymentMethods: {
    ...((process.env.PAYMENT_EASYPAISA || '').trim() ? { easypaisa: process.env.PAYMENT_EASYPAISA.trim() } : {}),
    ...((process.env.PAYMENT_JAZZCASH || '').trim() ? { jazzcash: process.env.PAYMENT_JAZZCASH.trim() } : {}),
    ...((process.env.PAYMENT_BANK || '').trim() ? { bank: process.env.PAYMENT_BANK.trim() } : {}),
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
  // Phase O2: the user's own recorded voice files for lip-sync live here
  // (per-user subfolders), served at /files/audio/ so fal can fetch them —
  // the same public-URL pattern the synthesized TTS audio uses.
  audioUploadsDir: process.env.AUDIO_UPLOADS_DIR || path.join(__dirname, 'data', 'audio-uploads'),
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
  // Voice add-on rates (credits). Phase G (owner directive 2026-10-23,
  // point 5 — "audio included"): voiceover is 0 — voice/dialogue is part
  // of the single generation price, never a separate fee. Phase G2
  // (owner decision 2026-10-23): the standalone /api/voice/lipsync job
  // is included at 0 too — made sustainable by capping its script at
  // LIPSYNC_SCRIPT_MAX_CHARS (300 chars ≈ ≤20 s of speech → worst case
  // ≈ $1.92 on the image route at 768P, ≈ $0.23 on the video route —
  // absorbed by the Pro / Extra Pro subscription that gates the tool;
  // see the README sustainability table) plus a per-day fair-use cap
  // (lipsyncDailyCap below). The in-generation Auto Director lip-sync
  // route (<=300-char dialogue, LatentSync flat $0.20) is likewise
  // included at 0.
  lipsyncCost: 0,
  // Fair-use guard for the now-free standalone lip-sync tool: max
  // standalone lip-sync jobs per user per day (env-overridable).
  lipsyncDailyCap: Number(process.env.LIPSYNC_DAILY_CAP || 10),
  voiceoverCost: 0,
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
  // Sound add-on rates (credits). Phase G (owner directive 2026-10-23,
  // point 5 — "audio included"): every mode is 0 — sound effects, sync
  // and background music are part of the single generation price, never
  // a separate fee. Sustainability (prices verified from fal's own
  // pages; full table in README): the priciest step is premium sync at
  // $0.010/s promo ($0.015/s after 2026-12-13) = $0.15 for a 10 s clip;
  // sync $0.001/s, SFX $0.002/s, music $0.02/output-minute — every tier
  // clears its floor revenue. Plan GATES stay (premium sync is still
  // Pro/Extra-Pro only): feature tiers now, not prices.
  soundCosts: { sync: 0, premium_sync: 0, sfx: 0, music: 0 },
  // Master switch: SOUND_ENABLED=0 turns the whole sound system off (the
  // endpoints then fail closed with 503 and charge nothing). The engines
  // all ride the FAL_KEY, so no key also means not configured.
  soundEnabled: process.env.SOUND_ENABLED !== '0',
  // --- Finishers + draft workflow (Phase C1) -------------------------------
  // One-tap finishers run on a completed video (POST /api/finish/:action)
  // and always produce a NEW History entry linked to the source.
  // Whisper transcription on fal (schema verified against fal's llms.txt +
  // queue OpenAPI 2026-10-23): { audio_url (mp4 accepted), task, language,
  // chunk_level } -> { text, chunks: [{ timestamp: [start, end], text }] }.
  whisperModel: (process.env.FAL_WHISPER_MODEL || 'fal-ai/whisper').trim(),
  // Topaz video upscale on fal (verified against fal's llms.txt
  // 2026-10-23): fal-ai/topaz/upscale/video, { video_url, model,
  // upscale_factor } -> { video }. Documented price: $0.01/s for output up
  // to 720p, $0.02/s for output up to 1080p, $0.08/s above 1080p (60fps
  // output doubles it — we never request it). The credit price uses the
  // owner's formula: ceil(per-second USD x seconds x 277 / 1.5) x 2 margin,
  // minimum 100 credits. (The divisor tracks the Rs-per-credit floor: at
  // the x10 credit scale the cheapest credit is ~Rs 1.40, so /1.5 yields
  // the same rupee price the pre-rescale /15 formula produced.)
  upscaleModel: (process.env.FAL_UPSCALE_MODEL || 'fal-ai/topaz/upscale/video').trim(),
  upscaleTopazModel: (process.env.FAL_UPSCALE_TOPAZ_MODEL || 'Proteus').trim(),
  upscalePerSecondUsd: { to720: 0.01, to1080: 0.02, above1080: 0.08 },
  upscaleMinCredits: 100,
  upscaleFactor: 2,
  // Locked owner rates for the finishers (credits). Reframe is local
  // ffmpeg compute — free, like clip joining.
  captionsCost: 50,
  // Draft generations: quality "draft" routes 480P on the standard H3
  // model (480P is a documented H3 tier at $0.05/s) at a flat cheap rate.
  // Drafts take no sound/voice add-ons; the full-quality version is a
  // separate standard-rate generation (POST /api/generations/:id/upgrade).
  draftCost: { 5: 70, 10: 140, 20: 280 },
  // --- Advertising preparation (Google AdMob groundwork) ------------------
  // INERT until the owner has an AdMob account: ADS_ENABLED=1 AND a valid
  // ADMOB_PUBLISHER_ID (pub- followed by exactly 16 digits) must BOTH be
  // set before /api/config reports ads as enabled — anything missing or
  // malformed fails closed (no ad slots shown, /app-ads.txt answers 404).
  // ADMOB_APP_ADS_TXT may carry a full custom app-ads.txt line, served
  // verbatim instead of the generated one. The IDs are the OWNER's own
  // AdMob values, set only via the environment — never hardcoded. Real ad
  // rendering (native / interstitial / rewarded formats) arrives with the
  // Android app build and the AdMob SDK; the web side ships slots, policy
  // gating and the app-ads.txt endpoint only. Ads are FREE-tier only:
  // any active paid plan is ad-free (see ADS_SETUP.md).
  adsEnabled: process.env.ADS_ENABLED === '1',
  admobPublisherId: (process.env.ADMOB_PUBLISHER_ID || '').trim(),
  admobAppAdsTxt: (process.env.ADMOB_APP_ADS_TXT || '').trim(),
  // --- AI Auto Director (Phase D) -----------------------------------------
  // Deterministic, rule-based prompt analysis (NO external LLM call). The
  // plan endpoint is free and never creates a generation; /api/generate
  // only applies a confirmed plan after re-running the same analyzer and
  // recomputing every cost server-side. AUTO_DIRECTOR_ENABLED=0 turns the
  // config flag off; the analyzer itself remains available for the Studio.
  autoDirectorEnabled: process.env.AUTO_DIRECTOR_ENABLED !== '0',
  autoDirectorVersion: 1,
  // --- Speaking engine (Phase E: Gemini Omni Flash 1.1) -------------------
  // One-step talking-video engine on fal: the endpoint below generates the
  // video WITH synchronized native audio/dialogue from one prompt (fal tags
  // it "lipsync"). Schema verified against fal's own llms.txt for
  // google/gemini-omni-flash/v1.1/text-to-video (2026-10-23): the request
  // body has exactly four fields — prompt (string, required), aspect_ratio
  // ("16:9" | "9:16", default "16:9"), resolution ("360p" | "720p" |
  // "1080p" | "4k", default "720p") and duration (integer 3-10, default 8).
  // There is NO safety-checker or audio-toggle field, so none is sent.
  // Output is { video: File }. Prices (fal, per second of output): 360p
  // $0.03, 720p $0.10, 1080p $0.15, 4K $0.30 — a 10s clip at our routed
  // 720p costs $1.00 ≈ Rs 277, safely inside the flat 250-credit price
  // (floor revenue Rs 350 at the cheapest Rs 1.40/credit). Dialogue
  // languages are NOT stated by fal — Urdu speech on this engine is
  // UNVERIFIED and is never promised to users. This engine REPLACES the
  // Veo talking-clip route, which was never wired: Google is retiring
  // Veo 3.1 (preview IDs shut down 2026-10-22; GA IDs flagged for
  // retirement from 2026-11-17) and Omni is its designated successor on
  // fal. The plan entitlement keeps its historical flag name (can_veo);
  // it now gates THIS engine. Flat price: 250 credits (owner's final
  // Kling-aligned rate, 2026-10-26), for both our durations (5s and 10s).
  modelOmni: (process.env.FAL_MODEL_OMNI || 'google/gemini-omni-flash/v1.1/text-to-video').trim(),
  speakingCost: 250,
  speakingAspects: ['16:9', '9:16'],
  speakingResolution: '720p',
  // --- Premium engine (Phase J: Seedance 2.5) ------------------------------
  // ByteDance's top-ranked video model on fal, sold as an explicit,
  // user-chosen PREMIUM engine — the AI Auto Director NEVER routes to it
  // (premium price), and an echoed auto-plan claiming this route is
  // discarded by canonicalization like any other forged route. Schema
  // verified against fal's own llms.txt for
  // bytedance/seedance-2.5/text-to-video (2026-10-23): prompt (string,
  // required), resolution (enum "480p" | "720p" | "1080p", default
  // "720p"), duration (STRING enum "auto" | "4".."30", default "auto" —
  // strings, unlike the Omni integer), aspect_ratio (enum "auto" |
  // "21:9" | "16:9" | "4:3" | "1:1" | "3:4" | "9:16", default "auto"),
  // generate_audio (boolean, default true — synchronized native audio,
  // billed the same either way), plus draft / bitrate_mode / codec /
  // end_user_id, which are never sent. NOTE: the live schema DOES list
  // a 1080p resolution option (~$1.164/s) — the app still routes 720p
  // only, per the owner's pricing decision below. Output is
  // { video: File, seed }. HONESTY: this engine is NEVER 4K and is
  // never labelled or sold as 4K anywhere — BytePlus's own API caps
  // Seedance 2.5 at 1080p, and native 4K belongs to Seedance 2.0 and to
  // our Kling O3 route. Prices (fal, token-billed $0.0214 per 1K
  // tokens): ≈ $0.4730/s at 720p 16:9, ≈ $0.2205/s at 480p. Credit
  // price (owner decision): 600 (5s) / 1200 (10s). Sustainability at the
  // Rs 1.40/credit floor and Rs 277/$: worst case 10s @720p ≈ $4.73 ≈
  // Rs 1,310 vs floor revenue 1200 × Rs 1.40 = Rs 1,680 (~28% margin);
  // 5s ≈ $2.37 ≈ Rs 656 vs Rs 840.
  // Phase L extends the SAME linear rate — 120 credits per second — to
  // the longer durations the fal schema genuinely allows (4–30s; the
  // product offers 5/10/15/20/30): 15s = 1800, 20s = 2400, 30s = 3600.
  // Margin holds linearly: the 30s worst case ≈ 30 × $0.473 = $14.19
  // ≈ Rs 3,930 vs floor revenue 3600 × Rs 1.40 = Rs 5,040 (~28%). A 30s
  // job (3600) sits inside the 4000/day cap by design — the cap is NOT
  // raised for it. Gate: the can_seedance plan flag
  // (Extra Pro only). Dialogue languages are NOT stated by fal — Urdu
  // speech on this engine is UNVERIFIED and is never promised.
  modelSeedance: (process.env.FAL_MODEL_SEEDANCE || 'bytedance/seedance-2.5/text-to-video').trim(),
  seedanceCost: { 5: 600, 10: 1200, 15: 1800, 20: 2400, 30: 3600 },
  seedanceDurations: [5, 10, 15, 20, 30],
  seedanceAspects: ['16:9', '9:16', '1:1'],
  seedanceResolution: '720p',
  // --- Modern auth (Phase N: identity model, Google Sign-In, email flows) --
  // Owner spec documents 5+6 (2026-10-24). Every provider here is a
  // CONFIG-GATED, FAIL-CLOSED adapter in the PayFast/Azure pattern:
  // nothing is offered in the UI and every endpoint answers 503 until
  // the OWNER's own provider account is configured in the environment.
  //  - Google Sign-In activates only when GOOGLE_CLIENT_ID (the owner's
  //    own Google Cloud OAuth Web client id) is set. ID tokens are
  //    verified server-side against Google's tokeninfo endpoint;
  //    GOOGLE_TOKENINFO_BASE overrides the host (tests point it at a
  //    local stub — production must never set it).
  //  - The mailer activates only when MAILER_API_BASE + MAILER_API_KEY +
  //    MAILER_FROM are ALL set. It is a generic HTTPS email API adapter:
  //    POST {base}/send with a Bearer key and a JSON {from,to,subject,
  //    text} body. It powers email verification + password reset ONLY;
  //    while it is off, signup keeps its historical behaviour (verified
  //    at once, bonus at signup) so nobody is ever locked out of a
  //    feature that was never switched on.
  // SECURITY (owner's hard rules): verification/reset tokens are stored
  // SHA-256-HASHED only, are short-lived and single-use, and are never
  // logged; NO admin surface ever exposes a password hash or a token;
  // accounts are NEVER auto-merged on an email match — identities are
  // linked only by a signed-in user after provider verification.
  googleClientId: (process.env.GOOGLE_CLIENT_ID || '').trim(),
  googleTokeninfoBase: (process.env.GOOGLE_TOKENINFO_BASE || 'https://oauth2.googleapis.com').replace(/\/+$/, ''),
  mailer: {
    base: (process.env.MAILER_API_BASE || '').trim().replace(/\/+$/, ''),
    key: (process.env.MAILER_API_KEY || '').trim(),
    from: (process.env.MAILER_FROM || '').trim(),
  },
  // --- Facebook Login + phone SMS OTP (Phase N2, same fail-closed pattern) --
  //  - Facebook Login activates only when FACEBOOK_APP_ID AND
  //    FACEBOOK_APP_SECRET (the owner's own Meta app) are BOTH set.
  //    Access tokens are verified server-side with Graph's debug_token
  //    using the app access token (APP_ID|APP_SECRET). THE SECRET IS
  //    SERVER-SIDE ONLY: it never appears in /api/config, the frontend,
  //    error messages or logs — only the App ID (a public identifier,
  //    like the Google client id) is exposed, and only when configured.
  //    FB_GRAPH_BASE overrides the Graph host (tests point it at a
  //    local stub — production must never set it).
  //  - Phone OTP activates only when SMS_API_BASE + SMS_API_KEY +
  //    SMS_FROM are ALL set. The SMS adapter mirrors the mailer:
  //    POST {base}/send with a Bearer key and a JSON {to,from,message}
  //    body, on the OWNER's own SMS-provider account (per-SMS charges
  //    are the provider's, on that account). OTP codes are 6 digits,
  //    stored SHA-256-HASHED only (never logged, never in any admin
  //    surface), expire after OTP_TTL_MS (default 1 minute — the
  //    owner's decision, 2026-10-24; the 60-second resend cooldown below
  //    aligns with it exactly), allow
  //    at most 5 verification attempts, and sends are capped per phone
  //    (1/minute, 5/day) inside the handlers.
  facebookAppId: (process.env.FACEBOOK_APP_ID || '').trim(),
  facebookAppSecret: (process.env.FACEBOOK_APP_SECRET || '').trim(),
  fbGraphBase: (process.env.FB_GRAPH_BASE || 'https://graph.facebook.com').replace(/\/+$/, ''),
  sms: {
    base: (process.env.SMS_API_BASE || '').trim().replace(/\/+$/, ''),
    key: (process.env.SMS_API_KEY || '').trim(),
    from: (process.env.SMS_FROM || '').trim(),
  },
  otpTtlMs: Math.max(1000, Number(process.env.OTP_TTL_MS || 60 * 1000) || 60 * 1000),
  // TikTok Login Kit + X (Twitter) OAuth 2.0 (Phase P) — REDIRECT
  // flows, unlike the token-POST Google/Facebook adapters above:
  // the browser leaves for the provider and returns to this
  // server's callback, which verifies the code server-side and
  // hands the session to the app through a one-time SSO code.
  // Both are the OWNER's own developer apps and FAIL CLOSED:
  // nothing is offered and every endpoint answers 503 until BOTH
  // values of a pair are set. The client secrets are server-side
  // only — they appear in no config response, page or log (the
  // TikTok client key / X client id are public identifiers, but
  // the redirect flow never needs them in the page either, so
  // nothing is exposed at all).
  tiktokClientKey: (process.env.TIKTOK_CLIENT_KEY || '').trim(),
  tiktokClientSecret: (process.env.TIKTOK_CLIENT_SECRET || '').trim(),
  // Test-only overrides (test.sh points them at the local auth
  // stub); production values are TikTok's own hosts.
  tiktokAuthBase: (process.env.TIKTOK_AUTH_BASE || 'https://www.tiktok.com').trim().replace(/\/+$/, ''),
  tiktokApiBase: (process.env.TIKTOK_API_BASE || 'https://open.tiktokapis.com').trim().replace(/\/+$/, ''),
  twitterClientId: (process.env.TWITTER_CLIENT_ID || '').trim(),
  twitterClientSecret: (process.env.TWITTER_CLIENT_SECRET || '').trim(),
  twitterAuthBase: (process.env.TWITTER_AUTH_BASE || 'https://twitter.com').trim().replace(/\/+$/, ''),
  twitterApiBase: (process.env.TWITTER_API_BASE || 'https://api.twitter.com').trim().replace(/\/+$/, ''),
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

// ---------- Camera & shot controls (Phase L) ------------------------------
// Optional cinematic direction chosen with chips in the Studio. These
// are PROMPT DIRECTIVES, not model parameters: no engine in our wiring
// exposes a mechanical camera control, so the server appends a plain-
// English directive phrase to the prompt actually sent to the provider
// and records the choices on the generation row (migration v18 — the
// dedicated columns are used rather than the auto_plan JSON because
// camera/shot apply with AI Auto on OR off, while auto_plan exists only
// for confirmed Auto plans; inventing a plan for manual generations
// would misrepresent the record). The UI says exactly what these are:
// "Camera moves are prompt directions to the AI" — the model treats
// them as guidance, never as a guarantee. Keys are the wire format;
// `label` is the display name; `directive` is the phrase appended.
const CAMERA_MOVES = {
  zoom_in:   { label: 'Zoom In',       directive: 'slow cinematic zoom in' },
  zoom_out:  { label: 'Zoom Out',      directive: 'slow cinematic zoom out, gradually revealing the wider scene' },
  pan_left:  { label: 'Pan Left',      directive: 'smooth cinematic pan to the left' },
  pan_right: { label: 'Pan Right',     directive: 'smooth cinematic pan to the right' },
  tilt_up:   { label: 'Tilt Up',       directive: 'slow cinematic tilt up' },
  tilt_down: { label: 'Tilt Down',     directive: 'slow cinematic tilt down' },
  tracking:  { label: 'Tracking Shot', directive: 'cinematic tracking shot that follows the subject' },
  orbit:     { label: 'Orbit',         directive: 'slow cinematic orbit around the subject' },
  handheld:  { label: 'Handheld',      directive: 'natural handheld camera feel with subtle realistic movement' },
  static:    { label: 'Static',        directive: 'static locked-off camera with no camera movement' },
};
const SHOT_SIZES = {
  close_up: { label: 'Close-up',       directive: 'close-up shot' },
  medium:   { label: 'Medium Shot',    directive: 'medium shot' },
  wide:     { label: 'Wide Shot',      directive: 'wide establishing shot' },
  aerial:   { label: 'Aerial / Drone', directive: 'aerial drone shot' },
};
// The exact suffix appended to the effective prompt (after translation
// and after the Auto Director's own enrichment) — a leading ", " phrase
// list, e.g. ", slow cinematic zoom in, wide establishing shot".
// Deterministic from the recorded choices, so History can show the user
// precisely what was sent (the same transparency pattern as
// translated_prompt).
function cameraDirectiveSuffix(cameraMove, shotSize) {
  const parts = [];
  if (cameraMove && CAMERA_MOVES[cameraMove]) parts.push(CAMERA_MOVES[cameraMove].directive);
  if (shotSize && SHOT_SIZES[shotSize]) parts.push(SHOT_SIZES[shotSize].directive);
  return parts.length ? `, ${parts.join(', ')}` : '';
}
// Lightweight wording detection, used ONLY to note a contradiction: when
// the prompt text itself names a camera move / shot size that differs
// from the explicit chip, the chip wins (it is appended last, as the
// direct instruction) and the stored auto plan notes the override. No
// extra confirmation round — the note is the whole mechanism.
const CAMERA_TEXT_KEYS = [
  ['zoom_in', /\bzoom(?:ing)?\s+in\b/i], ['zoom_out', /\bzoom(?:ing)?\s+out\b/i],
  ['pan_left', /\bpan(?:ning)?\s+(?:to\s+the\s+)?left\b/i],
  ['pan_right', /\bpan(?:ning)?\s+(?:to\s+the\s+)?right\b/i],
  ['tilt_up', /\btilt(?:ing)?\s+up\b/i], ['tilt_down', /\btilt(?:ing)?\s+down\b/i],
  ['tracking', /\btracking\s+shot\b/i], ['orbit', /\borbit(?:ing)?\b/i],
  ['handheld', /\bhandheld\b/i],
  ['static', /\bstatic\s+(?:shot|camera)\b|\blocked[- ]off\b|\btripod\s+shot\b/i],
];
const SHOT_TEXT_KEYS = [
  ['close_up', /\bclose[- ]?up\b/i], ['medium', /\bmedium\s+shot\b/i],
  ['wide', /\bwide\s+(?:shot|angle)\b|\bestablishing\s+shot\b/i],
  ['aerial', /\baerial\s+(?:shot|view)\b|\bdrone\s+shot\b/i],
];
function promptCameraClash(text, cameraMove, shotSize) {
  const hay = String(text || '');
  const clashes = [];
  if (cameraMove) {
    const hit = CAMERA_TEXT_KEYS.find(([, re]) => re.test(hay));
    if (hit && hit[0] !== cameraMove) clashes.push('camera');
  }
  if (shotSize) {
    const hit = SHOT_TEXT_KEYS.find(([, re]) => re.test(hay));
    if (hit && hit[0] !== shotSize) clashes.push('shot');
  }
  return clashes.length ? clashes.join(' and ') : null;
}

// Translate a prompt to English via Google Translate's free web endpoint
// (client=gtx). The response is nested arrays: data[0] is the list of
// translated segments and each segment's [0] is its text — join them all.
// Throws on any HTTP error, malformed body, or empty result.
async function translateViaGtx(text, fromCode) {
  const url = `${CONFIG.translateBase}/translate_a/single?client=gtx&sl=${encodeURIComponent(fromCode)}&tl=en&dt=t&q=${encodeURIComponent(text)}`;
  const r = await fetch(url, { signal: AbortSignal.timeout(10000) });
  if (!r.ok) throw new Error(`translate returned ${r.status}`);
  const data = await r.json();
  const segments = Array.isArray(data?.[0]) ? data[0] : [];
  const out = segments.map(s => (Array.isArray(s) ? String(s[0] ?? '') : '')).join('').trim();
  if (!out) throw new Error('translate returned empty text');
  return out;
}

// MyMemory (free, no key). Rejects quota warnings and "echo" replies (the
// input returned unchanged, which happens for languages it cannot actually
// translate) so a fake success is never recorded as a translation.
async function translateViaMyMemory(text, fromCode) {
  const url = `https://api.mymemory.translated.net/get?q=${encodeURIComponent(text)}&langpair=${encodeURIComponent(fromCode)}%7Cen&de=${encodeURIComponent(CONFIG.translateEmail)}`;
  const r = await fetch(url, { signal: AbortSignal.timeout(10000) });
  if (!r.ok) throw new Error(`mymemory returned ${r.status}`);
  const data = await r.json();
  const out = String(data?.responseData?.translatedText || '').trim();
  if (!out || data?.quotaFinished) throw new Error('mymemory quota exhausted');
  if (/MYMEMORY WARNING|QUERY LENGTH LIMIT|NO QUERY SPECIFIED|INVALID/i.test(out)) throw new Error('mymemory returned a warning, not a translation');
  if (out === text.trim()) throw new Error('mymemory echoed the input (language not supported)');
  return out;
}

// Provider chain (production): MyMemory first — the free Google "gtx" web
// endpoint now refuses datacenter IPs (302 to a "sorry" page, verified live
// 2026-10-27, which silently broke ALL non-English prompts) — with the gtx
// endpoint kept as a fallback in case it answers again. When
// TRANSLATE_API_BASE is set (tests), only that endpoint is used.
async function translatePrompt(text, fromCode) {
  if (CONFIG.translateBaseOverridden) return translateViaGtx(text, fromCode);
  try { return await translateViaMyMemory(text, fromCode); }
  catch (e1) {
    try { return await translateViaGtx(text, fromCode); }
    catch (e2) { throw new Error(`all translation providers failed (${e1.message}; ${e2.message})`); }
  }
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
    credits_monthly: 0, price_weekly: 1800, credits_weekly: 800,
    quality: '768P', quality_label: '768P',      resolution: '768P', model: CONFIG.model,   sort_order: 0,
    can_veo: 0, can_lipsync: 0, can_seedance: 0,
    play_product_monthly: null, play_product_yearly: null, play_product_weekly: 'ajk_weekly' },
  { id: 'normal',   name: 'Normal',    price_monthly: 5600, price_yearly: 56000,
    credits_monthly: 4000, price_weekly: null, credits_weekly: null,
    quality: '768P', quality_label: '768P',      resolution: '768P', model: CONFIG.model,   sort_order: 1,
    can_veo: 0, can_lipsync: 0, can_seedance: 0,
    play_product_monthly: 'ajk_normal_monthly',   play_product_yearly: 'ajk_normal_yearly',   play_product_weekly: null },
  { id: 'pro',      name: 'Pro',       price_monthly: 9500, price_yearly: 95000,
    credits_monthly: 5000, price_weekly: null, credits_weekly: null,
    quality: '2K',   quality_label: '2K',        resolution: '2K',   model: CONFIG.model,   sort_order: 2,
    can_veo: 1, can_lipsync: 1, can_seedance: 0,
    play_product_monthly: 'ajk_pro_monthly',      play_product_yearly: 'ajk_pro_yearly',      play_product_weekly: null },
  { id: 'extrapro', name: 'Extra Pro', price_monthly: 14000, price_yearly: 140000,
    credits_monthly: 6000, price_weekly: null, credits_weekly: null,
    quality: '4K',   quality_label: 'Native 4K', resolution: '4K',   model: CONFIG.model4k, sort_order: 3,
    can_veo: 1, can_lipsync: 1, can_seedance: 1,
    play_product_monthly: 'ajk_extrapro_monthly', play_product_yearly: 'ajk_extrapro_yearly', play_product_weekly: null },
  // Fifth tier above Extra Pro (owner, 2026-10-26): same native-4K quality
  // and model route and all premium entitlements, more credits. Worst case
  // verified no-loss by the owner: 10,000 credits spent entirely on native
  // 4K = Rs 12,927 fal cost vs Rs 19,999 revenue. Existing databases gain
  // this row via migration v24 (fresh DBs seed it from here).
  { id: 'extrapremier', name: 'Extra Premier', price_monthly: 19999, price_yearly: 199990,
    credits_monthly: 10000, price_weekly: null, credits_weekly: null,
    quality: '4K',   quality_label: 'Native 4K', resolution: '4K',   model: CONFIG.model4k, sort_order: 4,
    can_veo: 1, can_lipsync: 1, can_seedance: 1,
    play_product_monthly: 'ajk_extrapremier_monthly', play_product_yearly: 'ajk_extrapremier_yearly', play_product_weekly: null },
];

// One-time credit packs (top-ups bought outside subscriptions). Seeded into
// the `credit_packs` table on first boot; afterwards editable in the admin
// panel — boot never overwrites an admin's edits.
const PACK_DEFAULTS = [
  { credits: 500,  price_pkr: 899,  sort_order: 1, play_product_id: 'credits_500' },
  { credits: 1000, price_pkr: 1499, sort_order: 2, play_product_id: 'credits_1000' },
  { credits: 2500, price_pkr: 3499, sort_order: 3, play_product_id: 'credits_2500' },
];
const PACK_METHODS = ['easypaisa', 'jazzcash', 'bank', 'other'];

// ---------- Database with migrations ----------
// Engine gate — three modes:
//  1. node   (default): built-in node:sqlite on a local file. The legacy
//     path; unchanged unless an operator opts in below.
//  2. libsql (DB_ENGINE=libsql): the `libsql` driver on the SAME local
//     file. Exists to prove driver compatibility (every query in this
//     file runs unchanged) with no network dependency.
//  3. turso  (TURSO_DATABASE_URL + TURSO_AUTH_TOKEN set): libsql embedded
//     replica — the local file is a synced replica of the hosted primary,
//     so accounts/credits/history survive hosts whose local disk is
//     ephemeral (Render free tier wipes the file on every deploy/restart,
//     which production hit repeatedly on 2026-10-27).
// Safety rule: a partially-configured Turso env, or Turso env combined
// with an explicit conflicting DB_ENGINE, is a FATAL boot error — the
// server must never silently fall back to an ephemeral local file when
// the operator asked for the hosted database.
const DB_FILE = process.env.DB_PATH || 'myvideoai.db';
const _tursoUrl = process.env.TURSO_DATABASE_URL || '';
const _tursoToken = process.env.TURSO_AUTH_TOKEN || '';
const _dbEngineEnv = (process.env.DB_ENGINE || '').trim().toLowerCase();
function dbConfigFatal(msg) {
  console.error(`FATAL database configuration: ${msg}`);
  process.exit(1);
}
if ((_tursoUrl && !_tursoToken) || (!_tursoUrl && _tursoToken))
  dbConfigFatal('TURSO_DATABASE_URL and TURSO_AUTH_TOKEN must be set together (exactly one was provided).');
if (_tursoUrl && _dbEngineEnv && _dbEngineEnv !== 'libsql')
  dbConfigFatal(`DB_ENGINE=${_dbEngineEnv} conflicts with TURSO_DATABASE_URL/TURSO_AUTH_TOKEN (Turso requires the libsql driver).`);
if (_dbEngineEnv && !['libsql', 'node', 'sqlite'].includes(_dbEngineEnv))
  dbConfigFatal(`unknown DB_ENGINE "${_dbEngineEnv}" (expected "libsql" or unset).`);
const DB_MODE = _tursoUrl ? 'turso' : (_dbEngineEnv === 'libsql' ? 'libsql' : 'node');
let db;
if (DB_MODE === 'node') {
  db = new DatabaseSync(DB_FILE);
} else {
  let LibsqlDatabase = null;
  try { LibsqlDatabase = (await import('libsql')).default; }
  catch (e) { dbConfigFatal(`DB mode "${DB_MODE}" selected but the "libsql" package could not be loaded: ${e.message}`); }
  // Compatibility shim: libsql (0.5.x) attaches an enumerable `_metadata`
  // property ({duration}) to rows returned by statement.get(), which
  // node:sqlite does not. Left in place it would leak into API responses
  // built directly from rows. The wrapper strips it so row shapes are
  // identical across engines; every other call passes straight through.
  const wrapLibsqlDb = (raw) => {
    const clean = (row) => {
      if (row && typeof row === 'object' && '_metadata' in row) delete row._metadata;
      return row;
    };
    return {
      prepare(sql) {
        const st = raw.prepare(sql);
        return {
          run: (...a) => st.run(...a),
          get: (...a) => clean(st.get(...a)),
          all: (...a) => st.all(...a).map(clean),
          iterate: (...a) => st.iterate(...a),
        };
      },
      exec: (sql) => raw.exec(sql),
      sync: () => raw.sync(),
      close: () => raw.close(),
    };
  };
  if (DB_MODE === 'turso') {
    try {
      db = wrapLibsqlDb(new LibsqlDatabase(DB_FILE, { syncUrl: _tursoUrl, authToken: _tursoToken, syncInterval: 60 }));
      // Pull the hosted state BEFORE migrations/seeding/listen so a fresh
      // ephemeral disk resumes from the primary instead of starting empty.
      await db.sync();
    } catch (e) {
      console.error(`FATAL: could not open/sync the Turso embedded replica (${_tursoUrl}): ${e.message}`);
      process.exit(1);
    }
    // Best-effort final push on shutdown so the last <syncInterval of
    // writes are not lost when the host replaces the instance.
    let _finalSyncStarted = false;
    const _finalSync = async (sig) => {
      if (_finalSyncStarted) { process.exit(0); }
      _finalSyncStarted = true;
      try { await Promise.race([db.sync(), new Promise(r => setTimeout(r, 5000))]); }
      catch (e) { console.error(`Final Turso sync on ${sig} failed: ${e.message}`); }
      process.exit(0);
    };
    process.on('SIGTERM', () => { _finalSync('SIGTERM'); });
    process.on('SIGINT', () => { _finalSync('SIGINT'); });
  } else {
    db = wrapLibsqlDb(new LibsqlDatabase(DB_FILE));
  }
}
console.log(`Database engine: ${DB_MODE} (file: ${DB_FILE})`);
// The embedded replica manages its own journal; WAL is a local-file mode.
if (DB_MODE !== 'turso') db.exec('PRAGMA journal_mode = WAL');
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
  // v12 — finishers + draft workflow (Phase C1): generations gain a stage
  // marker. 'final' is every normal generation; 'draft' is a cheap 480P
  // preview generation (quality "draft") that can later be upgraded to a
  // full-quality generation at the standard rate. Finisher outputs reuse
  // the existing kind column ('reframe' | 'captions' | 'extend' |
  // 'upscale') and source_generation_id — no further columns needed.
  { version: 12, up: `
    ALTER TABLE generations ADD COLUMN stage TEXT NOT NULL DEFAULT 'final';` },
  // v13 — character library (Phase C2): a user saves a character once —
  // a reference image (one of their own uploads) plus an optional bound
  // voice — and reuses it across generations and lip-sync jobs for a
  // consistent look. generations.character_id records which saved
  // character a job used (NULL for character-free jobs); the column is a
  // plain reference with no cascade, so deleting a character never
  // deletes or alters the generations made with it (History then simply
  // shows no character name for those rows).
  { version: 13, up: `
    CREATE TABLE IF NOT EXISTS characters (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id),
      name TEXT NOT NULL,
      image_path TEXT NOT NULL,
      voice_provider TEXT,
      voice_id TEXT,
      voice_language TEXT,
      voice_style TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    ALTER TABLE generations ADD COLUMN character_id INTEGER;` },
  // v14 — AI Auto Director (Phase D): generations gain the confirmed
  // auto-plan summary (JSON text; NULL when Auto was not used), plus the
  // bookkeeping for a generate-time voice route chosen by that plan.
  // auto_voice_status mirrors the sound bookkeeping: 'none' | 'pending' |
  // 'applied' | 'failed_refunded' (the video is still delivered and only
  // the voice add-on is refunded). auto_voice_cost keeps the voice portion
  // separate inside cost_credits so it can be refunded exactly once.
  { version: 14, up: `
    ALTER TABLE generations ADD COLUMN auto_plan TEXT;
    ALTER TABLE generations ADD COLUMN auto_voice_status TEXT NOT NULL DEFAULT 'none';
    ALTER TABLE generations ADD COLUMN auto_voice_cost INTEGER NOT NULL DEFAULT 0;` },
  // v15 — Phase G ("audio included" + negation respect): when a confirmed
  // Auto Director plan asks for a silent video (mute:true), the row tracks
  // the post-completion audio-strip step: 'none' | 'pending' | 'applied' |
  // 'failed' (the original is then delivered WITH an honest note in the
  // stored plan — never silently presented as silent).
  { version: 15, up: `
    ALTER TABLE generations ADD COLUMN mute_status TEXT NOT NULL DEFAULT 'none';` },
  // v16 — tester feedback (Phase I): in-app feedback reports for the
  // Play closed test. user_agent and app_version are captured by the
  // SERVER at submit time (never client-supplied), generation_id links
  // an optional History item the report is about, and status is the
  // owner's triage state ('open' | 'resolved').
  { version: 16, up: `
    CREATE TABLE IF NOT EXISTS feedback (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id),
      category TEXT NOT NULL DEFAULT 'other',
      message TEXT NOT NULL,
      generation_id INTEGER REFERENCES generations(id),
      app_version TEXT,
      user_agent TEXT,
      status TEXT NOT NULL DEFAULT 'open',
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );` },
  // v17 — premium engine entitlement (Phase J): plans gain can_seedance,
  // the gate for the Seedance 2.5 premium engine (Extra Pro only). Same
  // one-time, version-gated pattern as the v9 flags, so later admin
  // edits are respected; PLAN_DEFAULTS re-syncs the flag structurally
  // on every boot like can_veo/can_lipsync.
  { version: 17, up: `
    ALTER TABLE plans ADD COLUMN can_seedance INTEGER NOT NULL DEFAULT 0;
    UPDATE plans SET can_seedance = 1 WHERE id = 'extrapro';` },
  // v18 — cinematic camera/shot controls (Phase L): the user's chip
  // choices (whitelist keys from CAMERA_MOVES / SHOT_SIZES; NULL when
  // not chosen) are recorded on the generation row so History can show
  // exactly which prompt directives were appended. Dedicated columns —
  // not the auto_plan JSON — because the controls work with AI Auto on
  // or off, while auto_plan exists only for confirmed Auto plans.
  { version: 18, up: `
    ALTER TABLE generations ADD COLUMN camera_move TEXT;
    ALTER TABLE generations ADD COLUMN shot_size TEXT;` },
  // v19 — modern auth (Phase N): the identity model, hashed single-use
  // auth tokens, and the user columns the new flows need.
  //  - user_identities: one row per sign-in method bound to an account
  //    (provider 'password' | 'google' | 'facebook' | 'phone';
  //    provider_user_id is the email for password, Google's `sub`, etc).
  //    UNIQUE(provider, provider_user_id) makes an identity bindable to
  //    exactly ONE account — the database-level backstop for the
  //    no-auto-merge rule: an email match alone NEVER links accounts.
  //  - auth_tokens: email-verification + password-reset tokens, stored
  //    SHA-256-HASHED only (the raw token exists solely in the email
  //    link). expires_at is epoch MILLISECONDS (compared in JS);
  //    used_at is set when the token is consumed — single-use.
  //  - users.email_verified: 1 for ALL existing rows (grandfathered —
  //    owner spec doc 6: verification applies to NEW signups, and only
  //    while the mailer is configured).
  //  - users.token_version: carried in every JWT as `tv`; the auth
  //    middleware rejects a mismatch, so a password reset (or account
  //    change) immediately invalidates every previously issued session.
  //  - users.signup_bonus_granted: 1 for all existing rows (they were
  //    granted at signup under the historical flow). New flows grant
  //    the bonus through grantSignupBonus(), which flips this flag in
  //    the same transaction — exactly once per account, whichever
  //    sign-in method created it.
  //  - Backfill: every existing user gets their 'password' identity
  //    row (provider_user_id = their email).
  { version: 19, up: `
    CREATE TABLE IF NOT EXISTS user_identities (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id),
      provider TEXT NOT NULL,
      provider_user_id TEXT NOT NULL,
      email TEXT,
      phone TEXT,
      verified INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(provider, provider_user_id)
    );
    CREATE TABLE IF NOT EXISTS auth_tokens (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id),
      purpose TEXT NOT NULL,
      token_hash TEXT NOT NULL UNIQUE,
      expires_at INTEGER NOT NULL,
      used_at TEXT,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    ALTER TABLE users ADD COLUMN email_verified INTEGER NOT NULL DEFAULT 0;
    UPDATE users SET email_verified = 1;
    ALTER TABLE users ADD COLUMN token_version INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE users ADD COLUMN signup_bonus_granted INTEGER NOT NULL DEFAULT 0;
    UPDATE users SET signup_bonus_granted = 1;
    INSERT OR IGNORE INTO user_identities (user_id, provider, provider_user_id, email, verified)
      SELECT id, 'password', email, email, 1 FROM users;` },
  // v20 — phone SMS OTP (Phase N2): one row per issued code. Mirrors the
  // auth_tokens discipline: code_hash is the SHA-256 of "phone:code" —
  // the raw 6-digit code exists only in the SMS itself and is never
  // stored or logged. expires_at / created_at are epoch MILLISECONDS
  // (the send-rate windows — 1/minute, 5/day — need sub-minute
  // precision). attempts counts verification tries (the code burns at
  // 5); used_at marks the code consumed, superseded or burned.
  // purpose separates login codes (user_id NULL) from account-linking
  // codes (user_id = the signed-in requester — a link code verifies
  // ONLY for the account that asked for it).
  { version: 20, up: `
    CREATE TABLE IF NOT EXISTS phone_otps (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      phone TEXT NOT NULL,
      code_hash TEXT NOT NULL,
      purpose TEXT NOT NULL DEFAULT 'login',
      user_id INTEGER,
      expires_at INTEGER NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      used_at INTEGER,
      created_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_phone_otps_phone ON phone_otps(phone, purpose, id);` },
  // v21 — own-voice audio uploads (Phase O2): one row per audio file a
  // user uploaded to drive lip-sync with their own recording (instead of
  // a synthesized TTS voice). The file itself lives on disk under
  // CONFIG.audioUploadsDir/<user_id>/<file_name> and is served at
  // /files/audio/<user_id>/<file_name> — the public URL fal fetches,
  // mirroring how TTS audio is hosted. duration_seconds is probed with
  // ffmpeg at upload time (files over 60s are rejected before any row is
  // written); content_type is the SNIFFED type, never the claimed one.
  { version: 21, up: `
    CREATE TABLE IF NOT EXISTS audio_uploads (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES users(id),
      file_name TEXT NOT NULL,
      content_type TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      duration_seconds REAL,
      created_at TEXT NOT NULL DEFAULT (datetime('now'))
    );
    CREATE INDEX IF NOT EXISTS idx_audio_uploads_user ON audio_uploads(user_id, id);` },
  // v22 — OAuth 2.0 redirect sign-in state (Phase P: TikTok + X).
  // Unlike Google/Facebook (the client posts a token the server
  // verifies), TikTok and X are redirect flows: the server mints a
  // random `state`, stores it here, and the provider callback must
  // present it back. A state is single-use (used_at stamped on
  // consume), expires 10 minutes after creation, and is bound to ONE
  // provider and ONE purpose ('login' | 'link'); link states also
  // carry the signed-in user they were minted for, and X states
  // carry the PKCE code_verifier whose S256 challenge was sent to
  // the authorize endpoint. Times are epoch ms — the same clock as
  // auth_tokens / phone_otps.
  { version: 22, up: `
    CREATE TABLE IF NOT EXISTS oauth_states (
      state TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      purpose TEXT NOT NULL DEFAULT 'login',
      user_id INTEGER REFERENCES users(id),
      code_verifier TEXT,
      created_at INTEGER NOT NULL,
      expires_at INTEGER NOT NULL,
      used_at INTEGER
    );` },
  // v23 — credit rescale x10 (owner decision 2026-10-26, the "Kling
  // model": big credit numbers at the SAME rupee prices, so a plan reads
  // 4,000 credits instead of 400). Every stored credit amount is
  // multiplied by 10 exactly once (version-gated): user balances (the
  // credits total and both buckets, plus credit_deficit, which is a
  // balance owed back), the plans' grant amounts (credits_monthly /
  // credits_weekly — NULL weekly columns stay NULL) and the credit
  // packs' amounts; a pack's play_product_id is kept on the default
  // 'credits_<n>' convention ONLY where it still follows that pattern
  // (an admin's custom id is never rewritten). PENDING pack purchases
  // carry the credit snapshot the approval grant uses verbatim, so
  // pending snapshots rescale too; approved/rejected purchase rows and
  // generations' recorded costs are history and stay untouched. The
  // code-side rates (rate card, speaking/draft/seedance/captions,
  // signup bonus, daily cap) moved x10 in the same release; the 4K rate
  // becomes the corrected 450/900 rather than a straight x10 of the
  // loss-making 40/80.
  { version: 23, up: `
    UPDATE users SET credits = credits * 10,
      free_credits = free_credits * 10,
      plan_credits = plan_credits * 10,
      credit_deficit = credit_deficit * 10;
    UPDATE plans SET credits_monthly = credits_monthly * 10,
      credits_weekly = credits_weekly * 10;
    UPDATE credit_packs SET play_product_id = 'credits_' || (credits * 10)
      WHERE play_product_id = 'credits_' || credits;
    UPDATE credit_packs SET credits = credits * 10;
    UPDATE pack_purchases SET credits = credits * 10 WHERE status = 'pending';` },
  // v24 — fifth plan tier "Extra Premier" (owner, 2026-10-26). INSERT OR
  // IGNORE, version-gated like the v9/v17 one-time inserts: an existing
  // database gains the row exactly once, and if the row already exists
  // (admin-created or edited) it is left completely untouched. The boot
  // seed loop afterwards re-syncs only structural fields from
  // PLAN_DEFAULTS. Runs AFTER v23, so the inserted 10,000 credits are
  // already at the rescaled scale — never multiplied.
  { version: 24, up: `
    INSERT OR IGNORE INTO plans (id, name, price_monthly, price_yearly, credits_monthly,
                quality, quality_label, resolution, model, sort_order,
                play_product_monthly, play_product_yearly,
                price_weekly, credits_weekly, play_product_weekly, can_veo, can_lipsync, can_seedance)
    VALUES ('extrapremier', 'Extra Premier', 19999, 199990, 10000,
            '4K', 'Native 4K', '4K', 'fal-ai/kling-video/o3/4k/text-to-video', 4,
            'ajk_extrapremier_monthly', 'ajk_extrapremier_yearly',
            NULL, NULL, NULL, 1, 1, 1);` },
  // v25 — 20-second videos (owner request, 2026-10-27): the two-part
  // chain marker + the user-visible settle note on generations.
  // chain_stage is NULL for every ordinary job; a 20s H3 job is born
  // 'part1', flips to 'extending' when part 1 completes and the chain
  // runs, and settles 'done' exactly once (joined 20s success, or
  // part-1 delivered at 10s with the second half refunded + chain_note).
  { version: 25, up: `
    ALTER TABLE generations ADD COLUMN chain_stage TEXT;
    ALTER TABLE generations ADD COLUMN chain_note TEXT;` },
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
                price_weekly, credits_weekly, play_product_weekly, can_veo, can_lipsync, can_seedance)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(p.id, p.name, p.price_monthly, p.price_yearly, p.credits_monthly,
           p.quality, p.quality_label, p.resolution, p.model, p.sort_order,
           p.play_product_monthly, p.play_product_yearly,
           p.price_weekly, p.credits_weekly, p.play_product_weekly,
           p.can_veo, p.can_lipsync, p.can_seedance);
  } else {
    // Play product ids are backfilled only when unset (COALESCE) — an
    // admin's edits in the Admin Panel always win over these defaults.
    // Feature flags are structural (they define the tier) and re-sync
    // like quality/model; prices and credit amounts never re-sync.
    db.prepare(`UPDATE plans SET name = ?, quality = ?, quality_label = ?,
                resolution = ?, model = ?, sort_order = ?,
                can_veo = ?, can_lipsync = ?, can_seedance = ?,
                play_product_monthly = COALESCE(play_product_monthly, ?),
                play_product_yearly = COALESCE(play_product_yearly, ?),
                play_product_weekly = COALESCE(play_product_weekly, ?) WHERE id = ?`)
      .run(p.name, p.quality, p.quality_label, p.resolution, p.model, p.sort_order,
           p.can_veo, p.can_lipsync, p.can_seedance,
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
    // (the talking-character engine, Phase B). can_veo gates the one-step
    // speaking-video engine (Phase E, Gemini Omni — it replaced the
    // never-wired Veo route; the flag keeps its historical name).
    // can_seedance gates the Seedance 2.5 premium engine (Phase J,
    // Extra Pro only). max_quality is the plan's routed quality ceiling.
    features: { can_veo: !!p.can_veo, can_lipsync: !!p.can_lipsync,
      can_seedance: !!p.can_seedance,
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
// JSON bodies are capped at 100kb — except the image/audio upload routes,
// whose base64 payloads need their own larger parsers (mounted on the
// routes; the global parser is skipped for those exact paths).
const jsonParser = express.json({ limit: '100kb' });
app.use((req, res, next) => (req.path === '/api/uploads/image' || req.path === '/api/uploads/audio') ? next() : jsonParser(req, res, next));
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
// Finishers mix local ffmpeg work and paid provider calls — limited per
// signed-in user like the sound endpoints.
const finishLimiter = rateLimit({ windowMs: 60 * 60 * 1000, max: 30,
  keyGenerator: (req) => String(req.user?.id || req.ip),
  message: { error: 'Rate limit: max 30 finisher requests per hour.' } });
// Feedback reports (Phase I): testers file them from inside the app —
// a tight per-user cap keeps the Admin Panel inbox meaningful.
const feedbackLimiter = rateLimit({ windowMs: 60 * 60 * 1000, max: 10,
  keyGenerator: (req) => String(req.user?.id || req.ip),
  message: { error: 'Rate limit: max 10 feedback reports per hour.' } });

// ---------- Modern auth (Phase N): adapters, tokens, identities ----------
// Verification / password-reset emails send through the mailer adapter
// and Google sign-in attempts hit Google — both get their own per-IP
// limiters on top of the per-account limits inside the handlers.
const authMailLimiter = rateLimit({ windowMs: 60 * 60 * 1000, max: 20,
  message: { error: 'Rate limit: too many email requests — please try again later.' } });
const googleAuthLimiter = rateLimit({ windowMs: 60 * 60 * 1000, max: 60,
  message: { error: 'Rate limit: too many sign-in attempts — please try again later.' } });

function mailerConfigured() {
  return !!(CONFIG.mailer.base && CONFIG.mailer.key && CONFIG.mailer.from);
}
function googleAuthConfigured() { return !!CONFIG.googleClientId; }

// Generic HTTPS email-API adapter (see the Phase N CONFIG note):
// POST {MAILER_API_BASE}/send with a Bearer key and a JSON body.
// Throws on any non-2xx so callers fail honestly; error messages never
// include the email's contents (which may carry a secret token link).
async function sendMail({ to, subject, text }) {
  const r = await fetch(`${CONFIG.mailer.base}/send`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json',
               Authorization: `Bearer ${CONFIG.mailer.key}` },
    body: JSON.stringify({ from: CONFIG.mailer.from, to, subject, text }),
    signal: AbortSignal.timeout(15000),
  });
  if (!r.ok) throw Object.assign(new Error(`MAILER_${r.status}`), { status: 502 });
  return true;
}

// Auth tokens (email verification, password reset): the RAW token is a
// 256-bit random value that exists only in the emailed link; the DB
// stores its SHA-256 hash. Issuing a fresh token supersedes every
// still-unused token of the same purpose for that user (a resend kills
// the previous link). Consuming is single-use and expiry-checked.
function sha256Hex(s) { return createHash('sha256').update(String(s)).digest('hex'); }
function issueAuthToken(userId, purpose, ttlMs) {
  db.prepare('DELETE FROM auth_tokens WHERE user_id = ? AND purpose = ? AND used_at IS NULL')
    .run(userId, purpose);
  const raw = randomBytes(32).toString('hex');
  db.prepare('INSERT INTO auth_tokens (user_id, purpose, token_hash, expires_at) VALUES (?, ?, ?, ?)')
    .run(userId, purpose, sha256Hex(raw), Date.now() + ttlMs);
  return raw;
}
function consumeAuthToken(raw, purpose) {
  if (!raw || typeof raw !== 'string') return null;
  const row = db.prepare('SELECT * FROM auth_tokens WHERE token_hash = ? AND purpose = ?')
    .get(sha256Hex(raw), purpose);
  if (!row || row.used_at || Number(row.expires_at) <= Date.now()) return null;
  db.prepare("UPDATE auth_tokens SET used_at = datetime('now') WHERE id = ?").run(row.id);
  return row;
}

// The signup bonus lands EXACTLY ONCE per account, whichever sign-in
// method created it (password signup, email verification, Google). The
// users.signup_bonus_granted flag flips in the same transaction as the
// grant, so concurrent first sign-ins cannot double it.
function grantSignupBonus(userId) {
  return tx(() => {
    const u = db.prepare('SELECT signup_bonus_granted FROM users WHERE id = ?').get(userId);
    if (!u || u.signup_bonus_granted) return false;
    db.prepare(`UPDATE users SET credits = credits + ?, free_credits = free_credits + ?,
      signup_bonus_granted = 1 WHERE id = ?`)
      .run(CONFIG.signupCredits, CONFIG.signupCredits, userId);
    return true;
  });
}

// Every session JWT carries the user's token_version as `tv` (Phase N).
function signUserToken(user) {
  return jwt.sign({ id: user.id, email: user.email, tv: Number(user.token_version || 0) },
    JWT_SECRET, { expiresIn: '7d' });
}

// Verifies a Google ID token server-side via Google's tokeninfo
// endpoint, validating audience, issuer, expiry and verified email
// exactly as Google prescribes. Returns the normalized profile, or
// null for ANY failure (network, wrong audience, expired, unverified).
async function verifyGoogleIdToken(idToken) {
  if (!idToken || typeof idToken !== 'string') return null;
  let data;
  try {
    const r = await fetch(
      `${CONFIG.googleTokeninfoBase}/tokeninfo?id_token=${encodeURIComponent(idToken)}`,
      { signal: AbortSignal.timeout(15000) });
    if (!r.ok) return null;
    data = await r.json();
  } catch { return null; }
  if (!data || data.aud !== CONFIG.googleClientId) return null;
  if (!['accounts.google.com', 'https://accounts.google.com'].includes(data.iss)) return null;
  if (!data.exp || Number(data.exp) * 1000 <= Date.now()) return null;
  if (String(data.email_verified) !== 'true') return null;
  if (!data.sub || !data.email) return null;
  return { sub: String(data.sub), email: String(data.email).toLowerCase(),
           name: data.name ? String(data.name) : null,
           picture: data.picture ? String(data.picture) : null };
}

// The two transactional emails. Links point at the app with the raw
// token in the query string (the frontend exchanges it immediately and
// strips it from the URL); the base is PUBLIC_BASE_URL when set, else
// the request's own origin — the same derivation the gateway uses.
function sendVerificationEmail(req, to, raw) {
  const base = CONFIG.publicBaseUrl || `${req.protocol}://${req.get('host')}`;
  return sendMail({ to, subject: 'Verify your AJK AI email',
    text: `Welcome to AJK AI — Your Imagination. AI Motion.\n\nConfirm this email address to activate your account and receive your ${CONFIG.signupCredits} free starter credits:\n\n${base}/?verify=${raw}\n\nThis link expires in 24 hours and works once.\nIf you did not create this account, you can ignore this email.` });
}
function sendResetEmail(req, to, raw) {
  const base = CONFIG.publicBaseUrl || `${req.protocol}://${req.get('host')}`;
  return sendMail({ to, subject: 'Reset your AJK AI password',
    text: `You asked to reset your AJK AI password.\n\nSet a new password with this link (it expires in 60 minutes and works once):\n\n${base}/?reset=${raw}\n\nIf you did not ask for this, ignore this email — your password is unchanged.` });
}

// The caller's linked sign-in methods, whitelisted for API responses
// (identity rows carry no secrets, but the shape is fixed here anyway).
function userProviders(userId) {
  return db.prepare(`SELECT provider, email, phone, verified, created_at
    FROM user_identities WHERE user_id = ? ORDER BY id`).all(userId);
}

// ---------- Facebook Login + phone OTP (Phase N2, config-gated) ----------
const socialAuthLimiter = rateLimit({ windowMs: 60 * 60 * 1000, max: 60,
  message: { error: 'Rate limit: too many sign-in attempts — please try again later.' } });
const phoneStartLimiter = rateLimit({ windowMs: 60 * 60 * 1000, max: 30,
  message: { error: 'Rate limit: too many code requests — please try again later.' } });

function facebookAuthConfigured() {
  return !!(CONFIG.facebookAppId && CONFIG.facebookAppSecret);
}
function smsConfigured() {
  return !!(CONFIG.sms.base && CONFIG.sms.key && CONFIG.sms.from);
}

// ---------- Phase P: TikTok + X redirect OAuth 2.0 ----------
// Both providers are authorization-code REDIRECT flows (no in-page
// SDK like Google/Facebook): GET /api/auth/<provider>/start mints a
// state row and 302s the browser to the provider; the provider
// returns the browser to /api/auth/<provider>/callback, which
// consumes the state, exchanges the code server-side, fetches the
// provider profile and then hands the resulting session to the app
// through the one-time `sso` code below (the callback is a plain
// browser navigation, so it cannot return a JSON JWT directly).
function tiktokAuthConfigured() {
  return !!(CONFIG.tiktokClientKey && CONFIG.tiktokClientSecret);
}
function twitterAuthConfigured() {
  return !!(CONFIG.twitterClientId && CONFIG.twitterClientSecret);
}

// Mint a state row (migration v22). 10-minute expiry, single-use;
// `purpose` is 'login' or 'link' (link rows carry the caller's user
// id); `codeVerifier` is set only for X (PKCE).
function createOAuthState(provider, purpose, userId, codeVerifier) {
  const state = randomBytes(32).toString('hex');
  const now = Date.now();
  db.prepare(`INSERT INTO oauth_states (state, provider, purpose, user_id, code_verifier, created_at, expires_at, used_at)
              VALUES (?, ?, ?, ?, ?, ?, ?, NULL)`)
    .run(state, provider, purpose, userId || null, codeVerifier || null, now, now + 10 * 60 * 1000);
  return state;
}

// Consume a state presented by a provider callback. Returns the row
// or null — a state is rejected when unknown, minted for a
// DIFFERENT provider, already used, or expired; on success it is
// stamped used so it can never be replayed.
function consumeOAuthState(state, provider) {
  if (!state || typeof state !== 'string') return null;
  const row = db.prepare('SELECT * FROM oauth_states WHERE state = ?').get(state);
  if (!row || row.provider !== provider) return null;
  if (row.used_at) return null;
  if (Date.now() > row.expires_at) return null;
  db.prepare('UPDATE oauth_states SET used_at = ? WHERE state = ?').run(Date.now(), state);
  return row;
}

// The SSO handoff: after a successful callback the server cannot
// hand a JWT to a browser redirect, so it mints a ONE-TIME code —
// stored SHA-256-hashed in auth_tokens with purpose 'sso', exactly
// like the verify/reset tokens — and redirects to /?sso=<code>.
// The app exchanges it via POST /api/auth/sso/exchange for the
// usual session payload. 5-minute life, single-use.
function issueSsoRedirect(userId, created) {
  const code = issueAuthToken(userId, 'sso', 5 * 60 * 1000);
  const base = (CONFIG.publicBaseUrl || '').replace(/\/+$/, '');
  return `${base}/?sso=${encodeURIComponent(code)}${created ? '&created=1' : ''}`;
}

// The public origin a provider callback must target. PUBLIC_BASE_URL
// is authoritative when set (it is what the owner registers in the
// provider's developer console); the request origin is the fallback
// for local runs.
function oauthCallbackOrigin(req) {
  if (CONFIG.publicBaseUrl) return CONFIG.publicBaseUrl;
  return `${req.protocol}://${req.get('host')}`;
}

// Shared callback tail for both redirect providers. `stateRow` is
// the already-consumed oauth_states row; `profile` is the VERIFIED
// provider profile { provider, providerUserId, email }. Link
// callbacks bind the identity to the user the state was minted for
// (409 semantics mirror link/google + link/facebook: an identity
// owned by another account is never moved); login callbacks run
// the shared socialLoginOrCreate (no auto-merge, bonus once) and
// finish with the SSO handoff redirect.
async function completeOAuthCallback(req, res, stateRow, profile) {
  if (stateRow.purpose === 'link') {
    const user = db.prepare('SELECT id FROM users WHERE id = ?').get(stateRow.user_id);
    if (!user) return res.redirect('/?auth_error=link_failed');
    const existing = db.prepare('SELECT user_id FROM user_identities WHERE provider = ? AND provider_user_id = ?')
      .get(profile.provider, profile.providerUserId);
    if (existing && Number(existing.user_id) !== Number(user.id)) {
      return res.redirect('/?auth_error=identity_in_use');
    }
    if (!existing) {
      db.prepare(`INSERT INTO user_identities (user_id, provider, provider_user_id, email, phone, verified)
                  VALUES (?, ?, ?, ?, ?, 1)`)
        .run(user.id, profile.provider, profile.providerUserId, profile.email || null, null);
    }
    return res.redirect(`/?linked=${profile.provider}`);
  }
  const result = await socialLoginOrCreate({
    provider: profile.provider,
    providerUserId: profile.providerUserId,
    email: profile.email,
    accountEmailVerified: !!profile.email,
  });
  if (!result.body || !result.body.token) return res.redirect('/?auth_error=login_failed');
  const identity = db.prepare('SELECT user_id FROM user_identities WHERE provider = ? AND provider_user_id = ?')
    .get(profile.provider, profile.providerUserId);
  if (!identity) return res.redirect('/?auth_error=login_failed');
  return res.redirect(issueSsoRedirect(identity.user_id, result.status === 201));
}

// TikTok (Login Kit): exchange the authorization code, then read
// the profile. TikTok returns NO email on the basic scope — the
// account is keyed on open_id alone, which the identity model
// already supports (Facebook's no-email path proved it).
async function exchangeTikTokCode(code, redirectUri) {
  const form = new URLSearchParams({
    client_key: CONFIG.tiktokClientKey,
    client_secret: CONFIG.tiktokClientSecret,
    code,
    grant_type: 'authorization_code',
    redirect_uri: redirectUri,
  });
  const resp = await fetch(`${CONFIG.tiktokApiBase}/v2/oauth/token/`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: form.toString(),
  });
  const data = await resp.json().catch(() => null);
  if (!resp.ok || !data || !data.access_token) throw new Error('TikTok token exchange failed');
  return data;
}
async function fetchTikTokUser(accessToken) {
  const resp = await fetch(`${CONFIG.tiktokApiBase}/v2/user/info/?fields=open_id,display_name`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const data = await resp.json().catch(() => null);
  const user = data && data.data && data.data.user;
  if (!resp.ok || !user || !user.open_id) throw new Error('TikTok user info failed');
  return user;
}
function tiktokAuthorizeUrl(redirectUri, state) {
  const u = new URL(`${CONFIG.tiktokAuthBase}/v2/auth/authorize/`);
  u.searchParams.set('client_key', CONFIG.tiktokClientKey);
  u.searchParams.set('scope', 'user.info.basic');
  u.searchParams.set('response_type', 'code');
  u.searchParams.set('redirect_uri', redirectUri);
  u.searchParams.set('state', state);
  return u.toString();
}

// X (Twitter): OAuth 2.0 with PKCE for a confidential client — the
// token call authenticates with HTTP Basic (client id + secret)
// AND proves possession of the code_verifier whose S256 challenge
// went to the authorize endpoint.
function pkceChallengeS256(verifier) {
  return createHash('sha256').update(verifier).digest('base64url');
}
function twitterAuthorizeUrl(redirectUri, state, codeVerifier) {
  const u = new URL(`${CONFIG.twitterAuthBase}/i/oauth2/authorize`);
  u.searchParams.set('response_type', 'code');
  u.searchParams.set('client_id', CONFIG.twitterClientId);
  u.searchParams.set('redirect_uri', redirectUri);
  u.searchParams.set('scope', 'users.read tweet.read');
  u.searchParams.set('state', state);
  u.searchParams.set('code_challenge', pkceChallengeS256(codeVerifier));
  u.searchParams.set('code_challenge_method', 'S256');
  return u.toString();
}
async function exchangeTwitterCode(code, redirectUri, codeVerifier) {
  const basic = Buffer.from(`${CONFIG.twitterClientId}:${CONFIG.twitterClientSecret}`).toString('base64');
  const form = new URLSearchParams({
    grant_type: 'authorization_code',
    code,
    redirect_uri: redirectUri,
    code_verifier: codeVerifier,
  });
  const resp = await fetch(`${CONFIG.twitterApiBase}/2/oauth2/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', Authorization: `Basic ${basic}` },
    body: form.toString(),
  });
  const data = await resp.json().catch(() => null);
  if (!resp.ok || !data || !data.access_token) throw new Error('X token exchange failed');
  return data;
}
async function fetchTwitterUser(accessToken) {
  const resp = await fetch(`${CONFIG.twitterApiBase}/2/users/me`, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  const data = await resp.json().catch(() => null);
  const me = data && data.data;
  if (!resp.ok || !me || !me.id) throw new Error('X user lookup failed');
  return me;
}

// Generic HTTPS SMS-API adapter (the mailer pattern): POST
// {SMS_API_BASE}/send with a Bearer key and a JSON {to,from,message}
// body. Throws on any non-2xx so callers fail honestly.
async function sendSms({ to, message }) {
  const r = await fetch(`${CONFIG.sms.base}/send`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json',
               Authorization: `Bearer ${CONFIG.sms.key}` },
    body: JSON.stringify({ from: CONFIG.sms.from, to, message }),
    signal: AbortSignal.timeout(15000),
  });
  if (!r.ok) throw Object.assign(new Error(`SMS_${r.status}`), { status: 502 });
  return true;
}

// Verifies a Facebook user access token server-side exactly as Meta
// prescribes: debug_token (with the app access token APP_ID|APP_SECRET)
// must say the token is valid AND was minted for THIS app; /me must
// then answer for the very same user id. The email is OPTIONAL in
// Facebook's world (the user can decline that permission) — a missing
// email is not a failure. Returns the profile, or null for ANY failure.
// The app secret is used only inside the debug_token call and is never
// returned, logged or exposed.
async function verifyFacebookAccessToken(accessToken) {
  if (!accessToken || typeof accessToken !== 'string') return null;
  const appToken = `${CONFIG.facebookAppId}|${CONFIG.facebookAppSecret}`;
  let dbg;
  try {
    const r = await fetch(
      `${CONFIG.fbGraphBase}/debug_token?input_token=${encodeURIComponent(accessToken)}&access_token=${encodeURIComponent(appToken)}`,
      { signal: AbortSignal.timeout(15000) });
    if (!r.ok) return null;
    dbg = await r.json();
  } catch { return null; }
  const d = dbg && dbg.data;
  if (!d || d.is_valid !== true || String(d.app_id) !== CONFIG.facebookAppId || !d.user_id)
    return null;
  let me;
  try {
    const r = await fetch(
      `${CONFIG.fbGraphBase}/me?fields=id,name,email,picture&access_token=${encodeURIComponent(accessToken)}`,
      { signal: AbortSignal.timeout(15000) });
    if (!r.ok) return null;
    me = await r.json();
  } catch { return null; }
  if (!me || String(me.id) !== String(d.user_id)) return null;
  return { id: String(me.id),
           email: me.email ? String(me.email).toLowerCase() : null,
           name: me.name ? String(me.name) : null,
           picture: me.picture && me.picture.data ? String(me.picture.data.url || '') || null : null };
}

// The shared tail of a provider sign-in (Phase N2's Facebook + phone;
// Google's Phase N handler predates this helper and is intentionally
// untouched — its semantics are identical):
//  - Known identity -> a session for ITS account.
//  - New identity -> a NEW account is auto-created (spec: first login
//    creates the account), the identity is bound, the bonus lands once.
//  - NO AUTO-MERGE, ever: a provider email already owned by another
//    account changes nothing — the new account gets a namespaced
//    placeholder address and the real contact lives on its identity row.
// Social accounts have no usable password (random placeholder hash, as
// in the Google flow); having a password is defined by the 'password'
// identity row, never by that column.
async function socialLoginOrCreate({ provider, providerUserId, email, phone, accountEmailVerified }) {
  const identity = db.prepare(
    'SELECT * FROM user_identities WHERE provider = ? AND provider_user_id = ?')
    .get(provider, providerUserId);
  if (identity) {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(identity.user_id);
    if (!user) return { status: 401, body: { error: 'Please sign in again.' } };
    return { status: 200, body: { token: signUserToken(user), credits: user.credits } };
  }
  const realEmail = email ? String(email).toLowerCase() : null;
  const emailTaken = realEmail
    ? db.prepare('SELECT id FROM users WHERE email = ?').get(realEmail) : null;
  const accountEmail = realEmail && !emailTaken
    ? realEmail : `${provider}-${providerUserId}@accounts.ajk-ai.local`;
  const placeholderHash = await bcrypt.hash(randomBytes(32).toString('hex'), 10);
  const isAdmin = CONFIG.adminEmail && accountEmail === CONFIG.adminEmail ? 1 : 0;
  let userId;
  try {
    userId = tx(() => {
      const info = db.prepare(
        `INSERT INTO users (email, password_hash, credits, free_credits, plan_credits, is_admin, email_verified)
         VALUES (?, ?, 0, 0, 0, ?, ?)`)
        .run(accountEmail, placeholderHash, isAdmin, accountEmailVerified ? 1 : 0);
      const id = Number(info.lastInsertRowid);
      db.prepare(
        `INSERT INTO user_identities (user_id, provider, provider_user_id, email, phone, verified)
         VALUES (?, ?, ?, ?, ?, 1)`)
        .run(id, provider, providerUserId, realEmail, phone || null);
      return id;
    });
  } catch { return { status: 409, body: { error: 'Could not create the account.' } }; }
  grantSignupBonus(userId);
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
  return { status: 201, body: { token: signUserToken(user), credits: user.credits, created: true } };
}

// ---------- Phone OTP machinery (Phase N2) ----------
// Codes are 6 digits from a CSPRNG, stored as sha256("phone:code").
// One live code per (phone, purpose): issuing supersedes every still-
// unused code. Sends are capped per phone across ALL purposes (so the
// link flow can never bypass the login caps).
const OTP_MAX_ATTEMPTS = 5;
const OTP_RESEND_MS = 60 * 1000;
const OTP_DAILY_MAX = 5;

function normalizePhone(raw) {
  const p = String(raw || '').replace(/[\s\-()]/g, '');
  return /^\+92\d{10}$/.test(p) || /^\+[1-9]\d{9,14}$/.test(p) ? p : null;
}
function phoneSendLimitError(phone) {
  const now = Date.now();
  const row = db.prepare(`SELECT COUNT(*) AS c, MAX(created_at) AS last
    FROM phone_otps WHERE phone = ? AND created_at > ?`).get(phone, now - 24 * 3600 * 1000);
  if (row && row.last && now - Number(row.last) < OTP_RESEND_MS) return 'otp_resend_too_soon';
  if (row && Number(row.c) >= OTP_DAILY_MAX) return 'otp_daily_limit';
  return null;
}
function issuePhoneOtp(phone, purpose, userId) {
  db.prepare('UPDATE phone_otps SET used_at = ? WHERE phone = ? AND purpose = ? AND used_at IS NULL')
    .run(Date.now(), phone, purpose);
  const code = String(randomInt(0, 1000000)).padStart(6, '0');
  db.prepare(`INSERT INTO phone_otps (phone, code_hash, purpose, user_id, expires_at, created_at)
    VALUES (?, ?, ?, ?, ?, ?)`)
    .run(phone, sha256Hex(`${phone}:${code}`), purpose, userId || null,
      Date.now() + CONFIG.otpTtlMs, Date.now());
  return code;
}
function discardPhoneOtp(phone, purpose) {
  db.prepare('UPDATE phone_otps SET used_at = ? WHERE phone = ? AND purpose = ? AND used_at IS NULL')
    .run(Date.now(), phone, purpose);
}
// Consumes one verification attempt against the latest live code for
// (phone, purpose). Returns the OTP row on success, null otherwise —
// wrong, expired, burned and superseded codes are indistinguishable
// to the caller on purpose. A link-purpose code additionally requires
// the code's user_id to be the caller (expectUserId).
function consumePhoneOtp(phone, purpose, rawCode, expectUserId) {
  const row = db.prepare(`SELECT * FROM phone_otps WHERE phone = ? AND purpose = ?
    AND used_at IS NULL ORDER BY id DESC LIMIT 1`).get(phone, purpose);
  if (!row) return null;
  if (purpose === 'link' && Number(row.user_id) !== Number(expectUserId)) return null;
  if (Number(row.expires_at) <= Date.now()) return null;
  if (Number(row.attempts) >= OTP_MAX_ATTEMPTS) return null;
  db.prepare('UPDATE phone_otps SET attempts = attempts + 1 WHERE id = ?').run(row.id);
  const given = Buffer.from(sha256Hex(`${phone}:${String(rawCode || '').trim()}`));
  const stored = Buffer.from(String(row.code_hash));
  const match = given.length === stored.length && timingSafeEqual(given, stored);
  if (!match) {
    if (Number(row.attempts) + 1 >= OTP_MAX_ATTEMPTS)
      db.prepare('UPDATE phone_otps SET used_at = ? WHERE id = ?').run(Date.now(), row.id);
    return null;
  }
  db.prepare('UPDATE phone_otps SET used_at = ? WHERE id = ?').run(Date.now(), row.id);
  return row;
}
// Issues a code and delivers it by SMS. Shared by the login and link
// start endpoints: rate limits first (429 with a clear code), the send
// itself last — a provider failure discards the stored code and
// surfaces as a 502, never a fake "sent".
async function startPhoneOtp(req, res, purpose, userId) {
  const phone = normalizePhone((req.body || {}).phone);
  if (!phone) return res.status(400).json({ error: 'invalid_phone',
    message: 'Enter the number in international format, e.g. +92 300 1234567.' });
  const limit = phoneSendLimitError(phone);
  if (limit) return res.status(429).json({ error: limit,
    message: limit === 'otp_resend_too_soon'
      ? 'A code was just sent to this number — wait a minute before asking for another.'
      : 'Too many codes requested for this number today — please try again tomorrow.' });
  const code = issuePhoneOtp(phone, purpose, userId);
  const minutes = Math.max(1, Math.round(CONFIG.otpTtlMs / 60000));
  const expiryText = minutes === 1 ? '1 minute' : `${minutes} minutes`;
  try {
    await sendSms({ to: phone,
      message: `Your AJK AI code is ${code}. It expires in ${expiryText}.` });
  } catch {
    discardPhoneOtp(phone, purpose);
    return res.status(502).json({ error: 'sms_send_failed',
      message: 'The SMS could not be sent — please try again in a moment.' });
  }
  return res.json({ ok: true, phone, expires_in_seconds: Math.round(CONFIG.otpTtlMs / 1000) });
}

function auth(req, res, next) {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  let payload;
  try { payload = jwt.verify(token, JWT_SECRET); }
  catch { return res.status(401).json({ error: 'Please sign in again.' }); }
  // Phase N: the JWT's `tv` must match users.token_version. A password
  // reset bumps the version, immediately invalidating every previously
  // issued session; a deleted account fails the lookup. Tokens minted
  // before Phase N carry no `tv` and read as version 0 — the same as a
  // fresh account's — so existing sessions survive until their account's
  // first version bump.
  const row = db.prepare('SELECT token_version FROM users WHERE id = ?').get(payload.id);
  if (!row || Number(payload.tv || 0) !== Number(row.token_version))
    return res.status(401).json({ error: 'Please sign in again.' });
  req.user = payload;
  next();
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
// Phase O2: the per-model display list behind the "Models & prices" card.
// DERIVATION RULE: every value comes from the live CONFIG constants and
// the COST_BY_QUALITY rate card — the exact objects the generation
// router and the credit charges read — so this list can never drift
// from what a user is actually charged. plan_gate names the LOWEST plan
// tier that can use the route ('all' = every plan incl. free credits at
// that plan's quality ceiling, 'pro' = Pro/Extra Pro via can_veo /
// can_lipsync, 'extrapro' = Extra Pro only). notes are short honest
// capability-note keys the UI renders verbatim next to the entry.
function publicModels() {
  return [
    { id: 'h3', name: 'MiniMax H3', kind: 'video',
      models: { text_to_video: CONFIG.model, image_to_video: CONFIG.modelI2V,
                reference_to_video: CONFIG.modelRef },
      resolutions: Object.keys(COST_BY_QUALITY),
      // 20s is offered on the H3 routes as an automatic two-part
      // generation (10s + 10s joined server-side) — see migration v25.
      durations: [5, 10, 20],
      price: { by_quality: COST_BY_QUALITY, draft_by_duration: CONFIG.draftCost },
      plan_gate: 'all', notes: 'native_audio_included' },
    { id: 'kling_o3_4k', name: 'Kling O3 4K', kind: 'video',
      model: CONFIG.model4k,
      resolutions: ['4K'], durations: CONFIG.durations,
      price: { by_quality: { '4K': COST_BY_QUALITY['4K'] } },
      plan_gate: 'extrapro', notes: 'native_4k' },
    { id: 'gemini_omni', name: 'Gemini Omni Flash — speaking video', kind: 'speaking',
      model: CONFIG.modelOmni,
      resolutions: [CONFIG.speakingResolution], durations: CONFIG.durations,
      aspects: CONFIG.speakingAspects,
      price: { flat: CONFIG.speakingCost },
      plan_gate: 'pro', notes: 'synchronized_dialogue_audio' },
    { id: 'seedance_2_5', name: 'Seedance 2.5 — premium', kind: 'premium',
      model: CONFIG.modelSeedance,
      resolutions: [CONFIG.seedanceResolution], durations: CONFIG.seedanceDurations,
      aspects: CONFIG.seedanceAspects,
      price: { by_duration: CONFIG.seedanceCost },
      plan_gate: 'extrapro', notes: 'native_audio_included_up_to_720p_route' },
    { id: 'lipsync', name: 'Lip-sync — talking character', kind: 'speaking',
      models: { image: CONFIG.lipsyncImageModel, video: CONFIG.lipsyncVideoModel },
      price: { flat: CONFIG.lipsyncCost },
      plan_gate: 'pro', notes: 'script_or_uploaded_voice' },
    { id: 'voice_sound', name: 'Voice & sound tools', kind: 'audio',
      models: { sound_sync: CONFIG.soundSyncModel, sound_premium_sync: CONFIG.soundSyncPremiumModel,
                sound_sfx: CONFIG.soundSfxModel, sound_music: CONFIG.soundMusicModel },
      price: { voiceover_flat: CONFIG.voiceoverCost, sound: CONFIG.soundCosts },
      notes: 'audio_included_in_generation_price' },
  ];
}
app.get('/api/config', (req, res) => res.json({
  model: CONFIG.model,
  // App version marker (Phase I) — the Settings footer shows it and the
  // server stamps it onto every feedback report.
  app_version: CONFIG.appVersion,
  aspect_ratios: CONFIG.aspectRatios,
  durations: CONFIG.durations,
  styles: CONFIG.styles,
  modes: MODE_LIST,
  prompt_languages: PROMPT_LANGUAGES,
  // Pakistan language registry (Phase M): the Language Lab in Settings
  // renders from this list. voice_status is honest by construction —
  // 'listed' means the provider lists the language but its quality is
  // still unproven; see PAK_LANGUAGES.
  languages: publicLanguages(),
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
  // Per-model cost/feature display (Phase O2): one entry per integrated
  // engine/route, computed by publicModels() from the SAME CONFIG
  // constants and rate card the router and pricing use — there is no
  // second price list that could drift. A value that cannot be derived
  // from config is left out of the entry rather than invented.
  models: publicModels(),
  // Finishers (Phase C1): one-tap post-processing on a completed video.
  // Each finisher creates a NEW History entry linked to the source video.
  // reframe is local ffmpeg work (free, like clip joining); captions is a
  // flat +50; extend is charged at the standard generation rate for the
  // source video's quality and the added duration; upscale is priced from
  // the verified Topaz per-second rate with the owner's formula
  // (ceil(USD/s x seconds x 277 / 1.5) x 2, minimum 100 credits).
  finishers: {
    configured: Boolean(FAL_KEY),
    actions: ['reframe', 'captions', 'extend', 'upscale'],
    prices: {
      reframe: 0,
      captions: CONFIG.captionsCost,
      extend: 'standard generation rate for the source quality and added duration',
      upscale: { model: CONFIG.upscaleModel, per_second_usd: CONFIG.upscalePerSecondUsd,
                 factor: CONFIG.upscaleFactor, min_credits: CONFIG.upscaleMinCredits,
                 formula: 'ceil(per-second USD x seconds x 277 / 1.5) x 2, minimum min_credits' },
    },
    reframe_targets: ['16:9', '9:16', '1:1', '4:5'],
    models: { captions: CONFIG.whisperModel, upscale: CONFIG.upscaleModel },
  },
  // Draft workflow (Phase C1): quality "draft" generates a cheap 480P
  // preview; a draft can later be upgraded to a full-quality generation
  // at the standard rate (POST /api/generations/:id/upgrade). Drafts
  // cannot take sound or voice add-ons.
  draft: {
    quality: '480P',
    cost_by_duration: CONFIG.draftCost,
    upgrade_qualities: ['768P', '2K', '4K'],
  },
  // Character library (Phase C2): a saved character is one of the user's
  // own uploaded images plus an optional bound voice. Generations with a
  // character are routed to the verified reference-to-video endpoint at
  // the STANDARD rate card (its per-second price is the H3 table and the
  // single reference image is inside the free allowance) — no surcharge.
  characters: {
    max_per_user: CHARACTER_MAX_PER_USER,
    model: CONFIG.modelRef,
  },
  // AI Auto Director (Phase D): the Studio's AI Auto toggle reads this
  // flag. The plan endpoint is free; confirmed plans are re-analyzed and
  // repriced server-side inside /api/generate before anything is charged.
  auto: { enabled: CONFIG.autoDirectorEnabled, version: CONFIG.autoDirectorVersion },
  // Speaking engine (Phase E): one-step talking videos on Gemini Omni —
  // the Veo route was retired before it was ever wired. Flat 500 credits,
  // Pro/Extra Pro only (the can_veo entitlement), 16:9 / 9:16 only,
  // routed at 720p; the engine generates its own synchronized dialogue
  // audio, so no voice/sound add-ons combine with it.
  speaking_engine: { provider: 'gemini-omni', model: CONFIG.modelOmni,
    price_credits: CONFIG.speakingCost, aspects: CONFIG.speakingAspects },
  // Premium engine (Phase J): Seedance 2.5 — a direct, user-chosen
  // premium engine (AI Auto never routes to it), Extra Pro only (the
  // can_seedance entitlement), 16:9 / 9:16 / 1:1, routed at 720p with
  // native synchronized audio included. Priced per duration at a linear
  // 120 credits/second (600 / 5s … 3600 / 30s; Phase L added the 15/20/30s
  // durations the fal schema genuinely allows). It is NOT a 4K engine
  // and is never presented as one.
  seedance_engine: { provider: 'seedance-2.5', model: CONFIG.modelSeedance,
    price_credits: CONFIG.seedanceCost, durations: CONFIG.seedanceDurations,
    aspects: CONFIG.seedanceAspects,
    resolution: CONFIG.seedanceResolution },
  // Advertising preparation (AdMob groundwork): flags and placement names
  // only — the publisher id itself is never exposed here. `enabled` is
  // true ONLY when ADS_ENABLED=1 and a valid publisher id are both set;
  // the frontend shows the (empty) ad slots only to signed-in FREE-tier
  // users when enabled is true. Paid plans are ad-free; real ad rendering
  // (native/interstitial/rewarded) requires the Android app build.
  ads: {
    enabled: adsEnabled(),
    configured: adsConfigured(),
    provider: adsConfigured() ? 'admob' : null,
    free_tier_only: true,
    placements: ['studio_bottom', 'home_native'],
    note: 'Web groundwork only: slot containers + policy gating + app-ads.txt. Native, interstitial and rewarded ad formats require the Android app build with the AdMob SDK.',
  },
  // Modern auth (Phases N + N2): which sign-in / account-recovery
  // methods are actually switched on. Every flag is false until the
  // owner's own provider account is configured server-side (see the
  // auth CONFIG notes) — the frontend renders live controls ONLY for
  // true flags and an honest "coming soon" state for the rest. The
  // Google client id and the Facebook app id are PUBLIC identifiers
  // (they ship in every sign-in button on the web); each is exposed
  // only while its provider is configured. They are the only auth
  // values ever exposed — the Facebook app secret, the mailer key and
  // the SMS key never leave the server.
  auth: {
    google: googleAuthConfigured(),
    facebook: facebookAuthConfigured(),
    phone: smsConfigured(),
    tiktok: tiktokAuthConfigured(),
    twitter: twitterAuthConfigured(),
    email_verification: mailerConfigured(),
    password_reset: mailerConfigured(),
  },
  ...(googleAuthConfigured() ? { google_client_id: CONFIG.googleClientId } : {}),
  ...(facebookAuthConfigured() ? { facebook_app_id: CONFIG.facebookAppId } : {}),
}));

// app-ads.txt (AdMob app-ownership verification): served ONLY when a
// valid publisher id or a verbatim override line is configured — 404
// otherwise, so an unconfigured deployment never claims an ad identity.
// The body is exactly the AdMob snippet for the owner's publisher id.
app.get('/app-ads.txt', (req, res) => {
  const body = appAdsTxtBody();
  if (!body) return res.status(404).type('text/plain').send('Not configured.\n');
  res.set('Cache-Control', 'public, max-age=3600');
  // An override line is served byte-for-byte verbatim; the generated
  // snippet gets the conventional trailing newline.
  res.type('text/plain').send(CONFIG.admobAppAdsTxt ? body : body + '\n');
});
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
// Email + password signup. Two regimes, chosen by whether the mailer
// is configured (Phase N):
//  - Mailer OFF (the historical behaviour): the account is verified at
//    once, the signup bonus lands immediately, a session is returned.
//  - Mailer ON (owner spec doc 6 — new signups must verify): the
//    account is created UNVERIFIED with NO bonus; a hashed, 24-hour,
//    single-use token is emailed as a link; verification activates the
//    account and grants the bonus exactly once (grantSignupBonus).
async function handleRegister(req, res) {
  const { email, password } = req.body || {};
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !password || password.length < 8)
    return res.status(400).json({ error: 'A valid email and a password of 8+ characters are required.' });
  const emailLc = String(email).toLowerCase();
  const isAdmin = CONFIG.adminEmail && emailLc === CONFIG.adminEmail ? 1 : 0;
  const hash = await bcrypt.hash(password, 10);
  const verification = mailerConfigured();
  let userId;
  try {
    userId = tx(() => {
      const info = db.prepare(
        `INSERT INTO users (email, password_hash, credits, free_credits, plan_credits, is_admin, email_verified)
         VALUES (?, ?, 0, 0, 0, ?, ?)`)
        .run(emailLc, hash, isAdmin, verification ? 0 : 1);
      const id = Number(info.lastInsertRowid);
      db.prepare(
        `INSERT INTO user_identities (user_id, provider, provider_user_id, email, verified)
         VALUES (?, 'password', ?, ?, ?)`)
        .run(id, emailLc, emailLc, verification ? 0 : 1);
      return id;
    });
  } catch { return res.status(409).json({ error: 'An account with this email already exists.' }); }
  if (!verification) {
    grantSignupBonus(userId);
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
    return res.json({ token: signUserToken(user), credits: user.credits });
  }
  const raw = issueAuthToken(userId, 'verify_email', 24 * 3600 * 1000);
  try {
    await sendVerificationEmail(req, emailLc, raw);
  } catch {
    // The account exists (unverified); the user can request a fresh
    // link from the sign-in screen. Answer honestly — never fake a send.
    return res.status(502).json({ error: 'mail_send_failed',
      message: 'Your account was created, but the verification email could not be sent. Use "Resend verification" on the sign-in screen.' });
  }
  res.status(201).json({ verification_required: true, email: emailLc });
}
app.post('/api/auth/register', handleRegister);
app.post('/api/auth/signup', handleRegister); // alias — same handler, same semantics

app.post('/api/auth/login', async (req, res) => {
  const { email, password } = req.body || {};
  const user = db.prepare('SELECT * FROM users WHERE email = ?').get((email || '').toLowerCase());
  if (!user || !(await bcrypt.compare(password || '', user.password_hash)))
    return res.status(401).json({ error: 'Wrong email or password.' });
  // Phase N (spec doc 6): while the mailer is configured, an unverified
  // email account cannot sign in. (Accounts created before the mailer
  // was switched on are grandfathered verified=1 by migration v19.)
  if (mailerConfigured() && !user.email_verified)
    return res.status(403).json({ error: 'email_not_verified',
      message: 'Please verify your email first — open the link we sent you, or request a fresh one.' });
  // Bootstrap admin also applies to accounts registered before ADMIN_EMAIL
  // was configured.
  if (CONFIG.adminEmail && user.email === CONFIG.adminEmail && !user.is_admin)
    db.prepare('UPDATE users SET is_admin = 1 WHERE id = ?').run(user.id);
  const token = signUserToken(user);
  res.json({ token, credits: user.credits });
});

// Email verification: the emailed link lands on the app as
// /?verify=<raw token>; the frontend posts the token here. Consuming it
// verifies the account AND grants the signup bonus (exactly once).
app.post('/api/auth/verify-email', (req, res) => {
  const rec = consumeAuthToken((req.body || {}).token, 'verify_email');
  if (!rec) return res.status(400).json({ error: 'This verification link is invalid, expired, or already used.' });
  const user = db.prepare('SELECT id FROM users WHERE id = ?').get(rec.user_id);
  if (!user) return res.status(400).json({ error: 'This verification link is invalid, expired, or already used.' });
  tx(() => {
    db.prepare('UPDATE users SET email_verified = 1 WHERE id = ?').run(rec.user_id);
    db.prepare("UPDATE user_identities SET verified = 1 WHERE user_id = ? AND provider = 'password'")
      .run(rec.user_id);
  });
  grantSignupBonus(rec.user_id);
  const after = db.prepare('SELECT credits FROM users WHERE id = ?').get(rec.user_id);
  res.json({ ok: true, verified: true, credits: after.credits });
});

// Resend a verification link. ALWAYS a generic 200 (no account
// enumeration); a fresh link is actually issued only when the account
// exists and is still unverified, at most 1/minute and 5/day per email.
app.post('/api/auth/resend-verification', authMailLimiter, async (req, res) => {
  if (!mailerConfigured())
    return res.status(503).json({ error: 'mailer_not_configured' });
  const emailLc = String((req.body || {}).email || '').toLowerCase();
  const user = db.prepare('SELECT * FROM users WHERE email = ?').get(emailLc);
  if (user && !user.email_verified) {
    const recent = db.prepare(`SELECT
        SUM(CASE WHEN created_at > datetime('now','-1 minute') THEN 1 ELSE 0 END) AS last_min,
        COUNT(*) AS last_day
      FROM auth_tokens WHERE user_id = ? AND purpose = 'verify_email'
        AND created_at > datetime('now','-1 day')`).get(user.id);
    if (!Number(recent.last_min || 0) && Number(recent.last_day || 0) < 5) {
      const raw = issueAuthToken(user.id, 'verify_email', 24 * 3600 * 1000);
      try { await sendVerificationEmail(req, emailLc, raw); } catch { /* generic by design */ }
    }
  }
  res.json({ ok: true });
});

// Forgot password: generic 200 either way (no enumeration). A reset
// token (hashed, 60 minutes, single-use) is created ONLY for an account
// that actually has a password identity — social-only accounts have
// nothing to reset.
app.post('/api/auth/forgot', authMailLimiter, async (req, res) => {
  if (!mailerConfigured())
    return res.status(503).json({ error: 'mailer_not_configured' });
  const emailLc = String((req.body || {}).email || '').toLowerCase();
  const user = db.prepare('SELECT * FROM users WHERE email = ?').get(emailLc);
  const hasPassword = user && db.prepare(
    "SELECT id FROM user_identities WHERE user_id = ? AND provider = 'password'").get(user.id);
  if (hasPassword) {
    const raw = issueAuthToken(user.id, 'reset_password', 60 * 60 * 1000);
    try { await sendResetEmail(req, emailLc, raw); } catch { /* generic by design */ }
  }
  res.json({ ok: true });
});

// Reset password with an emailed token. Success sets the new hash,
// marks the email verified (the link proved control of the inbox) and
// bumps token_version — every previously issued session dies at once.
app.post('/api/auth/reset', async (req, res) => {
  const { token, new_password } = req.body || {};
  if (!new_password || String(new_password).length < 8)
    return res.status(400).json({ error: 'A new password of 8+ characters is required.' });
  const rec = consumeAuthToken(token, 'reset_password');
  if (!rec) return res.status(400).json({ error: 'This reset link is invalid, expired, or already used.' });
  const hash = await bcrypt.hash(String(new_password), 10);
  db.prepare(`UPDATE users SET password_hash = ?, email_verified = 1,
    token_version = token_version + 1 WHERE id = ?`).run(hash, rec.user_id);
  res.json({ ok: true });
});

// ---------- Google Sign-In (Phase N, config-gated) ----------
// POST /api/auth/google { id_token }: the client obtains the ID token
// from Google's own sign-in flow (GIS); the server verifies it against
// Google's tokeninfo endpoint before trusting anything in it.
//  - Known Google identity -> session for ITS account.
//  - New Google identity -> a NEW account is auto-created (spec: first
//    login creates the account), verified by Google, bonus once.
//  - NO AUTO-MERGE, ever: an email match with an existing password
//    account changes nothing — that account is neither signed into nor
//    linked. (Linking is a separate, signed-in, verified action.)
app.post('/api/auth/google', googleAuthLimiter, async (req, res) => {
  if (!googleAuthConfigured())
    return res.status(503).json({ error: 'auth_provider_not_configured' });
  const profile = await verifyGoogleIdToken((req.body || {}).id_token);
  if (!profile) return res.status(401).json({ error: 'Google sign-in could not be verified.' });
  const identity = db.prepare(
    "SELECT * FROM user_identities WHERE provider = 'google' AND provider_user_id = ?")
    .get(profile.sub);
  if (identity) {
    const user = db.prepare('SELECT * FROM users WHERE id = ?').get(identity.user_id);
    if (!user) return res.status(401).json({ error: 'Please sign in again.' });
    return res.json({ token: signUserToken(user), credits: user.credits });
  }
  // users.email is UNIQUE and a password account may already own this
  // Google email — the accounts must stay separate, so on collision
  // the Google account gets a namespaced placeholder address and the
  // real Google email lives on the identity row.
  const emailTaken = db.prepare('SELECT id FROM users WHERE email = ?').get(profile.email);
  const accountEmail = emailTaken ? `google-${profile.sub}@accounts.ajk-ai.local` : profile.email;
  // Social accounts have no password: the NOT NULL hash column gets a
  // bcrypt hash of a random secret nobody knows (password login for
  // this account simply never matches). Having a password is defined
  // by the 'password' IDENTITY row, never by this column.
  const placeholderHash = await bcrypt.hash(randomBytes(32).toString('hex'), 10);
  const isAdmin = CONFIG.adminEmail && accountEmail === CONFIG.adminEmail ? 1 : 0;
  let userId;
  try {
    userId = tx(() => {
      const info = db.prepare(
        `INSERT INTO users (email, password_hash, credits, free_credits, plan_credits, is_admin, email_verified)
         VALUES (?, ?, 0, 0, 0, ?, 1)`)
        .run(accountEmail, placeholderHash, isAdmin);
      const id = Number(info.lastInsertRowid);
      db.prepare(
        `INSERT INTO user_identities (user_id, provider, provider_user_id, email, verified)
         VALUES (?, 'google', ?, ?, 1)`)
        .run(id, profile.sub, profile.email);
      return id;
    });
  } catch { return res.status(409).json({ error: 'Could not create the account.' }); }
  grantSignupBonus(userId);
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(userId);
  res.status(201).json({ token: signUserToken(user), credits: user.credits, created: true });
});

// Link Google to the SIGNED-IN account (the consent path that replaces
// any email-match merging): the caller proves control of both accounts
// — their session plus a fresh, verified Google token.
app.post('/api/auth/link/google', auth, googleAuthLimiter, async (req, res) => {
  if (!googleAuthConfigured())
    return res.status(503).json({ error: 'auth_provider_not_configured' });
  const profile = await verifyGoogleIdToken((req.body || {}).id_token);
  if (!profile) return res.status(401).json({ error: 'Google sign-in could not be verified.' });
  const existing = db.prepare(
    "SELECT * FROM user_identities WHERE provider = 'google' AND provider_user_id = ?")
    .get(profile.sub);
  if (existing) {
    if (existing.user_id === req.user.id)
      return res.json({ ok: true, already_linked: true, providers: userProviders(req.user.id) });
    return res.status(409).json({ error: 'identity_in_use',
      message: 'This Google account is already linked to a different AJK AI account.' });
  }
  db.prepare(
    `INSERT INTO user_identities (user_id, provider, provider_user_id, email, verified)
     VALUES (?, 'google', ?, ?, 1)`)
    .run(req.user.id, profile.sub, profile.email);
  res.status(201).json({ ok: true, linked: 'google', providers: userProviders(req.user.id) });
});

// The caller's linked sign-in methods (Settings renders from this).
app.get('/api/auth/identities', auth, (req, res) => {
  res.json({ identities: userProviders(req.user.id) });
});

// Unlink a provider (google | facebook | phone | tiktok | twitter;
// the password identity is the account's root credential and is
// never unlinked). The LAST remaining sign-in method can never be
// removed — an account must always keep a way back in; the guard
// counts every other identity row, whatever its provider.
app.post('/api/auth/unlink', auth, (req, res) => {
  const provider = String((req.body || {}).provider || '').toLowerCase();
  if (!['google', 'facebook', 'phone', 'tiktok', 'twitter'].includes(provider))
    return res.status(400).json({ error: 'Only Google, Facebook, TikTok, X or a phone number can be unlinked here.' });
  const label = provider === 'google' ? 'Google'
    : provider === 'facebook' ? 'Facebook'
    : provider === 'tiktok' ? 'TikTok'
    : provider === 'twitter' ? 'X'
    : 'This phone number';
  const rows = db.prepare('SELECT * FROM user_identities WHERE user_id = ?').all(req.user.id);
  const target = rows.find(r => r.provider === provider);
  if (!target) return res.status(404).json({ error: `${label} is not linked to this account.` });
  if (rows.filter(r => r.provider !== provider).length === 0)
    return res.status(400).json({ error: 'last_auth_method',
      message: 'This is your only sign-in method — add a password or another method before removing it.' });
  db.prepare('DELETE FROM user_identities WHERE id = ?').run(target.id);
  res.json({ ok: true, providers: userProviders(req.user.id) });
});

// ---------- Facebook Login (Phase N2, config-gated) ----------
// POST /api/auth/facebook { access_token }: the client obtains the
// token from Facebook's own login flow (JS SDK); the server verifies
// it against Graph (debug_token for THIS app + a matching /me) before
// trusting anything. Semantics are IDENTICAL to Google (Phase N):
// known identity -> its account; new identity -> a NEW account, bonus
// once; NO AUTO-MERGE on an email match, ever. Facebook's email is
// optional (the user may decline it) — the account is then created
// with a namespaced placeholder address, verified by Facebook itself.
app.post('/api/auth/facebook', socialAuthLimiter, async (req, res) => {
  if (!facebookAuthConfigured())
    return res.status(503).json({ error: 'auth_provider_not_configured' });
  const profile = await verifyFacebookAccessToken((req.body || {}).access_token);
  if (!profile) return res.status(401).json({ error: 'Facebook sign-in could not be verified.' });
  const out = await socialLoginOrCreate({ provider: 'facebook', providerUserId: profile.id,
    email: profile.email, phone: null, accountEmailVerified: !!profile.email });
  res.status(out.status).json(out.body);
});

// Link Facebook to the SIGNED-IN account (same consent path as Google).
app.post('/api/auth/link/facebook', auth, socialAuthLimiter, async (req, res) => {
  if (!facebookAuthConfigured())
    return res.status(503).json({ error: 'auth_provider_not_configured' });
  const profile = await verifyFacebookAccessToken((req.body || {}).access_token);
  if (!profile) return res.status(401).json({ error: 'Facebook sign-in could not be verified.' });
  const existing = db.prepare(
    "SELECT * FROM user_identities WHERE provider = 'facebook' AND provider_user_id = ?")
    .get(profile.id);
  if (existing) {
    if (existing.user_id === req.user.id)
      return res.json({ ok: true, already_linked: true, providers: userProviders(req.user.id) });
    return res.status(409).json({ error: 'identity_in_use',
      message: 'This Facebook account is already linked to a different AJK AI account.' });
  }
  db.prepare(
    `INSERT INTO user_identities (user_id, provider, provider_user_id, email, verified)
     VALUES (?, 'facebook', ?, ?, 1)`)
    .run(req.user.id, profile.id, profile.email);
  res.status(201).json({ ok: true, linked: 'facebook', providers: userProviders(req.user.id) });
});

// ---------- Phone number + SMS OTP (Phase N2, config-gated) ----------
// POST /api/auth/phone/start { phone }: sends a 6-digit code by SMS to
// the REQUESTED number (owner spec doc 6: the code goes to the number
// being verified — never to the owner's or admin's number). Stored
// hashed only; the response never contains the code.
// POST /api/auth/phone/verify { phone, code }: identity (provider
// 'phone', provider_user_id = the number) -> its account; new number
// -> a NEW account (the phone itself is the verified contact, so the
// account is verified), bonus once. Wrong / expired / burned codes
// share ONE honest error — nothing distinguishes them to a guesser.
app.post('/api/auth/phone/start', phoneStartLimiter, async (req, res) => {
  if (!smsConfigured()) return res.status(503).json({ error: 'sms_not_configured' });
  await startPhoneOtp(req, res, 'login', null);
});
app.post('/api/auth/phone/verify', socialAuthLimiter, async (req, res) => {
  if (!smsConfigured()) return res.status(503).json({ error: 'sms_not_configured' });
  const phone = normalizePhone((req.body || {}).phone);
  if (!phone) return res.status(400).json({ error: 'invalid_phone',
    message: 'Enter the number in international format, e.g. +92 300 1234567.' });
  const row = consumePhoneOtp(phone, 'login', (req.body || {}).code, null);
  if (!row) return res.status(400).json({ error: 'invalid_or_expired_code',
    message: 'That code is wrong, expired, or too many attempts were made — request a new code.' });
  const out = await socialLoginOrCreate({ provider: 'phone', providerUserId: phone,
    email: null, phone, accountEmailVerified: true });
  res.status(out.status).json(out.body);
});

// Link a phone to the SIGNED-IN account: the OTP is issued with
// purpose 'link' and bound to the caller — it verifies for nobody
// else, and the number must not already belong to another account.
app.post('/api/auth/link/phone/start', auth, phoneStartLimiter, async (req, res) => {
  if (!smsConfigured()) return res.status(503).json({ error: 'sms_not_configured' });
  await startPhoneOtp(req, res, 'link', req.user.id);
});
app.post('/api/auth/link/phone/verify', auth, socialAuthLimiter, async (req, res) => {
  if (!smsConfigured()) return res.status(503).json({ error: 'sms_not_configured' });
  const phone = normalizePhone((req.body || {}).phone);
  if (!phone) return res.status(400).json({ error: 'invalid_phone',
    message: 'Enter the number in international format, e.g. +92 300 1234567.' });
  const row = consumePhoneOtp(phone, 'link', (req.body || {}).code, req.user.id);
  if (!row) return res.status(400).json({ error: 'invalid_or_expired_code',
    message: 'That code is wrong, expired, or too many attempts were made — request a new code.' });
  const existing = db.prepare(
    "SELECT * FROM user_identities WHERE provider = 'phone' AND provider_user_id = ?")
    .get(phone);
  if (existing) {
    if (existing.user_id === req.user.id)
      return res.json({ ok: true, already_linked: true, providers: userProviders(req.user.id) });
    return res.status(409).json({ error: 'identity_in_use',
      message: 'This phone number is already linked to a different AJK AI account.' });
  }
  db.prepare(
    `INSERT INTO user_identities (user_id, provider, provider_user_id, phone, verified)
     VALUES (?, 'phone', ?, ?, 1)`)
    .run(req.user.id, phone, phone);
  res.status(201).json({ ok: true, linked: 'phone', providers: userProviders(req.user.id) });
});

// ---------- TikTok + X redirect sign-in (Phase P, config-gated) ----------
// Redirect-based OAuth 2.0 (see the Phase P helpers above). Every
// endpoint FAILS CLOSED with 503 auth_provider_not_configured until
// the owner's own developer app is configured; the login screen
// renders the matching honest "coming soon" state from /api/config.
// Semantics mirror Google/Facebook exactly: known identity -> its
// account; new identity -> a NEW account (signup bonus once); NO
// AUTO-MERGE — neither provider returns a trustworthy email on the
// basic scope anyway (TikTok: none at all; X: not requested), so
// accounts are keyed purely on the provider user id, and linking is
// the signed-in, state-bound action below.

// Exchange a one-time SSO handoff code (minted by a provider
// callback) for the usual session payload. Hashed lookup,
// single-use, 5-minute life — see issueSsoRedirect.
app.post('/api/auth/sso/exchange', socialAuthLimiter, (req, res) => {
  const code = String((req.body || {}).code || '');
  if (!code) return res.status(400).json({ error: 'missing_code',
    message: 'No sign-in code was provided.' });
  const row = consumeAuthToken(code, 'sso');
  if (!row) return res.status(401).json({ error: 'invalid_or_expired_code',
    message: 'This sign-in link has expired or was already used — please sign in again.' });
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(row.user_id);
  if (!user) return res.status(401).json({ error: 'invalid_or_expired_code',
    message: 'This sign-in link has expired or was already used — please sign in again.' });
  res.json({ token: signUserToken(user), credits: user.credits });
});

app.get('/api/auth/tiktok/start', socialAuthLimiter, (req, res) => {
  if (!tiktokAuthConfigured())
    return res.status(503).json({ error: 'auth_provider_not_configured',
      message: 'TikTok sign-in is not configured on this server yet.' });
  const redirectUri = `${oauthCallbackOrigin(req)}/api/auth/tiktok/callback`;
  const state = createOAuthState('tiktok', 'login', null, null);
  res.redirect(tiktokAuthorizeUrl(redirectUri, state));
});

app.post('/api/auth/tiktok/link/start', auth, socialAuthLimiter, (req, res) => {
  if (!tiktokAuthConfigured())
    return res.status(503).json({ error: 'auth_provider_not_configured',
      message: 'TikTok sign-in is not configured on this server yet.' });
  const redirectUri = `${oauthCallbackOrigin(req)}/api/auth/tiktok/callback`;
  const state = createOAuthState('tiktok', 'link', req.user.id, null);
  res.json({ authorize_url: tiktokAuthorizeUrl(redirectUri, state) });
});

app.get('/api/auth/tiktok/callback', socialAuthLimiter, async (req, res) => {
  if (!tiktokAuthConfigured())
    return res.status(503).json({ error: 'auth_provider_not_configured',
      message: 'TikTok sign-in is not configured on this server yet.' });
  const stateRow = consumeOAuthState(String(req.query.state || ''), 'tiktok');
  if (!stateRow) return res.redirect('/?auth_error=invalid_state');
  const code = String(req.query.code || '');
  if (!code) return res.redirect('/?auth_error=provider_denied');
  const redirectUri = `${oauthCallbackOrigin(req)}/api/auth/tiktok/callback`;
  try {
    const tokenData = await exchangeTikTokCode(code, redirectUri);
    const tuser = await fetchTikTokUser(tokenData.access_token);
    return await completeOAuthCallback(req, res, stateRow,
      { provider: 'tiktok', providerUserId: String(tuser.open_id), email: null });
  } catch {
    return res.redirect('/?auth_error=provider_failed');
  }
});

app.get('/api/auth/twitter/start', socialAuthLimiter, (req, res) => {
  if (!twitterAuthConfigured())
    return res.status(503).json({ error: 'auth_provider_not_configured',
      message: 'X sign-in is not configured on this server yet.' });
  const redirectUri = `${oauthCallbackOrigin(req)}/api/auth/twitter/callback`;
  const codeVerifier = randomBytes(48).toString('base64url');
  const state = createOAuthState('twitter', 'login', null, codeVerifier);
  res.redirect(twitterAuthorizeUrl(redirectUri, state, codeVerifier));
});

app.post('/api/auth/twitter/link/start', auth, socialAuthLimiter, (req, res) => {
  if (!twitterAuthConfigured())
    return res.status(503).json({ error: 'auth_provider_not_configured',
      message: 'X sign-in is not configured on this server yet.' });
  const redirectUri = `${oauthCallbackOrigin(req)}/api/auth/twitter/callback`;
  const codeVerifier = randomBytes(48).toString('base64url');
  const state = createOAuthState('twitter', 'link', req.user.id, codeVerifier);
  res.json({ authorize_url: twitterAuthorizeUrl(redirectUri, state, codeVerifier) });
});

app.get('/api/auth/twitter/callback', socialAuthLimiter, async (req, res) => {
  if (!twitterAuthConfigured())
    return res.status(503).json({ error: 'auth_provider_not_configured',
      message: 'X sign-in is not configured on this server yet.' });
  const stateRow = consumeOAuthState(String(req.query.state || ''), 'twitter');
  if (!stateRow) return res.redirect('/?auth_error=invalid_state');
  const code = String(req.query.code || '');
  if (!code) return res.redirect('/?auth_error=provider_denied');
  const redirectUri = `${oauthCallbackOrigin(req)}/api/auth/twitter/callback`;
  try {
    const tokenData = await exchangeTwitterCode(code, redirectUri, stateRow.code_verifier || '');
    const xuser = await fetchTwitterUser(tokenData.access_token);
    return await completeOAuthCallback(req, res, stateRow,
      { provider: 'twitter', providerUserId: String(xuser.id), email: null });
  } catch {
    return res.redirect('/?auth_error=provider_failed');
  }
});

// ---------- Account deletion (Phase N) ----------
// Self-serve, permanent. Requires the typed word DELETE and — when the
// account has a password — that password (social-only accounts confirm
// by typing alone). The schema declares REFERENCES without ON DELETE
// CASCADE, so every user-owned row is deleted explicitly, in one
// transaction, children first; uploaded source images go best-effort.
app.post('/api/account/delete', auth, async (req, res) => {
  const { confirm, password } = req.body || {};
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.id);
  if (!user) return res.status(404).json({ error: 'Account not found.' });
  if (String(confirm || '').trim().toUpperCase() !== 'DELETE')
    return res.status(400).json({ error: 'Type DELETE to confirm account deletion.' });
  const hasPassword = !!db.prepare(
    "SELECT id FROM user_identities WHERE user_id = ? AND provider = 'password'").get(user.id);
  if (hasPassword && !(await bcrypt.compare(String(password || ''), user.password_hash)))
    return res.status(401).json({ error: 'Your password is incorrect — the account was not deleted.' });
  tx(() => {
    db.prepare('DELETE FROM reports WHERE user_id = ?').run(user.id);
    db.prepare('DELETE FROM feedback WHERE user_id = ?').run(user.id);
    db.prepare('DELETE FROM voice_jobs WHERE user_id = ?').run(user.id);
    db.prepare('DELETE FROM generations WHERE user_id = ?').run(user.id);
    db.prepare('DELETE FROM characters WHERE user_id = ?').run(user.id);
    db.prepare('DELETE FROM pack_purchases WHERE user_id = ?').run(user.id);
    db.prepare('DELETE FROM payments WHERE user_id = ?').run(user.id);
    db.prepare('DELETE FROM subscriptions WHERE user_id = ?').run(user.id);
    db.prepare('DELETE FROM auth_tokens WHERE user_id = ?').run(user.id);
    db.prepare('DELETE FROM oauth_states WHERE user_id = ?').run(user.id);
    db.prepare('DELETE FROM phone_otps WHERE user_id = ?').run(user.id);
    db.prepare('DELETE FROM user_identities WHERE user_id = ?').run(user.id);
    db.prepare('DELETE FROM users WHERE id = ?').run(user.id);
  });
  try { fs.rmSync(path.join(CONFIG.uploadsDir, String(user.id)), { recursive: true, force: true }); }
  catch { /* uploaded files are removed best-effort */ }
  res.json({ ok: true, deleted: true });
});

app.get('/api/me', auth, (req, res) => {
  refreshSubscriptionState(req.user.id);
  const u = db.prepare('SELECT id, email, credits, free_credits, plan_credits, credit_deficit, is_admin, email_verified, created_at FROM users WHERE id = ?').get(req.user.id);
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

// ---------- Own-voice audio upload for lip-sync (Phase O2) ----------
// The user records their own voice (or a speaker who gave permission) and
// uploads the file; lip-sync then uses THAT recording instead of a
// synthesized TTS voice. Transport mirrors the image upload exactly:
// base64 JSON (the global 100kb parser skips this path; the route mounts
// its own). The type is decided by MAGIC BYTES, never the claimed type —
// MP3 (ID3 tag or an 0xFFEx frame sync), WAV (RIFF/WAVE), M4A (ftyp box),
// OGG (OggS) and WEBM (EBML header). Cap: 10 MB. Duration guard: the file
// is probed with the pinned ffmpeg binary (the app ships no ffprobe —
// probeAudioDuration parses `ffmpeg -i` output, the same pattern the
// voice system uses); over 60 seconds is rejected with 400
// audio_too_long, and an unprobeable file is rejected too — the guard
// FAILS CLOSED with a clear error, it is never silently skipped. The
// file is deleted again on any rejection, so a rejected upload leaves
// nothing behind. The returned url is the public /files/audio/ path fal
// fetches for the lip-sync call — the same hosting pattern as TTS audio.
const AUDIO_UPLOAD_MAX_BYTES = 10 * 1024 * 1024;
const AUDIO_UPLOAD_MAX_SECONDS = 60;
const AUDIO_UPLOAD_TYPES = [
  { type: 'audio/mpeg', ext: 'mp3', test: (b) =>
      (b.length >= 3 && b[0] === 0x49 && b[1] === 0x44 && b[2] === 0x33) || // "ID3"
      (b.length >= 2 && b[0] === 0xff && (b[1] & 0xe0) === 0xe0) },        // frame sync
  { type: 'audio/wav', ext: 'wav', test: (b) =>
      b.length >= 12 && b.toString('latin1', 0, 4) === 'RIFF' && b.toString('latin1', 8, 12) === 'WAVE' },
  { type: 'audio/mp4', ext: 'm4a', test: (b) =>
      b.length >= 8 && b.toString('latin1', 4, 8) === 'ftyp' },
  { type: 'audio/ogg', ext: 'ogg', test: (b) =>
      b.length >= 4 && b.toString('latin1', 0, 4) === 'OggS' },
  { type: 'audio/webm', ext: 'webm', test: (b) =>
      b.length >= 4 && b[0] === 0x1a && b[1] === 0x45 && b[2] === 0xdf && b[3] === 0xa3 },
];
function sniffAudioType(buf) {
  return AUDIO_UPLOAD_TYPES.find((t) => t.test(buf)) || null;
}
app.post('/api/uploads/audio', auth, express.json({ limit: '16mb' }), async (req, res) => {
  const raw = String(req.body?.audio_base64 || '').trim();
  if (!raw) return res.status(400).json({ error: 'audio_base64 is required.' });
  const base64 = raw.startsWith('data:') ? (raw.split(',', 2)[1] || '') : raw;
  if (!/^[A-Za-z0-9+/=\s]+$/.test(base64))
    return res.status(400).json({ error: 'audio_base64 is not valid base64.' });
  const buf = Buffer.from(base64, 'base64');
  if (buf.length === 0) return res.status(400).json({ error: 'The uploaded audio is empty.' });
  if (buf.length > AUDIO_UPLOAD_MAX_BYTES)
    return res.status(413).json({ error: 'Audio is too large — the limit is 10 MB.' });
  const type = sniffAudioType(buf);
  if (!type)
    return res.status(400).json({ error: 'Only MP3, WAV, M4A, OGG and WebM audio recordings are supported.' });
  const dir = path.join(CONFIG.audioUploadsDir, String(req.user.id));
  fs.mkdirSync(dir, { recursive: true });
  const name = `${randomUUID()}.${type.ext}`;
  const abs = path.join(dir, name);
  fs.writeFileSync(abs, buf);
  const reject = (status, body) => { try { fs.unlinkSync(abs); } catch { /* already gone */ } return res.status(status).json(body); };
  let seconds = 0;
  try { seconds = await probeAudioDuration(abs); } catch { seconds = 0; }
  if (!seconds || !(seconds > 0))
    return reject(400, { error: 'audio_unreadable', message: 'The recording could not be read, so its length could not be verified. Please upload a standard MP3, WAV, M4A, OGG or WebM file.' });
  if (seconds > AUDIO_UPLOAD_MAX_SECONDS)
    return reject(400, { error: 'audio_too_long', message: `The recording is ${Math.round(seconds)} seconds — lip-sync voice uploads are limited to ${AUDIO_UPLOAD_MAX_SECONDS} seconds. Please trim it and upload again.` });
  const info = db.prepare(`INSERT INTO audio_uploads (user_id, file_name, content_type, size_bytes, duration_seconds)
    VALUES (?, ?, ?, ?, ?)`)
    .run(req.user.id, name, type.type, buf.length, Math.round(seconds * 1000) / 1000);
  res.status(201).json({
    id: Number(info.lastInsertRowid),
    url: `/files/audio/${req.user.id}/${name}`,
    content_type: type.type, size_bytes: buf.length,
    duration_seconds: Math.round(seconds * 1000) / 1000,
  });
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

// ---------- Character library (Phase C2) ----------------------------------
// A saved character = one reference image (always one of the user's OWN
// uploads — the same ownership proof as image-to-video) plus an OPTIONAL
// bound voice (provider + voice + spoken language + style, validated
// against the public voice catalog). Users save a character once and
// reuse it: in /api/generate the character's image drives the visual via
// the reference-to-video endpoint (charged at the standard rate card —
// see CONFIG.modelRef), and in /api/voice/lipsync the character supplies
// both the source image and (unless overridden) the voice. Character
// consistency is the model's best effort, never a guarantee — the UI and
// README say so plainly.
const CHARACTER_MAX_PER_USER = 10;

function publicCharacter(c) {
  if (!c) return null;
  return { id: c.id, name: c.name, image_path: c.image_path,
    // Uploaded images are served under /files/uploads/<userId>/<file>;
    // image_path is the stored "data/uploads/<userId>/<file>" form.
    image_url: '/' + String(c.image_path).replace(/^data\//, 'files/'),
    voice: c.voice_provider
      ? { provider: c.voice_provider, voice_id: c.voice_id,
          language: c.voice_language, style: c.voice_style }
      : null,
    created_at: c.created_at };
}
function getOwnCharacter(userId, characterId) {
  const id = Number(characterId);
  if (!Number.isInteger(id) || id <= 0) return null;
  return db.prepare('SELECT * FROM characters WHERE id = ? AND user_id = ?')
    .get(id, userId) || null;
}
// Validate the optional voice binding of a character against the public
// voice catalog (the same catalog /api/config exposes — only configured
// providers can be bound, since an unconfigured provider could never be
// used). Returns a normalized { provider, voice_id, language, style } or
// null when no binding was supplied. Throws { status, error } on bad
// input. When a provider is bound, the language defaults to Urdu and the
// style to conversation, and the voice to the provider's default voice
// for the language — a bound character always carries a COMPLETE voice
// so lip-sync can use it without further choices.
function parseCharacterVoice(body) {
  const bad = (msg) => Object.assign(new Error(msg), { status: 400 });
  const has = (k) => body?.[k] !== undefined && body?.[k] !== null && body?.[k] !== '';
  const anyVoice = ['voice_provider', 'voice_id', 'voice_language', 'voice_style'].some(has);
  if (!anyVoice) return null;
  const provider = String(body?.voice_provider || '').toLowerCase();
  if (!provider)
    throw bad('voice_provider is required when a voice is bound to a character.');
  const catalogEntry = publicVoiceCatalog().find(p => p.provider === provider);
  if (!catalogEntry)
    throw bad(`voice_provider "${provider}" is not in the voice catalog (or its provider is not configured on this server).`);
  const language = has('voice_language') ? String(body.voice_language).toLowerCase() : 'ur';
  if (!VOICE_LANGUAGES.some(l => l.code === language))
    throw bad(`voice_language must be one of: ${VOICE_LANGUAGES.map(l => l.code).join(', ')}`);
  // Phase M: a bound character voice in Punjabi/Pashto/Sindhi can only
  // ever be synthesized by the Gemini provider (see parseVoiceSettings).
  if (GEMINI_ONLY_VOICE_LANGUAGES.has(language) && provider !== 'gemini')
    throw bad(`voice_language "${language}" is available through the Gemini provider only.`);
  const style = has('voice_style') ? String(body.voice_style).toLowerCase() : 'conversation';
  if (!VOICE_STYLES.includes(style))
    throw bad(`voice_style must be one of: ${VOICE_STYLES.join(', ')}`);
  let voiceId;
  if (has('voice_id')) {
    voiceId = String(body.voice_id);
    const ok = providerVoicesFor(provider, language).some(v => v.id === voiceId);
    if (!ok) throw bad(`voice_id "${voiceId}" is not available for ${provider} / ${language}.`);
  } else {
    const def = defaultVoiceFor(provider, language);
    if (!def) throw bad(`No voice is available for ${provider} / ${language}.`);
    voiceId = def.id;
  }
  return { provider, voice_id: voiceId, language, style };
}

app.post('/api/characters', auth, (req, res) => {
  const b = req.body || {};
  const name = String(b.name || '').trim();
  if (name.length < 1 || name.length > 60)
    return res.status(400).json({ error: 'A character name of 1–60 characters is required.' });
  // The reference image must be one of THIS user's uploads — the exact
  // same ownership check as image-to-video. Another user's image path
  // fails here because it does not resolve under the caller's folder.
  const owned = resolveOwnedUpload(req.user.id, b.image_path);
  if (!owned)
    return res.status(400).json({ error: 'image_path must be an image you uploaded (POST /api/uploads/image).' });
  let voice;
  try { voice = parseCharacterVoice(b); }
  catch (e) { return res.status(e.status || 400).json({ error: e.message }); }
  const count = db.prepare('SELECT COUNT(*) AS c FROM characters WHERE user_id = ?')
    .get(req.user.id).c;
  if (Number(count) >= CHARACTER_MAX_PER_USER)
    return res.status(400).json({ error: `You can save at most ${CHARACTER_MAX_PER_USER} characters. Delete one before adding another.` });
  const imagePath = String(b.image_path).replace(/\\/g, '/').replace(/^\.\//, '');
  const info = db.prepare(
    `INSERT INTO characters (user_id, name, image_path, voice_provider, voice_id, voice_language, voice_style)
     VALUES (?, ?, ?, ?, ?, ?, ?)`)
    .run(req.user.id, name, imagePath,
         voice?.provider || null, voice?.voice_id || null,
         voice?.language || null, voice?.style || null);
  const row = db.prepare('SELECT * FROM characters WHERE id = ?').get(Number(info.lastInsertRowid));
  res.status(201).json({ character: publicCharacter(row) });
});

app.get('/api/characters', auth, (req, res) => {
  const rows = db.prepare('SELECT * FROM characters WHERE user_id = ? ORDER BY id')
    .all(req.user.id);
  res.json({ characters: rows.map(publicCharacter) });
});

app.delete('/api/characters/:id', auth, (req, res) => {
  const row = getOwnCharacter(req.user.id, req.params.id);
  if (!row) return res.status(404).json({ error: 'Character not found.' });
  // Only the character row goes away — generations made with it keep
  // their character_id and their history (the name join just returns
  // nothing for them afterwards).
  db.prepare('DELETE FROM characters WHERE id = ?').run(row.id);
  res.json({ ok: true });
});

// ==========================================================================
// AI Auto Director (Phase D) — deterministic, rule-based prompt analysis
// ==========================================================================
// The analyzer is deliberately RULE-BASED v1: keyword/regex detection over
// the (already translated) English prompt plus script detection on the
// user's original text. It makes NO external LLM call, so planning is fast,
// free and predictable. It only ever proposes settings that already exist
// in this codebase (modes, aspect ratios, the sound add-ons, the voice
// routes and the generation engines below) — anything unavailable is
// reported in `notes`, never silently promised.
//
// POST /api/generate/plan is FREE: it never charges and never creates a
// generation row. /api/generate accepts a confirmed plan, RE-RUNS this
// analyzer on the real request, and applies only the effects that match
// the fresh analysis — every cost is recomputed from the rate card, so a
// tampered plan cannot invent a discount or a free add-on.

function parseStoredAutoPlan(value) {
  if (!value) return null;
  if (typeof value === 'object') return value;
  try { return JSON.parse(value); } catch { return null; }
}
function publicGenerationRow(row) {
  if (!row) return row;
  const out = { ...row, auto_plan: parseStoredAutoPlan(row.auto_plan) };
  // Phase L: expose the exact camera/shot directive phrase that was
  // appended to this job's prompt, recomputed from the recorded choices
  // with the same pure function generation used — History shows the
  // user precisely what the model was told.
  const directive = cameraDirectiveSuffix(row.camera_move, row.shot_size);
  if (directive) out.camera_directive = directive;
  return out;
}

// The plan a user is currently entitled to (null on the free tier).
function autoUserPlan(userId) {
  refreshSubscriptionState(userId);
  const sub = currentSubscription(userId);
  return sub ? getPlan(sub.plan_id) : null;
}
// Mirror of the /api/generate routing ladder for ONE aspect ratio: the
// plan's quality ceiling, an explicit lower resolution when allowed, the
// native-4K aspect fallback (4K -> 2K outside 16:9/9:16/1:1) and the flat
// draft rate. Used by the analyzer so plan totals equal generate totals.
function autoRoutedQuality(userId, { wantedResolution = null, aspectRatio = '16:9', duration = 5, isDraft = false } = {}) {
  const plan = autoUserPlan(userId);
  const planResolution = plan ? plan.resolution : CONFIG.resolution;
  let resolution = planResolution;
  if (wantedResolution && RESOLUTIONS.includes(wantedResolution) &&
      RESOLUTIONS.indexOf(wantedResolution) <= RESOLUTIONS.indexOf(planResolution))
    resolution = wantedResolution;
  if (resolution === '4K' && !FOUR_K_ASPECTS.includes(aspectRatio)) resolution = '2K';
  if (isDraft) resolution = '480P';
  const cost = isDraft ? (CONFIG.draftCost[Number(duration)] ?? 70)
                       : generationCost(resolution, Number(duration));
  return { plan, resolution, cost };
}

// Engine/route selection — ONLY routes already integrated in this codebase.
// `route` is the base generation route; when the plan's voice route is
// lip-sync, `voice_route` names the existing lip-sync endpoint that runs
// on the finished video. Server-side routing in /api/generate always wins:
// the applied plan records the route the server actually used.
function autoEngineRoute({ character = null, hasSourceImage = false, resolution = '768P', plan = null, voice = null, speaking = false } = {}) {
  let route, model, reason;
  if (speaking) {
    route = 'omni_speaking'; model = CONFIG.modelOmni;
    reason = 'dialogue detected → one-step speaking video engine';
  } else if (character) {
    route = 'h3_reference_to_video'; model = CONFIG.modelRef;
    reason = 'Character selected → reference-to-video route for character consistency.';
  } else if (hasSourceImage) {
    route = 'h3_image_to_video'; model = CONFIG.modelI2V;
    reason = 'Starting image attached → image-to-video route animates that image.';
  } else if (resolution === '4K' && plan && plan.resolution === '4K') {
    route = 'kling_o3_4k'; model = CONFIG.model4k;
    reason = 'Native 4K quality on an entitled plan → Kling O3 4K route.';
  } else {
    route = 'h3_text_to_video'; model = CONFIG.model;
    reason = 'Standard prompt → H3 text-to-video route.';
  }
  const engine = { route, model, reason };
  if (voice && voice.kind === 'lipsync') {
    engine.voice_route = 'latentsync_video';
    engine.voice_model = CONFIG.lipsyncVideoModel;
    engine.reason += ' Dialogue will be lip-synced to the finished video with the existing video lip-sync endpoint.';
  }
  return engine;
}

const AUTO_ARABIC_RE = /[\u0600-\u06FF]/;
const AUTO_DEVANAGARI_RE = /[\u0900-\u097F]/;
function autoCleanDialogue(text) {
  return String(text || '').trim()
    .replace(/^[\s"'“”«»「『:：,.\-]+/, '')
    .replace(/[\s"'“”«»」』]+$/, '')
    .slice(0, 300).trim();
}
function autoQuotedText(text) {
  const t = String(text || '');
  const pairs = [['“', '”'], ['"', '"'], ['«', '»'], ['「', '」'], ["'", "'"]];
  for (const [open, close] of pairs) {
    const i = t.indexOf(open);
    if (i < 0) continue;
    const j = t.indexOf(close, i + 1);
    if (j <= i + 1) continue;
    const inner = autoCleanDialogue(t.slice(i + 1, j));
    // A quoted fragment counts as speech when it is a phrase (has a
    // space or non-Latin script) — a single quoted word is usually a title.
    if (inner.length >= 2 && (/\s/.test(inner) || /[^\x00-\x7F]/.test(inner))) return inner;
  }
  return null;
}
function autoSpeechRemainder(text) {
  const t = String(text || '');
  const patterns = [
    /(?:\bsays\b|\bsaid\b|\basks\b|\basked\b|\bshouts\b|\bshouted\b|\bwhispers\b|\bwhispered\b|\breplies\b|\breplied\b)\s*(?::|,|that)?\s+(.+)$/i,
    /(?:کہتا ہے|کہتی ہے|بولتا ہے|بولتی ہے|کہا|پوچھتا ہے|پوچھتی ہے)\s*[:：]?\s*(.+)$/u,
    /(?:कहता है|कहती है|बोलता है|बोलती है|पूछता है)\s*[:：]?\s*(.+)$/u,
  ];
  for (const re of patterns) {
    const m = t.match(re);
    if (m && m[1]) {
      const out = autoCleanDialogue(m[1]);
      if (out.length >= 2) return out;
    }
  }
  return null;
}
// Extract the spoken line, preferring the ORIGINAL text (the translation
// may lose the exact words — and for Urdu/Hindi the voice must speak the
// original script, never the English translation).
function autoDetectDialogue(originalPrompt, effectivePrompt, promptLanguage) {
  let text = null, fromOriginal = false;
  text = autoQuotedText(originalPrompt);
  if (text) fromOriginal = true;
  if (!text) { text = autoSpeechRemainder(originalPrompt); if (text) fromOriginal = true; }
  if (!text) text = autoQuotedText(effectivePrompt);
  if (!text) text = autoSpeechRemainder(effectivePrompt);
  if (!text) return null;
  let language = 'en', scriptMode = 'native';
  if (AUTO_DEVANAGARI_RE.test(text)) language = 'hi';
  else if (AUTO_ARABIC_RE.test(text)) language = promptLanguage === 'ar' ? 'ar' : 'ur';
  else if (['ur', 'hi'].includes(promptLanguage)) {
    language = promptLanguage;
    scriptMode = fromOriginal && /[A-Za-z]/.test(text) ? 'roman' : 'native';
    // Words recovered only from the English translation cannot be spoken
    // as Urdu/Hindi — flag them so the analyzer stays honest (no charge).
    if (!fromOriginal) return { text, language, scriptMode, from_translation: true };
  }
  return { text, language, script_mode: scriptMode };
}

const AUTO_SFX_RULES = [
  ['rain',       /\brain(ing|fall)?\b|بارش/, 'rain'],
  ['thunder',    /\bthunder|lightning\b|گرج/, 'thunder'],
  ['car',        /\bcars?\b|گاڑی/, 'car engine'],
  ['brake',      /\bbrak(e|es|ing)\b|\bscreech/, 'braking'],
  ['traffic',    /\btraffic\b/, 'traffic'],
  ['crowd',      /\bcrowd|cheering|applause\b/, 'crowd'],
  ['ocean',      /\bocean|sea\b|سمندر/, 'ocean'],
  ['waves',      /\bwaves?\b|لہریں/, 'waves'],
  ['birds',      /\bbirds?\b|chirping/, 'birds'],
  ['explosion',  /\bexplosion|exploding|blast\b/, 'explosion'],
  ['footsteps',  /\bfootsteps?|walking|running\b/, 'footsteps'],
  ['door',       /\bdoor (opens|closes|slams|creaks)\b|\bdoorbell\b/, 'door'],
  ['wind',       /\bwind(y)?\b|ہوا/, 'wind'],
  ['city',       /\bcity|street|market|bazaar\b/, 'city ambience'],
];
function autoDetectSfx(text) {
  const events = [], labels = [];
  for (const [id, re, label] of AUTO_SFX_RULES) {
    if (re.test(text)) { events.push(id); labels.push(label); }
  }
  return { events, labels };
}

// Base cost for an auto plan: the speaking route is a flat price (the
// rate-card tier does not apply — the engine is billed per clip), every
// other route uses the routed tier cost. Used by BOTH the analyzer and
// the canonicalizer so plan math and charge math can never diverge.
function autoBaseCost(routed, speaking) {
  return speaking ? CONFIG.speakingCost : routed.cost;
}

// The pure analyzer. Callers supply the translated prompt, the validated
// selections and a costForAspect(aspect) closure (server-side routing).
// Phase G negation detection (owner directive 2026-10-23, point 5): when
// the user says what they do NOT want — "no music", "silent video",
// "without dialogue", Urdu موسیقی نہیں / خاموش / بغیر آواز — the Auto
// Director must respect it: suppress the matching audio proposal, and for
// a global silence request flag the plan mute:true so the delivered
// video's audio track is stripped after generation. Detection runs on the
// raw user prompt (original + normalized effective text), never on
// server-appended style suffixes. Patterns are word-boundary based so
// unrelated words ("noir", "musical") never trigger.
const AUTO_NEGATION_PATTERNS = {
  mute: [
    /\bsilent\b/i, /\bsilence\b/i, /\bmuted?\b/i, /\bno audio\b/i,
    /\bwithout audio\b/i, /\bno sound\b/i, /\bwithout sound\b/i,
    /\bno voice\b/i, /\bwithout voice\b/i,
    /خاموش/, /بغیر آواز/, /آواز نہیں/, /کوئی آواز نہیں/,
  ],
  music: [
    /\bno music\b/i, /\bwithout music\b/i, /\bno background music\b/i,
    /\bno soundtrack\b/i, /\bno song\b/i,
    /موسیقی نہیں/, /موسیقی مت/, /بغیر موسیقی/, /گانا نہیں/,
  ],
  dialogue: [
    /\bno dialogue\b/i, /\bno dialog\b/i, /\bwithout dialogue\b/i,
    /\bno voiceover\b/i, /\bno voice-over\b/i, /\bno talking\b/i,
    /\bno speech\b/i, /\bno narration\b/i, /\bno narrator\b/i,
    /مکالمہ نہیں/, /مکالمے نہیں/, /گفتگو نہیں/,
  ],
  sfx: [
    /\bno sound effects\b/i, /\bno sfx\b/i, /\bwithout sound effects\b/i,
    /ساؤنڈ ایفیکٹس نہیں/,
  ],
};
function autoDetectNegations(...texts) {
  const hay = texts.filter(Boolean).join(' \n ');
  const hit = (list) => list.some(re => re.test(hay));
  const mute = hit(AUTO_NEGATION_PATTERNS.mute);
  return {
    mute,
    music: mute || hit(AUTO_NEGATION_PATTERNS.music),
    dialogue: mute || hit(AUTO_NEGATION_PATTERNS.dialogue),
    sfx: mute || hit(AUTO_NEGATION_PATTERNS.sfx),
  };
}

function analyzeAutoDirector(opts) {
  const {
    userId, originalPrompt, effectivePrompt, languageCode = 'en',
    selectedMode = 'realistic', selectedStyle = 'realistic',
    selectedAspect = '16:9', aspectExplicit = false,
    duration = 5, isDraft = false, character = null, hasSourceImage = false,
    existingSound = null, voiceSelection = null, voicePreferences = null,
    costForAspect,
  } = opts;
  const text = String(effectivePrompt || '').toLowerCase();
  const original = String(originalPrompt || '');
  const combined = `${original} ${effectivePrompt || ''}`;
  const notes = ['AI Auto Director is rule-based v1: it reads keywords and patterns in your prompt — it is not a large language model.'];
  const conflicts = [];
  // Phase G: what the user asked NOT to have (no music / no dialogue /
  // silent …) — computed once from the raw prompt and honoured below.
  const neg = autoDetectNegations(original, effectivePrompt);

  // --- content class ------------------------------------------------------
  const cartoonCues = /\bcartoon|animation|animated|anime|kids story|children'?s story|pixar\b/.test(text) ||
    /کارٹون|اینیمیشن|بچوں/.test(combined);
  const animalMatch = combined.match(/\b(lion|tiger|leopard|cheetah|jaguar|cat|dog|bird|horse|elephant|monkey|bear|deer|rabbit|fox|wolf|zebra|giraffe|cow|goat|sheep|duck|chicken|fish|whale|shark|panda|kangaroo|snake|frog|butterfly|bee|ant|spider|camel|donkey|buffalo|parrot|eagle|owl|penguin|dolphin|turtle|crocodile|hippo|rhino|koala|raccoon|squirrel|mouse|rat|pig|hen|rooster|turkey|ostrich)s?\b/i) ||
    /(شیر|بلی|کتا|پرندہ|گھوڑا|ہاتھی|بندر)/.test(combined);
  const productCues = /\bproduct|advertisement|commercial|brand|logo|perfume|smartphone|handbag|cosmetics|sneakers?\b/.test(text);
  const newsCues = /\bbreaking news|news presenter|news anchor|news studio|reporter|broadcast|headline\b/.test(text) ||
    /(خبریں|رپورٹر|اینکر|نشریات)/.test(combined);
  const musicPerfCues = /\bsinger|singing|music video|concert|musician|guitar|piano|violin|rapper|band performs\b/.test(text);
  const cinematicCues = /\bcinematic|film scene|movie scene|trailer|action scene|dramatic|drama\b/.test(text);
  const humanCues = /\bman|woman|person|people|human|boy|girl|lady|actor|actress|presenter|reporter|doctor|teacher|farmer|driver|singer|dancer|someone\b/.test(text) ||
    /(آدمی|انسان|شخص|لڑکا|لڑکی|عورت|مرد|اداکار|استاد|کسان|ڈرائیور|خاتون)/.test(combined);
  const realisticCues = /\bphotoreal(istic)?|real person|real human|realistic human|lifelike\b/.test(text) ||
    /حقیقی انسان|اصلی انسان/.test(combined);
  const realWildlifeCues = /\breal|wildlife|documentary|natural habitat\b/.test(text);
  let contentClass = 'general';
  if (cartoonCues) contentClass = 'cartoon';
  else if (animalMatch) contentClass = 'animal';
  else if (productCues) contentClass = 'product';
  else if (newsCues) contentClass = 'news';
  else if (musicPerfCues) contentClass = 'music';
  else if (cinematicCues) contentClass = 'cinematic';
  else if (humanCues) contentClass = 'human';

  // --- style enrichment ---------------------------------------------------
  const suffixParts = [];
  if (contentClass === 'animal') suffixParts.push('natural animal movement, realistic wildlife documentary feel, species-accurate behaviour');
  if (contentClass === 'cartoon') suffixParts.push('bright cartoon animation, expressive characters, playful movement');
  if (cinematicCues || contentClass === 'cinematic') suffixParts.push('cinematic lighting, dynamic camera movement, film-like composition');
  if (contentClass === 'human') suffixParts.push('natural human movement and expressions, realistic gestures');
  if (contentClass === 'product') suffixParts.push('clean commercial product presentation, polished studio lighting');
  if (contentClass === 'news') suffixParts.push('professional broadcast news presentation, studio lighting');
  if (contentClass === 'music') suffixParts.push('rhythmic music-video energy, performance-focused camera movement');
  const styleSuffix = [...new Set(suffixParts)].join('; ');

  // --- mode conflicts -------------------------------------------------------
  if (cartoonCues && selectedMode === 'realistic')
    conflicts.push({ field: 'mode', selected: selectedMode, detected: 'cartoon',
      question: 'Your prompt sounds like a cartoon/animation, but Realistic mode is selected. Which should win?' });
  else if (realisticCues && selectedMode === 'cartoon')
    conflicts.push({ field: 'mode', selected: selectedMode, detected: 'realistic',
      question: 'Your prompt asks for a real/photorealistic person, but Cartoon mode is selected. Which should win?' });
  else if (contentClass === 'animal' && selectedMode === 'cartoon' && realWildlifeCues)
    conflicts.push({ field: 'mode', selected: selectedMode, detected: 'realistic',
      question: 'Your prompt describes a real/wildlife animal, but Cartoon mode is selected. Which should win?' });

  // --- orientation ----------------------------------------------------------
  let orientationHint = null;
  if (/\bshorts?\b|\breels?\b|tiktok|vertical|portrait video/.test(text) || /عمودی/.test(combined))
    orientationHint = '9:16';
  else if (/\bwidescreen|landscape|cinematic\b/.test(text) || /افقی/.test(combined))
    orientationHint = '16:9';
  let finalAspect = selectedAspect;
  if (orientationHint && orientationHint !== selectedAspect) {
    if (aspectExplicit) {
      conflicts.push({ field: 'aspect_ratio', selected: selectedAspect, detected: orientationHint,
        question: `Your prompt suggests a ${orientationHint} video, but ${selectedAspect} is selected. Which should win?` });
    } else finalAspect = orientationHint;
  }

  // --- dialogue + voice route ----------------------------------------------
  const dialogue = autoDetectDialogue(original, effectivePrompt, languageCode);
  const routedHere = costForAspect(finalAspect);
  const canLipsync = !!(routedHere.plan && routedHere.plan.can_lipsync);
  // Speaking-engine preference (Phase E): fresh text-to-video human/news
  // scenes with usable dialogue on a speaking-eligible plan (can_veo =
  // Pro/Extra Pro) route to the one-step Gemini Omni engine FIRST — it
  // makes the video, its synchronized audio and the dialogue together at
  // the flat speaking price, so no voiceover/lip-sync add-on is stacked.
  // Character and image jobs keep the reference/image routes below.
  const canSpeaking = !!(routedHere.plan && routedHere.plan.can_veo);
  const speakingScene = contentClass === 'human' || contentClass === 'news';
  const omniRoute = !!(dialogue && !dialogue.from_translation &&
    ['ur', 'hi', 'en'].includes(dialogue.language) && !isDraft &&
    // 20s is a manual-only choice: the speaking engine's schema caps at
    // 10s, so a 20s request NEVER auto-routes to it — the dialogue takes
    // the standard two-part route with the voice step instead.
    Number(duration) <= 10 &&
    canSpeaking && !character && !hasSourceImage && speakingScene &&
    !voiceSelection && !existingSound && !neg.mute && !neg.dialogue &&
    CONFIG.speakingAspects.includes(finalAspect));
  if (dialogue && canSpeaking && !character && !hasSourceImage && !isDraft &&
      speakingScene && !dialogue.from_translation &&
      ['ur', 'hi', 'en'].includes(dialogue.language) && !omniRoute) {
    if (Number(duration) === 20)
      notes.push('20-second videos are made on the standard engine in two parts, so this dialogue uses the voice route instead of the speaking engine.');
    else if (!CONFIG.speakingAspects.includes(finalAspect))
      notes.push('The speaking engine only makes 16:9 or 9:16 videos, so this dialogue uses the voice route instead.');
    else if (existingSound)
      notes.push('You selected a sound add-on yourself, so the one-step speaking engine was not used — its own synchronized audio would clash with the add-on. The dialogue uses the voice route instead.');
  }
  // Phase G: a global silence request suppresses EVERY audio proposal
  // (voice, sound, and the speaking engine) and flags the plan mute:true —
  // the finished video's audio track is stripped before delivery. A
  // speaking video can never be silent, so when the dialogue would have
  // routed to the speaking engine this is a TRUE conflict for the
  // confirmation path to explain (the standard engine + mute wins).
  if (neg.mute) {
    notes.push('You asked for a silent video: no voice, sound effects or music will be added, and the generated audio track is removed before delivery (plan flag: mute = true).');
    if (dialogue && !dialogue.from_translation && canSpeaking && speakingScene &&
        !character && !hasSourceImage && !isDraft)
      conflicts.push({ field: 'audio', selected: 'speaking engine (synchronized speech)', detected: 'silent video',
        question: 'A speaking video cannot be silent — the speaking engine always generates speech audio. Make the silent video on the standard engine instead?' });
  }
  let voice = null;
  if (dialogue) {
    if (neg.dialogue) {
      // Phase G: "no dialogue / no voice / خاموش" wins over every voice
      // route — including a manually echoed voice selection.
      notes.push('You asked for no dialogue/voice, so the detected dialogue was not routed to a voice.');
    } else if (dialogue.from_translation) {
      notes.push('Dialogue was detected, but the exact original words could not be isolated, so no voice add-on was proposed — quote the spoken line in your prompt to use the voice route.');
    } else if (!['ur', 'hi', 'en'].includes(dialogue.language)) {
      notes.push(`Dialogue in "${dialogue.language}" cannot use the voice route — the voice catalog covers Urdu, Hindi and English only — so no voice add-on was proposed.`);
    } else if (isDraft) {
      notes.push('Drafts cannot take voice add-ons, so the detected dialogue was not routed to a voice. Upgrade the draft to full quality to add it.');
    } else if (omniRoute) {
      // voice stays null — the speaking engine IS the voice.
      notes.push('Speaking engine: the video, its synchronized audio and the dialogue are generated in one step (Gemini Omni) at the flat speaking price — no separate voiceover or lip-sync add-on is charged.');
      if (dialogue.language === 'ur')
        notes.push('Urdu speech on the speaking engine is not officially documented — judge it on the real generated sample. The separate Urdu voice + lip-sync route remains available on character and image videos.');
    } else if (voiceSelection && voiceSelection.kind) {
      const kind = voiceSelection.kind === 'lipsync' ? 'lipsync' : 'voiceover';
      voice = { kind, language: dialogue.language,
        // Phase G: in-generation audio is INCLUDED (cost 0) — the auto
        // route's lip-sync is LatentSync flat $0.20 + capped TTS, absorbed
        // by every tier (see README). The standalone /api/voice/lipsync
        // job is likewise included since Phase G2 (300-char script cap
        // + daily fair-use cap); it does not pass through here.
        cost: 0,
        text: dialogue.text, script_mode: dialogue.script_mode || 'native' };
    } else if (!defaultVoiceProvider()) {
      notes.push('Dialogue was detected, but no voice provider is configured on this server, so no voice add-on was proposed.');
    } else {
      const hasFace = !!character || contentClass === 'human';
      const kind = hasFace && canLipsync ? 'lipsync' : 'voiceover';
      voice = { kind, language: dialogue.language,
        cost: 0, // Phase G: included in the generation price (see above).
        text: dialogue.text, script_mode: dialogue.script_mode || 'native' };
      if (voicePreferences && typeof voicePreferences === 'object') {
        for (const k of ['provider', 'voice', 'style', 'speed'])
          if (voicePreferences[k]) voice[k] = String(voicePreferences[k]);
      }
      if (hasFace && !canLipsync)
        notes.push('Lip-sync needs the Pro or Extra Pro plan, so the dialogue uses the voiceover route instead.');
      if (dialogue.language === 'ur')
        notes.push('Urdu dialogue uses the separate Urdu voice route (voiceover or lip-sync): the video model\'s own built-in audio language is not guaranteed, and Urdu speech is not officially documented for it.');
      else
        notes.push('Dialogue uses the separate voice route: the video model\'s own built-in audio language is not guaranteed.');
      notes.push(kind === 'lipsync'
        ? 'Lip-sync is best-effort — the mouth match must be judged on the real generated sample, never assumed perfect.'
        : 'The voiceover replaces the generated video\'s original audio track with the synthesized voice.');
    }
  } else if (contentClass === 'animal') {
    notes.push('No human dialogue was detected, so no voice add-on is proposed.');
  }

  // --- sound: SFX events + music --------------------------------------------
  const { events: sfxEvents, labels: sfxLabels } = autoDetectSfx(combined.toLowerCase());
  const musicAsk = /\bbackground music|music|song|soundtrack|melody\b/.test(text) || /موسیقی|گانا/.test(combined);
  let sound = null;
  if (neg.mute) {
    // Phase G: silence wins over every sound proposal — including a sound
    // mode selected before "silent" was written in the prompt.
    if (existingSound && existingSound.mode)
      notes.push('You asked for a silent video, so the selected sound was dropped — the delivered video will have no audio track.');
    else if (sfxEvents.length || musicAsk)
      notes.push('You asked for a silent video, so the detected sounds/music were not added.');
  } else if (existingSound && existingSound.mode) {
    const mode = existingSound.mode;
    let prompt = existingSound.prompt || String(effectivePrompt || '');
    if (sfxLabels.length && !sfxLabels.some(l => prompt.toLowerCase().includes(l)))
      prompt = `${prompt} — sound events: ${sfxLabels.join(', ')}`.slice(0, 500);
    sound = { mode, prompt, cost: CONFIG.soundCosts[mode] || 0,
              volume: existingSound.volume ?? SOUND_DEFAULT_VOLUME[mode] ?? 100 };
    if (musicAsk && mode !== 'music')
      notes.push('Music was mentioned, but the sound mode you already selected is kept — only one generate-time sound mode is applied.');
  } else if (isDraft) {
    if (sfxEvents.length || musicAsk)
      notes.push('Drafts cannot take sound add-ons, so the detected sounds were not added. Upgrade the draft to full quality to add them.');
  } else if (omniRoute) {
    if (sfxEvents.length || musicAsk)
      notes.push('Scene sounds are part of the speaking engine\'s own synchronized audio, so no separate sound add-on was proposed.');
  } else if (!soundConfigured()) {
    if (sfxEvents.length || musicAsk)
      notes.push('Sounds were detected, but the sound engines are not configured on this server, so no sound add-on was proposed.');
  } else if (sfxEvents.length && !neg.sfx) {
    sound = { mode: 'sync',
      prompt: `${String(effectivePrompt || '').slice(0, 300)} — natural synchronized sounds: ${sfxLabels.join(', ')}`.slice(0, 500),
      cost: CONFIG.soundCosts.sync, volume: SOUND_DEFAULT_VOLUME.sync };
    if (musicAsk && !neg.music)
      notes.push('Music was also mentioned, but auto sync sound was chosen — only one generate-time sound mode can be applied, so the separate music track was skipped.');
    else if (musicAsk && neg.music)
      notes.push('You asked for no music, so no background music was added — only the scene sounds are synced.');
  } else if (musicAsk && !neg.music) {
    sound = { mode: 'music',
      prompt: `${String(effectivePrompt || '').slice(0, 300)} — instrumental background music matching the scene`.slice(0, 500),
      cost: CONFIG.soundCosts.music, volume: SOUND_DEFAULT_VOLUME.music };
  }
  if (!sound && !neg.mute && !isDraft) {
    if (neg.sfx && sfxEvents.length)
      notes.push('You asked for no sound effects, so the detected sound events were not added.');
    if (neg.music && musicAsk)
      notes.push('You asked for no music, so no background music was added.');
  }

  // --- costs + engine ---------------------------------------------------------
  const routed = costForAspect(finalAspect);
  const baseCost = autoBaseCost(routed, omniRoute);
  const addonsCost = omniRoute ? 0 : (sound ? sound.cost : 0) + (voice ? voice.cost : 0);
  const engine = autoEngineRoute({ character, hasSourceImage, resolution: routed.resolution, plan: routed.plan, voice, speaking: omniRoute });
  // Phase G: confirmation is for TRUE conflicts only (owner directive,
  // point 3). Audio is included in the generation price, so a voice/sound
  // proposal is standard — never a cost surprise — and the speaking route
  // and an auto-picked orientation apply automatically like everything
  // else. Only a genuine contradiction (mode clash, explicit aspect vs
  // prompt, speaking-vs-silent) asks the user first.
  const needsConfirmation = conflicts.length > 0;

  return {
    detected: {
      content_class: contentClass,
      dialogue: dialogue && !dialogue.from_translation
        ? { text: dialogue.text, language: dialogue.language } : (dialogue ? { text: dialogue.text, language: dialogue.language } : null),
      sfx_events: sfxEvents,
      music: musicAsk,
      negations: neg,
      orientation_hint: orientationHint,
    },
    apply: {
      mode: selectedMode,
      style_suffix: styleSuffix,
      aspect_ratio: finalAspect,
      sound, voice,
      // Phase E: true when this plan routes to the one-step speaking
      // engine; speaking_dialogue carries the exact line the engine
      // should speak (server-derived, re-validated on generate).
      speaking_engine: omniRoute,
      // Phase G: true when the user asked for a silent video — after the
      // video completes, its audio track is stripped before delivery
      // (ensureMuteApplied); the row tracks it via mute_status.
      mute: neg.mute,
      ...(omniRoute && dialogue ? { speaking_dialogue: { text: dialogue.text, language: dialogue.language } } : {}),
    },
    engine,
    conflicts,
    base_cost: baseCost,
    addons_cost: addonsCost,
    total_cost: baseCost + addonsCost,
    notes,
    needs_confirmation: needsConfirmation,
    meta: {
      aspect_explicit: !!aspectExplicit,
      selected_aspect_ratio: selectedAspect,
      selected_mode: selectedMode,
      selected_style: selectedStyle,
      resolution: routed.resolution,
    },
  };
}

// Canonicalize a confirmed plan against a FRESH analysis: only effects the
// echoed plan actually contains AND that match the fresh analysis are
// applied; every cost is recomputed from the rate card / routing ladder.
function canonicalizeAutoPlan(fresh, echo, { character = null, hasSourceImage = false, costForAspect } = {}) {
  if (!echo || typeof echo !== 'object' || !echo.apply || typeof echo.apply !== 'object') return null;
  const e = echo.apply;
  const selectedAspect = fresh.meta.selected_aspect_ratio;
  const selectedMode = fresh.meta.selected_mode;
  let aspect = selectedAspect;
  if (CONFIG.aspectRatios.includes(e.aspect_ratio)) {
    if (e.aspect_ratio === fresh.apply.aspect_ratio) aspect = e.aspect_ratio;
    else {
      const c = fresh.conflicts.find(x => x.field === 'aspect_ratio');
      if (c && e.aspect_ratio === c.detected) aspect = e.aspect_ratio;
    }
  }
  let mode = selectedMode;
  if (e.mode && Object.hasOwn(VIDEO_MODES, e.mode)) {
    if (e.mode === fresh.apply.mode) mode = e.mode;
    else {
      const c = fresh.conflicts.find(x => x.field === 'mode');
      if (c && e.mode === c.detected) mode = e.mode;
    }
  }
  const suffix = (typeof e.style_suffix === 'string' && e.style_suffix === fresh.apply.style_suffix)
    ? e.style_suffix : '';
  let sound = null;
  if (e.sound && fresh.apply.sound && e.sound.mode === fresh.apply.sound.mode &&
      e.sound.prompt === fresh.apply.sound.prompt)
    sound = { ...fresh.apply.sound, cost: CONFIG.soundCosts[fresh.apply.sound.mode] || 0 };
  let voice = null;
  if (e.voice && fresh.apply.voice && e.voice.kind === fresh.apply.voice.kind &&
      e.voice.language === fresh.apply.voice.language && e.voice.text === fresh.apply.voice.text)
    voice = { ...fresh.apply.voice,
      cost: 0 }; // Phase G: in-generation audio is included — recomputed as 0.
  // Speaking route (Phase E): applies ONLY when the fresh analysis AND
  // the echoed plan both carry the speaking route — a client can never
  // forge it, and when it applies, voice/sound add-ons stay null (the
  // engine's own synchronized audio replaces them) and the base cost is
  // the flat speaking price. The dialogue line is the server-derived one.
  const speaking = fresh.apply.speaking_engine === true && e.speaking_engine === true &&
    fresh.engine && fresh.engine.route === 'omni_speaking' &&
    echo.engine && echo.engine.route === 'omni_speaking';
  if (speaking) { sound = null; voice = null; }
  // Phase G mute: applies ONLY when the fresh analysis AND the echoed
  // plan both carry it — server-derived, never forgeable. (Speaking +
  // mute cannot co-occur canonically: the analyzer never proposes the
  // speaking route for a muted prompt, so `speaking` is false then.)
  const mute = fresh.apply.mute === true && e.mute === true;
  const routed = costForAspect(aspect);
  const baseCost = autoBaseCost(routed, speaking);
  const addonsCost = (sound ? sound.cost : 0) + (voice ? voice.cost : 0);
  const engine = autoEngineRoute({ character, hasSourceImage, resolution: routed.resolution, plan: routed.plan, voice, speaking });
  return {
    ...fresh,
    apply: { mode, style_suffix: suffix, aspect_ratio: aspect, sound, voice,
      speaking_engine: speaking, mute,
      ...(speaking && fresh.apply.speaking_dialogue
        ? { speaking_dialogue: fresh.apply.speaking_dialogue } : {}) },
    engine,
    base_cost: baseCost,
    addons_cost: addonsCost,
    total_cost: baseCost + addonsCost,
    confirmed: true,
  };
}

// ---------- AI Auto Director: free plan endpoint ---------------------------
// Same validation family as /api/generate (auth + the generate rate-limit
// family), but it NEVER charges and NEVER creates a generation row.
app.post('/api/generate/plan', auth, generateLimiter, async (req, res) => {
  const b = req.body || {};
  const prompt = b.prompt;
  const languageCode = String(b.prompt_language || b.language || 'en').toLowerCase();
  const mode = String(b.mode || 'realistic').toLowerCase();
  const style = b.style === undefined ? 'realistic' : b.style;
  const duration = b.duration === undefined ? 5 : b.duration;
  const aspectExplicit = b.aspect_ratio !== undefined && b.aspect_ratio !== null && b.aspect_ratio !== '';
  const selectedAspect = aspectExplicit ? String(b.aspect_ratio) : '16:9';
  if (!prompt || typeof prompt !== 'string' || prompt.trim().length < 3 || prompt.length > 500)
    return res.status(400).json({ error: 'Please describe your video in 3–500 characters.' });
  if (!CONFIG.aspectRatios.includes(selectedAspect))
    return res.status(400).json({ error: `aspect_ratio must be one of: ${CONFIG.aspectRatios.join(', ')}` });
  if (!CONFIG.durations20.includes(Number(duration)))
    return res.status(400).json({ error: `duration must be one of: ${CONFIG.durations20.join(', ')} seconds` });
  if (!CONFIG.styles.includes(style))
    return res.status(400).json({ error: `style must be one of: ${CONFIG.styles.join(', ')}` });
  if (!Object.hasOwn(VIDEO_MODES, mode))
    return res.status(400).json({ error: `mode must be one of: ${Object.keys(VIDEO_MODES).join(', ')}` });
  if (!VIDEO_MODES[mode].includes(style))
    return res.status(400).json({ error: `style "${style}" is not available in ${mode} mode — use one of: ${VIDEO_MODES[mode].join(', ')}` });
  if (!PROMPT_LANGUAGES.some(l => l.code === languageCode))
    return res.status(400).json({ error: `language must be one of: ${PROMPT_LANGUAGES.map(l => l.code).join(', ')}` });
  const isDraft = String(b.quality || '').toLowerCase() === 'draft';
  let wantedResolution = null;
  const wantedRaw = b.resolution !== undefined && b.resolution !== null && b.resolution !== ''
    ? String(b.resolution).toUpperCase()
    : (['768P', '2K', '4K'].includes(String(b.quality || '').toUpperCase()) ? String(b.quality).toUpperCase() : null);
  if (wantedRaw) {
    if (!RESOLUTIONS.includes(wantedRaw))
      return res.status(400).json({ error: `resolution must be one of: ${RESOLUTIONS.join(', ')}` });
    wantedResolution = wantedRaw;
  }
  let character = null;
  if (b.character_id !== undefined && b.character_id !== null && b.character_id !== '') {
    character = getOwnCharacter(req.user.id, b.character_id);
    if (!character) return res.status(404).json({ error: 'Character not found.' });
  }
  let hasSourceImage = false;
  if (character) hasSourceImage = false; // the character route wins, as in /api/generate
  else if (b.image_path !== undefined && b.image_path !== null && b.image_path !== '') {
    if (!resolveOwnedUpload(req.user.id, b.image_path))
      return res.status(400).json({ error: 'image_path must be an image you uploaded (POST /api/uploads/image).' });
    hasSourceImage = true;
  }
  // Current sound selection (if any) — validated exactly like /api/generate.
  let existingSound = null;
  if (b.sound !== undefined && b.sound !== null) {
    const s = (typeof b.sound === 'object') ? b.sound : {};
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
    existingSound = { mode: smode, volume: svol, promptRaw: sPromptRaw, prompt: null };
  }
  if (isDraft && existingSound)
    return res.status(400).json({ error: 'Drafts cannot take sound add-ons. Generate the draft first, then upgrade it to full quality and add sound to that version.' });
  if (moderated(prompt))
    return res.status(400).json({ error: 'This prompt was blocked by content moderation. Please rephrase it.' });
  // Translation first (same step, same honest failure as /api/generate) —
  // still no charge and no generation row, whatever happens.
  let effectivePrompt = prompt.trim();
  if (TRANSLATED_LANGUAGES.has(languageCode)) {
    let translated;
    try { translated = await translatePrompt(prompt.trim(), languageCode); }
    catch { return res.status(502).json({ error: 'We could not translate your prompt into English, so nothing was charged. Please try again.' }); }
    if (moderated(translated))
      return res.status(400).json({ error: 'This prompt was blocked by content moderation. Please rephrase it.' });
    effectivePrompt = translated;
  }
  if (existingSound) {
    if (existingSound.promptRaw && TRANSLATED_LANGUAGES.has(languageCode)) {
      try { existingSound.prompt = await translatePrompt(existingSound.promptRaw, languageCode); }
      catch { return res.status(502).json({ error: 'We could not translate your sound description into English, so nothing was charged. Please try again.' }); }
      if (moderated(existingSound.prompt))
        return res.status(400).json({ error: 'The sound description was blocked by content moderation. Please rephrase it.' });
    } else {
      existingSound.prompt = existingSound.promptRaw || effectivePrompt;
    }
  }
  const costForAspect = (aspect) => autoRoutedQuality(req.user.id, {
    wantedResolution, aspectRatio: aspect, duration: Number(duration), isDraft });
  const voiceSelection = (b.voice && typeof b.voice === 'object' && b.voice.kind) ? b.voice : null;
  const characterPrefs = character && character.voice_provider
    ? { provider: character.voice_provider, voice: character.voice_id, style: character.voice_style } : {};
  const voicePreferences = { ...characterPrefs,
    ...((b.voice && typeof b.voice === 'object' && !b.voice.kind) ? b.voice : {}) };
  const plan = analyzeAutoDirector({
    userId: req.user.id, originalPrompt: prompt, effectivePrompt, languageCode,
    selectedMode: mode, selectedStyle: style, selectedAspect, aspectExplicit,
    duration: Number(duration), isDraft, character, hasSourceImage,
    existingSound, voiceSelection, voicePreferences, costForAspect,
  });
  res.json({ plan });
});


// ---------- Generation (idempotent + atomic charge) ----------
app.post('/api/generate', auth, generateLimiter, async (req, res) => {
  const { prompt, duration = 5, language = 'en' } = req.body || {};
  let aspect_ratio = req.body?.aspect_ratio || '16:9';
  let style = req.body?.style === undefined ? 'realistic' : req.body.style;
  let mode = String(req.body?.mode || 'realistic').toLowerCase();
  const idemKey = String(req.headers['idempotency-key'] || req.body?.idempotency_key || '').slice(0, 80) || null;

  if (!prompt || prompt.trim().length < 3 || prompt.length > 500)
    return res.status(400).json({ error: 'Please describe your video in 3–500 characters.' });
  if (!CONFIG.aspectRatios.includes(aspect_ratio))
    return res.status(400).json({ error: `aspect_ratio must be one of: ${CONFIG.aspectRatios.join(', ')}` });
  // Duration set (Phase L, extended 2026-10-27): every engine is capped
  // at the standard set EXCEPT the Seedance premium engine, whose fal
  // schema genuinely allows up to 30s — it alone may use its extended
  // set. The standard set now includes 20s, which ONLY the H3 routes
  // (768P / 2K / Draft) honour — as a two-part chained generation; the
  // speaking block and the post-routing 4K check below reject 20s for
  // their routes BEFORE any charge, so a longer duration is never faked.
  const engineRequested = String(req.body?.engine || '').toLowerCase();
  const allowedDurations = ['seedance', 'seedance_premium'].includes(engineRequested)
    ? CONFIG.seedanceDurations : CONFIG.durations20;
  if (!allowedDurations.includes(Number(duration)))
    return res.status(400).json({ error: `duration must be one of: ${allowedDurations.join(', ')} seconds` });
  if (!CONFIG.styles.includes(style))
    return res.status(400).json({ error: `style must be one of: ${CONFIG.styles.join(', ')}` });
  if (!Object.hasOwn(VIDEO_MODES, mode))
    return res.status(400).json({ error: `mode must be one of: ${Object.keys(VIDEO_MODES).join(', ')}` });
  if (!VIDEO_MODES[mode].includes(style))
    return res.status(400).json({ error: `style "${style}" is not available in ${mode} mode — use one of: ${VIDEO_MODES[mode].join(', ')}` });
  // Optional cinematic direction (Phase L): camera movement + shot
  // size from fixed whitelists — anything else is a 400 before any
  // charge. The choices are appended to the prompt as plain-English
  // directives after translation + Auto enrichment (below) and are
  // recorded on the row; they cost nothing extra.
  let cameraMove = null;
  let shotSize = null;
  if (req.body?.camera !== undefined && req.body?.camera !== null && String(req.body.camera) !== '') {
    const c = String(req.body.camera).toLowerCase();
    if (!Object.hasOwn(CAMERA_MOVES, c))
      return res.status(400).json({ error: `camera must be one of: ${Object.keys(CAMERA_MOVES).join(', ')}` });
    cameraMove = c;
  }
  if (req.body?.shot !== undefined && req.body?.shot !== null && String(req.body.shot) !== '') {
    const s = String(req.body.shot).toLowerCase();
    if (!Object.hasOwn(SHOT_SIZES, s))
      return res.status(400).json({ error: `shot must be one of: ${Object.keys(SHOT_SIZES).join(', ')}` });
    shotSize = s;
  }
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
  // Draft workflow (Phase C1): quality "draft" = a cheap 480P preview on
  // the standard H3 model, priced flat (70/140 credits). Drafts cannot take
  // sound add-ons — sound belongs on the upgraded full-quality version.
  const isDraft = String(req.body?.quality || '').toLowerCase() === 'draft';
  if (isDraft && soundSpec)
    return res.status(400).json({ error: 'Drafts cannot take sound add-ons. Generate the draft first, then upgrade it to full quality and add sound to that version.' });
  // Optional saved character (Phase C2): the character must be one of
  // THIS user's saved characters (404 otherwise — never a hint that
  // someone else's character exists). Its reference image drives the
  // visual via the reference-to-video route below, so the character's
  // image becomes the source image here; an explicit image_path sent
  // alongside a character is ignored (the character wins).
  let character = null;
  if (req.body?.character_id !== undefined && req.body?.character_id !== null && req.body?.character_id !== '') {
    character = getOwnCharacter(req.user.id, req.body.character_id);
    if (!character)
      return res.status(404).json({ error: 'Character not found.' });
  }
  // Optional image-to-video: the source image must be one of THIS user's
  // uploads (see POST /api/uploads/image). It is sent to the verified H3
  // image-to-video endpoint in its documented `image_url` field as a
  // base64 data URI (fal accepts data URIs for file inputs).
  let sourceImagePath = null;
  let sourceImageDataUri = null;
  const wantedImagePath = character ? character.image_path : req.body?.image_path;
  if (wantedImagePath !== undefined && wantedImagePath !== null && wantedImagePath !== '') {
    const owned = resolveOwnedUpload(req.user.id, wantedImagePath);
    if (!owned)
      return res.status(400).json({ error: character
        ? 'The saved character image is no longer available. Please delete the character and save it again with a fresh upload.'
        : 'image_path must be an image you uploaded (POST /api/uploads/image).' });
    sourceImagePath = String(wantedImagePath).replace(/\\/g, '/').replace(/^\.\//, '');
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

  // --- AI Auto Director (Phase D): apply a confirmed plan ------------------
  // The client echoes the plan it showed the user plus auto_confirmed:true.
  // The server RE-RUNS the analyzer on this exact request and applies only
  // the effects that match the fresh analysis (canonicalizeAutoPlan) — all
  // costs are recomputed from the rate card, so a tampered plan cannot
  // invent discounts, free add-ons or an unentitled engine route. When
  // auto is not used, nothing below runs and behaviour is unchanged.
  let autoPlanToStore = null;
  let autoVoiceSpec = null;
  let autoVoiceCost = 0;
  let autoMute = false;
  if (req.body?.auto_confirmed === true && req.body?.auto_plan &&
      typeof req.body.auto_plan === 'object') {
    if (req.body.resolution !== undefined) {
      const wantedCheck = String(req.body.resolution).toUpperCase();
      if (!RESOLUTIONS.includes(wantedCheck))
        return res.status(400).json({ error: `resolution must be one of: ${RESOLUTIONS.join(', ')}` });
    }
    const echo = req.body.auto_plan;
    const aspectExplicit = echo?.meta?.aspect_explicit !== undefined
      ? !!echo.meta.aspect_explicit
      : (req.body?.aspect_ratio !== undefined && req.body?.aspect_ratio !== null && req.body?.aspect_ratio !== '');
    const wantedResolution = req.body.resolution !== undefined
      ? String(req.body.resolution).toUpperCase()
      : (['768P', '2K', '4K'].includes(String(req.body?.quality || '').toUpperCase())
          ? String(req.body.quality).toUpperCase() : null);
    const autoCostForAspect = (aspect) => autoRoutedQuality(req.user.id, {
      wantedResolution, aspectRatio: aspect, duration: Number(duration), isDraft });
    const characterPrefs = character && character.voice_provider
      ? { provider: character.voice_provider, voice: character.voice_id, style: character.voice_style } : {};
    const voicePreferences = { ...characterPrefs,
      ...((req.body?.voice && typeof req.body.voice === 'object' && !req.body.voice.kind) ? req.body.voice : {}) };
    const freshPlan = analyzeAutoDirector({
      userId: req.user.id, originalPrompt: prompt, effectivePrompt, languageCode,
      selectedMode: mode, selectedStyle: style, selectedAspect: aspect_ratio, aspectExplicit,
      duration: Number(duration), isDraft, character, hasSourceImage: !!sourceImagePath,
      existingSound: soundSpec ? { mode: soundSpec.mode, prompt: soundSpec.prompt, volume: soundSpec.volume } : null,
      voiceSelection: (req.body?.voice && typeof req.body.voice === 'object' && req.body.voice.kind) ? req.body.voice : null,
      voicePreferences, costForAspect: autoCostForAspect,
    });
    const appliedPlan = canonicalizeAutoPlan(freshPlan, echo, {
      character, hasSourceImage: !!sourceImagePath, costForAspect: autoCostForAspect });
    if (appliedPlan) {
      autoPlanToStore = appliedPlan;
      if (appliedPlan.apply.mode && appliedPlan.apply.mode !== mode) {
        mode = appliedPlan.apply.mode;
        if (!VIDEO_MODES[mode].includes(style)) style = VIDEO_MODES[mode][0];
      }
      if (appliedPlan.apply.aspect_ratio) aspect_ratio = appliedPlan.apply.aspect_ratio;
      if (appliedPlan.apply.style_suffix) {
        const suffix = appliedPlan.apply.style_suffix;
        if (!effectivePrompt.includes(suffix)) effectivePrompt = `${effectivePrompt} — ${suffix}`;
      }
      if (appliedPlan.apply.sound) {
        const as = appliedPlan.apply.sound;
        soundSpec = { mode: as.mode,
          volume: as.volume ?? (soundSpec ? soundSpec.volume : undefined) ?? SOUND_DEFAULT_VOLUME[as.mode] ?? 100,
          promptRaw: soundSpec ? soundSpec.promptRaw : null, prompt: as.prompt };
      } else if (soundSpec) {
        // Auto was confirmed but the echoed plan does not include the
        // manual sound selection — only what the plan contains applies.
        soundSpec = null;
      }
      if (appliedPlan.apply.voice) {
        autoVoiceSpec = appliedPlan.apply.voice;
        autoVoiceCost = Number(autoVoiceSpec.cost) || 0;
      }
      // Phase G: a confirmed silent plan — the row starts with
      // mute_status='pending' and the audio track is stripped after the
      // video completes (ensureMuteApplied), before watermarking.
      if (appliedPlan.apply.mute === true) autoMute = true;
    }
  }

  // --- Cinematic direction (Phase L): apply the camera/shot chips -----
  // The directive suffix goes on LAST: after translation and after the
  // Auto Director's own enrichment, so every text-prompt route below
  // (H3 text/image/reference, Kling 4K, Omni speaking, Seedance) sends
  // it verbatim. When the prompt text itself names a DIFFERENT camera
  // move or shot size, the explicit chip wins (it is the final, direct
  // instruction) and the stored plan notes the override — no extra
  // confirmation round.
  const cameraSuffix = cameraDirectiveSuffix(cameraMove, shotSize);
  if (cameraSuffix) {
    if (autoPlanToStore) {
      const clash = promptCameraClash(effectivePrompt, cameraMove, shotSize);
      if (clash) {
        const chosen = [cameraMove && CAMERA_MOVES[cameraMove].label,
                        shotSize && SHOT_SIZES[shotSize].label].filter(Boolean).join(' · ');
        autoPlanToStore = { ...autoPlanToStore,
          notes: [...(Array.isArray(autoPlanToStore.notes) ? autoPlanToStore.notes : []),
            `Camera direction: your ${clash} chip choice (${chosen}) was applied as a prompt directive and overrides the camera wording in your prompt text.`] };
      }
    }
    effectivePrompt = `${effectivePrompt}${cameraSuffix}`;
  }

  // --- Speaking engine (Phase E: Gemini Omni) ------------------------------
  // Selected directly via engine:'speaking' (alias 'omni_speaking') or via
  // a confirmed AI Auto plan whose canonicalized apply carries
  // speaking_engine:true. The engine generates the video WITH its own
  // synchronized dialogue audio in one step, so voice/sound add-ons that
  // would duplicate that audio are REJECTED with 400 (clearer than
  // silently dropping a paid selection), as are drafts, characters and
  // source images (text-to-video only) and non-16:9/9:16 aspects — all
  // BEFORE any charge. Entitlement: plans with can_veo (Pro/Extra Pro).
  const wantsSpeaking = ['speaking', 'omni_speaking']
    .includes(String(req.body?.engine || '').toLowerCase());
  const planSpeaking = !!(autoPlanToStore && autoPlanToStore.apply &&
    autoPlanToStore.apply.speaking_engine === true);
  let isSpeaking = false;
  let speakingDialogue = null;
  if (wantsSpeaking || planSpeaking) {
    // 20s is never a speaking video: the Omni schema caps at 10s and the
    // two-part chain exists only on the H3 routes. Rejected pre-charge.
    if (Number(duration) === 20)
      return res.status(400).json({ error: '20-second videos are made on the standard engine in two parts — the speaking engine makes up to 10 seconds. Remove the speaking engine, or choose 5 or 10 seconds.' });
    // Phase G: a speaking video CANNOT be silent — the engine always
    // generates synchronized speech audio. A silence request in the
    // prompt (or a confirmed mute plan) is a true conflict: reject with a
    // clear message before any charge.
    if (autoMute || autoDetectNegations(prompt).mute)
      return res.status(400).json({ error: 'A speaking video cannot be silent — the speaking engine always generates speech audio. Remove the silence request, or generate the silent video without the speaking engine (AI Auto strips the audio track instead).' });
    if (isDraft)
      return res.status(400).json({ error: 'The speaking engine makes full-quality videos only — it cannot be combined with a draft.' });
    if (character)
      return res.status(400).json({ error: 'The speaking engine is text-to-video only — saved-character videos keep the reference route with its voice options.' });
    if (sourceImagePath)
      return res.status(400).json({ error: 'The speaking engine is text-to-video only — videos from a starting image keep the image-to-video route with its voice options.' });
    if (!CONFIG.speakingAspects.includes(aspect_ratio))
      return res.status(400).json({ error: `The speaking engine only makes ${CONFIG.speakingAspects.join(' or ')} videos — pick one of those aspect ratios, or generate without the speaking engine.` });
    if (soundSpec)
      return res.status(400).json({ error: 'The speaking engine generates its own synchronized audio, so sound add-ons cannot be combined with it. Remove the sound add-on, or generate without the speaking engine.' });
    if (autoVoiceSpec)
      return res.status(400).json({ error: 'The speaking engine speaks the dialogue itself, so voiceover/lip-sync add-ons cannot be combined with it.' });
    refreshSubscriptionState(req.user.id);
    const speakSub = currentSubscription(req.user.id);
    const speakPlan = speakSub ? getPlan(speakSub.plan_id) : null;
    if (!speakPlan || !speakPlan.can_veo)
      return res.status(403).json({ error: 'Speaking video clips are included with the Pro and Extra Pro plans.' });
    isSpeaking = true;
    if (planSpeaking && autoPlanToStore.apply.speaking_dialogue)
      speakingDialogue = autoPlanToStore.apply.speaking_dialogue;
  }

  // --- Premium engine (Phase J: Seedance 2.5) ------------------------------
  // Selected DIRECTLY via engine:'seedance' (alias 'seedance_premium') —
  // never by the AI Auto Director, which never proposes this engine
  // (premium price): canonicalizeAutoPlan rebuilds the plan's engine
  // from the fresh analysis, which has no seedance route, so a forged
  // seedance claim in an echoed plan is discarded exactly like a forged
  // Kling claim. A confirmed auto plan therefore cannot combine with
  // this engine (400 below). The engine generates its own synchronized
  // native audio, so voice/sound add-ons are REJECTED with 400 (never
  // silently dropped), as are drafts, characters and source images
  // (text-to-video only) and aspects outside 16:9 / 9:16 / 1:1 — all
  // BEFORE any charge. Entitlement: Extra Pro only (can_seedance).
  // Routed at 720p — this engine is NEVER 4K (see the CONFIG note).
  const wantsSeedance = ['seedance', 'seedance_premium']
    .includes(String(req.body?.engine || '').toLowerCase());
  let isSeedance = false;
  if (wantsSeedance) {
    if (autoPlanToStore)
      return res.status(400).json({ error: 'The Seedance premium engine is a direct choice and never part of an AI Auto plan. Turn AI Auto off, or generate without the premium engine.' });
    if (isDraft)
      return res.status(400).json({ error: 'The Seedance premium engine makes full-quality videos only — it cannot be combined with a draft.' });
    if (character)
      return res.status(400).json({ error: 'The Seedance premium engine is text-to-video only — saved-character videos keep the reference route.' });
    if (sourceImagePath)
      return res.status(400).json({ error: 'The Seedance premium engine is text-to-video only — videos from a starting image keep the image-to-video route.' });
    if (!CONFIG.seedanceAspects.includes(aspect_ratio))
      return res.status(400).json({ error: `The Seedance premium engine only makes ${CONFIG.seedanceAspects.join(', ')} videos — pick one of those aspect ratios, or generate without the premium engine.` });
    if (soundSpec)
      return res.status(400).json({ error: 'The Seedance premium engine generates its own synchronized audio, so sound add-ons cannot be combined with it. Remove the sound add-on, or generate without the premium engine.' });
    if (autoVoiceSpec || (req.body?.voice && typeof req.body.voice === 'object' && req.body.voice.kind))
      return res.status(400).json({ error: 'The Seedance premium engine generates its own synchronized audio and speech, so voiceover/lip-sync add-ons cannot be combined with it.' });
    refreshSubscriptionState(req.user.id);
    const sdSub = currentSubscription(req.user.id);
    const sdPlan = sdSub ? getPlan(sdSub.plan_id) : null;
    if (!sdPlan || !sdPlan.can_seedance)
      return res.status(403).json({ error: 'Seedance 2.5 premium videos are included with the Extra Pro plan.' });
    isSeedance = true;
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
  // Character override: a saved character's image goes to the verified
  // reference-to-video endpoint (it takes the image as a REFERENCE for
  // subject consistency rather than as the literal opening frame). Plan
  // caps, the rate card and the 4K aspect fallback above are unchanged —
  // the endpoint's own resolution ladder matches the H3 table (its 2K/4K
  // are upscales of a 768P base, exactly like the H3 text/image routes;
  // only the Kling route is native 4K, and a character job never takes
  // it because Kling has no reference-image input).
  if (character) model = CONFIG.modelRef;
  // Draft override: 480P on the standard H3 model (480P is a documented
  // H3 resolution tier), flat draft pricing instead of the rate card.
  if (isDraft) {
    resolution = '480P';
    model = character ? CONFIG.modelRef
          : sourceImagePath ? CONFIG.modelI2V : CONFIG.model;
  }
  // Speaking override (Phase E): the one-step Gemini Omni route at 720p.
  // The structural gates above guarantee no character/image/draft/add-ons
  // reach this point, so the override is unconditional here.
  if (isSpeaking) { model = CONFIG.modelOmni; resolution = '720P'; }
  // Premium override (Phase J): the Seedance 2.5 route at 720p. Its
  // structural gates above likewise guarantee no character/image/draft/
  // add-ons reach this point, so the override is unconditional here.
  if (isSeedance) { model = CONFIG.modelSeedance; resolution = '720P'; }
  // 20s two-part chain (2026-10-27): after every override, a job still
  // routed to native 4K (Kling O3 — its schema has no 20s and there is
  // no chained route for it) is rejected BEFORE any charge. (A 4K job
  // at an unsupported aspect already fell back to 2K above, so it takes
  // the chain like any other 2K job; speaking rejected 20s in its own
  // block; Seedance prices 20s from its own table.)
  if (Number(duration) === 20 && !isSeedance && resolution === '4K')
    return res.status(400).json({ error: '20 seconds is not available in native 4K. Choose 768P, 2K or Draft quality for a 20-second video — it is made in two parts and joined automatically.' });
  // A 20s job that reaches the charge below is therefore always an H3
  // route (text / image / reference, or a 480P draft): it is born with
  // chain_stage 'part1' and its provider submission is a normal 10s job.
  const isChain20 = Number(duration) === 20 && !isSeedance;
  // Rate card (v9, x10 scale since 2026-10-26): the credit cost comes
  // from the ROUTED quality's own row — 768P 100/200, 2K 150/300,
  // native 4K 450/900 for 5s/10s. Speaking jobs are the flat speaking
  // price instead (500 credits, either duration); Seedance premium
  // jobs pay the per-duration premium price (Phase J, extended by
  // Phase L: a linear 120 credits/second — 600/1200/1800/2400/3600
  // for 5/10/15/20/30s).
  const cost = isSeedance ? (CONFIG.seedanceCost[Number(duration)] ?? CONFIG.seedanceCost[5])
             : isSpeaking ? CONFIG.speakingCost
             : isDraft ? (CONFIG.draftCost[Number(duration)] ?? 70)
                       : generationCost(resolution, Number(duration));
  // The sound add-on is charged together with the video in the same
  // atomic transaction (exactly once). If the video fails, the whole
  // amount is refunded by failAndRefund; if only the sound step fails,
  // just the add-on is refunded (see ensureSoundApplied).
  const soundCost = soundSpec ? CONFIG.soundCosts[soundSpec.mode] : 0;
  const totalCost = cost + soundCost + autoVoiceCost;
  // The applied plan records the route the server ACTUALLY used — server
  // routing always wins over whatever the echoed plan claimed (e.g. a
  // plan claiming the Kling 4K route for a non-entitled user records the
  // H3 route the server really took).
  if (autoPlanToStore) {
    const actualEngine = autoEngineRoute({ character, hasSourceImage: !!sourceImagePath,
      resolution, plan, voice: autoVoiceSpec, speaking: isSpeaking });
    if (actualEngine.route !== autoPlanToStore.engine?.route ||
        actualEngine.voice_route !== autoPlanToStore.engine?.voice_route)
      autoPlanToStore = { ...autoPlanToStore, engine: actualEngine };
  }

  // Duplicate-request protection: same idempotency key returns the existing
  // job — no second charge, no second fal.ai submission.
  if (idemKey) {
    const existing = db.prepare('SELECT * FROM generations WHERE user_id = ? AND idempotency_key = ?')
      .get(req.user.id, idemKey);
    if (existing) return res.json({ id: existing.id, status: existing.status, duplicate: true,
      ...(existing.auto_plan ? { auto_plan: parseStoredAutoPlan(existing.auto_plan) } : {}) });
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
        `INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, cost_credits, idempotency_key, resolution, model, prompt_language, translated_prompt, mode, source_image_path, watermark_text, watermark_status, sound_mode, sound_status, sound_prompt, sound_volume, sound_cost, stage, character_id, auto_plan, auto_voice_status, auto_voice_cost, mute_status, camera_move, shot_size, chain_stage)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`).run(user.id, prompt.trim(), aspect_ratio, Number(duration), style, totalCost, idemKey, resolution, model, languageCode, translatedPrompt, mode, sourceImagePath, watermarkText, watermarkStatus,
           soundSpec ? soundSpec.mode : null, soundSpec ? 'pending' : 'none',
           soundSpec ? soundSpec.prompt : null, soundSpec ? soundSpec.volume : null, soundCost,
           isDraft ? 'draft' : 'final', character ? character.id : null,
           autoPlanToStore ? JSON.stringify(autoPlanToStore) : null,
           autoVoiceSpec ? 'pending' : 'none', autoVoiceCost,
           autoMute ? 'pending' : 'none', cameraMove, shotSize,
           isChain20 ? 'part1' : null);
      return Number(info.lastInsertRowid);
    });
  } catch (e) {
    if (e.message === 'DAILY_LIMIT') return res.status(429).json({ error: 'Daily spending limit reached. Try again tomorrow.' });
    if (e.message === 'NO_CREDITS') return res.status(402).json({ error: 'Not enough credits.' });
    if (String(e.message).includes('UNIQUE')) { // race on idempotency key
      const existing = db.prepare('SELECT * FROM generations WHERE user_id = ? AND idempotency_key = ?')
        .get(req.user.id, idemKey);
      if (existing) return res.json({ id: existing.id, status: existing.status, duplicate: true,
        ...(existing.auto_plan ? { auto_plan: parseStoredAutoPlan(existing.auto_plan) } : {}) });
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
  // Reference-to-video body (schema verified from fal's llms.txt for
  // minimax/h3/reference-to-video, 2026-10-23): the character image goes
  // in reference_image_urls as a base64 data URI (fal accepts data URIs
  // for file inputs, as with image_url elsewhere), and the prompt names
  // it "Image 1" — the documented way to cite a reference in the text.
  // Speaking body (Phase E): EXACTLY the four fields of the verified
  // Gemini Omni schema — prompt, aspect_ratio, resolution, duration —
  // and nothing else (the endpoint has no safety-checker/audio fields).
  // The prompt carries the dialogue the user wrote; when a confirmed
  // auto plan detected the spoken line, it is appended explicitly so
  // the engine speaks those exact words.
  let speakingPrompt = null;
  if (isSpeaking) {
    speakingPrompt = `${effectivePrompt} — style: ${style}`;
    if (speakingDialogue && speakingDialogue.text &&
        !effectivePrompt.includes(speakingDialogue.text))
      speakingPrompt = `${effectivePrompt} — the speaker says: "${speakingDialogue.text}" — style: ${style}`;
  }
  // Premium body (Phase J): EXACTLY the Seedance 2.5 schema fields this
  // route uses — prompt, resolution ("720p"), duration as a STRING enum
  // ("5"/"10" — this schema's durations are strings, unlike the Omni
  // integers), aspect_ratio, and generate_audio pinned true (native
  // synchronized audio is part of the premium price). The schema's
  // draft / bitrate_mode / codec / end_user_id fields are never sent.
  // A chained 20s job submits PART 1 as a completely normal 10s job —
  // the provider never sees a 20s request (the H3 schemas cap at 15s and
  // this app only ever orders 5/10s singles); the second 10s is chained
  // on completion by ensureTwentyChain.
  const submitDuration = isChain20 ? 10 : Number(duration);
  const falBody = isSpeaking
    ? { prompt: speakingPrompt, aspect_ratio,
        resolution: CONFIG.speakingResolution, duration: Number(duration) }
    : isSeedance
    ? { prompt: `${effectivePrompt} — style: ${style}`,
        resolution: CONFIG.seedanceResolution, duration: String(duration),
        aspect_ratio, generate_audio: true }
    : character
    ? { prompt: `Image 1 is the main character. ${effectivePrompt} — style: ${style}`,
        duration: submitDuration, aspect_ratio, resolution,
        enable_safety_checker: true,
        reference_image_urls: [sourceImageDataUri] }
    : sourceImagePath
    ? { prompt: `${effectivePrompt} — style: ${style}`,
        duration: submitDuration, resolution,
        enable_safety_checker: true, image_url: sourceImageDataUri }
    : isNative4k
    ? { prompt: `${effectivePrompt} — style: ${style}`,
        duration: String(duration), aspect_ratio,
        generate_audio: false, enable_safety_checker: true }
    : { prompt: `${effectivePrompt} — style: ${style}`,
        duration: submitDuration, aspect_ratio, resolution,
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
               stage: isDraft ? 'draft' : 'final',
               mode, source_image_path: sourceImagePath,
               ...(character ? { character_id: character.id, character_name: character.name } : {}),
               watermark_status: watermarkStatus,
               ...(soundSpec ? { sound_mode: soundSpec.mode, sound_status: 'pending',
                                 sound_cost_credits: soundCost } : {}),
               ...(translatedPrompt ? { translated_prompt: translatedPrompt } : {}),
               ...((cameraMove || shotSize) ? { camera_move: cameraMove, shot_size: shotSize,
                                                camera_directive: cameraSuffix } : {}),
               ...(autoPlanToStore ? { auto_plan: autoPlanToStore,
                                       auto_voice_status: autoVoiceSpec ? 'pending' : 'none',
                                       auto_voice_cost: autoVoiceCost } : {}),
               ...(autoVoiceSpec ? { voice_mode: autoVoiceSpec.kind,
                                     voice_cost_credits: autoVoiceCost } : {}),
               ...(isSpeaking ? { engine: 'speaking',
                   speaking_engine: { provider: 'gemini-omni', model: CONFIG.modelOmni,
                                      price_credits: CONFIG.speakingCost },
                   note: 'Speaking engine: the dialogue and audio are generated by the model in one step. Speech quality — including Urdu — is unverified; judge it on this sample.' } : {}),
               ...(isSeedance ? { engine: 'seedance',
                   seedance_engine: { provider: 'seedance-2.5', model: CONFIG.modelSeedance,
                                      price_credits: cost },
                   note: 'Seedance 2.5 premium engine: 720p with native synchronized audio included. Real-world quality is unverified until the first paid sample is reviewed.' } : {}),
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

// ---------- Generate-time auto voice post-processing (Phase D) ------------
// Mirrors ensureSoundApplied: when a generation whose confirmed auto plan
// routed its dialogue to a voice completes, the voice step runs before the
// client sees the video. voiceover synthesizes the dialogue and muxes it
// over the video (replacing the model's own audio; when an auto sound
// soundtrack was applied first, the voice is mixed OVER it so neither is
// silently lost). lipsync synthesizes the dialogue and runs the existing
// video lip-sync endpoint (LatentSync) on the finished video; an applied
// soundtrack is then mixed back under the synced voice. If the voice step
// fails, the VIDEO IS STILL DELIVERED — only the voice add-on is refunded
// (exactly once: the refund happens only in the UPDATE that flips
// auto_voice_status away from 'pending') and the row is honestly marked
// auto_voice_status='failed_refunded'.
const autoVoiceInFlight = new Set();

async function renderAutoVoiceover(job, audioAbs) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ajk-auto-vo-'));
  try {
    const srcFile = path.join(work, 'source.mp4');
    await downloadClip(job.video_url, srcFile, { left: JOIN_MAX_BYTES });
    const probe = await probeMedia(srcFile);
    fs.mkdirSync(CONFIG.generatedDir, { recursive: true });
    const name = `${randomUUID()}.mp4`;
    const output = path.join(CONFIG.generatedDir, name);
    const duckBed = probe.hasAudio && job.sound_status === 'applied' && job.sound_mode;
    const args = duckBed
      ? ['-y', '-i', srcFile, '-i', audioAbs, '-filter_complex',
         '[0:a]volume=0.3[a0];[1:a]volume=1[a1];[a0][a1]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]',
         '-map', '0:v:0', '-map', '[aout]', '-c:v', 'copy', '-c:a', 'aac', '-shortest', output]
      : ['-y', '-i', srcFile, '-i', audioAbs, '-map', '0:v:0', '-map', '1:a:0',
         '-c:v', 'copy', '-c:a', 'aac', '-shortest', output];
    try { await runFfmpeg(args); }
    catch {
      await runFfmpeg(args.map(a => a === 'copy' ? 'libx264' : a)
        .filter((a, i, arr) => !(a === 'libx264' && arr[i - 1] === 'libx264')));
    }
    const outProbe = await probeMedia(output);
    if (!outProbe.hasAudio) throw new Error('Auto voiceover render produced no audio track');
    return `/files/generated/${name}`;
  } finally { fs.rmSync(work, { recursive: true, force: true }); }
}

// Mix an existing soundtrack (the video at bedUrl) UNDER the audio of the
// main video at mainUrl — used to keep an applied auto soundtrack audible
// beneath a lip-synced voice. Returns a local /files/generated/ URL.
async function mixSoundtrackUnderMain(bedUrl, mainUrl) {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ajk-auto-mix-'));
  try {
    const bedFile = path.join(work, 'bed.mp4');
    const mainFile = path.join(work, 'main.mp4');
    await downloadClip(bedUrl, bedFile, { left: JOIN_MAX_BYTES });
    await downloadClip(mainUrl, mainFile, { left: JOIN_MAX_BYTES });
    const bedProbe = await probeMedia(bedFile);
    const mainProbe = await probeMedia(mainFile);
    if (!bedProbe.hasAudio || !mainProbe.hasAudio) return mainUrl;
    fs.mkdirSync(CONFIG.generatedDir, { recursive: true });
    const name = `${randomUUID()}.mp4`;
    const output = path.join(CONFIG.generatedDir, name);
    await runFfmpeg(['-y', '-i', bedFile, '-i', mainFile, '-filter_complex',
      '[0:a]volume=0.3[a0];[1:a]volume=1[a1];[a0][a1]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[aout]',
      '-map', '1:v:0', '-map', '[aout]', '-c:v', 'copy', '-c:a', 'aac', '-shortest', output]);
    const outProbe = await probeMedia(output);
    if (!outProbe.hasAudio) throw new Error('Soundtrack mix produced no audio track');
    return `/files/generated/${name}`;
  } finally { fs.rmSync(work, { recursive: true, force: true }); }
}

async function ensureAutoVoiceApplied(job, baseUrl) {
  if (!job || job.status !== 'completed' || !job.video_url) return job;
  if (job.auto_voice_status !== 'pending') return job;
  const plan = parseStoredAutoPlan(job.auto_plan);
  const spec = plan?.apply?.voice || null;
  if (!spec || !spec.text) {
    db.prepare(`UPDATE generations SET auto_voice_status = 'none', auto_voice_cost = 0,
                updated_at = datetime('now') WHERE id = ? AND auto_voice_status = 'pending'`)
      .run(job.id);
    const fresh0 = db.prepare('SELECT * FROM generations WHERE id = ?').get(job.id);
    if (fresh0) Object.assign(job, fresh0);
    return job;
  }
  if (autoVoiceInFlight.has(job.id)) return job;
  autoVoiceInFlight.add(job.id);
  let voiceJobId = null;
  try {
    let settings;
    const wantedBody = { script: spec.text, spoken_language: spec.language,
      script_mode: spec.script_mode || 'native',
      provider: spec.provider, voice: spec.voice, style: spec.style, speed: spec.speed };
    try { settings = parseVoiceSettings(wantedBody); }
    catch { settings = parseVoiceSettings({ script: spec.text, spoken_language: spec.language,
      script_mode: spec.script_mode || 'native' }); }
    if (!settings.provider) throw new Error('voice_not_configured');
    if (moderated(settings.rawScript)) throw new Error('The dialogue was blocked by content moderation.');
    voiceJobId = recordVoiceJob({ userId: job.user_id,
      kind: spec.kind === 'lipsync' ? 'lipsync' : 'voiceover',
      settings, text: settings.text, status: 'processing', generationId: job.id });
    const out = await synthesizeScript(settings, settings.text);
    db.prepare('UPDATE generations SET voice_audio_path = ? WHERE id = ?').run(out.audioPath, job.id);
    let finalUrl;
    if (spec.kind === 'lipsync') {
      const result = await runFalQueueJob(CONFIG.lipsyncVideoModel, {
        video_url: absoluteMediaUrl(job.video_url, baseUrl),
        audio_url: `${baseUrl}${out.audioPath}`,
        enable_safety_checker: true,
      });
      finalUrl = result?.video?.url || result?.data?.video?.url || null;
      if (!finalUrl) throw new Error('Lip-sync provider returned no video');
      if (job.sound_status === 'applied' && job.sound_mode)
        finalUrl = await mixSoundtrackUnderMain(job.video_url, finalUrl);
    } else {
      finalUrl = await renderAutoVoiceover(job, out.absPath);
    }
    db.prepare(`UPDATE generations SET video_url = ?, auto_voice_status = 'applied',
                updated_at = datetime('now') WHERE id = ? AND auto_voice_status = 'pending'`)
      .run(finalUrl, job.id);
    if (voiceJobId)
      db.prepare(`UPDATE voice_jobs SET status = 'completed', audio_path = ? WHERE id = ?`)
        .run(out.audioPath, voiceJobId);
  } catch (e) {
    console.error(`auto voice step failed for generation ${job.id}:`, e.message);
    const vc = Number(job.auto_voice_cost) || Number(spec.cost) || 0;
    const changed = db.prepare(`UPDATE generations SET auto_voice_status = 'failed_refunded',
                  cost_credits = cost_credits - ?, updated_at = datetime('now')
                  WHERE id = ? AND auto_voice_status = 'pending'`).run(vc, job.id);
    if (Number(changed.changes) === 1 && vc > 0)
      tx(() => refundBuckets(job.user_id, vc));
    if (voiceJobId)
      db.prepare(`UPDATE voice_jobs SET status = 'failed', error = ? WHERE id = ?`)
        .run(e.message, voiceJobId);
  } finally {
    autoVoiceInFlight.delete(job.id);
  }
  const fresh = db.prepare('SELECT * FROM generations WHERE id = ?').get(job.id);
  if (fresh) Object.assign(job, fresh);
  return job;
}


// ---------- Mute post-processing (Phase G) --------------------------------
// A confirmed Auto Director plan with mute:true promised a SILENT video.
// After the video completes (a muted plan never schedules sound/voice
// steps), the audio track is stripped locally with ffmpeg -an — the same
// generated-dir/local-file pattern the finishers use — and the muted file
// replaces video_url. Honesty rule: if the strip fails, the ORIGINAL is
// delivered, the row is marked mute_status='failed' and a note is appended
// to the stored plan — a video is never presented as silent when it is
// not. Muting is included in the generation price; there is no charge and
// therefore nothing to refund.
const muteInFlight = new Set();
async function ensureMuteApplied(job) {
  if (!job || job.status !== 'completed' || !job.video_url) return job;
  if (job.mute_status !== 'pending') return job;
  if (muteInFlight.has(job.id)) return job;
  muteInFlight.add(job.id);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ajk-mute-'));
  try {
    const input = path.join(work, 'input.mp4');
    await downloadClip(job.video_url, input, { left: JOIN_MAX_BYTES });
    const probe = await probeMedia(input);
    fs.mkdirSync(CONFIG.generatedDir, { recursive: true });
    const name = `${randomUUID()}.mp4`;
    const output = path.join(CONFIG.generatedDir, name);
    if (probe.hasAudio) {
      try {
        await runFfmpeg(['-y', '-i', input, '-map', '0:v:0', '-c:v', 'copy', '-an', output]);
      } catch {
        await runFfmpeg(['-y', '-i', input, '-map', '0:v:0', '-c:v', 'libx264',
          '-preset', 'veryfast', '-crf', '20', '-an', output]);
      }
      const outProbe = await probeMedia(output);
      if (outProbe.hasAudio) throw new Error('Mute render still has an audio track');
    } else {
      fs.copyFileSync(input, output); // already silent — keep the same bytes
    }
    db.prepare(`UPDATE generations SET video_url = ?, mute_status = 'applied',
                updated_at = datetime('now') WHERE id = ? AND mute_status = 'pending'`)
      .run(`/files/generated/${name}`, job.id);
  } catch (e) {
    console.error(`mute step failed for generation ${job.id}:`, e.message);
    const plan = parseStoredAutoPlan(job.auto_plan);
    if (plan && Array.isArray(plan.notes)) {
      const noted = { ...plan, notes: [...plan.notes,
        'The silent version could not be rendered, so the original video (WITH its audio) was delivered — it is NOT silent.'] };
      db.prepare(`UPDATE generations SET mute_status = 'failed', auto_plan = ?,
                  updated_at = datetime('now') WHERE id = ? AND mute_status = 'pending'`)
        .run(JSON.stringify(noted), job.id);
    } else {
      db.prepare(`UPDATE generations SET mute_status = 'failed',
                  updated_at = datetime('now') WHERE id = ? AND mute_status = 'pending'`)
        .run(job.id);
    }
  } finally {
    muteInFlight.delete(job.id);
    fs.rmSync(work, { recursive: true, force: true });
  }
  const fresh = db.prepare('SELECT * FROM generations WHERE id = ?').get(job.id);
  if (fresh) Object.assign(job, fresh);
  return job;
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

// ---------- 20-second two-part chain (2026-10-27, migration v25) --------
// A 20s H3 job is charged once, up front, at 2x the 10s rate. Part 1 is a
// normal 10s provider job; when it completes, the poll handler flips the
// row to chain_stage 'extending' (part 1's URL stashed in video_url) and
// calls this function, which mirrors the finish/extend action's
// internals step for step — last frame -> CONFIG.modelI2V for 10s ->
// joinTwoClips — but settles the SAME generation row:
//   success: status 'completed', video_url = the joined file, duration
//     stays the contracted 20 (the joined file's probed length is
//     deliberately NOT recorded — the user bought 20 seconds);
//   failure: settleTwentyChainFailure delivers part 1 at duration 10
//     with exactly the second-half price refunded exactly once and a
//     bilingual chain_note that History renders — never a silent
//     shortening.
// Exactly-once is enforced three ways: the in-flight set, the
// conditional settle UPDATEs (chain_stage must still be 'extending'),
// and the refund riding inside the settle's own transaction. The stage
// marker lives on the row, so a restart mid-chain is resumed by the
// next poll (and by the boot scan below) instead of losing the job.
// Never throws: every failure lands in the part-1 settle.
const chainInFlight = new Set();

function settleTwentyChainFailure(job) {
  const half = job.stage === 'draft' ? (CONFIG.draftCost[10] ?? 140)
                                     : generationCost(job.resolution, 10);
  const note = `The second part could not be made, so ${half} credits were refunded. · دوسرا حصہ نہیں بن سکا، ${half} کریڈٹ واپس کر دیے گئے`;
  tx(() => {
    const info = db.prepare(
      `UPDATE generations SET status = 'completed', duration = 10,
              chain_stage = 'done', chain_note = ?,
              cost_credits = cost_credits - ?,
              updated_at = datetime('now')
       WHERE id = ? AND chain_stage = 'extending'`).run(note, half, job.id);
    if (Number(info.changes) === 1) refundBuckets(job.user_id, half);
  });
}

async function ensureTwentyChain(job) {
  if (!job || Number(job.duration) !== 20 || job.chain_stage !== 'extending' ||
      !job.video_url)
    return job;
  if (chainInFlight.has(job.id)) return job;
  chainInFlight.add(job.id);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ajk-chain-'));
  try {
    const part1Url = job.video_url;
    const input = path.join(work, 'part1.mp4');
    await downloadClip(part1Url, input, { left: JOIN_MAX_BYTES });
    const probe = await probeMedia(input);
    const frame = path.join(work, 'last-frame.jpg');
    const seek = Math.max(0, probe.duration - 0.25).toFixed(2);
    await runFfmpeg(['-y', '-ss', seek, '-i', input, '-frames:v', '1', '-q:v', '3', frame]);
    if (!fs.existsSync(frame) || fs.statSync(frame).size === 0)
      throw new Error('could not extract the last frame of part 1');
    const frameUri = `data:image/jpeg;base64,${fs.readFileSync(frame).toString('base64')}`;
    // The same prompt part 1 was sent: the stored (translated) prompt
    // plus the recorded camera/shot directive, with the style suffix —
    // exactly the finish/extend action's prompt construction.
    const effectivePrompt = (job.translated_prompt || job.prompt) +
      (cameraDirectiveSuffix(job.camera_move, job.shot_size) || '');
    const tier = ['768P', '2K', '480P'].includes(job.resolution) ? job.resolution : '768P';
    const result = await runFalQueueJob(CONFIG.modelI2V, {
      prompt: `${effectivePrompt} — style: ${job.style}`,
      duration: 10, resolution: tier,
      enable_safety_checker: true, image_url: frameUri,
    });
    const extUrl = result?.video?.url || result?.data?.video?.url || null;
    if (!extUrl) throw new Error('the second-part generation returned no video');
    const joined = await joinTwoClips(part1Url, extUrl, work);
    db.prepare(`UPDATE generations SET status = 'completed', video_url = ?,
                chain_stage = 'done', updated_at = datetime('now')
                WHERE id = ? AND chain_stage = 'extending'`)
      .run(joined.videoUrl, job.id);
  } catch (e) {
    console.error(`20s chain failed for generation ${job.id}:`, e.message);
    settleTwentyChainFailure(job);
  } finally {
    chainInFlight.delete(job.id);
    fs.rmSync(work, { recursive: true, force: true });
  }
  return db.prepare('SELECT * FROM generations WHERE id = ?').get(job.id) || job;
}

app.get('/api/generations/:id', auth, async (req, res) => {
  const job = db.prepare(
    `SELECT g.*, c.name AS character_name FROM generations g
     LEFT JOIN characters c ON c.id = g.character_id
     WHERE g.id = ? AND g.user_id = ?`)
    .get(req.params.id, req.user.id);
  if (!job) return res.status(404).json({ error: 'Generation not found.' });
  if (job.status === 'completed') {
    // Pending post steps (e.g. the completing poll was interrupted) still
    // run — sound first, then the auto voice route, then the watermark, so
    // all three can apply to one video.
    const base = CONFIG.publicBaseUrl || `${req.protocol}://${req.get('host')}`;
    if (job.sound_status === 'pending')
      await ensureSoundApplied(job, base);
    if (job.auto_voice_status === 'pending')
      await ensureAutoVoiceApplied(job, base);
    // Phase G: a confirmed silent plan strips the audio track after the
    // voice step and before the watermark.
    if (job.mute_status === 'pending')
      await ensureMuteApplied(job);
    return res.json(publicGenerationRow(await ensureWatermarkApplied(job)));
  }
  if (job.status === 'failed' || !job.fal_request_id)
    return res.json(publicGenerationRow(job));
  // 20s chain restart-resume: the chain was claimed (chain_stage
  // 'extending') but the process died before it settled. Part 1's URL
  // is stashed on the row, so the chain finishes right here without
  // asking the provider about the old request again; the post-steps
  // then run on the FINAL file, in the usual order.
  if (job.chain_stage === 'extending') {
    if (job.video_url) {
      const chained = await ensureTwentyChain(job);
      if (chained.status !== 'completed')
        return res.json(publicGenerationRow(chained));
      const base = CONFIG.publicBaseUrl || `${req.protocol}://${req.get('host')}`;
      if (chained.sound_status === 'pending')
        await ensureSoundApplied(chained, base);
      if (chained.auto_voice_status === 'pending')
        await ensureAutoVoiceApplied(chained, base);
      if (chained.mute_status === 'pending')
        await ensureMuteApplied(chained);
      return res.json(publicGenerationRow(await ensureWatermarkApplied(chained)));
    }
    // Claimed but part 1's URL never landed — nothing deliverable can
    // be recovered, so fail safe to a full refund (exactly once).
    failAndRefund(job.id, 'The 20-second video could not be completed.');
    const fresh = db.prepare('SELECT * FROM generations WHERE id = ?').get(job.id);
    return res.json(publicGenerationRow(fresh || job));
  }
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
          // 20s two-part chain: part 1 just finished at the provider.
          // Claim the chain exactly once (this conditional UPDATE is
          // the claim), stash part 1's URL on the row for restart
          // resume, run the chain, and only then run the post-steps —
          // so sound / voice / mute / watermark apply to the FINAL
          // joined file, never to part 1 alone.
          if (Number(job.duration) === 20 && job.chain_stage === 'part1') {
            const claim = db.prepare(
              `UPDATE generations SET chain_stage = 'extending', video_url = ?,
                      updated_at = datetime('now')
               WHERE id = ? AND chain_stage = 'part1'`).run(url, job.id);
            if (Number(claim.changes) !== 1) {
              // A parallel poll claimed the chain first — report the
              // current state; that poll is finishing the job.
              const cur = db.prepare('SELECT * FROM generations WHERE id = ?').get(job.id);
              return res.json(publicGenerationRow(cur || job));
            }
            job.chain_stage = 'extending'; job.video_url = url;
            const chained = await ensureTwentyChain(job);
            if (chained.status !== 'completed')
              return res.json(publicGenerationRow(chained));
            const base = CONFIG.publicBaseUrl || `${req.protocol}://${req.get('host')}`;
            if (chained.sound_status === 'pending')
              await ensureSoundApplied(chained, base);
            if (chained.auto_voice_status === 'pending')
              await ensureAutoVoiceApplied(chained, base);
            if (chained.mute_status === 'pending')
              await ensureMuteApplied(chained);
            return res.json(publicGenerationRow(await ensureWatermarkApplied(chained)));
          }
          db.prepare(`UPDATE generations SET status = 'completed', video_url = ?,
                      updated_at = datetime('now') WHERE id = ?`).run(url, job.id);
          job.status = 'completed'; job.video_url = url;
          // If this job asked for sound, run the sound step BEFORE the
          // client sees the completed video: applied, or honestly marked
          // failed_refunded with the video still delivered (the add-on
          // is refunded inside ensureSoundApplied).
          const base = CONFIG.publicBaseUrl || `${req.protocol}://${req.get('host')}`;
          if (job.sound_status === 'pending')
            await ensureSoundApplied(job, base);
          // If the confirmed auto plan routed dialogue to a voice, run
          // that step now (applied, or honestly marked failed_refunded
          // with the video still delivered and the add-on refunded).
          if (job.auto_voice_status === 'pending')
            await ensureAutoVoiceApplied(job, base);
          // Phase G: strip the audio track for a confirmed silent plan
          // (applied, or honestly marked failed with the original kept).
          if (job.mute_status === 'pending')
            await ensureMuteApplied(job);
          // If this job asked for a watermark, post-process BEFORE the
          // client sees the completed video (applied or honestly failed).
          if (job.watermark_text && job.watermark_status === 'pending')
            return res.json(publicGenerationRow(await ensureWatermarkApplied(job)));
          const fresh = db.prepare(
            `SELECT g.*, c.name AS character_name FROM generations g
             LEFT JOIN characters c ON c.id = g.character_id WHERE g.id = ?`)
            .get(job.id);
          return res.json(publicGenerationRow(fresh || job));
        }
      }
      // fal's queue reports failures via the result payload; a non-2xx status
      // check is handled below by leaving the job in progress for the next poll.
    }
  } catch { /* network hiccup — keep last known status; frontend polls again */ }
  res.json(publicGenerationRow(job));
});

app.get('/api/history', auth, (req, res) => {
  // character_name rides along (NULL when the job used no character, or
  // the character was deleted afterwards — the generation itself and its
  // character_id are never touched by a character delete).
  const rows = db.prepare(
    `SELECT g.*, c.name AS character_name FROM generations g
     LEFT JOIN characters c ON c.id = g.character_id
     WHERE g.user_id = ? ORDER BY g.id DESC LIMIT 50`)
    .all(req.user.id);
  const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
  res.json({ credits: me.credits, generations: rows.map(publicGenerationRow) });
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
  // Buffer the body instead of piping a stream through a counting
  // Transform: backpressure-pausing the parser while a plain HTTP/1.0
  // server closes the socket can trip an undici assertion and take the
  // whole process down (seen with the test suite's python http.server).
  // The 200 MB budget is checked again on the real byte count below.
  const buf = Buffer.from(await r.arrayBuffer());
  if (buf.length > budget.left) throw new Error('These clips are too large to join (200 MB total limit).');
  fs.writeFileSync(dest, buf);
  budget.left -= buf.length;
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
// Pakistan language registry (Phase M, owner spec document 3, 2026-10-24)
// ==========================================================================
// One honest table driving the Language Lab (Settings) and the
// `languages` block of /api/config. voice_status is deliberately
// conservative:
//   'available'   — a configured provider lists the language AND the
//                   flow ships today (ur/hi/en).
//   'listed'      — the Gemini TTS enum on fal lists the language, but
//                   reading quality is UNPROVEN until the owner's
//                   ear-test (sample battery Batch G). The UI badge
//                   says "Listed — testing", never "supported".
//   'unavailable' — no verified provider voice exists. No sample is
//                   synthesized, no result is faked; the Lab offers
//                   the Urdu-voice / prompt alternatives and a report
//                   action instead.
// prompt_status mirrors the prompt-language pipeline (PROMPT_LANGUAGES):
// only ur/hi/en/ks are 'supported' among these codes.
// Samples: one natural, widely standard sentence each for ur/hi/en/
// pa (Shahmukhi) / ps / sd (Arabic script) / ks. Languages whose text
// cannot be verified here carry sample: null — the native NAME is
// shown, never an invented sentence.
const PAK_LANGUAGES = [
  { code: 'ur', name_en: 'Urdu', name_native: 'اردو', script: 'Urdu (Perso-Arabic)', rtl: true,
    voice_status: 'available', prompt_status: 'supported',
    sample: 'السلام علیکم! میرا نام احمد ہے اور میں پاکستان سے ہوں۔' },
  { code: 'hi', name_en: 'Hindi', name_native: 'हिन्दी', script: 'Devanagari', rtl: false,
    voice_status: 'available', prompt_status: 'supported',
    sample: 'नमस्ते! मेरा नाम अहमद है और मैं पाकिस्तान से हूँ।' },
  { code: 'en', name_en: 'English', name_native: 'English', script: 'Latin', rtl: false,
    voice_status: 'available', prompt_status: 'supported',
    sample: 'Hello! My name is Ahmad, and I am from Pakistan.' },
  { code: 'pa', name_en: 'Punjabi', name_native: 'پنجابی', script: 'Shahmukhi (Perso-Arabic)', rtl: true,
    voice_status: 'listed', prompt_status: 'none',
    sample: 'میرا ناں احمد اے تے میں پنجابی وچ گل کرنا چاہنا آں۔' },
  { code: 'ps', name_en: 'Pashto', name_native: 'پښتو', script: 'Pashto (Perso-Arabic)', rtl: true,
    voice_status: 'listed', prompt_status: 'none',
    sample: 'السلام علیکم! زما نوم احمد دی او زه د پاکستان یم۔' },
  { code: 'sd', name_en: 'Sindhi', name_native: 'سنڌي', script: 'Sindhi (Perso-Arabic)', rtl: true,
    voice_status: 'listed', prompt_status: 'none',
    sample: 'السلام عليڪم! منهنجو نالو احمد آهي ۽ مان پاڪستان کان آهيان۔' },
  { code: 'ks', name_en: 'Kashmiri', name_native: 'کٔشیٖر', script: 'Kashmiri (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'supported',
    sample: 'میہٕ چھُ ناو احمد۔' },
  { code: 'skr', name_en: 'Saraiki', name_native: 'سرائیکی', script: 'Saraiki (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'none', sample: null },
  { code: 'bal', name_en: 'Balochi', name_native: 'بلوچی', script: 'Balochi (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'none', sample: null },
  { code: 'hnd', name_en: 'Hindko', name_native: 'ہندکو', script: 'Hindko (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'none', sample: null },
  { code: 'brh', name_en: 'Brahui', name_native: 'براہوئی', script: 'Brahui (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'none', sample: null },
  { code: 'pothwari', name_en: 'Pothwari', name_native: 'پوٹھوہاری', script: 'Shahmukhi (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'none', sample: null },
  { code: 'shina', name_en: 'Shina', name_native: 'شینا', script: 'Shina (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'none', sample: null },
  { code: 'balti', name_en: 'Balti', name_native: 'بلتی', script: 'Balti (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'none', sample: null },
  { code: 'burushaski', name_en: 'Burushaski', name_native: 'بروشسکی', script: 'Burushaski (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'none', sample: null },
  { code: 'wakhi', name_en: 'Wakhi', name_native: 'وخی', script: 'Wakhi (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'none', sample: null },
  { code: 'khowar', name_en: 'Khowar', name_native: 'کھوار', script: 'Khowar (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'none', sample: null },
  { code: 'kalasha', name_en: 'Kalasha', name_native: 'کالاشا', script: 'Kalasha (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'none', sample: null },
  { code: 'marwari', name_en: 'Marwari', name_native: 'مارواڑی', script: 'Marwari (Perso-Arabic)', rtl: true,
    voice_status: 'unavailable', prompt_status: 'none', sample: null },
];
// Public-safe projection for /api/config (exactly the Lab's fields).
function publicLanguages() {
  return PAK_LANGUAGES.map(l => ({ code: l.code, name_en: l.name_en,
    name_native: l.name_native, script: l.script, rtl: l.rtl,
    voice_status: l.voice_status, prompt_status: l.prompt_status,
    sample: l.sample }));
}

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
  // Phase M (2026-10-24): Punjabi, Pashto and Sindhi are listed in the
  // Gemini 3.1 Flash TTS language enum on fal — provider-LISTED, with
  // reading quality still unproven until the owner's ear-test (sample
  // battery Batch G). They are Gemini-only: see GEMINI_ONLY_VOICE_LANGUAGES.
  { code: 'pa', name: 'Punjabi' },
  { code: 'ps', name: 'Pashto' },
  { code: 'sd', name: 'Sindhi' },
];
// Spoken languages served by the Gemini provider ONLY. ElevenLabs v3
// support for pa/ps/sd is NOT verified and the Azure catalog carries no
// voices for them, so parseVoiceSettings fails closed (400, before any
// provider call) when one of these codes is paired with another
// provider, and the public catalog never advertises them elsewhere.
const GEMINI_ONLY_VOICE_LANGUAGES = new Set(['pa', 'ps', 'sd']);
const VOICE_STYLES = ['narration', 'conversation', 'news', 'energetic', 'emotional'];
const VOICE_SPEEDS = ['slow', 'normal', 'fast'];
const VOICE_PREVIEW_MAX_CHARS = 150;
const VOICE_SCRIPT_MAX_CHARS = 6000;
// Standalone lip-sync cap (Phase G2, owner decision 2026-10-23): the
// /api/voice/lipsync script is limited to 300 chars (≈ ≤20 s of speech)
// so the now-included tool stays inside the Pro subscription's margin.
// Only that endpoint passes this to parseVoiceSettings — previews,
// voiceovers and the in-generation routes keep VOICE_SCRIPT_MAX_CHARS.
const LIPSYNC_SCRIPT_MAX_CHARS = 300;
const TTS_CHUNK_MAX_CHARS = 3000; // per-request cap; longer scripts chunk

const VOICE_CATALOG = {
  gemini: {
    label: 'Gemini 3.1 Flash TTS (via fal.ai)',
    premium: false,
    model: 'fal-ai/gemini-3.1-flash-tts',
    // fal's documented language_code enum values. The pa/ps/sd strings
    // are the EXACT enum values from fal's llms.txt for this endpoint
    // (verified 2026-10-24): "Punjabi (India)" — the listed Punjabi is
    // the Indian/Gurmukhi tradition; how accurately it reads Pakistani
    // Shahmukhi text is sample-test pending (Batch G). Same caveat for
    // the India variant of Sindhi.
    languageNames: { ur: 'Urdu (Pakistan)', hi: 'Hindi (India)', en: 'English (US)',
                     pa: 'Punjabi (India)', ps: 'Pashto (Afghanistan)', sd: 'Sindhi (India)' },
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
      // Phase M: the Gemini-only languages (pa/ps/sd) are advertised
      // only on the Gemini entry — never on ElevenLabs/Azure, whose
      // support for them is unverified/absent.
      if (GEMINI_ONLY_VOICE_LANGUAGES.has(lang) && providerId !== 'gemini') continue;
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
function parseVoiceSettings(body, { scriptRequired = true, maxScriptChars = VOICE_SCRIPT_MAX_CHARS } = {}) {
  const bad = (msg) => Object.assign(new Error(msg), { status: 400 });
  const language = String(body?.spoken_language || 'ur').toLowerCase();
  if (!VOICE_LANGUAGES.some(l => l.code === language))
    throw bad(`spoken_language must be one of: ${VOICE_LANGUAGES.map(l => l.code).join(', ')}`);
  const scriptMode = String(body?.script_mode || body?.script_type || 'native').toLowerCase();
  if (!['native', 'roman'].includes(scriptMode))
    throw bad('script_mode must be "native" or "roman"');
  // Phase M: Roman transliteration exists for Urdu/Hindi only. The
  // provider-listed languages (pa/ps/sd) are native-script only for
  // now — stated plainly instead of silently mis-converting the text.
  const langName = (VOICE_LANGUAGES.find(l => l.code === language) || {}).name || language;
  if (GEMINI_ONLY_VOICE_LANGUAGES.has(language) && scriptMode === 'roman')
    throw bad(`Roman script is not supported for ${langName} yet — please write the script in its native script.`);
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
  // Phase M: pa/ps/sd are served by the Gemini provider ONLY (they are
  // in its fal language enum; ElevenLabs v3 support is unverified and
  // Azure has no voices for them in this catalog). Fail closed HERE —
  // before voice selection and long before any provider call — with
  // the reason stated plainly.
  if (GEMINI_ONLY_VOICE_LANGUAGES.has(language) && provider && provider !== 'gemini')
    throw bad(`${langName} voice is available through the Gemini provider only — the ${provider} provider does not offer ${langName}. Please choose the Gemini provider for ${langName}.`);
  let voice = null;
  if (provider) {
    if (body?.voice) {
      voice = providerVoicesFor(provider, language).find(v => v.id === String(body.voice)) || null;
      if (!voice) throw bad(`voice "${body.voice}" is not available for ${provider} / ${language}.`);
    } else voice = defaultVoiceFor(provider, language);
  }
  const rawScript = body?.script === undefined || body?.script === null ? '' : String(body.script);
  if (scriptRequired && (rawScript.trim().length < 1 || rawScript.length > maxScriptChars))
    throw bad(`script must be 1–${maxScriptChars} characters.`);
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
function chargeVoiceGeneration(userId, { cost, prompt, aspectRatio, duration, style, model, kind, sourceGenerationId = null, sourceImagePath = null, promptLanguage = null, translatedPrompt = null, resolution = '768P', stage = 'final', mode = 'realistic', characterId = null }) {
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
         mode, source_image_path, kind, source_generation_id, stage, character_id)
       VALUES (?, ?, ?, ?, ?, 'in_progress', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
      .run(userId, prompt, aspectRatio, duration, style, cost, resolution, model,
           promptLanguage, translatedPrompt, mode, sourceImagePath, kind, sourceGenerationId,
           stage, characterId);
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

// ---------- Talking character / lip-sync (Pro+ plans, included) ------------
// Phase G2 (owner decision 2026-10-23): price 0 — the script is capped
// at LIPSYNC_SCRIPT_MAX_CHARS (300) and a fair-use cap of
// CONFIG.lipsyncDailyCap standalone jobs per user per day applies.
app.post('/api/voice/lipsync', auth, voiceLimiter, async (req, res) => {
  const b = req.body || {};
  // Entitlement first: the existing plan flag gates the feature.
  refreshSubscriptionState(req.user.id);
  const sub = currentSubscription(req.user.id);
  const plan = sub ? getPlan(sub.plan_id) : null;
  if (!plan || !plan.can_lipsync)
    return res.status(403).json({ error: 'Talking / Lip-Sync videos need the Pro or Extra Pro plan. Upgrade your plan to create a talking character.' });
  // Visual source: a saved character (its reference image), an owned
  // uploaded image, OR a completed generation's video. A character plus
  // a generation_id is ambiguous and rejected; a character plus an
  // image_path uses the character's image.
  let character = null;
  if (b.character_id !== undefined && b.character_id !== null && b.character_id !== '') {
    character = getOwnCharacter(req.user.id, b.character_id);
    if (!character)
      return res.status(404).json({ error: 'Character not found.' });
  }
  const hasImage = !!character || (b.image_path !== undefined && b.image_path !== null && b.image_path !== '');
  const hasGen = b.generation_id !== undefined && b.generation_id !== null && b.generation_id !== '';
  if (character && hasGen)
    return res.status(400).json({ error: 'Choose either a character or a finished video for lip-sync, not both.' });
  if (hasImage === hasGen)
    return res.status(400).json({ error: 'Provide exactly one of character_id, image_path (an uploaded image) or generation_id (a finished video).' });
  let owned = null, sourceGen = null;
  if (hasImage) {
    owned = resolveOwnedUpload(req.user.id, character ? character.image_path : b.image_path);
    if (!owned)
      return res.status(400).json({ error: character
        ? 'The saved character image is no longer available. Please delete the character and save it again with a fresh upload.'
        : 'image_path must be an image you uploaded (POST /api/uploads/image).' });
  } else {
    sourceGen = db.prepare('SELECT * FROM generations WHERE id = ? AND user_id = ?')
      .get(Number(b.generation_id), req.user.id);
    if (!sourceGen) return res.status(404).json({ error: 'Generation not found.' });
    if (sourceGen.status !== 'completed' || !sourceGen.video_url)
      return res.status(400).json({ error: 'Only a completed video can be lip-synced.' });
    if (sourceGen.stage === 'draft')
      return res.status(400).json({ error: 'Drafts cannot take voice add-ons. Upgrade this draft to full quality first, then add lip-sync to that version.' });
  }
  // Audio source: a fresh script (synthesized now), a previous voice job,
  // or the user's own uploaded recording (Phase O2). The sources are
  // mutually exclusive — naming two is ambiguous and rejected, exactly
  // like the visual-source rule above.
  let settings = null, audioJob = null, audioUpload = null;
  const wantsUpload = b.audio_upload_id !== undefined && b.audio_upload_id !== null && b.audio_upload_id !== '';
  const wantsJob = b.voice_job_id !== undefined && b.voice_job_id !== null && b.voice_job_id !== '';
  if (wantsUpload && wantsJob)
    return res.status(400).json({ error: 'Choose either an uploaded voice recording or a saved voice job for lip-sync, not both.' });
  if (wantsUpload) {
    // Ownership is part of the lookup: another user's upload id is a 404,
    // never a leak of its existence. Script/language/provider fields are
    // NOT required (and ignored) — TTS is never called for this source.
    audioUpload = db.prepare('SELECT * FROM audio_uploads WHERE id = ? AND user_id = ?')
      .get(Number(b.audio_upload_id), req.user.id);
    if (!audioUpload) return res.status(404).json({ error: 'Uploaded voice recording not found.' });
    // The duration guard ran at upload time; re-check the stored value so
    // no row can ever drive a longer call than the upload gate allowed.
    if (audioUpload.duration_seconds && Number(audioUpload.duration_seconds) > AUDIO_UPLOAD_MAX_SECONDS)
      return res.status(400).json({ error: 'audio_too_long', message: `That recording is longer than ${AUDIO_UPLOAD_MAX_SECONDS} seconds — lip-sync voice uploads are limited to ${AUDIO_UPLOAD_MAX_SECONDS} seconds.` });
  }
  if (wantsJob) {
    audioJob = db.prepare(
      `SELECT * FROM voice_jobs WHERE id = ? AND user_id = ? AND status = 'completed' AND audio_path IS NOT NULL`)
      .get(Number(b.voice_job_id), req.user.id);
    if (!audioJob) return res.status(400).json({ error: 'voice_job_id must be one of your completed voice jobs.' });
  } else if (!audioUpload) {
    // Voice settings: fields sent explicitly in the request win; any
    // field left out falls back to the character's bound voice (when a
    // character with a bound voice is used), so picking a character is
    // enough to get its voice.
    let settingsBody = b;
    if (character && character.voice_provider) {
      settingsBody = { ...b };
      if (!settingsBody.provider) settingsBody.provider = character.voice_provider;
      if (!settingsBody.voice && character.voice_id) settingsBody.voice = character.voice_id;
      if (!settingsBody.spoken_language && character.voice_language)
        settingsBody.spoken_language = character.voice_language;
      if (!settingsBody.style && character.voice_style) settingsBody.style = character.voice_style;
    }
    try { settings = parseVoiceSettings(settingsBody, { maxScriptChars: LIPSYNC_SCRIPT_MAX_CHARS }); }
    catch (e) { return res.status(e.status || 400).json({ error: e.message }); }
    if (!settings.provider)
      return res.status(503).json({ error: 'voice_not_configured', message: VOICE_NOT_CONFIGURED_MSG });
    if (moderated(settings.rawScript))
      return res.status(400).json({ error: 'This script was blocked by content moderation. Please rephrase it.' });
  }
  // A referenced voice job carries its own script: the same 300-char
  // cap applies to its text, so the included price cannot be bypassed
  // by synthesizing a long script elsewhere first.
  if (audioJob && String(audioJob.script_text || '').length > LIPSYNC_SCRIPT_MAX_CHARS)
    return res.status(400).json({ error: `Lip-sync scripts are limited to ${LIPSYNC_SCRIPT_MAX_CHARS} characters — the referenced voice job's script is longer than that. Please use a shorter script.` });
  // Fair use (Phase G2): the standalone tool is free now, so bound it —
  // at most CONFIG.lipsyncDailyCap standalone lip-sync jobs per user per
  // day. Standalone jobs are the generations rows of kind 'lipsync',
  // which only this endpoint creates (the in-generation routes process
  // an existing generation and record voice_jobs instead).
  const lipJobsToday = db.prepare(
    `SELECT COUNT(*) AS c FROM generations WHERE user_id = ? AND kind = 'lipsync'
     AND date(created_at) = date('now')`).get(req.user.id).c;
  if (Number(lipJobsToday) >= CONFIG.lipsyncDailyCap)
    return res.status(429).json({ error: `Daily fair-use limit reached: standalone lip-sync is limited to ${CONFIG.lipsyncDailyCap} jobs per day. Please try again tomorrow.` });
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
      sourceImagePath: hasImage
        ? String(character ? character.image_path : b.image_path).replace(/\\/g, '/').replace(/^\.\//, '')
        : null,
      characterId: character ? character.id : null,
      promptLanguage: settings ? settings.language : (audioJob ? audioJob.language : null),
      translatedPrompt: settings && settings.scriptMode === 'roman' ? settings.text : null,
    });
  } catch (e) { return res.status(e.status || 500).json({ error: e.message }); }
  const voiceJobId = recordVoiceJob({ userId: req.user.id, kind: 'lipsync',
    settings: settings || (audioUpload
      // Uploaded recording: the voice_jobs row records the source as
      // provider 'upload' (the durable note that no TTS voice was used).
      ? { provider: 'upload' }
      : { provider: audioJob.provider, voiceId: audioJob.voice,
          language: audioJob.language, scriptMode: audioJob.script_mode,
          style: audioJob.style, speed: audioJob.speed }),
    text: settings ? settings.text : (audioJob ? audioJob.script_text : null),
    status: 'processing', generationId: jobId });
  try {
    let audioAbs, audioPublicPath;
    if (audioJob) {
      audioPublicPath = audioJob.audio_path;
      audioAbs = path.join(CONFIG.voiceDir, path.basename(audioJob.audio_path));
      if (!fs.existsSync(audioAbs)) throw new Error('The referenced voice audio no longer exists.');
    } else if (audioUpload) {
      // The uploaded file itself is the audio: its public /files/audio/
      // URL goes to the lip-sync route and TTS is never called.
      audioPublicPath = `/files/audio/${req.user.id}/${audioUpload.file_name}`;
      audioAbs = path.join(CONFIG.audioUploadsDir, String(req.user.id), audioUpload.file_name);
      if (!fs.existsSync(audioAbs)) throw new Error('The uploaded voice file is missing — please upload it again.');
      db.prepare('UPDATE generations SET voice_audio_path = ? WHERE id = ?').run(audioPublicPath, jobId);
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

// ---------- Voiceover (all plans, included — 0 credits) -------------------
// Synthesizes the script and muxes it over a finished video, REPLACING the
// video's original audio track (the model's native audio is not kept).
app.post('/api/voice/voiceover', auth, voiceLimiter, async (req, res) => {
  const b = req.body || {};
  const sourceGen = db.prepare('SELECT * FROM generations WHERE id = ? AND user_id = ?')
    .get(Number(b.generation_id), req.user.id);
  if (!sourceGen) return res.status(404).json({ error: 'Generation not found.' });
  if (sourceGen.status !== 'completed' || !sourceGen.video_url)
    return res.status(400).json({ error: 'Only a completed video can get a voiceover.' });
  if (sourceGen.stage === 'draft')
    return res.status(400).json({ error: 'Drafts cannot take voice add-ons. Upgrade this draft to full quality first, then add a voiceover to that version.' });
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
  if (sourceGen.stage === 'draft')
    return res.status(400).json({ error: 'Drafts cannot take sound add-ons. Upgrade this draft to full quality first, then add sound to that version.' });
  if (sourceGen.kind === 'sound' && !sourceGen.source_generation_id)
    return res.status(400).json({ error: 'That history entry is an audio file, not a video — sound can only be applied to a video.' });
  const mode = String(b.mode || '').toLowerCase();
  if (!SOUND_APPLY_MODES.includes(mode))
    return res.status(400).json({ error: `mode must be one of: ${SOUND_APPLY_MODES.join(', ')}` });
  if (mode === 'premium_sync') {
    refreshSubscriptionState(req.user.id);
    const sub = currentSubscription(req.user.id);
    const plan = sub ? getPlan(sub.plan_id) : null;
    if (!plan || !['pro', 'extrapro', 'extrapremier'].includes(plan.id))
      return res.status(403).json({ error: 'Premium sync sound needs the Pro, Extra Pro or Extra Premier plan. Upgrade your plan to keep the dialogue and add a premium soundtrack.' });
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

// ==========================================================================
// Finishers + draft upgrade (Phase C1)
// ==========================================================================
// One-tap finishers run on a COMPLETED video the user owns and always
// produce a NEW History entry (kind = the finisher name) linked back via
// source_generation_id — the source video is never modified.
//   reframe  — local ffmpeg: scale-to-fit over a blurred-pad background
//              (never a hard crop). FREE, like clip joining.
//   captions — fal Whisper transcription (verified schema) -> .ass built
//              from the timed segments -> burned in with the subtitles
//              filter (same libass styling family as the watermark).
//              +50 credits, refunded on failure. A video with NO audio
//              stream is refused with 400 BEFORE any charge.
//   extend   — last frame -> the existing H3 image-to-video route for
//              +5s/+10s at the SOURCE clip's quality tier (standard rate
//              card, plan caps as in normal generation) -> joined with the
//              source into one longer video. The extension is a NEW AI
//              generation from the last frame: continuity is the model's
//              best effort, not a guarantee. Any step failing refunds
//              exactly once and leaves no partial entry completed.
//   upscale  — Topaz video upscale on fal (verified endpoint + price).
//              Credit price = ceil(per-second USD x seconds x 277 / 1.5)
//              x 2 margin, minimum 100 credits. The result tier (one step
//              above the source) must be within the plan's max quality —
//              the same gate as generation.
const FINISH_ACTIONS = ['reframe', 'captions', 'extend', 'upscale'];
const REFRAME_TARGETS = { '16:9': [1920, 1080], '9:16': [1080, 1920], '1:1': [1080, 1080], '4:5': [1080, 1350] };
// Whisper's documented language enum uses ISO codes; the app's prompt
// languages map directly except Kashmiri (not a Whisper language —
// auto-detect is used instead).
const WHISPER_LANGUAGE_BY_PROMPT_LANG = { en: 'en', ur: 'ur', hi: 'hi', ar: 'ar', fa: 'fa', zh: 'zh' };

function planResolutionFor(userId) {
  refreshSubscriptionState(userId);
  const sub = currentSubscription(userId);
  const plan = sub ? getPlan(sub.plan_id) : null;
  return { plan, planResolution: plan ? plan.resolution : CONFIG.resolution };
}

// Owner's upscale price formula on the verified Topaz per-second rate.
function upscalePriceCredits(durationSeconds, outputHeight) {
  const perSec = outputHeight <= 720 ? CONFIG.upscalePerSecondUsd.to720
    : outputHeight <= 1080 ? CONFIG.upscalePerSecondUsd.to1080
    : CONFIG.upscalePerSecondUsd.above1080;
  const raw = Math.ceil(perSec * Math.max(1, Math.ceil(durationSeconds)) * 277 / 1.5) * 2;
  return Math.max(CONFIG.upscaleMinCredits, raw);
}

// Join exactly two clips (source + extension) with the same normalize +
// concat approach as the clip-joining endpoint: everything is conformed
// to the FIRST clip's geometry/fps, silent audio is synthesized for a
// clip that has none, and the result lands in the joined directory.
async function joinTwoClips(urlA, urlB, workDir) {
  const budget = { left: JOIN_MAX_BYTES };
  const srcA = path.join(workDir, 'ext-src.mp4');
  const srcB = path.join(workDir, 'ext-new.mp4');
  await downloadClip(urlA, srcA, budget);
  await downloadClip(urlB, srcB, budget);
  const probes = [await probeMedia(srcA), await probeMedia(srcB)];
  const target = probes[0];
  const vf = `scale=${target.width}:${target.height}:force_original_aspect_ratio=decrease,` +
             `pad=${target.width}:${target.height}:(ow-iw)/2:(oh-ih)/2,` +
             `fps=${target.fps},setsar=1,format=yuv420p`;
  const norms = [];
  for (let i = 0; i < 2; i++) {
    const src = i === 0 ? srcA : srcB;
    const out = path.join(workDir, `ext-norm${i}.mp4`);
    const enc = ['-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
                 '-c:a', 'aac', '-ar', '48000', '-ac', '2'];
    if (probes[i].hasAudio) {
      await runFfmpeg(['-y', '-i', src, '-map', '0:v:0', '-map', '0:a:0', '-vf', vf, ...enc, out]);
    } else {
      await runFfmpeg(['-y', '-i', src,
                       '-f', 'lavfi', '-t', String(probes[i].duration),
                       '-i', 'anullsrc=channel_layout=stereo:sample_rate=48000',
                       '-map', '0:v:0', '-map', '1:a:0', '-vf', vf, ...enc, '-shortest', out]);
    }
    norms.push(out);
  }
  const listFile = path.join(workDir, 'ext-list.txt');
  fs.writeFileSync(listFile, norms.map(n => `file '${n}'`).join('\n'));
  const joinedTmp = path.join(workDir, 'ext-joined.mp4');
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
  return { videoUrl: `/files/joined/${name}`,
           duration: probes[0].duration + probes[1].duration };
}

// Build an .ass subtitle file from Whisper segments (chunks with
// [start, end] timestamps in seconds). Same libass styling approach as
// the watermark: Noto Naskh Arabic so Urdu/Arabic captions shape
// correctly, white text with a dark outline, bottom-centre.
function buildCaptionsAss(chunks, width, height, totalDuration) {
  const fontSize = Math.min(64, Math.max(16, Math.round(height / 16)));
  const lines = [
    '[Script Info]',
    'ScriptType: v4.00+',
    `PlayResX: ${width}`,
    `PlayResY: ${height}`,
    'WrapStyle: 0',
    '',
    '[V4+ Styles]',
    'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding',
    `Style: Captions,Noto Naskh Arabic,${fontSize},&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,1,2,24,24,28,1`,
    '',
    '[Events]',
    'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text',
  ];
  for (const c of chunks) {
    const start = Number(c?.timestamp?.[0]) || 0;
    let end = Number(c?.timestamp?.[1]) || 0;
    if (end <= start) end = Math.min(totalDuration || start + 2, start + 2);
    const text = escapeAssText(String(c?.text || '').trim());
    if (!text) continue;
    lines.push(`Dialogue: 0,${assTimestamp(start)},${assTimestamp(end)},Captions,,0,0,0,,${text}`);
  }
  lines.push('');
  return lines.join('\n');
}

function loadFinishSource(req, res, generationId) {
  const sourceGen = db.prepare('SELECT * FROM generations WHERE id = ? AND user_id = ?')
    .get(Number(generationId), req.user.id);
  if (!sourceGen) { res.status(404).json({ error: 'Generation not found.' }); return null; }
  if (sourceGen.status !== 'completed' || !sourceGen.video_url) {
    res.status(400).json({ error: 'Finishers can only run on a completed video.' });
    return null;
  }
  if (sourceGen.kind === 'sound' && !sourceGen.source_generation_id) {
    res.status(400).json({ error: 'That history entry is an audio file, not a video.' });
    return null;
  }
  return sourceGen;
}

app.post('/api/finish/:action', auth, finishLimiter, async (req, res) => {
  const action = String(req.params.action || '').toLowerCase();
  const b = req.body || {};
  if (!FINISH_ACTIONS.includes(action))
    return res.status(400).json({ error: `action must be one of: ${FINISH_ACTIONS.join(', ')}` });
  const sourceGen = loadFinishSource(req, res, b.generation_id);
  if (!sourceGen) return; // response already sent
  const base = CONFIG.publicBaseUrl || `${req.protocol}://${req.get('host')}`;
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ajk-finish-'));
  try {
    // ---------------- reframe (free, local ffmpeg) ----------------
    if (action === 'reframe') {
      const target = String(b.aspect_ratio || '');
      if (!Object.hasOwn(REFRAME_TARGETS, target))
        return res.status(400).json({ error: `aspect_ratio must be one of: ${Object.keys(REFRAME_TARGETS).join(', ')}` });
      const [W, H] = REFRAME_TARGETS[target];
      const info = db.prepare(
        `INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status,
           cost_credits, resolution, model, mode, kind, source_generation_id, stage)
         VALUES (?, ?, ?, ?, ?, 'in_progress', 0, ?, 'local-ffmpeg', ?, 'reframe', ?, 'final')`)
        .run(req.user.id, `Reframe to ${target}: ${sourceGen.prompt}`.slice(0, 500), target,
             sourceGen.duration, sourceGen.style, sourceGen.resolution || '768P',
             sourceGen.mode || 'realistic', sourceGen.id);
      const jobId = Number(info.lastInsertRowid);
      try {
        const input = path.join(work, 'reframe-in.mp4');
        await downloadClip(sourceGen.video_url, input, { left: JOIN_MAX_BYTES });
        const probe = await probeMedia(input);
        fs.mkdirSync(CONFIG.generatedDir, { recursive: true });
        const name = `${randomUUID()}.mp4`;
        const output = path.join(CONFIG.generatedDir, name);
        const fc = `[0:v]split=2[bgin][fgin];` +
          `[bgin]scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},boxblur=luma_radius=24:luma_power=3[bg];` +
          `[fgin]scale=${W}:${H}:force_original_aspect_ratio=decrease[fg];` +
          `[bg][fg]overlay=(W-w)/2:(H-h)/2,format=yuv420p[v]`;
        const args = ['-y', '-i', input, '-filter_complex', fc, '-map', '[v]'];
        if (probe.hasAudio) args.push('-map', '0:a:0', '-c:a', 'aac', '-ar', '48000', '-ac', '2');
        args.push('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', output);
        await runFfmpeg(args);
        if (!fs.existsSync(output) || fs.statSync(output).size === 0)
          throw new Error('reframe render produced no output');
        db.prepare(`UPDATE generations SET status = 'completed', video_url = ?,
                    updated_at = datetime('now') WHERE id = ?`).run(`/files/generated/${name}`, jobId);
        const row = db.prepare('SELECT * FROM generations WHERE id = ?').get(jobId);
        const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
        return res.status(201).json({ generation: row, credits_left: me.credits, cost_credits: 0 });
      } catch (e) {
        db.prepare(`UPDATE generations SET status = 'failed', error = ?,
                    updated_at = datetime('now') WHERE id = ?`).run(`Reframe failed (${e.message})`, jobId);
        return res.status(502).json({ error: `Reframe failed (${e.message}). Reframing is free — nothing was charged.` });
      }
    }

    // Paid finishers need the provider key; without it they fail closed
    // with 503 and charge nothing (reframe above stays available).
    if (!FAL_KEY)
      return res.status(503).json({ error: 'finisher_not_configured', message: 'This finisher is not configured on this server yet, so nothing was charged.' });

    // ---------------- captions (+5, Whisper -> .ass -> burn) ----------------
    if (action === 'captions') {
      const input = path.join(work, 'captions-in.mp4');
      await downloadClip(sourceGen.video_url, input, { left: JOIN_MAX_BYTES });
      const probe = await probeMedia(input);
      if (!probe.hasAudio)
        return res.status(400).json({ error: 'This video has no audio track, so there is nothing to transcribe into captions. Nothing was charged.' });
      let jobId;
      try {
        jobId = chargeVoiceGeneration(req.user.id, {
          cost: CONFIG.captionsCost,
          prompt: `Captions: ${sourceGen.prompt}`.slice(0, 500),
          aspectRatio: sourceGen.aspect_ratio, duration: sourceGen.duration,
          style: sourceGen.style, model: CONFIG.whisperModel, kind: 'captions',
          sourceGenerationId: sourceGen.id,
          resolution: sourceGen.resolution || '768P', mode: sourceGen.mode || 'realistic',
          promptLanguage: sourceGen.prompt_language,
        });
      } catch (e) { return res.status(e.status || 500).json({ error: e.message }); }
      try {
        const language = WHISPER_LANGUAGE_BY_PROMPT_LANG[sourceGen.prompt_language] || null;
        const result = await runFalQueueJob(CONFIG.whisperModel, {
          audio_url: absoluteMediaUrl(sourceGen.video_url, base),
          task: 'transcribe', chunk_level: 'segment',
          ...(language ? { language } : {}),
        });
        let chunks = Array.isArray(result?.chunks) ? result.chunks : [];
        if (!chunks.length && result?.text)
          chunks = [{ timestamp: [0, probe.duration], text: result.text }];
        if (!chunks.length)
          throw new Error('the transcription returned no timed segments');
        const assPath = path.join(work, 'captions.ass');
        fs.writeFileSync(assPath, buildCaptionsAss(chunks, probe.width, probe.height, probe.duration));
        fs.mkdirSync(CONFIG.generatedDir, { recursive: true });
        const name = `${randomUUID()}.mp4`;
        const output = path.join(CONFIG.generatedDir, name);
        const filterPath = assPath.replace(/\\/g, '/').replace(/:/g, '\\:').replace(/'/g, "\\'");
        await runFfmpeg(['-y', '-i', input, '-vf', `subtitles=${filterPath}`,
                         '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
                         '-c:a', 'copy', output]);
        if (!fs.existsSync(output) || fs.statSync(output).size === 0)
          throw new Error('caption burn-in produced no output');
        db.prepare(`UPDATE generations SET status = 'completed', video_url = ?,
                    updated_at = datetime('now') WHERE id = ?`).run(`/files/generated/${name}`, jobId);
        const row = db.prepare('SELECT * FROM generations WHERE id = ?').get(jobId);
        const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
        return res.status(201).json({ generation: row, credits_left: me.credits, cost_credits: CONFIG.captionsCost });
      } catch (e) {
        failAndRefund(jobId, `Captions failed (${e.message})`);
        return res.status(502).json({ error: `Captions failed (${e.message}). Your ${CONFIG.captionsCost} credits were refunded.` });
      }
    }

    // ---------------- extend (standard rate, i2v from last frame) ------------
    if (action === 'extend') {
      if (sourceGen.stage === 'draft' || (sourceGen.resolution || '') === '480P')
        return res.status(400).json({ error: 'Drafts cannot be extended. Upgrade this draft to full quality first, then extend that version.' });
      const extra = Number(b.extra_seconds ?? b.duration ?? 5);
      if (!CONFIG.durations.includes(extra))
        return res.status(400).json({ error: `extra_seconds must be one of: ${CONFIG.durations.join(', ')}` });
      const tier = RESOLUTIONS.includes(sourceGen.resolution) ? sourceGen.resolution : '768P';
      const { planResolution } = planResolutionFor(req.user.id);
      if (RESOLUTIONS.indexOf(tier) > RESOLUTIONS.indexOf(planResolution))
        return res.status(403).json({ error: `Extending a ${tier} video needs a plan that includes ${tier}. Your current plan goes up to ${planResolution}.` });
      const cost = generationCost(tier, extra);
      let jobId;
      try {
        jobId = chargeVoiceGeneration(req.user.id, {
          cost,
          prompt: `Extended (+${extra}s): ${sourceGen.prompt}`.slice(0, 500),
          aspectRatio: sourceGen.aspect_ratio, duration: sourceGen.duration + extra,
          style: sourceGen.style, model: CONFIG.modelI2V, kind: 'extend',
          sourceGenerationId: sourceGen.id,
          resolution: tier, mode: sourceGen.mode || 'realistic',
          promptLanguage: sourceGen.prompt_language,
          translatedPrompt: sourceGen.translated_prompt,
        });
      } catch (e) { return res.status(e.status || 500).json({ error: e.message }); }
      try {
        const input = path.join(work, 'extend-in.mp4');
        await downloadClip(sourceGen.video_url, input, { left: JOIN_MAX_BYTES });
        const probe = await probeMedia(input);
        const frame = path.join(work, 'last-frame.jpg');
        const seek = Math.max(0, probe.duration - 0.25).toFixed(2);
        await runFfmpeg(['-y', '-ss', seek, '-i', input, '-frames:v', '1', '-q:v', '3', frame]);
        if (!fs.existsSync(frame) || fs.statSync(frame).size === 0)
          throw new Error('could not extract the last frame of the source video');
        const frameUri = `data:image/jpeg;base64,${fs.readFileSync(frame).toString('base64')}`;
        const effectivePrompt = sourceGen.translated_prompt || sourceGen.prompt;
        const result = await runFalQueueJob(CONFIG.modelI2V, {
          prompt: `${effectivePrompt} — style: ${sourceGen.style}`,
          duration: extra, resolution: tier,
          enable_safety_checker: true, image_url: frameUri,
        });
        const extUrl = result?.video?.url || result?.data?.video?.url || null;
        if (!extUrl) throw new Error('the extension generation returned no video');
        const joined = await joinTwoClips(sourceGen.video_url, extUrl, work);
        db.prepare(`UPDATE generations SET status = 'completed', video_url = ?, duration = ?,
                    updated_at = datetime('now') WHERE id = ?`)
          .run(joined.videoUrl, Math.max(1, Math.round(joined.duration)), jobId);
        const row = db.prepare('SELECT * FROM generations WHERE id = ?').get(jobId);
        const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
        return res.status(201).json({ generation: row, credits_left: me.credits, cost_credits: cost });
      } catch (e) {
        failAndRefund(jobId, `Extend failed (${e.message})`);
        return res.status(502).json({ error: `Extend failed (${e.message}). Your ${cost} credits were refunded.` });
      }
    }

    // ---------------- upscale (Topaz, owner price formula) ------------------
    if (action === 'upscale') {
      const tier = RESOLUTIONS.includes(sourceGen.resolution) ? sourceGen.resolution : '768P';
      const tierIdx = RESOLUTIONS.indexOf(tier);
      if (tierIdx >= RESOLUTIONS.length - 1)
        return res.status(400).json({ error: 'This video is already at the highest quality tier — there is nothing to upscale to.' });
      const resultTier = RESOLUTIONS[tierIdx + 1];
      const { planResolution } = planResolutionFor(req.user.id);
      if (RESOLUTIONS.indexOf(resultTier) > RESOLUTIONS.indexOf(planResolution))
        return res.status(403).json({ error: `Upscaling this video to ${resultTier} needs a plan that includes ${resultTier}. Your current plan goes up to ${planResolution}.` });
      const input = path.join(work, 'upscale-in.mp4');
      await downloadClip(sourceGen.video_url, input, { left: JOIN_MAX_BYTES });
      const probe = await probeMedia(input);
      const outputHeight = Math.min(4320, Math.round(probe.height * CONFIG.upscaleFactor));
      const cost = upscalePriceCredits(probe.duration, outputHeight);
      let jobId;
      try {
        jobId = chargeVoiceGeneration(req.user.id, {
          cost,
          prompt: `Upscale to ${resultTier}: ${sourceGen.prompt}`.slice(0, 500),
          aspectRatio: sourceGen.aspect_ratio, duration: sourceGen.duration,
          style: sourceGen.style, model: CONFIG.upscaleModel, kind: 'upscale',
          sourceGenerationId: sourceGen.id,
          resolution: resultTier, mode: sourceGen.mode || 'realistic',
          promptLanguage: sourceGen.prompt_language,
        });
      } catch (e) { return res.status(e.status || 500).json({ error: e.message }); }
      try {
        const result = await runFalQueueJob(CONFIG.upscaleModel, {
          video_url: absoluteMediaUrl(sourceGen.video_url, base),
          model: CONFIG.upscaleTopazModel,
          upscale_factor: CONFIG.upscaleFactor,
          H264_output: true,
        });
        const outUrl = result?.video?.url || result?.data?.video?.url || null;
        if (!outUrl) throw new Error('the upscale provider returned no video');
        db.prepare(`UPDATE generations SET status = 'completed', video_url = ?,
                    updated_at = datetime('now') WHERE id = ?`).run(outUrl, jobId);
        const row = db.prepare('SELECT * FROM generations WHERE id = ?').get(jobId);
        const me = db.prepare('SELECT credits FROM users WHERE id = ?').get(req.user.id);
        return res.status(201).json({ generation: row, credits_left: me.credits, cost_credits: cost });
      } catch (e) {
        failAndRefund(jobId, `Upscale failed (${e.message})`);
        return res.status(502).json({ error: `Upscale failed (${e.message}). Your ${cost} credits were refunded.` });
      }
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
});

// ---------- Draft upgrade ---------------------------------------------------
// One tap on a draft re-runs the SAME prompt/settings (mode, style,
// aspect, duration, language) at a chosen full quality for the standard
// rate — a normal new generation linked to the draft via
// source_generation_id. Plan quality caps apply exactly as in /api/generate.
app.post('/api/generations/:id/upgrade', auth, generateLimiter, async (req, res) => {
  const draft = db.prepare('SELECT * FROM generations WHERE id = ? AND user_id = ?')
    .get(req.params.id, req.user.id);
  if (!draft) return res.status(404).json({ error: 'Generation not found.' });
  if (draft.stage !== 'draft')
    return res.status(400).json({ error: 'Only draft generations can be upgraded — this video is already a full generation.' });
  const quality = String(req.body?.quality || req.body?.resolution || '768P').toUpperCase();
  if (!['768P', '2K', '4K'].includes(quality))
    return res.status(400).json({ error: 'quality must be one of: 768P, 2K, 4K' });
  const { plan, planResolution } = planResolutionFor(req.user.id);
  if (RESOLUTIONS.indexOf(quality) > RESOLUTIONS.indexOf(planResolution))
    return res.status(403).json({ error: `The ${quality} quality needs a plan that includes it. Your current plan goes up to ${planResolution}.` });
  let resolution = quality;
  let model = resolution === '4K' ? (plan && plan.resolution === '4K' ? plan.model : CONFIG.model4k)
                                  : CONFIG.model;
  let fallbackNote = null;
  if (resolution === '4K' && !FOUR_K_ASPECTS.includes(draft.aspect_ratio)) {
    resolution = '2K';
    model = CONFIG.model;
    fallbackNote = 'Native 4K is only available for 16:9, 9:16 and 1:1 videos; ' +
                   'this upgrade was generated at 2K instead.';
  }
  // A 20s draft upgrades through the same two-part chain as a fresh 20s
  // generation — and native 4K has no chain, so it is refused here
  // (before any charge) exactly as in /api/generate.
  if (Number(draft.duration) === 20 && resolution === '4K')
    return res.status(400).json({ error: '20 seconds is not available in native 4K. Upgrade this draft to 768P or 2K instead — it is made in two parts and joined automatically.' });
  const upgradeChain20 = Number(draft.duration) === 20;
  // Keep the draft's route family: an image-to-video draft upgrades
  // through the image-to-video endpoint when its source image still exists.
  let sourceImageDataUri = null;
  if (draft.source_image_path) {
    const owned = resolveOwnedUpload(req.user.id, draft.source_image_path);
    if (owned) { sourceImageDataUri = owned.dataUri; model = CONFIG.modelI2V; }
  }
  const cost = generationCost(resolution, Number(draft.duration));
  let jobId;
  try {
    jobId = tx(() => {
      const user = db.prepare('SELECT * FROM users WHERE id = ?').get(req.user.id);
      const spentToday = db.prepare(
        `SELECT COALESCE(SUM(cost_credits),0) AS s FROM generations
         WHERE user_id = ? AND date(created_at) = date('now') AND status != 'failed'`).get(user.id).s;
      if (spentToday + cost > CONFIG.maxDailyCredits) throw Object.assign(new Error('DAILY_LIMIT'), { status: 429 });
      if (creditBuckets(user).total < cost) throw Object.assign(new Error('NO_CREDITS'), { status: 402 });
      spendBuckets(user, cost);
      const info = db.prepare(
        `INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, cost_credits,
           resolution, model, prompt_language, translated_prompt, mode, source_image_path,
           kind, source_generation_id, stage, chain_stage)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'video', ?, 'final', ?)`)
        .run(user.id, draft.prompt, draft.aspect_ratio, Number(draft.duration), draft.style,
             cost, resolution, model, draft.prompt_language, draft.translated_prompt,
             draft.mode || 'realistic', sourceImageDataUri ? draft.source_image_path : null,
             draft.id, upgradeChain20 ? 'part1' : null);
      return Number(info.lastInsertRowid);
    });
  } catch (e) {
    if (e.message === 'DAILY_LIMIT') return res.status(429).json({ error: 'Daily spending limit reached. Try again tomorrow.' });
    if (e.message === 'NO_CREDITS') return res.status(402).json({ error: 'Not enough credits.' });
    return res.status(e.status || 500).json({ error: e.message });
  }
  const effectivePrompt = draft.translated_prompt || draft.prompt;
  const isNative4k = resolution === '4K' && model === CONFIG.model4k;
  // A chained 20s upgrade submits part 1 as a normal 10s job (as in
  // /api/generate); the chain finishes it on completion.
  const upgradeSubmitDuration = upgradeChain20 ? 10 : Number(draft.duration);
  const falBody = sourceImageDataUri
    ? { prompt: `${effectivePrompt} — style: ${draft.style}`,
        duration: upgradeSubmitDuration, resolution,
        enable_safety_checker: true, image_url: sourceImageDataUri }
    : isNative4k
    ? { prompt: `${effectivePrompt} — style: ${draft.style}`,
        duration: String(draft.duration), aspect_ratio: draft.aspect_ratio,
        generate_audio: false, enable_safety_checker: true }
    : { prompt: `${effectivePrompt} — style: ${draft.style}`,
        duration: upgradeSubmitDuration, aspect_ratio: draft.aspect_ratio, resolution,
        enable_safety_checker: true };
  lastFalBody = falBody;
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
               cost_credits: cost, resolution, model,
               source_generation_id: draft.id, stage: 'final',
               ...(fallbackNote ? { note: fallbackNote } : {}) });
  } catch (e) {
    failAndRefund(jobId, `Provider submission failed (${e.message})`);
    res.status(502).json({ error: 'Video service is unavailable right now. Your credit was refunded.' });
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

// ---------- Tester feedback (Phase I) --------------------------------------
// In-app feedback for the Play closed test: a signed-in user files a
// categorized report from Settings (optionally attached to one of THEIR
// OWN generations via the History "Report issue" action). The server —
// never the client — stamps the app version and the request's
// User-Agent onto the row, so the owner reading the Admin Panel knows
// exactly which build and device class a report came from. The owner
// triages reports via GET /api/admin/feedback (below).
const FEEDBACK_CATEGORIES = ['bug', 'quality', 'feature', 'other'];
app.post('/api/feedback', auth, feedbackLimiter, (req, res) => {
  const b = req.body || {};
  const category = (b.category === undefined || b.category === null || b.category === '')
    ? 'other' : String(b.category).toLowerCase();
  if (!FEEDBACK_CATEGORIES.includes(category))
    return res.status(400).json({ error: `category must be one of: ${FEEDBACK_CATEGORIES.join(', ')}` });
  const message = String(b.message ?? '').trim();
  if (message.length < 5 || message.length > 1000)
    return res.status(400).json({ error: 'Please write between 5 and 1000 characters so the team can act on your feedback.' });
  if (moderated(message))
    return res.status(400).json({ error: 'This feedback was blocked by content moderation. Please rephrase it.' });
  let generationId = null;
  if (b.generation_id !== undefined && b.generation_id !== null && b.generation_id !== '') {
    const gid = Number(b.generation_id);
    const own = Number.isInteger(gid)
      ? db.prepare('SELECT id FROM generations WHERE id = ? AND user_id = ?').get(gid, req.user.id)
      : null;
    if (!own)
      return res.status(400).json({ error: 'That video is not in your history — send the feedback without attaching it.' });
    generationId = gid;
  }
  const info = db.prepare(`INSERT INTO feedback (user_id, category, message, generation_id, app_version, user_agent)
                           VALUES (?, ?, ?, ?, ?, ?)`)
    .run(req.user.id, category, message, generationId, CONFIG.appVersion,
         String(req.headers['user-agent'] || '').slice(0, 300));
  res.status(201).json({ id: Number(info.lastInsertRowid), status: 'open' });
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
// ---------- Advertising (AdMob groundwork — fail closed) -------------------
// A publisher id is valid only in the exact AdMob format: "pub-" + 16
// digits. adsConfigured() = a valid id OR a verbatim app-ads.txt override
// is present; adsEnabled() additionally requires the ADS_ENABLED=1 master
// switch AND the valid publisher id, per the owner's go-live sequence
// (account -> Play listing -> link/review -> env). Nothing here ever
// calls an ad network; it only gates slots and serves app-ads.txt.
const ADMOB_PUBLISHER_ID_RE = /^pub-\d{16}$/;
function admobPublisherValid() { return ADMOB_PUBLISHER_ID_RE.test(CONFIG.admobPublisherId); }
function adsConfigured() { return admobPublisherValid() || !!CONFIG.admobAppAdsTxt; }
function adsEnabled() { return CONFIG.adsEnabled && admobPublisherValid(); }
function appAdsTxtBody() {
  if (CONFIG.admobAppAdsTxt) return CONFIG.admobAppAdsTxt;
  if (admobPublisherValid())
    return `google.com, ${CONFIG.admobPublisherId}, DIRECT, f08c47fec0942fa0`;
  return null;
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
// period); can_veo/can_lipsync are the Phase B entitlement flags and
// can_seedance is the Phase J premium-engine flag (Extra Pro by default).
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
      can_seedance: boolField('can_seedance'),
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
                can_veo = ?, can_lipsync = ?, can_seedance = ?,
                play_product_monthly = ?, play_product_yearly = ?, play_product_weekly = ?,
                updated_at = datetime('now') WHERE id = ?`)
      .run(updated.price_monthly, updated.price_yearly, updated.credits_monthly,
           updated.price_weekly, updated.credits_weekly,
           updated.quality_label, updated.quality, updated.resolution, updated.model,
           updated.is_active, updated.can_veo, updated.can_lipsync, updated.can_seedance,
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

// ---------- Admin: tester feedback (Phase I) -------------------------------
// The owner reads every in-app feedback report here (Admin Panel →
// Feedback section): reporter email, category, message, the optional
// generation it is about, and the server-stamped app version + user
// agent. ?status=open narrows to the untriaged inbox. Resolving or
// reopening is a plain status flip — reports are never deleted.
app.get('/api/admin/feedback', auth, requireAdmin, (req, res) => {
  const status = String(req.query.status || '');
  const base = `SELECT f.*, u.email AS user_email FROM feedback f
                JOIN users u ON u.id = f.user_id`;
  const rows = ['open', 'resolved'].includes(status)
    ? db.prepare(`${base} WHERE f.status = ? ORDER BY f.id DESC LIMIT 200`).all(status)
    : db.prepare(`${base} ORDER BY f.id DESC LIMIT 200`).all();
  res.json({ feedback: rows });
});

app.post('/api/admin/feedback/:id/status', auth, requireAdmin, (req, res) => {
  const status = String(req.body?.status || '');
  if (!['open', 'resolved'].includes(status))
    return res.status(400).json({ error: "status must be 'open' or 'resolved'." });
  const fb = db.prepare('SELECT * FROM feedback WHERE id = ?').get(req.params.id);
  if (!fb) return res.status(404).json({ error: 'Feedback not found.' });
  db.prepare('UPDATE feedback SET status = ? WHERE id = ?').run(status, fb.id);
  res.json({ ok: true, feedback: db.prepare('SELECT * FROM feedback WHERE id = ?').get(fb.id) });
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
fs.mkdirSync(CONFIG.uploadsDir, { recursive: true });
fs.mkdirSync(CONFIG.audioUploadsDir, { recursive: true });
app.use('/files/joined', express.static(CONFIG.joinedDir));
// Uploaded source images are served so the app can show them (character
// thumbnails, the starting-image preview). Filenames are unguessable
// UUIDs — the same exposure model as the other /files mounts.
app.use('/files/uploads', express.static(CONFIG.uploadsDir));
app.use('/files/generated', express.static(CONFIG.generatedDir));
app.use('/files/voice', express.static(CONFIG.voiceDir));
// Phase O2: uploaded own-voice recordings for lip-sync — fal fetches the
// audio from this mount during a lip-sync call (filenames are UUIDs, the
// same exposure model as the other /files mounts).
app.use('/files/audio', express.static(CONFIG.audioUploadsDir));
app.use('/files/sounds', express.static(CONFIG.soundsDir));
app.use(express.static(path.join(__dirname, 'public')));
app.get(/^\/(?!api\/).*/, (req, res) =>
  res.sendFile(path.join(__dirname, 'public', 'index.html')));

app.use((err, req, res, next) => { // last-resort error handler
  console.error(err);
  res.status(500).json({ error: 'Something went wrong on the server.' });
});

// ---------- 20s chain boot recovery (migration v25) ---------------------
// Jobs the chain had claimed ('extending') when the process stopped:
// with part 1's URL on the row the chain can simply run again (its
// settle is exactly-once), so resume those in the background; without
// a URL nothing deliverable exists — fail safe to a full refund. Rows
// still in 'part1' are untouched: their provider job may yet complete
// and the next poll drives the chain from there.
for (const stuck of db.prepare(
  `SELECT * FROM generations WHERE chain_stage = 'extending'`).all()) {
  if (stuck.video_url) {
    ensureTwentyChain(stuck).catch(e =>
      console.error(`20s chain boot resume failed for generation ${stuck.id}:`, e.message));
  } else {
    failAndRefund(stuck.id, 'The 20-second video could not be completed.');
  }
}

app.listen(process.env.PORT || 8080,
  () => console.log(`My Video AI backend running on port ${process.env.PORT || 8080} (model: ${CONFIG.model})`));
