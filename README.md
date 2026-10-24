# My Video AI — Backend Setup & Deployment Guide

This is the secure server-side backend for the **My Video AI** frontend.
The frontend must **never** contain your fal.ai key. All generation requests go:

```
Browser / Android app  →  this backend (login → credits → daily cap → moderation)  →  fal.ai
```

## Requirements
- **Node.js 22.5 or newer** (uses the built-in `node:sqlite` module — no native compilation, no separate database server)
- A **fal.ai account** and API key → https://fal.ai/dashboard/keys. fal.ai bills you per video generated; check the model's page on fal.ai for its price before testing.

## Setup (5 minutes)

1. Open this folder in a terminal and copy the environment template:
   ```
   cp .env.example .env
   ```
2. Edit `.env` and fill in your own values:
   - `FAL_KEY` — your fal.ai key (server-side only; never commit `.env` to git)
   - `JWT_SECRET` — any long random string (e.g. 40+ random characters)
   - `FRONTEND_ORIGIN` — the exact URL where the frontend is hosted
   - `FAL_MODEL` — verified default: `minimax/h3/text-to-video` (see "API verification" below)
   - `FAL_RESOLUTION` — `480P | 768P | 2K | 4K` (lower = cheaper)
3. Install and start:
   ```
   npm install
   npm start
   ```
   On first run the server applies database migrations and creates `myvideoai.db`.
   **Restarting after a config change:** `.env` is only read at startup. Whenever
   you edit `.env` (for example, replacing the placeholder with your real
   `FAL_KEY`), stop the server with `Ctrl+C` and run `npm start` again. Your
   accounts, credits, and history are in `myvideoai.db` and survive restarts.
4. Open `http://localhost:8080/api/health` — you should see `{"ok":true,...}`.

## Connect the frontend
In the My Video AI web app's settings, set the **API base URL** to this server's
address (for local testing: `http://localhost:8080`). The app then calls:
- `POST /api/auth/register`, `POST /api/auth/login`
- `GET /api/me` (account view), `GET /api/config` (model, aspect ratios, durations, costs — public, no secrets)
- `POST /api/generate` with an `Idempotency-Key` header (fresh UUID per click → no duplicate charges)
- `GET /api/generations/:id` (poll every ~4s until `completed`/`failed`)
- `GET /api/history`, `POST /api/report`
- `GET /api/plans` (public pricing), `GET /api/payments` (own payment history); `/api/me` also returns the current plan, subscription status, and the free/plan credit split

## API verification (model & parameters)
Verified against fal.ai's official API docs on 2026-10-20 (no account needed):
- Model id: `minimax/h3/text-to-video`
- Inputs: `prompt` (required), `duration` (integer seconds, default 5),
  `aspect_ratio` (21:9 | 16:9 | 4:3 | 1:1 | 3:4 | 9:16, default 16:9),
  `resolution` (480P | 768P | 2K | 4K), `enable_safety_checker` (default true)
- Output: `{ video: { url, content_type, file_name, file_size } }`
- fal.ai's docs also state the key must be used through a **server-side proxy**, never client-side — which is exactly this architecture.

## Native-4K endpoint (Kling O3 4K)
Verified against fal.ai's official API docs on 2026-10-22
(https://fal.ai/models/fal-ai/kling-video/o3/4k/text-to-video/api):
- Model id: `fal-ai/kling-video/o3/4k/text-to-video` — genuine native 4K in
  one pass, **no upscaling stage**
- Inputs: `prompt` (string, required), `duration` (DurationEnum **as a
  string**, "3"-"15", e.g. `"5"` — this differs from the H3 model's integer),
  `aspect_ratio` (`16:9` | `9:16` | `1:1` only), `generate_audio` (boolean),
  `enable_safety_checker` (default true)
- **There is no `resolution` parameter** — 4K output is fixed by the endpoint,
  so the backend omits it for 4K generations (H3 generations keep it)
- Pricing: flat **$0.42/second**, audio bundled at no extra cost; 5s = $2.10,
  10s = $4.20. 4K is served from fal's **Singapore region** only
- Output: same shape as H3 (`{ video: { url, ... } }`) — the existing polling
  code already parses it

**Aspect-ratio fallback:** the 4K endpoint only renders 16:9, 9:16 and 1:1.
An Extra Pro generation requested at any other ratio falls back to the H3
model at 2K and is charged the **2K rate** — it is neither
charged nor recorded as 4K, and the response carries a `note` explaining this.

## Prompt languages (7)
Users can write their prompt in any of 7 languages. `POST /api/generate`
accepts an optional `language` code (default `en`); `GET /api/config`
exposes the same list as `prompt_languages`. Unknown codes are rejected
with 400 before anything is charged.

| Code | Language | How it reaches the model |
|---|---|---|
| `en` | English | Sent as written (natively supported) |
| `zh` | Chinese | Sent as written (natively supported) |
| `ur` | Urdu | **Auto-translated to English** on the server first |
| `ks` | Kashmiri | **Auto-translated to English** on the server first |
| `ar` | Arabic | **Auto-translated to English** on the server first |
| `fa` | Persian | **Auto-translated to English** on the server first |
| `hi` | Hindi | **Auto-translated to English** on the server first |

**How translation works:** for the five auto-translated languages the server
calls Google Translate's free web endpoint (`client=gtx`) and joins the
returned segments. Translation happens **before** plan routing, credit
deduction and the fal.ai call: if translation fails or returns empty text,
the request fails with 502 and **no credit is deducted and no job is
created**. The endpoint base URL is configurable via `TRANSLATE_API_BASE`
(production default `https://translate.googleapis.com`; the test suite
points it at a local stub — `test-translate-stub.js` — and never calls the
real endpoint). The translated text is also run through the same
blocked-words moderation before it is sent to the model.

**Storage (migration v4):** `generations.prompt` always keeps the user's
**original** text. Two columns record the rest: `prompt_language` (the code
the user wrote in) and `translated_prompt` (the English text sent to the
model; `NULL` for English/Chinese). Both are exposed by `GET /api/history`
and `GET /api/generations/:id`; the app's History shows the original prompt
plus the language and the English text that was sent.

**Honest limitation:** Kashmiri (`ks`) depends on the live Google Translate
endpoint's coverage of that language. The automated tests exercise the
translation plumbing against a local stub only, so real-world Kashmiri
translation coverage/quality is exercised only in production.

## Video modes, image-to-video & watermarks (migration v7)

The Studio opens with two clearly separated mode cards, and every
generation request carries a `mode`:

| Mode | Label in the app | Styles it permits |
|---|---|---|
| `realistic` (default) | Realistic Human Video | `realistic`, `cinematic` |
| `cartoon` | Cartoon / Animation | `cartoon`, `anime` |

The server validates the pairing: an unknown mode, or a style outside
the selected mode's list, is rejected with 400 before anything is
charged. The mode is stored on the generation row (migration v7) and
shown as a label in History. Mode does **not** change credit costs —
the existing duration/quality pricing applies unchanged, and the same
is true for image-to-video and watermarks (see below).

**Audio honesty (verified against fal.ai's docs, 2026-10-23):** MiniMax
H3 generates a native stereo audio track (score, dialogue and foley)
inside every generation, and its schema has **no `generate_audio`
toggle** — so this backend never sends one for H3 text- or
image-to-video calls. If a prompt asks for spoken dialogue, the model
may generate speech that follows the prompt, but the dialogue
**language is not guaranteed**, and Urdu dialogue is **not officially
documented** for this (or any) fal model. Urdu dialogue is instead
produced by the separate voice system (next section): a dedicated TTS
stage synthesizes the speech, and the lip-sync endpoints animate the
mouth to that audio. No lip-sync or pronunciation quality is promised:
the owner's rule stands that realistic samples (a person walking and
speaking, a talking close-up, natural gestures) and cartoon samples
must be generated and reviewed before these experiences are called
complete — that review needs a funded fal.ai balance and has
not happened yet.

**Image-to-video.** `POST /api/uploads/image` (signed-in users only)
accepts `{ image_base64, content_type }` for PNG/JPEG/WebP. The declared
type is never trusted — the real type is sniffed from the magic bytes —
and the decoded image is capped at 5 MB. Files are stored under
`data/uploads/<userId>/` and the endpoint returns that path. A
generation may then pass `image_path`; the server only accepts a path
inside the **caller's own** upload folder, stores it on the row
(`source_image_path`), and routes the job to the image-to-video model
(`FAL_MODEL_I2V`, default `minimax/h3/image-to-video` — **verified**
against fal.ai's official API docs on 2026-10-23:
https://fal.ai/models/minimax/h3/image-to-video/api). The image is sent
in the endpoint's documented **`image_url`** field as a base64 data URI
(fal accepts data URIs for file inputs). The endpoint's canvas follows
the supplied image, so no `aspect_ratio` is sent for image jobs. If
`FAL_MODEL_I2V` is pointed at an endpoint that does not exist, fal
rejects the submission and the job fails with the usual automatic
refund — the same failure path as text-to-video.

**Watermarks.** A generation may include `watermark_text` (1–30
printable ASCII/Latin characters; anything else — including
Urdu/Arabic script — is rejected with 400, because the renderer cannot
shape those scripts correctly). When a job with watermark text
completes, the server downloads the finished MP4, renders the text at
the **bottom-right in white at ~70% opacity**, stores the result under
`data/generated/` (served at `/files/generated/...`), and points the
history row at it with `watermark_status = 'applied'`. If
post-processing fails for any reason, the original unwatermarked video
is kept and the row is marked `watermark_status = 'failed'` — a failed
watermark is never reported as applied. Jobs without watermark text
keep `watermark_status = 'none'`.

*Renderer note (honest deviation):* the brief asked for ffmpeg's
`drawtext` filter, but the pinned `ffmpeg-static` 5.3.0 binary was
built **without libfreetype and has no `drawtext` filter at all**
(verified locally: `No such filter: 'drawtext'`). The same pinned
binary does ship **libass**, so the watermark is rendered with its
`ass` subtitle filter instead — identical placement, opacity and size
contract, and no system ffmpeg dependency (a system ffmpeg cannot be
assumed on the host). Generated files live on local disk, like joined
clips: on ephemeral hosting they disappear on restart/redeploy, so
users should download watermarked videos promptly.

## Audio included — one price, no audio add-ons (Phase G, migration v15)

**Owner directive (2026-10-23, point 5 of the comprehensive
instruction):** voice, dialogue, lip-sync, sound effects and background
music are **not charged separately** — all necessary audio is included
in the single generation price shown before generating. There are no
hidden audio fees. Plan **gates** stay (lip-sync still needs the plan's
`can_lipsync`; premium sync still needs Pro / Extra Pro) — they are
feature tiers now, not prices. Concretely:

- `CONFIG.voiceoverCost = 0` and `CONFIG.soundCosts = { sync: 0,
  premium_sync: 0, sfx: 0, music: 0 }`; Auto Director voice/sound
  proposals carry `cost: 0` and no longer trigger a cost confirmation —
  `needs_confirmation` is true only for true conflicts (mode clash,
  explicit-aspect contradiction, speaking-vs-silent).
- The UI shows **"Included · قیمت میں شامل"** wherever an audio price
  used to appear; the sticky Studio total equals the base video price
  whenever only audio options are chosen.
- **Negations are respected.** The analyzer detects "no music",
  "without dialogue", "no sound effects" and Urdu equivalents
  (موسیقی نہیں / مت، مکالمہ نہیں) and suppresses the matching proposal.
  A global silence request ("silent video", "no audio", خاموش،
  بغیر آواز) sets `apply.mute = true`: no audio is proposed, and after
  the video completes the server strips its audio track locally
  (ffmpeg `-an`; migration v15 adds `generations.mute_status`:
  `pending → applied`). If stripping fails, the original is delivered
  with `mute_status = 'failed'` and an honest note stored on the plan —
  a video is never presented as silent when it is not. A **speaking**
  job can never be silent: at plan time that becomes an `audio`
  conflict for the confirmation path to explain; a direct
  `engine: 'speaking'` generate whose prompt asks for silence is
  rejected with 400 before any charge.
- The speaking engine stays flat **50 credits** — its synchronized
  audio was always part of that one price, never an add-on.

**Sustainability check (run BEFORE the price change, per the owner's
no-loss rule).** Per-use fal prices verified from fal's own model
pages / llms.txt on 2026-10-23:

| Audio step | Endpoint | Verified fal price |
|---|---|---|
| Lip-sync on a finished video (the only lip-sync the in-generation routes use) | `fal-ai/latentsync` | **$0.20 flat** (output ≤ 40 s; $0.005/s beyond) |
| Auto sync sound | `fal-ai/mmaudio-v2` | $0.001/s |
| Premium sync sound | `mirelo-ai/sfx2.0/video-to-audio` | $0.010/s promo until 2026-12-13, then $0.015/s (server pins `num_samples: 1`) |
| Sound effects | `fal-ai/elevenlabs/sound-effects/v2` | $0.002/s of generated audio (≤ 22 s) |
| Music bed | `cassetteai/music-generator` | $0.02 per output minute |
| Voice (default TTS) | `fal-ai/gemini-3.1-flash-tts` | $0.05 / 1,000 chars |
| Voice (premium TTS) | `fal-ai/elevenlabs/tts/eleven-v3` | $0.10 / 1,000 chars |
| Lip-sync from an image (standalone job only — see the Phase G2 note) | `minimax/h3-max/lip-sync/image-to-video` | per second of output (= audio length): $0.05 @480p, **$0.08 @768p**, $0.16 @1080p, $0.32 @2K; ×1.2 past 15 s |

Worst case per tier — the video plus EVERY audio step the workflow can
attach (auto dialogue is capped at 300 chars ≈ $0.03 of premium TTS;
USD/PKR 277; floor revenue values one credit at Rs 14 = $0.0505; Pro
plan credits are worth Rs 19 each, Extra Pro Rs 23.33):

| Tier | Worst-case fal cost | Revenue compared | Verdict |
|---|---|---|---|
| Draft 480P (7/14 cr) | $0.25 / $0.50 — drafts accept NO audio steps at all | $0.354 / $0.708 (floor) | ✅ absorbs |
| 768P 5s/10s (10/20 cr) | $0.34 / $0.65 (video + TTS + priciest sound a free user can attach) | $0.505 / $1.011 (floor) | ✅ absorbs |
| 2K 5s/10s (15/30 cr, Pro/Extra Pro only) | $0.89 / $1.55 (adds LatentSync $0.20 + premium sync) | $1.03 / $2.06 (Pro credit value) | ✅ absorbs |
| Native 4K 5s/10s (40/80 cr, Extra Pro) | $2.34 / $4.45 (the Kling base is silent — `generate_audio: false` — so sound/voice steps attach after it) | $3.37 / $6.74 (Extra Pro value) | ✅ absorbs |
| Speaking / Omni (flat 50 cr) | $0.50 / $1.00 (native synchronized audio; add-ons are rejected, none can attach) | $2.53 (floor) | ✅ absorbs |
| Post-hoc applies, per use | premium sync ≤ $0.15 (10 s), sync $0.01, SFX $0.02, music $0.003; audio-only SFX ≤ $0.044, music ≤ $0.02 | included at 0 cr — absorbed by the margins above | ✅ |

Notes on the 2K row: valued at the absolute Rs 14 pack floor, the 10 s
stack would be ~$0.03 over — but 2K cannot be bought with pack credits
at all (it requires a Pro / Extra Pro plan, whose credits are worth
Rs 19+), so that combination is not purchasable. A Pro user generating
at 768P with the full lip-sync + premium stack stays inside too
(≈ $0.98 vs $1.37 at Pro credit value for 10 s).

> ✅ **RESOLVED (Phase G2, owner decision 2026-10-23) — the standalone
> `POST /api/voice/lipsync` job is INCLUDED (0 credits) too.** In
> Phase G this was the one exception: with scripts up to 6,000
> characters (~400 s of speech) and an image route that bills **per
> second of output**, the worst case was 400 s × $0.08 × 1.2 ≈
> **$38.40** — beyond any plan's per-job revenue. The owner's fix:
> **cap the script at 300 characters** (≈ ≤ 20 s of speech → worst
> case ≈ **$1.92** on the image route, ≈ **$0.23** on the video
> route), which the Pro / Extra Pro subscription that gates the tool
> absorbs. The endpoint now enforces the cap end to end: longer
> scripts are rejected with a 400 before any charge (the same cap
> applies to a referenced voice job's script), the Pro gate is
> unchanged, and because the tool is free it carries a **fair-use cap
> of 10 standalone lip-sync jobs per user per day** (the 11th gets a
> 429). `/api/config` truthfully reports `lipsync_credits: 0` and the
> app's button shows the same "Included · قیمت میں شامل" label as the
> other audio actions.
> **Still open (owner to decide):** a pathological standalone
> *voiceover* script (6,000 chars on the premium TTS = $0.60) exceeds
> what its old 10-credit price covered either — typical scripts
> (≤ 300 chars ≈ $0.03) sit far inside the margin. Voiceover behaviour
> is unchanged; the same script cap would close that corner too.

**Unchanged by this phase:** captions (**+5 credits**) and the
upscale/extend finisher prices keep their rates — they are post-video
finishers, not generation audio. Plan prices are unchanged (frozen by
the owner).

## Voice system — TTS, voice preview, lip-sync & voiceover (Phase B, migration v10)

The Studio's **Voice & Dialogue** card adds spoken Urdu / Hindi /
English to videos. Everything runs server-side; provider keys never
reach the client. Generations gain a `kind` column (`video` |
`lipsync` | `voiceover`), the synthesized track's path
(`voice_audio_path`) and their source generation
(`source_generation_id`); every voice operation (including free
previews) is recorded in the `voice_jobs` table.

**Providers.** Three TTS providers sit behind one interface
(`synthesize({ text, language, voice, style, speed })`):

| Provider | Route | Voices | Cost to us | Activation |
|---|---|---|---|---|
| `gemini` (default) | fal `fal-ai/gemini-3.1-flash-tts` | 10 of the 30 documented Gemini voices (5 female, 5 male), one multilingual set | $0.05 / 1K chars | the existing `FAL_KEY` |
| `elevenlabs` (premium) | fal `fal-ai/elevenlabs/tts/eleven-v3` | 8 documented ElevenLabs voices | $0.10 / 1K chars | the existing `FAL_KEY` |
| `azure` | Azure Speech REST (direct) | **ur-PK-UzmaNeural (F) / ur-PK-AsadNeural (M)** — the only dedicated Pakistani Urdu voices anywhere — plus hi-IN Swara/Madhur, en-US Jenny/Guy | $15 / 1M chars (500K chars/month free tier) | the owner's own `AZURE_SPEECH_KEY` + `AZURE_SPEECH_REGION` |

Both fal schemas were verified against fal's API docs on 2026-10-23
(`prompt`/`voice`/`language_code`/`style_instructions`/`output_format`
for Gemini — its `language_code` enum literally lists "Urdu
(Pakistan)" and "Hindi (India)"; `text`/`voice`/`stability`/
`language_code` (ISO 639-1) for ElevenLabs v3). Style maps to Gemini's
documented natural-language `style_instructions` and to ElevenLabs
`stability`. **Speed honesty:** neither fal schema has a speed field —
Gemini's pace is steered through `style_instructions` (documented),
ElevenLabs v3 accepts the speed setting but cannot apply it (noted,
not faked); Azure takes a real SSML `prosody rate` (0.85 / 1 / 1.15).
Azure SSML style expressions (`mstts:express-as`) are NOT sent for the
ur-PK voices because their style support is not documented — the style
setting is accepted and noted for Azure, as with ElevenLabs speed.
`TTS_PROVIDERS` can restrict the enabled set (e.g. `gemini,azure`, or
`none`); `TTS_DEFAULT_PROVIDER` picks the default. **Fail closed:**
with no provider enabled, all voice endpoints answer 503
(`voice_not_configured`) and charge nothing, and the app shows a
notice instead of dead buttons. `/api/config` exposes the catalog and
configured-provider booleans only — never keys.

**Voice settings** on every voice request: `spoken_language`
(`ur` | `hi` | `en`), `script_mode` (`native` | `roman`), `voice`
(a catalog id for the chosen provider + language), `style`
(`narration` | `conversation` | `news` | `energetic` | `emotional`),
`speed` (`slow` | `normal` | `fast`).

**Roman script.** No commercial TTS provider documents Roman Urdu or
Roman Hindi input, so Roman text is transliterated to the native
script on the server *before* synthesis — the script choice never
changes the spoken language. The converter is **best-effort and
conservative**: a built-in dictionary of common words (mera → میرا /
मेरा, naam → نام / नाम, hai → ہے / है …) plus a character-mapping
fallback (Urdu letter mapping; a syllabic Devanagari converter with
matras/halants). It is not a linguistic transliterator — ambiguous
spellings will sometimes come out wrong, and **native script is always
the recommended input**. The exact text that was synthesized is
returned to the user (preview response) and stored on the job.

**Endpoints.**

- `POST /api/voice/preview` (signed in) — synthesizes at most the
  first **150 characters** of the script with the chosen settings and
  returns a playable URL (audio stored under `data/voice/`, served at
  `/files/voice/...`). **Free — no credits are ever charged**, and it
  is never stored as a generation. Rate-limited twice: **5 previews
  per user per day** plus a global daily guard
  (`VOICE_PREVIEW_DAILY_CAP` / `VOICE_PREVIEW_GLOBAL_DAILY_CAP`).
  Provider errors return a clear 502; nothing is charged either way.
- `POST /api/voice/lipsync` (signed in, **Pro / Extra Pro only** — the
  plan's existing `can_lipsync` flag; Weekly/Normal get 403 with an
  upgrade message). Inputs: an uploaded image (`image_path`, the same
  owned-upload route as image-to-video) **or** a completed generation
  (`generation_id`), plus a `script` — or `voice_job_id`, a previous
  completed voice job whose audio is reused. The full script is
  synthesized (chunked at sentence boundaries, ~3,000 characters per
  request, one consistent voice; chunks are concatenated in order),
  then submitted to fal: image route
  `minimax/h3-max/lip-sync/image-to-video` (`image_url` + `audio_url`,
  resolution 768P), video route `fal-ai/latentsync` (`video_url` +
  `audio_url`) — both schemas verified against fal's docs 2026-10-23,
  both overridable via `FAL_LIPSYNC_IMAGE_MODEL` /
  `FAL_LIPSYNC_VIDEO_MODEL`. Note: fal fetches the audio itself, so the
  server must be publicly reachable at `PUBLIC_BASE_URL` (or the
  request host) for the audio URL. The H3 lip-sync endpoint documents
  that its audio should be **at least 5 seconds** long. **Charge: 30
  credits exactly once** — the ONE documented exception to the Phase G
  "audio included" policy (see *Audio included* above: this standalone
  job's per-second image route cannot be absorbed for long scripts),
  refunded exactly once on any failure via the standard refund path.
  The result lands in History labelled **Talking / Lip-Sync**.
- `POST /api/voice/voiceover` (signed in, all plans) — takes a
  completed generation + script/settings, synthesizes the voice, and
  muxes it over the video with ffmpeg, **replacing the video's
  original audio track** (the model's native audio is not kept; if the
  voice is longer than the video it is trimmed to the video's length).
  The result is stored under `data/generated/` and lands in History
  labelled **Voiceover**. **Charge: 0 credits — included** (Phase G
  "audio included"); on failure nothing was charged and the source
  video is untouched.

**Honesty note (owner's rule).** Voice and lip-sync *quality is
unproven*: no real sample has been generated or listened to yet,
because that needs a funded fal.ai balance (and, for the Azure ur-PK
voices, the owner's own Azure account). Until the owner's sample
audition (Urdu conversation, Urdu newsreader, Hindi speech, a talking
Urdu character with lip sync, a long multilingual script) has been
generated and approved, these features must **not** be marketed as
"perfect" pronunciation or lip-sync — the app copy says exactly that.
The test suite covers all of the above with stubbed providers only
(`test-fal-stub.js`); the Azure path is code-complete but untested
until the owner's key exists.

## Sound system — auto sync sound, SFX & music (Phase B2, migration v11)

Four fal-hosted engines (all schemas verified against fal.ai's own API
docs on 2026-10-23; model ids are env-overridable):

| Engine | Model (env) | Price (fal) | Credits |
|---|---|---|---|
| Auto sync sound | `fal-ai/mmaudio-v2` (`SOUND_SYNC_MODEL`) | $0.001/s | **Included (0)** |
| Premium sync | `mirelo-ai/sfx2.0/video-to-audio` (`SOUND_SYNC_PREMIUM_MODEL`) | $0.010/s promo to 2026-12-13, then $0.015/s | **Included (0)** (Pro / Extra Pro gate stays) |
| Sound effects | `fal-ai/elevenlabs/sound-effects/v2` (`SOUND_SFX_MODEL`) | $0.002/s | **Included (0)** |
| Music bed | `cassetteai/music-generator` (`SOUND_MUSIC_MODEL`) | $0.02/output min | **Included (0)** |

(Credit column updated by Phase G — see *Audio included* above; before
Phase G these were +10 / +25 / +5 / +5 add-ons.)

MMAudio takes the finished video's URL + a prompt and returns a
finished MP4 whose audio track **is** the generated soundtrack (it
replaces the original audio). Mirelo returns generated audio only —
the server muxes it as the video's audio track; the model is designed
to keep the video's existing speech (`preserve_speech: true`,
`num_samples: 1`). ElevenLabs SFX takes the field literally named
`text` plus `duration_seconds` and returns an MP3; CassetteAI takes
`prompt` + `duration` and returns a WAV — the server appends
"instrumental, no vocals" to every music prompt. Standalone audio
lives under `data/sounds/` (env `SOUNDS_DIR`), served at
`/files/sounds/`.

**Three flows.** (1) Generate-time: `POST /api/generate` accepts an
optional `sound: {mode: sync|sfx|music, prompt?, volume?}` — one
atomic charge (the video price; sound is included at 0 since Phase G,
daily cap and balance checked on the total); the video generates
first, then the sound step runs
before the completed video is shown. Sync is applied as returned
(an ffmpeg gain pass runs only when volume ≠ 100); SFX/music are
generated and ffmpeg-mixed **under** the video's original audio at the
chosen volume (`amix`, normalize off) — if the video has no audio
stream, the new track simply becomes its track. (2) Apply to an
existing video: `POST /api/sound/apply` with
`{generation_id, mode: sync|premium_sync|sfx|music, prompt?, volume?}`
creates a new History entry (`kind: "sound"`, linked via
`source_generation_id`); premium sync is gated to the Pro/Extra Pro
plans. (3) Audio only: `POST /api/sound/generate` with
`{kind: sfx|music, prompt, duration_seconds}` (SFX 1–22s, default 10;
music 10–60s, default 30) returns a playable/downloadable audio file.

**Money rules.** Sound prompts go through the same
translate-to-English pipeline as video prompts (any of the 7 prompt
languages) **before** charging — a translation failure charges
nothing. If the sound step fails after the video succeeded, the video
is still delivered as a normal completed generation and the row is
honestly marked `sound_status: 'failed_refunded'` (the status name is
kept from the add-on era; since Phase G the sound portion costs 0, so
the refund bookkeeping moves no money and `cost_credits` already is
the video-only price). Standalone sound jobs run through the same
charge/refund machinery as voice jobs — at 0 credits since Phase G.
Fail-closed: with `SOUND_ENABLED=0` (or no `FAL_KEY`) the sound
endpoints return `503 sound_not_configured` and charge nothing.

**Honest limits (stated in the app copy too).** No engine accepts
timestamped events ("brake at 3.2s") — synchronization is the model's
own estimate from the picture, not a frame-accurate guarantee. Sound
categories (laughter, animals, vehicles…) are not documented on any
fal page; only example prompts exist. Urdu/Hindi sound prompts are
unverified on the audio models, which is why they are translated to
English first. Commercial licensing terms were **not** stated on the
fal pages checked — verify each provider's terms before commercial
launch. And per the owner's rule, sound quality is **unproven** until
real samples are generated on a funded fal.ai balance and reviewed —
the suite covers everything above with stubs only.

## Finishers, draft workflow & templates (Phase C1, migration v12)

**One-tap finishers** — `POST /api/finish/:action` with
`{generation_id, ...}` runs on one of the user's own **completed**
videos and always creates a **new** History entry (`kind` = the
finisher name) linked to the source via `source_generation_id`; the
source is never modified. Cross-user ids return 404.

- **reframe** (`{aspect_ratio: 16:9|9:16|1:1|4:5}`) — local ffmpeg:
  the picture is scaled to fit inside the new frame over a
  blurred-pad background (a blurred, enlarged copy of the video
  itself), never a hard crop. **Free** (local compute, like clip
  joining), no provider call.
- **captions** — the video's own audio is transcribed with fal
  Whisper (`fal-ai/whisper`; schema verified against fal's llms.txt +
  queue OpenAPI 2026-10-23: `audio_url` — MP4 is an accepted format,
  so the video file is passed directly — `task: transcribe`,
  `chunk_level: segment`, `language` when the generation has a known
  dialogue language, else auto-detect) and the timed segments are
  rendered into an `.ass` file (Noto Naskh Arabic styling, the same
  libass renderer as the watermark) and burned in with the
  `subtitles` filter. **+5 credits**, refunded exactly once on any
  failure. A video with **no audio stream is refused with 400 before
  any charge** — there is nothing to transcribe.
- **extend** (`{extra_seconds: 5|10}`) — the source's **last frame**
  is extracted with ffmpeg and sent through the existing H3
  image-to-video route for +5s/+10s at the **source clip's quality
  tier**, charged at the **standard rate card** for that
  quality/duration (plan quality caps apply exactly as in normal
  generation; drafts cannot be extended). Source + extension are
  joined with the clip-joining machinery into one longer video. Any
  step failing refunds exactly once and leaves no partial entry.
- **upscale** — Topaz video upscale on fal
  (`fal-ai/topaz/upscale/video`, model `Proteus`, factor 2; endpoint
  and prices verified against fal's llms.txt 2026-10-23: $0.01/s for
  output up to 720p, $0.02/s up to 1080p, $0.08/s above 1080p). The
  credit price is the owner's formula on the video's **measured**
  duration and output height: `ceil(per-second USD × seconds × 277 /
  15) × 2` margin, **minimum 10 credits** (e.g. a 30-second video
  upscaled to 720p costs `ceil(0.01×30×277/15)×2 = 12` credits; a
  5-second 768P video costs 16). The result is **one tier above the
  source** and must be within the plan's max quality — the same gate
  as generation — and the entry is labelled with the tier it reaches.

**Draft → upgrade.** `POST /api/generate` accepts `quality: "draft"`:
a cheap **480P** preview on the standard H3 model (480P is a
documented H3 tier), flat **7 credits (5s) / 14 credits (10s)**,
marked `stage: 'draft'` (migration v12) and counted against the daily
cap like any charge. Drafts **cannot take sound or voice add-ons**
(the API rejects them with a clear message; the app hides them for
drafts). `POST /api/generations/:id/upgrade` with
`{quality: 768P|2K|4K}` re-runs the **same** prompt/settings (mode,
style, aspect, duration, language) at the chosen full quality for the
standard rate — a normal new generation linked to the draft.

**Template gallery.** The Studio opens with "Start from a template":
Talking Photo (opens the existing voice lip-sync flow), Kids Story
(cartoon mode + story scaffold), Product Ad (realistic, 9:16),
Breaking-News Short (realistic, 9:16; the scaffold itself carries the
honesty line that the visuals are AI-generated), Music Video
(realistic + the existing music sound mode preselected) and Cartoon
Episode (cartoon scaffold). Templates are pure frontend presets over
existing controls — no new backend, no new capabilities.

**Honest limits (stated in the app copy too).** Extend's continuation
is a **new AI generation from the last frame** — continuity across
the join is the model's best effort, **not guaranteed**, and the join
may not be perfectly seamless. Caption **accuracy depends entirely on
the transcription model** — Whisper's published pricing page lists no
per-language accuracy, and Urdu/Hindi caption quality is unverified;
always review captions before publishing. Upscale output is an
**AI-enhanced upscale**, labelled with the tier it reaches (e.g.
"Upscale to 2K") — it is not native capture at that resolution, and
nothing here sells a "native 4K upscale" beyond what the Topaz
endpoint actually does. All finisher quality is **unproven** until
real outputs are generated on a funded fal.ai balance and reviewed —
the suite covers everything above with stubs only.

## Unified one-screen Studio (Phase C3, frontend only)

Creating a video is now a **single, compact create screen**. The six
templates are a slim, horizontally scrolling chip strip at the top of
the Studio (icon + short name + one-line hint) instead of six stacked
full-width cards, and everything needed to create a video lives in
one continuous form in a fixed order: prompt (with its language),
video mode (compact cards), character picker, starting image, then
style / aspect ratio / duration / quality (including Draft). The
optional Voice & Dialogue and Sound & Effects cards are collapsible
and start collapsed — their "not configured" notices stay visible
even while collapsed — followed by the Watermark card and the My
Characters library. Template chips apply exactly the same presets as
before (Talking Photo still scrolls to the voice card, which now also
opens; Music Video still preselects the music sound mode, with the
sound card opened so the choice is visible). A sticky action bar
pinned to the bottom of the Studio shows the **live total credit
cost** (the video price — sound is included at 0 since Phase G —
draft-aware; the same `updateCost()`
computation and the same `#costNum` / `#generateBtn` elements as
before, just relocated) and the Generate button, so neither ever
needs scrolling to find. On phones the hero and connection banner are
compacted so the prompt box sits in the first screenful. No API, id,
or pricing behaviour changed — this phase is layout only, and the
full 506-check suite passes unchanged.

*Phase E layout update:* the manual half of this form (mode,
character, image, style/aspect/duration/quality) plus the Voice,
Sound and Watermark cards now live inside ONE collapsed-by-default
"Advanced settings (optional)" container — see "Frontend (AUTO-FIRST
Studio)" under the Speaking engine section.

## Character library — save a character once, reuse it everywhere (Phase C2, migration v13)

The pattern Kling Elements, Pika Character Studio and Google Flow
Ingredients market: a user saves a character **once** — a reference
photo plus an optional bound voice — and then reuses that character
across videos, so the same character keeps appearing with a consistent
look instead of being re-described (and re-randomized) in every prompt.

**Saving a character.** `POST /api/characters` with `{ name,
image_path }` and optional voice fields (`voice_provider`,
`voice_id`, `voice_language`, `voice_style`). The image must be one of
the caller's **own uploads** — the exact same ownership resolution as
image-to-video, so another user's image path fails with 400 (the file
simply does not exist under the caller's folder). The voice binding is
validated against the public voice catalog (the providers `/api/config`
exposes): an unknown provider, a voice the provider does not offer for
that language, a bad language or a bad style are all 400. When a
provider is bound, the language defaults to Urdu, the style to
conversation and the voice to the provider's default for the language,
so a bound character always carries a **complete** voice. Cap: **10
characters per user** (the 11th create is a 400). `GET /api/characters`
lists only the caller's own characters, each with an `image_url`
(uploaded images are served under `/files/uploads/<userId>/<file>` —
unguessable UUID filenames, the same exposure model as the other
`/files` mounts) and the bound voice. `DELETE /api/characters/:id`
deletes only the caller's own character (404 otherwise) and **never
touches past generations** — jobs made with it keep their
`character_id`; History just shows no name for them afterwards.

**Generating with a character.** `POST /api/generate` accepts
`character_id` (the caller's own, else 404). The character's image
drives the visual through MiniMax H3 **reference-to-video**
(`minimax/h3/reference-to-video`, env `FAL_MODEL_REF`). The endpoint's
schema **and** price were verified against fal.ai's own llms.txt for
the model (2026-10-23) before wiring: inputs are `prompt` (required —
references are cited in the text as "Image 1", "Video 1", …),
`reference_image_urls` (list of strings), `duration` (integer 5–15),
`resolution` (480P | 768P | 2K | 4K), `aspect_ratio`, and
`enable_safety_checker`; the output is `{ video: { url } }`. The app
sends exactly one reference image (as a base64 data URI, like the other
H3 image inputs) and a prompt of the form `Image 1 is the main
character. <prompt> — style: <style>`. **Price:** the endpoint charges
the standard H3 per-second table ($0.05 at 480P, $0.06 at 768P, $0.13
at 2K, $0.16 at 4K) and the first 5 reference images are free (each
additional image $0.08) — a character always sends one image, inside
the free allowance — so character generations are charged the
**standard rate card with no surcharge**, and plan caps, mode/style
pairing, prompt translation, moderation, the sound add-on and the
draft workflow all behave exactly as for a normal generation (a
character also wins over an explicit `image_path` when both are sent).
The job row records `character_id`, and History (and the generation
response) show the character's name. One routing note: a character job
never takes the Kling native-4K route (that endpoint has no
reference-image input) — at 4K a character job is the reference
endpoint's own 4K tier, which — like H3's other 2K/4K tiers — upscales
a 768P base; only character-free jobs on the Extra Pro plan are native
4K.

**Lip-sync with a character.** `POST /api/voice/lipsync` accepts
`character_id` as its visual source: the character's photo is animated
(image route), and the row records the character. Voice fields sent
explicitly in the request win per-field; any field left out falls back
to the character's **bound voice** (provider, voice, language, style),
so picking a character is enough to get its voice. A `character_id`
combined with a `generation_id` is rejected (400), and another user's
character is a 404 that charges nothing. The usual Pro/Extra Pro
lip-sync entitlement still applies first.

**In the app.** The Studio has a **My Characters** card (name + photo
upload reusing the image-upload flow, optional voice binding from the
same catalog as the Voice card, character cards with thumbnail, name,
bound-voice label and Delete), a character picker with thumbnail in
the generate form, and a character picker in the lip-sync flow that
fills the photo and the bound voice. History labels character jobs
with the character's name.

**Honest limits.** Character consistency is the **model's best
effort, not a guarantee** — the app copy says so wherever characters
are offered. The reference endpoint keeps the subject consistent
according to its own model quality, which is **unproven** until real
outputs are generated on a funded fal.ai balance and reviewed; the
suite covers everything above with the local fal stub only. One
reference image is used per character (the endpoint accepts up to 9,
plus reference video/audio — out of scope here).

## AI Auto Director — automatic, prompt-driven creation (Phase D, migration v14)

The Studio has an **AI Auto** toggle (ON by default, remembered per
browser). With it ON, pressing Generate first asks the server for a
**plan** — free, and it never creates a generation or touches credits —
and only asks the user when something would change the price or
contradicts what they picked. With it OFF, the flow is exactly the
manual one.

**How it works.** The analyzer is deterministic and rule-based (v1) —
keyword/regex rules over the prompt, no external LLM calls, so planning
is instant and free. When the prompt language needs translation, the
plan endpoint runs the same translation step as generation first
(translation failure returns the same honest error, still no charge),
then analyzes the English text together with the original script
(Urdu/Devanagari detection happens on the original).

**What it auto-selects**

- **Content class** — animal, human, cartoon, cinematic, product,
  news, music or general — with a matching prompt enrichment
  (`style_suffix`, e.g. wildlife-documentary language for animals,
  camera language for cinematic scenes). Enrichment is appended to the
  user's prompt, never a replacement.
- **Dialogue & voice** — quoted speech, "says:" constructions and Urdu
  dialogue markers are extracted (language: Urdu script → `ur`,
  Devanagari → `hi`, else `en`). When the job has a face (a selected
  character or a human scene) and the plan includes lip-sync, the plan
  proposes the **lip-sync route**; otherwise a **voiceover** — both
  **included (0 credits)** since Phase G, so a voice proposal no
  longer requires confirmation; it is itemized in the plan summary as
  included. The voice step runs after the base video completes,
  through the existing TTS / lip-sync pipeline; if only the voice
  step fails, the video is still delivered and the step is honestly
  marked failed (the included portion costs 0, so no money moves).
- **Sound** — detected events (rain, thunder, car/braking, traffic,
  crowd, ocean/waves, birds, explosion, footsteps, door, wind, city)
  propose synchronized sound; an explicit music ask proposes music —
  both **included (0 credits)** since Phase G. If both fire, sync wins
  and the plan notes that music was skipped. A sound the user already
  selected is kept and enriched instead. **Negations (Phase G):**
  "no music" / "without dialogue" / "no sound effects" (and Urdu
  equivalents) suppress the matching proposal, and a global silence
  request sets `apply.mute` — see *Audio included* above.
- **Orientation** — "shorts / reel / vertical / عمودی" suggests 9:16;
  "widescreen / landscape / افقی" suggests 16:9 — only when the user
  did not explicitly choose an aspect ratio.
- **Engine / route** — see the routing table below.

**When it asks.** Since Phase G, `needs_confirmation` is true **only
for true conflicts**: (a) the prompt clearly conflicts with a selected
option (cartoon prompt + realistic mode, photoreal prompt + cartoon
mode, real-wildlife animal prompt + cartoon mode, or an explicit
aspect ratio that contradicts the prompt's orientation), or (b) a
silence request collides with the speaking engine (a speaking video
cannot be silent). Audio proposals and auto-picked orientations apply
automatically — audio is included in the price, so there is no cost
surprise to confirm. (Before Phase G, chargeable add-ons and aspect
changes also forced confirmation.) The confirmation panel shows what
was understood, each conflict as a two-choice question (my selection
wins / the prompt wins), the itemized cost (base + add-ons = total),
and the honest notes. Confirming generates with the plan; cancelling
generates with the user's manual settings and no plan.

**Engine routing (only routes already integrated in this codebase)**

| Situation | Engine route | Why |
|---|---|---|
| Character selected | H3 reference-to-video | Keeps the saved character consistent across scenes |
| Source image attached | H3 image-to-video | Animates the user's own image |
| Routed quality is native 4K on an entitled plan | Kling O3 4K | The only native-4K route; never forced on other plans |
| Anything else | H3 text-to-video | Default generation route |
| Plan voice is lip-sync | existing video lip-sync endpoint (voice step) | Syncs the generated voice to the finished video's face |

The plan's engine is advisory: when a confirmed plan is applied,
`/api/generate` re-runs the analyzer and the **server's own routing
always wins** — a plan can never force an unentitled route (e.g.
Kling 4K on a non-Extra-Pro plan), and the stored plan records the
route actually used. Costs are likewise always recomputed server-side
from the rate card; client-edited plan prices are ignored.

**Plan endpoint contract**

`POST /api/generate/plan` (auth; shares the generate rate-limit
family; free). Body: the generate form's fields (`prompt`,
`prompt_language`, `mode`, `style`, `aspect_ratio` optional,
`duration`, `quality`, `character_id`, `image_path`, plus optional
`sound` and `voice` selections). Response: `{ plan }` with
`detected { content_class, dialogue, sfx_events, music,
negations { mute, music, dialogue, sfx }, orientation_hint }`,
`apply { mode, style_suffix, aspect_ratio, sound, voice,
speaking_engine, mute }`, `engine { route, model, reason,
voice_route?, voice_model? }`, `conflicts[]`, `base_cost`,
`addons_cost`, `total_cost`, `notes[]`, `needs_confirmation`.
`POST /api/generate` accepts `auto_plan` + `auto_confirmed: true`;
the applied plan is stored on the generation row (migration v14,
`generations.auto_plan`) and returned in the generate response and
History, where the app shows an "AI نے خود منتخب کیا" summary line.

**Honest limits.** Rule-based v1 understanding: it matches keywords
and patterns, it does not truly "understand" a prompt, and unusual
phrasing can be misread (the confirmation panel exists for exactly
that). Urdu dialogue in a video model's own native audio is not
guaranteed by any integrated model — Urdu speech is routed through
the separate voice/lip-sync route (included since Phase G), and
lip-sync quality is best-effort. Whether any of this produces good *output* can only be
judged from real generated samples on a funded fal.ai balance; the
test suite verifies the planning, charging, routing and refund logic
against local stubs only. `GET /api/config` exposes
`auto: { enabled, version }`; set `AUTO_DIRECTOR_ENABLED=0` to turn
the feature off server-side.

*Phase E update:* for speaking-eligible plans (Pro/Extra Pro), a fresh
text-to-video human/news scene with detected dialogue now routes to
the one-step speaking engine below FIRST; the separate voice/lip-sync
route above still serves free/Normal plans, character jobs and
image-to-video jobs.

## Speaking engine — one-step talking videos (Phase E, Gemini Omni)

The talking-clip route is now a real engine: **Gemini Omni Flash 1.1**
on fal (`google/gemini-omni-flash/v1.1/text-to-video`, configurable via
`FAL_MODEL_OMNI`). It generates the video **with synchronized native
audio and dialogue in one step** from a single prompt — no separate
TTS or lip-sync pass.

**Why not Veo?** The plan flag is still called `can_veo`, but the Veo
talking-clip engine was **never wired** — it existed only as an
entitlement flag. Google is retiring Veo 3.1 (its preview model IDs
shut down 2026-10-22 and the GA IDs are flagged for retirement from
2026-11-17), and Omni is Google's designated successor on fal. At the
flat 50-credit speaking price, Veo's $0.40/s would also have lost
money on longer clips; Omni at 720p does not (see the cost check).

**Verified schema** (fal's own llms.txt for the endpoint, 2026-10-23).
The request body has exactly four fields — anything else is a bug:
`prompt` (string, required; carries the dialogue text the user wrote),
`aspect_ratio` (`"16:9"` | `"9:16"` only, default `"16:9"`),
`resolution` (`"360p"` | `"720p"` | `"1080p"` | `"4k"`, default
`"720p"` — the app routes `"720p"` and records the job as `720P`), and
`duration` (integer 3–10, default 8 — the app sends its usual 5 or 10).
There is **no** safety-checker or audio-toggle field, so none is sent.
Output is `{ video: File }`. Prices (fal, per second of output): 360p
$0.03, 720p $0.10, 1080p $0.15, 4K $0.30.

**How it is sold.** Flat **50 credits** per clip (5s or 10s — the
existing speaking-clip rate), **Pro and Extra Pro only** (the
`can_veo` entitlement; everyone else gets 403). Select it directly
with `engine: "speaking"` (alias `"omni_speaking"`) on
`POST /api/generate`, or let AI Auto choose it: when the analyzer
detects dialogue on a speaking-eligible plan and the job is a fresh
text-to-video human/news scene (no character, no starting image), the
plan's engine route is `omni_speaking` with base cost 50 and **no**
voiceover/lip-sync add-on stacked; confirmed plans generate through
the speaking route at that same flat 50. Character and image jobs keep
the Phase D reference/image + lip-sync routes. Because the engine
speaks itself, combining it with voice or sound add-ons is **rejected
with 400** (never silently dropped), as are drafts and any aspect
ratio other than 16:9 / 9:16 — all before charging. Provider failures
use the same exactly-once refund as every other route.
`GET /api/config` exposes `speaking_engine: { provider: "gemini-omni",
model, price_credits: 50, aspects: ["16:9", "9:16"] }`.

**Cost check.** 10s at 720p = 10 × $0.10 = **$1.00 ≈ Rs 277**; 50
credits at the cheapest acquisition (Rs 14/credit) = **Rs 700**
revenue — safely profitable at every duration the app offers.

**Honest limits.** fal does **not** state which dialogue languages
this engine speaks — **Urdu speech on it is UNVERIFIED**, exactly like
every other model's native audio; judge it on real generated samples
before believing any claim about it. Only 16:9 and 9:16 exist. Omni's
"4k" tier is not claimed to be native 4K (that claim belongs only to
the Kling O3 route), and the app does not route it. As with every
engine here, the test suite verifies request shape, charging, gating
and refunds against a local stub — output quality is proven only by
real samples on a funded fal.ai balance.

**Frontend (AUTO-FIRST Studio).** The Studio's primary surface is now
just the Templates strip, the prompt card (with the AI Auto toggle)
and the sticky cost/Generate bar. **All** manual controls — Video Mode
cards, Character picker, Starting image, Style / Aspect / Duration /
Quality, the Voice & Dialogue card, the Sound & Effects card and the
Watermark card — live in **one** collapsible container,
`#advancedCard` ("Advanced settings (optional) · مزید ترتیبات
(اختیاری)"), **collapsed by default**. It reuses the existing collapse
mechanism; every element id inside is unchanged and the generate flow
reads the values exactly as before, collapsed or not. Picking any
template chip opens the container (its presets live inside, so the
user sees what was set), turning AI Auto **off** opens it once, and
the AI Auto confirmation panel stays where it was — inside the prompt
card, above the action bar, never inside the container. The long
explanatory paragraphs (Templates intro, Describe guidance, the AI
Auto description, the modes' audio note) were shortened to one short
line each.

**Flow-style minimal Studio (Phase F, frontend only).** The create
surface is now composer-first, in this order: a quiet template rail
(icon + short label only, one horizontally scrolling row), the prompt
composer (the existing `#prompt` textarea and a compact
`#promptLang` select), one quick chip row, the unchanged AI Auto
confirmation panel, a compact Recent strip, the existing collapsed
`#advancedCard`, and the unchanged sticky cost/Generate bar. The chip
row reuses the **same** `#aspectSeg` and `#durationSeg` controls —
moved, not duplicated — and the same `#aiAutoToggle` checkbox,
restyled as a small switch labelled "Auto"; the generate flow reads
exactly the same elements and state as before. Recent shows the
signed-in user's latest three generations from the same
`/api/history` response the History tab already renders (a video
thumbnail when one is available, otherwise a status icon, plus the
short prompt and status); tapping an item opens History, and the
strip renders nothing at all when there are no generations. The
advanced container still holds mode, character picker, starting
image, style and quality, with the Voice, Sound and Watermark cards
nested as before. No control, element id or API call shape changed:
all 189 existing ids are preserved. The two visible differentiators
from Flow-style composers remain the AI Auto switch and the total
credit cost shown up front in the sticky bar.

**Premium home finishing (Phase H, frontend only).** The Studio now
opens like a finished studio, not a bare form. (1) The existing hero
is a slim band with a gradient wordmark eyebrow ("AJK AI · AI Video
Generator"), the tagline, and a CSS-only blue/purple glow — compact
enough that the composer stays in the first screenful. (2) A
**showcase rail** ("Create anything · سب کچھ بنائیں") shows four
visual style cards (`public/showcase/*.jpg`, each ≤200 KB, max width
720px, ~488 KB total, `loading="lazy"`). Every card is labelled
**"Style preview · انداز کی جھلک"** — the pictures are design
artwork showing a style, NOT videos the app generated — and every
card is a real control wired to the existing `applyTemplate()`:
Realistic & Cinematic and Animals & Wildlife use two new presets in
the same `TEMPLATES` map; Cartoon & Kids reuses the Kids Story
template; Talking & Speaking reuses the Talking Photo template
(opens the Voice card, exactly like the template chip). (3) A
**feature highlights** row (#featureRow) lists six truthful labels
with inline SVG icons: AI Auto Director, Urdu voice & lip-sync,
Speaking video, Native 4K · Extra Pro, Audio included, Your
characters. (4) A **"Your creations" gallery** (#creationsCard)
upgrades the Recent concept into a grid of the user's latest 4
COMPLETED generations with real video thumbnails (same
`preload="metadata"` + `#t=0.1` poster-frame approach as Recent),
prompt caption and duration/resolution/aspect meta; tapping opens
History, and the section stays hidden — no placeholder — until a
completed video exists. No server changes, no behaviour changes to
Phases D–G: all 189 pre-existing element ids are preserved, with
exactly three new container ids (`showcaseRail`, `featureRow`,
`creationsCard`). Test suite: 602 checks, including 7 Phase H
presence/serving checks.

**Home declutter (Phase K, frontend only).** After reviewing
Runway's Play Store screens, the owner found the Phase H-finished
Home crowded ("ہمارے Home سکرین میں کافی رش ہے") — the finishing
worked against the calm, composer-first direction of Phases E/F.
Phase K therefore supersedes the Phase H *placement* (the Phase H
sections themselves were honestly labelled and fully wired; this is
a layout decision, not a defect fix). Removed from the Studio view:
the hero band (`.hero` — the header already carries the brand), the
showcase rail (`#showcaseRail`), the feature highlights row
(`#featureRow`), the Your-creations gallery (`#creationsCard` +
`renderCreations()`), and the Phase F Recent strip (+
`renderRecent()`); the two Phase H showcase-only template presets
went with the rail. Nothing functional is lost: creations live in
the History view, which renders the same `/api/history` data in
full, and the showcase image files stay in `public/showcase/`
(still served, currently unused). In their place, one slim greeting
line tops the Studio — "What are we creating today? · آج کیا بنائیں
گے؟" (`#homeGreeting`) — prefixed Runway-style with "Hi <name>,"
when the already-loaded `/api/me` state carries a display name
(`me.name` / `me.display_name`; `/api/me` returns no name today, so
the generic line stands until it does — no new endpoint, no server
change). Everything else is untouched and in the same order:
template chip rail, composer card, quick chip row, the Phase D
confirmation panel, the collapsed `#advancedCard`, and the sticky
cost/Generate bar. Element ids: exactly the three removed
containers' ids (`showcaseRail`, `featureRow`, `creationsCard`)
went with their sections, plus the id-less Recent strip; one new
id (`homeGreeting`); every other id preserved.

## Premium engine — Seedance 2.5 (Phase J, migration v17)

ByteDance's Seedance 2.5 — currently the top-ranked video model in
independent comparisons — is integrated as an explicit, user-chosen
**premium engine**, approved by the owner on 2026-10-23. It is never
selected automatically: the AI Auto Director never routes to it, and
a forged seedance claim in an echoed auto plan is discarded by
canonicalization exactly like a forged Kling claim (that generation
runs on the server's own route at the recomputed rate-card price).

**Verified schema** (fal's own llms.txt for
`bytedance/seedance-2.5/text-to-video`, 2026-10-23). The request body
has exactly five fields — anything else is a bug: `prompt` (string,
required), `resolution` (`"720p"` — see below), `duration` (a STRING
enum, `"5"` / `"10"` — this schema's durations are strings, unlike
the Omni integer), `aspect_ratio` (`"16:9"` | `"9:16"` | `"1:1"` on
this route), and `generate_audio` (pinned `true`: synchronized
native audio, billed the same either way). The schema's `draft`,
`bitrate_mode`, `codec` and `end_user_id` fields are never sent.
Output is `{ video: File, seed }`. One correction to the working
assumption this phase started from: fal's live schema DOES list a
1080p resolution option (~$1.164/s) alongside 480p (~$0.2205/s) and
720p (~$0.4730/s) — the app still routes 720p only, per the pricing
below. Token billing is $0.0214 per 1K tokens at 480p/720p.

**The no-4K rule.** This engine is NEVER labelled or sold as 4K — not
in the UI, not in plan text, not in this document. BytePlus's own API
caps Seedance 2.5 output at 1080p; the widely shared "Seedance 2.5
native 4K" claim merges two announcements (native 4K was added to
Seedance 2.0). Our native-4K promise belongs only to the Kling O3
route. The Studio option reads "Seedance 2.5 · Premium — Top-ranked
quality · 720p · Extra Pro", and the test suite asserts no "4K"
wording appears anywhere near it.

**How it is sold.** **60 credits (5s) / 120 credits (10s)** — extended
by Phase L to the full linear table below — **Extra Pro only** (the
`can_seedance` entitlement, migration v17; everyone else gets 403). Sustainability at the Rs 14/credit floor and
Rs 277/$: worst case 10s @720p ≈ $4.73 ≈ Rs 1,310 vs floor revenue
120 × Rs 14 = Rs 1,680 (~28% margin); 5s ≈ $2.37 ≈ Rs 656 vs
Rs 840. Select it directly with `engine: "seedance"` (alias
`"seedance_premium"`) on `POST /api/generate`, or with the Seedance
option in the Studio's Quality control (locked, with the plan note,
for everyone else). Because the engine generates its own synchronized
audio, combining it with sound or voice add-ons is **rejected with
400** (never silently dropped), as are drafts, saved characters,
source images, aspects outside 16:9 / 9:16 / 1:1, and any confirmed
AI Auto plan — all before charging. Provider failures use the same
exactly-once refund as every other route. `GET /api/config` exposes
`seedance_engine: { provider: "seedance-2.5", model,
price_credits: { 5: 60, 10: 120 }, aspects: ["16:9", "9:16", "1:1"],
resolution: "720p" }`, and plan payloads carry
`features.can_seedance`. Dialogue languages are not stated by fal —
Urdu speech on this engine is UNVERIFIED and never promised.

**Status: built and simulation-tested — real quality verdict after
the owner's fal top-up sample** (sample battery Batch F: one 5s 720p
clip on benchmark prompt P1, ≈ $2.37, judged against the H3 output
on the same prompt; if it does not clearly beat H3 on realism and
motion, the engine gets disabled, not sold quietly).

## Cinematic camera & shot controls + per-engine durations (Phase L, migration v18)

From the owner's feature spec v2 (2026-10-24, sections 2/3/4/6):
Runway/Higgsfield-style camera direction and Kling-style duration
choice, implemented only where the integrated APIs genuinely support
them.

**Camera movement & shot size — prompt directives, honestly labelled.**
Two optional chip rows in the Studio's Advanced settings: Camera
movement (None, Zoom In, Zoom Out, Pan Left, Pan Right, Tilt Up,
Tilt Down, Tracking Shot, Orbit, Handheld, Static) and Shot size
(None, Close-up, Medium Shot, Wide Shot, Aerial / Drone). No engine in
our wiring exposes a mechanical camera parameter, so these are
**prompt directives**: `POST /api/generate` validates `camera` /
`shot` against fixed whitelists (unknown values → 400 before any
charge) and the server appends a plain-English phrase to the prompt
actually sent to the provider — e.g. `, slow cinematic zoom in,
wide establishing shot` — after translation and after the Auto
Director's own enrichment, so it reaches every text-prompt route
(H3 text/image/reference, Kling O3 4K, Gemini Omni speaking,
Seedance 2.5) verbatim. The Studio hint says exactly what they are:
*"Camera moves are prompt directions to the AI · کیمرہ حرکات AI کو
ہدایات ہیں — the model follows them as guidance, not as a mechanical
guarantee."* Directives are free (no credit change) and work with AI
Auto on or off. If the prompt text itself names a *different* camera
move, the explicit chip wins — it is appended last, as the direct
instruction — and the stored auto plan notes the override (no extra
confirmation round). The choices are recorded on the generation row
(migration v18: `generations.camera_move` / `shot_size` — dedicated
columns rather than the auto_plan JSON, because the controls apply
with Auto on or off while auto_plan exists only for confirmed Auto
plans), and History shows the choices together with the exact
directive phrase that was appended (`camera_directive`, recomputed
server-side from the recorded choices — the same transparency pattern
as `translated_prompt`).

**Longer durations — only where the model genuinely allows them.**
The Seedance 2.5 schema allows 4–30s, so its offered set grows from
{5, 10} to **{5, 10, 15, 20, 30}** at the same linear rate of
**12 credits/second**:

| Duration | 5s | 10s | 15s | 20s | 30s |
|---|---|---|---|---|---|
| Credits | 60 | 120 | 180 | 240 | 360 |

The margin holds linearly: the 30s worst case ≈ 30 × $0.473 =
$14.19 ≈ Rs 3,930 vs floor revenue 360 × Rs 14 = Rs 5,040 (~28%).
The duration is still sent to fal as a **string**, and
`seedance_engine` in `GET /api/config` now carries the `durations`
list beside the price map; the Studio's duration control renders the
extended set only while the Seedance engine is selected and
re-clamps the selection when switching engines. A 30s job costs 360
of the 400-credit daily cap — intended; the cap is unchanged. Every
other engine keeps 5/10s: the H3, Omni and Kling schemas are wired
at those durations in this codebase, a 15s request to them is a 400,
and longer durations are **never faked** — a 60-second video is
served by the existing free clip-joining (up to 6 finished clips),
not by pretending a model generated it in one pass.

**Status: built and simulation-tested** — whether the models honour
the camera directives well is a quality question only the owner's
fal top-up sample battery can answer; the directives are guidance
to the model, and the UI never promises more than that.

## Test results (backend, 2026-10-20)
Run locally with `bash test.sh` — **19/19 tests passed** with a dummy key (no paid calls):
- ✅ health + config endpoint exposes no secrets
- ✅ registration (10 free credits), duplicate-registration rejected, wrong password rejected, unauthenticated requests rejected
- ✅ invalid aspect ratio → 400; blocked prompt → 400; rejected prompts never touch credits
- ✅ generation submit → fal.ai returned a real HTTP 401 for the dummy key → job marked `failed`, **credit refunded** (10 → 10), error stored in history
- ✅ idempotency: same key twice → same job, `duplicate: true`, **no second charge**
- ✅ rate limit: 429 after the hourly generation cap
- ✅ abuse report endpoint accepted
- ✅ **persistence**: server killed and restarted — account, credits, and all 7 history records intact

Not yet testable without your input:
- ❌ a real generation end-to-end (needs your real `FAL_KEY` — your call when to do the one paid test)
- ❌ the frontend build (in progress) against this live backend

**Update (2026-10-23):** the suite has since grown — rescale ×10, credit
packs (incl. NayaPay approve-exactly-once and the served QR image) and clip
joining with real ffmpeg normalization are covered. Latest full run:
**150/150 checks passed** (dummy fal key only; see `test.sh` header for the
server env the battery expects).

**Update (2026-10-23, automatic payments):** the suite now also covers the
Play Billing pipeline (mocked verifier) and the PayFast gateway
(mock-signed IPNs): fail-closed 503s on the unconfigured main server;
valid pack token grants exactly once and replays are no-ops; subscription
token activates the plan; unknown/unpaid tokens grant nothing; a token
can't be replayed by another user; voided-purchase sync claws credits
back and marks the payment refunded; gateway checkout creates a pending
payment; a correctly-signed success IPN grants once (replay no-op); a bad
signature is rejected; a failure IPN grants nothing; a reversal IPN
claws back. Latest full run: **201/201 checks passed**.

**Update (2026-10-23, video modes + Normal price change):** the suite
now also covers the two video modes (validation, style pairing, stored
mode), image uploads (magic-byte sniffing against a lying declared
type, the 5 MB cap, cross-user ownership), the i2v fal request shape
(`image_url` data URI, no `aspect_ratio`, no `generate_audio`), the
watermark pipeline (applied on a locally generated clip with duration
and dimensions preserved; failure path keeps the original video and
marks `failed`), migration v7 re-applying on a v6-shaped database, and
migration v8 repricing the Normal plan on a pre-v8 database (Pro
untouched). Latest full run: **235/235 checks passed**.

**Update (2026-10-23, owner FINAL pricing + Weekly plan — migration v9):**
the suite now also covers migration v9 repricing a pre-v9 database (and
an admin price edit surviving a reboot), the Weekly plan end to end
(activation grants 80 credits for a 7-day period; buying it monthly or
yearly is a 400; a weekly Google Play purchase activates it), the full
per-quality rate card in `/api/config` and in real generation charges
(Pro 2K = 15/30, Extra Pro native 4K = 40/80), plan feature flags in
`/api/plans`, and the daily spending cap at its new default of 400.
Latest full run: **276/276 checks passed**.

**Update (2026-10-23, Phase G — audio included, migration v15):** the
suite now also covers the Phase G policy end to end: config reports
voiceover 0 and all sound modes 0 (the standalone lip-sync job was the
one exception at 30 — resolved in Phase G2 below); generate-time sync/SFX totals equal the base video price,
and post-hoc applies (incl. the Pro premium gate at 0) and audio-only
jobs charge 0; Auto Director plans itemize voice/sound at 0 with
`needs_confirmation` false (the Phase D/E expectations that asserted
add-on charges were updated — AP2/AP3/AP7, GEN1–GEN3, the B18 failure
balances, and the Phase E omni plan's confirmation flag); negation
plans ("no music", "without dialogue") suppress the matching proposal;
a "silent video" plan generates a job whose **delivered file is
asserted to have no audio stream** (the stub source clip has one);
omni + mute is an `audio` conflict at plan time and a clear 400 for a
direct speaking generate; migration v15 re-applies on boot. Latest
full run: **595/595 checks passed**.

**Update (2026-10-23, Phase G2 — standalone lip-sync included):** the
one Phase G exception is resolved per the owner's decision: the
standalone lip-sync job is 0 credits (config reports
`lipsync_credits: 0`; the Phase B7/C2 expectations that asserted the
30-credit charge were updated), its script is capped at 300
characters (301 chars → 400 before any charge, no row; exactly 300 →
201 at 0 credits), and a fair-use cap of 10 standalone jobs per user
per day applies (11th → 429). The Pro gate is unchanged and the
in-generation lip-sync route is untouched.

## Safety built in
- Key and JWT secret live only in `.env`; `/api/config` returns only public settings.
- Credits are deducted and the job recorded in **one atomic transaction** (double-spend safe).
- Failures refund exactly once (guarded `WHERE status NOT IN ('failed','completed')`).
- Rate limits: 300 req/15min global + 10 generations/user/hour; daily spending cap via `MAX_DAILY_CREDITS`.
- Blocked-words moderation runs before any charge; fal's safety checker runs too.

## Monetization (Phase 1 — plans, subscriptions, admin)

Four PKR subscription plans sit on top of the existing credit system
(owner's FINAL pricing, 2026-10-23 — migration v9; yearly = 10× monthly).
Prices and credits are **defaults seeded into the `plans` table** — afterwards
they are edited in the Admin Panel and boot never overwrites an admin's edits.

| Plan | Price | Credits | Quality | Generation route | Premium features |
|---|---|---|---|---|---|
| Weekly | Rs 1,800 / **week** | 80 / week | 768P | H3 model, resolution `768P` | — (H3 modes only) |
| Normal | Rs 5,600 / mo (Rs 56,000 / yr) | 400 / mo | 768P | H3 model, resolution `768P` | — |
| Pro | Rs 9,500 / mo (Rs 95,000 / yr) | 500 / mo | 2K | H3 model, resolution `2K` | Speaking video + lip-sync |
| Extra Pro | Rs 14,000 / mo (Rs 140,000 / yr) | 600 / mo | Native 4K | Kling O3 4K native-4K endpoint (no `resolution` param; 16:9/9:16/1:1 only) | Speaking video + lip-sync, all premium |

**Allowance rationale (brief):** each tier's credits were sized from the
worst case — the subscriber spends every credit at the tier's most
expensive routed quality, priced at fal's published per-second rates
(≈ Rs 277/$). Weekly: 80 credits = 40 s at 768P ≈ $2.40 ≈ Rs 665 of model
cost against Rs 1,800. Normal: 400 credits = 200 s at 768P ≈ $12 ≈
Rs 3,324 against Rs 5,600. Pro: 500 credits ≈ 165 s at 2K ≈ $21.50 ≈
Rs 5,940 against Rs 9,500. Extra Pro: 600 credits = 75 s at native 4K ≈
$31.50 ≈ Rs 8,726 against Rs 14,000. Every tier stays profitable even if
a subscriber maxes out the allowance at the priciest quality.

**The Weekly plan** is a first-class weekly subscription: its price and
credits live in the plan's `price_weekly` / `credits_weekly` columns, a
weekly subscription's period runs **start + 7 days**, and the weekly
credits are granted once per weekly period (same reset/no-rollover rule
as monthly grants). It has **no monthly or yearly price** — the API
reports those fields as `null` for it, and buying it with a monthly or
yearly period is rejected with 400 (as is buying a monthly plan with a
weekly period). On Google Play it maps to its own subscription product
(`ajk_weekly` by default) — Play supports weekly base plans, so the same
verify-then-activate pipeline handles it.

**Feature flags:** plans carry `can_veo` and `can_lipsync`
entitlements, exposed by `/api/plans` in each plan's `features`
descriptor (with `max_quality`) and shown on the plan cards.
`can_lipsync` gates lip-sync (wired in Phase B; since Phase G it is a
feature gate, not a price — in-generation lip-sync is included, and
since Phase G2 the standalone lip-sync job is included too, under a
300-char script cap and a 10-per-day fair-use cap; see
*Audio included*).
`can_veo` — the name is historical — gates the one-step **speaking
video engine** (Gemini Omni, wired in Phase E; the Veo engine it was
named for was never wired and Veo 3.1 is being retired by Google).
See "Speaking engine" below.

**Quality honesty:** on the H3 model, fal's own docs describe 2K/4K as
upscaling a 768P base — the UI labels Pro's quality simply "2K". Extra Pro's
4K is routed to the **native-4K endpoint** (`fal-ai/kling-video/o3/4k/text-to-video`,
verified against fal.ai's API docs 2026-10-22 — genuine native 4K, no upscaling
stage, flat $0.42/s). The endpoint id is configurable via `FAL_MODEL_4K` but the
verified id is the built-in default; it is not a guess. Requests at aspect
ratios the 4K endpoint can't render (only 16:9, 9:16, 1:1) fall back to H3 at
2K at the 2K rate — never charged or recorded as 4K.

**Credit accounting (two buckets):**
- Every user has `free_credits` (the 100 sign-up credits — never expire) and
  `plan_credits` (granted by a subscription). `users.credits` is always their
  sum, so older code paths see one balance.
- Spending takes **plan credits first**. Refunds go back plan-bucket-first,
  capped at the plan's grant for the subscription's period, so a refund can't inflate plan credits.
- On activation and on each renewal, plan credits **reset** to the
  plan's grant for that period (`credits_monthly`, or `credits_weekly`
  for a weekly subscription) — unused plan credits do **not** roll over.
- **Rate card (v9 — replaces the old "native 4K costs double" rule):**
  every routed quality has its own row, charged by duration:

  | Routed quality | 5s | 10s |
  |---|---|---|
  | 768P | 10 credits | 20 credits |
  | 2K | 15 credits | 30 credits |
  | Native 4K | 40 credits | 80 credits |

  `/api/config` exposes the full table as `cost_by_quality` (plus
  `cost_by_duration`, the 768P row, for compatibility), and the Studio
  shows the exact charge for the selected duration at the signed-in
  user's routed quality before generating. If an Extra Pro user
  explicitly picks a lower resolution, that resolution's row and the H3 model apply.
  The same applies to the automatic fallback: a 4K-quality request at an
  aspect ratio the 4K endpoint can't render goes to H3 at 2K at the 2K
  rate, and the row is recorded as H3/2K. The daily cap
  (`MAX_DAILY_CREDITS`, default **400**) counts these costs, and failed generations keep the exact-once auto-refund.

**Subscription lifecycle:** `active → canceled` (benefits continue to the
period end) `→ expired` (period end passes; unused plan credits are removed
lazily on the user's next request). `grace` is reserved for Phase 3 billing
retries. A new activation supersedes the previous subscription.

**Security rule:** plan credits can only appear through `activateSubscription`,
which is reachable **only** from a succeeded payment record or an admin
action. There is no user-facing activation endpoint.

**Payments (Phase 1):** the **admin-only** manual path —
`POST /api/admin/users/:id/manual-payment` — records a payment with
provider `manual_test` (clearly marked, no real charge) and activates the
subscription from it. It remains available for testing/comping alongside
the automatic pipelines below. Users can read their own history at
`GET /api/payments`.

**Admin:** set `ADMIN_EMAIL` in `.env`; that account gets `is_admin` (at
registration, login, or boot). Admin Panel: **`/admin`**. Admin API:
`GET /api/admin/users`, `GET|PUT /api/admin/plans(/:id)`,
`POST /api/admin/users/:id/manual-payment | activate | grant-renewal |
cancel-subscription`, `GET /api/admin/payments`, `GET /api/admin/revenue`
(totals by plan/status + monthly revenue, succeeded payments only).
All admin endpoints return 403 for non-admin users.

## Google Play Billing (automatic — the Android app pipeline)

This is the fully automatic purchase pipeline for the Android (TWA) app:
the user pays inside Google Play → the app sends the purchase token to
this backend → the backend verifies it **with Google** → credits land
instantly, exactly once → refunds/voids claw the credits back.

```
Play app ──purchase──▶ Google Play ──token──▶ POST /api/billing/play/verify
                                                    │ verify with Google
                                                    │ (androidpublisher v3)
                                                    ▼
                                     payments row (provider "google_play",
                                     provider_txn_id = purchase token)
                                                    │ paid?
                                          ┌──yes────┴────no──┐
                                          ▼                  ▼
                              pack → free_credits      attempt recorded
                              plan → activateSubscription  (status failed,
                              (period end = Google expiry)   no grant)
Refunds: RTDN webhook (voidedPurchaseNotification) and/or the admin
"sync voided" reconcile ──▶ shared clawback (below).
```

**Fail closed.** Until `PLAY_PACKAGE_NAME` **and**
`GOOGLE_PLAY_CREDENTIALS` are both set in the server environment, the
verify endpoint returns `503 billing_not_configured` and grants nothing,
and `/api/config` reports `play_billing_configured: false`. No Play
Console account or service account exists yet, so in production today
the pipeline is deliberately inert — nothing about it pretends to work.

**Verification.** The service-account credential
(`GOOGLE_PLAY_CREDENTIALS` — a path to the JSON file, or the JSON inline;
server-side only) is exchanged for an OAuth token using an RS256-signed
JWT built with Node's built-in `node:crypto` (no new dependency), then
the purchase is read from the Play Developer API
(`purchases/products` for packs, `purchases/subscriptions` for plans).
A purchase counts as paid only in Google's paid states (product
`purchaseState = 0`; subscription `paymentState = 1` received or `2` free
trial). Anything else is recorded as a failed attempt and grants nothing.

**Idempotency & token binding.** The purchase token is stored as the
payment's unique `provider_txn_id`. Verifying the same token twice
returns the recorded result and never grants twice; a token first
verified by one account can never be replayed into another account
(409). Grants: packs add their credits to `free_credits`; subscriptions
go through the existing `activateSubscription` path with the period end
taken from Google's expiry time.

**Refunds / voids — the shared clawback.** Google reports refunds via
Real-Time Developer Notifications (Pub/Sub push to
`POST /api/billing/play/rtdn`, shared-secret checked against
`PLAY_RTDN_SECRET` when set) and via the voided-purchases list, which an
admin can pull any time with `POST /api/admin/billing/sync-voided`. Both
run the same `clawbackPayment` helper the gateway uses: the payment is
marked `refunded`, the granted credits are deducted from the bucket they
went to (pack → free, plan → plan, floored at 0), any unrecovered
remainder (credits already spent) is added to the user's
`credit_deficit` — visible in `/api/me` and the Admin Panel — and a
refunded plan payment expires the subscription it paid for. Revenue
needs no special handling: it aggregates `status = 'succeeded'` only,
so refunded Play/gateway payments drop out of the totals automatically
(the by-status breakdown still shows them).

**App side.** In the installed Play app, `public/index.html`
feature-detects the Digital Goods API (`window.getDigitalGoodsService`).
When present, plan cards get "Subscribe — Google Play"
buttons (monthly/yearly, or a single weekly button on the Weekly plan)
and pack cards a "Buy with Google Play" button: the flow fetches
the item details, launches Play's billing sheet, posts the returned
purchase token to the verify endpoint, and only then reports success and
refreshes the balance. Any error (no service, item missing, sheet
cancelled, verification failed) shows a clear message — never a fake
success. When the API is absent (plain web), the existing manual wallet
flow is completely untouched.

**Product IDs** (stored on plans/packs, editable in the Admin Panel; they
must match Play Console exactly):

| Item | Play product ID |
|---|---|
| Weekly (weekly base plan) | `ajk_weekly` |
| Normal monthly / yearly | `ajk_normal_monthly` / `ajk_normal_yearly` |
| Pro monthly / yearly | `ajk_pro_monthly` / `ajk_pro_yearly` |
| Extra Pro monthly / yearly | `ajk_extrapro_monthly` / `ajk_extrapro_yearly` |
| 50 / 100 / 250 credit packs | `credits_50` / `credits_100` / `credits_250` |

### Launch checklist — Google Play (owner steps, in order)

1. **Play Developer account** ($25 one-time, owner's own card) — does not
   exist yet; this is the one hard blocker for live testing.
2. Create the app in Play Console with a package name; set the SAME value
   as `PLAY_PACKAGE_NAME` in the server env (it must match exactly).
3. Create the 7 subscription products (the Weekly plan is a subscription
   with a **weekly base plan** — Play supports weekly billing periods)
   and 3 one-time products with the
   IDs in the table above (or edit the IDs in the Admin Panel to match
   whatever was created — they must agree).
4. Create a **service account** (Google Cloud) with the Play Developer
   API enabled, grant it access to the app in Play Console
   (Users & permissions → the account → financial/order permissions),
   download its JSON key, and set `GOOGLE_PLAY_CREDENTIALS` on the
   server (path or inline). Never put this file/key in the app or repo.
5. Set up **RTDN**: create a Pub/Sub topic, attach it in Play Console
   (Monetization setup → Real-time developer notifications), and point a
   push subscription at `https://<server>/api/billing/play/rtdn?secret=<PLAY_RTDN_SECRET>`
   with `PLAY_RTDN_SECRET` set to the same long random value on the server.
6. Add **license testers** (Play Console → License testing) so test
   purchases don't charge real money, and run one real end-to-end
   purchase + one test refund before opening sales.

**Honest limitation:** end-to-end live testing is impossible until the
Play Developer account exists. The automated suite therefore verifies the
whole pipeline against a token-keyed **mock verifier**
(`PLAY_TEST_MODE=1`, test environments only): valid pack token grants
exactly once (replay is a no-op), subscription token activates the plan,
unknown/unpaid tokens grant nothing, another user can't replay a token,
and a voided purchase is clawed back with the payment marked refunded.

**Closed-testing notes (14 days, ~20 testers):** in-app feedback plus the
app-version marker (Phase I, above) are the test's reporting channel —
testers file from Settings → Feedback, the owner triages in Admin Panel →
Feedback, and every report names the build it came from. Run the closed
test **only after the fal.ai top-up** — without it, every tester's
generation fails and refunds, and the 14 days are wasted.

## PayFast gateway (automatic local payments — Easypaisa / JazzCash / cards / bank)

The local route is automatic too — no screenshots, no manual approval.
A **provider abstraction** sits in front of the gateway: a provider
implements `createCheckout(...)` (returns the hosted-checkout URL + form
fields) and `verifyWebhook(body)` (returns a normalized, signature-checked
result). One concrete adapter ships: **PayFast** (the Pakistani
aggregator — one integration surfaces Easypaisa, JazzCash, bank channels
and cards).

```
Buy Credits ──"Instant" button──▶ POST /api/billing/gateway/checkout
                                     │ payments row (pending,
                                     │ provider_txn_id = our basket id)
                                     ▼
                        PayFast hosted page (user pays)
                                     │ signed IPN
                                     ▼
                        POST /api/billing/gateway/webhook
                        signature + basket + amount verified?
                          yes + success ──▶ succeeded + grant once
                          failure ──▶ marked failed, nothing granted
                          reversal ──▶ shared clawback + refunded
```

**Fail closed.** Until `GATEWAY_PROVIDER=payfast` and
`PAYFAST_MERCHANT_ID` / `PAYFAST_SECURED_KEY` are set, checkout returns
`503 gateway_not_configured`, the webhook grants nothing, and
`/api/config` reports `gateway_configured: false`. When unconfigured,
the Buy Credits page simply keeps the manual transfer flow as the
fallback; when configured, each pack also shows an
**"Instant — pay with Easypaisa / JazzCash / Card"** button that starts
the hosted checkout (a form POST to PayFast's `PostTransaction` URL after
the server mints an access token via `GetAccessToken`).

**Verification.** Per PayFast's merchant integration guide, the checkout
signature is the MD5 hex of
`MERCHANT_ID:MERCHANT_NAME:TXNAMT:BASKET_ID`. The webhook is trusted only
when (a) its `SIGNATURE` equals that construction recomputed with **our**
configured merchant id/name over the IPN's amount + basket id, (b) the
basket id matches a pending payment we created, and (c) the amounts
match. Success is granted **exactly once** — a replayed success IPN on an
already-succeeded payment is a no-op; failed/pending IPNs grant nothing;
a verified reversal/refund runs the same `clawbackPayment` helper as
Play voids. Gateway payments appear in the Admin Panel's
Billing/Transactions list with provider `payfast` and count in revenue
while `succeeded` (and drop out when refunded), exactly like Play.

**Confirm at go-live (from the public docs alone these could not be
pinned down — check them against the merchant dashboard before taking
real money):** the production API host (the code defaults to the UAT
host `ipguat.apps.net.pk` via `PAYFAST_BASE_URL`), the exact IPN field
set PayFast posts (the adapter accepts the documented aliases:
`TRANSACTION_ID`, `BASKET_ID`, `TXNAMT`, `RESPONSE_CODE`, `SIGNATURE`),
the exact status string PayFast sends for a refund/reversal (the adapter
recognizes `refunded/refund/reversed/chargeback/voided` aliases), and
whether the callback URL must also be registered in the dashboard (the
checkout passes it as `CHECKOUT_URL`).

### Go-live requirements — PayFast (owner steps)

1. **The owner's own PayFast merchant account.** Sign-up/KYC needs the
   owner's **CNIC and bank account** — only the owner can complete it;
   nobody else can do this step for him.
2. Put `PAYFAST_MERCHANT_ID`, `PAYFAST_MERCHANT_NAME` and
   `PAYFAST_SECURED_KEY` in the server env, set `GATEWAY_PROVIDER=payfast`
   and `PAYFAST_BASE_URL` to the production host from the dashboard, and
   set `PUBLIC_BASE_URL` to this server's public URL.
3. PayFast charges **its own per-transaction fee** on top of the pack
   price (the rate is set in the merchant agreement — it is not in the
   public docs and is not charged by this app).
4. Run one small real purchase + one refund end-to-end before announcing.

**Honest note on bank transfers:** a plain IBAN transfer can never
verify itself — there is no bank API here that reports "this transfer
arrived". Bank payment becomes automatic **only** as a channel inside
the gateway checkout above. The manual IBAN/wallet flow stays in the app
purely as a fallback for while the gateway account doesn't exist.

## Advertising preparation (Google AdMob groundwork)

Groundwork only — **no ads run yet**, and nothing calls an ad network.
Ads will be served by **Google AdMob into the owner's own account** and
shown to **free-tier users only** (every paid plan is ad-free; no ads on
admin, payment, login or privacy pages). Configuration is env-driven and
**fails closed**: `/api/config` reports an `ads` block
(`enabled` / `configured` / `provider` / `free_tier_only` /
`placements: ["studio_bottom","home_native"]` / `note`), and `enabled`
is true **only** when `ADS_ENABLED=1` **and** `ADMOB_PUBLISHER_ID` is a
valid AdMob publisher id (`pub-` + 16 digits). `GET /app-ads.txt` serves
the owner's `google.com, pub-…, DIRECT, f08c47fec0942fa0` snippet (or the
verbatim `ADMOB_APP_ADS_TXT` override) when configured, **404**
otherwise. The frontend ships two hidden, zero-height slot containers
(`#adStudioBottom`, `#adHomeNative`) that the gated JS unhides only for
signed-in free-tier users while ads are enabled — and then shows only a
neutral "Advertisement" placeholder: no fake ads, no third-party
scripts. Real ad formats (native/interstitial/rewarded) require the
Android app build with the AdMob SDK. **Full owner checklist, go-live
order, payout rules and invalid-traffic warnings: see
[ADS_SETUP.md](ADS_SETUP.md).**

## Credit packs (one-time top-ups, manual payment verification)

Besides subscriptions, users can buy one-time credit packs from the app's
**Buy Credits** view. Pack credits land in the `free_credits` bucket, so they
**never expire** and stack on top of any plan credits.

| Pack | Price |
|---|---|
| 50 credits | Rs 899 |
| 100 credits | Rs 1,499 |
| 250 credits | Rs 3,499 |

Packs are seeded into the `credit_packs` table and are editable (credits,
price, active) in the Admin Panel or via `GET|PUT /api/admin/packs(/:id)`.

**Flow (manual, no payment gateway):**
1. The buyer picks a pack and a payment method — **easypaisa, JazzCash,
   NayaPay, or bank transfer**. The destination number/details for each
   method come from the server env (`PAYMENT_EASYPAISA`, `PAYMENT_JAZZCASH`,
   `PAYMENT_NAYAPAY`, `PAYMENT_BANK`) and are exposed via
   `GET /api/config → payment_methods` (only the methods that are set). If
   none are set, the page shows "Payment details will appear here soon."
   Selecting NayaPay also shows the owner's QR code (`/nayapay-qr.jpg`) so
   buyers can scan to pay.
2. The buyer pays manually, then submits the **transaction ID**
   (`POST /api/packs/:id/purchase`). This creates a **pending** purchase in
   `pack_purchases` with a snapshot of the pack's credits/price — it grants
   **nothing**.
3. An admin verifies the payment arrived, then approves in the Admin Panel
   (or `POST /api/admin/pack-purchases/:id/approve`). Approval grants the
   credits **exactly once**, transactionally — approving again returns 409
   and never double-grants. `POST .../reject {note}` rejects without
   granting. Buyers track their orders at `GET /api/my/pack-purchases`.

**Honest limitation:** this is manual verification, not a checkout. Live
gateway checkout (automatic payment confirmation) needs the owner's own
merchant accounts with easypaisa/JazzCash/NayaPay or a bank — those do not
exist yet, so nothing here pretends to charge a card or wallet directly.
(PayPal is not officially available in Pakistan.)

## Joining clips (free, server-side ffmpeg)

From History, a user can tick **2–6** of their own completed videos and join
them into one MP4 (`POST /api/generations/join`, rate-limited to 10 joins per
hour per user). The backend (using the pinned `ffmpeg-static` binary)
downloads each clip (200 MB total cap), normalizes every clip to the **first
clip's** width/height/fps (scale + pad, libx264 + AAC; clips without audio
get a silent track), concatenates them, and saves the result as a normal
history entry — prompt `Joined video (N clips)`, **cost 0 credits**, served
from `/files/joined/<uuid>.mp4`. Joining another user's clip returns 404;
failures return a clear error and never create a charge.

**Storage caveat:** joined files live on the server's **local disk**
(`JOINED_DIR`, default `data/joined/`). On the free Render tier that disk is
**ephemeral** — joined videos disappear when the instance restarts or
redeploys. Users should **download joined videos promptly**; the history row
remains, but the file behind it may not.

## Tester feedback (Phase I, migration v16)

Built for the 14-day Google Play closed test: testers report problems from
**inside the app**, and the owner reads every report in the Admin Panel —
no screenshots over chat, no lost messages.

**How testers report:** Settings → the **Feedback · رائے / مسئلہ** card.
Pick a category (مسئلہ / کوالٹی / نئی سہولت / دیگر = bug / quality / feature
/ other), write what happened (5–1000 characters), tap **Send feedback**.
From any History item, the **Report issue** action jumps straight to the
card with that video attached (a removable chip names it, and the
`generation_id` rides along with the report). Sign-in is required, so the
team can follow up. Reports are rate-limited to **10 per hour per user** to
keep the inbox meaningful.

**What the owner sees:** Admin Panel → **Feedback** lists every report,
newest first, with the reporter's **email**, category badge, message, the
attached video (when one was attached), and a meta line carrying the
**app version + user agent + date**. Both are stamped **server-side** — a
tester cannot forge them — so each report is tied to the exact build and
device class it came from. `?status=open` narrows the inbox to untriaged
reports; **Resolve / Reopen** flips a report's status (reports are never
deleted).

**Version marker:** `APP_VERSION` env (default `1.0`; bump per release) is
exposed as `app_version` in `/api/config` and shown in the Settings footer
as `AJK AI · Version <x>`. The same value is stamped onto every feedback
report.

**Also fixed in this build (owner-visible bug):** the credits chip could
stay stuck at "– credits" for a whole session — the balance loader gave up
silently on any non-401 failure (network hiccup, 5xx, server waking).
It now **retries up to 3 times a few seconds apart**, and on final failure
toasts *"Balance couldn't load — tap the chip to retry"*; **tapping the
chip re-runs the load** (it still opens Buy Credits when the balance loads
fine).

## The localhost fix: app + API on one address
This server also serves the AJK AI web app itself (`public/index.html`) at its
root address `/`. So one address does everything: open the server's address in
a browser and you get the app, with its API calls going to the same address
(same-origin). No separate frontend hosting or CORS setup is required.
(The app's API-URL setting in Settings still lets you point at a different
server if you ever host the two separately.)

## Public HTTPS deployment (Render — free tier)
`localhost` only works on your own device. To use the app from your phone or
share it with others, the server must be public:

1. Make a free GitHub account and upload this project's folder (drag-and-drop
   in the browser works; do NOT upload your `.env` file).
2. Go to render.com → New → Web Service → connect your GitHub repo.
   - Root directory: the folder holding `package.json`
   - Build command: `npm install`
   - Start command: `npm start`
3. In the service's Environment settings, add the same variables as `.env`:
   `FAL_KEY`, `JWT_SECRET`, `FRONTEND_ORIGIN` (your Render URL, e.g.
   `https://ajk-ai.onrender.com`).
4. Deploy. When it is live, open the Render URL — the full AJK AI app is there.
   In the app's Settings the API base URL is already this same address, so
   nothing else needs configuring. (Render free tier sleeps when idle; the
   first open after a pause takes ~1 minute to wake up.)

## Database
- The database is the single `myvideoai.db` file — no DB server to pay for.
- Accounts, credits, and history survive restarts (verified by stopping and
  restarting the server).
- On free hosting tiers the file is wiped when the service redeploys or
  sleeps; keep a backup copy if the history data matters to you.

## Later: Android app (Google Play)
The frontend is a standard single-page web app, which is exactly what
[Capacitor](https://capacitorjs.com) wraps into a native Android app:
`npm i @capacitor/core @capacitor/cli && npx cap init`, then `npx cap add android`.
Keep all secrets server-side (already the case) and the same backend serves the app.
Publishing also needs a Play Console account and your app's privacy policy URL —
the privacy policy page is included in the web app.

## Files
- `server.js` — auth, generate (idempotent, plan-routed, video modes + image-to-video + watermark post-processing), status polling, history, reports, config, plans/subscriptions/payments, credit packs, clip joining (ffmpeg-static), Google Play Billing verification + RTDN + voided-purchase clawback, PayFast gateway checkout + signed IPN, admin API, voice system (TTS providers, preview, lip-sync, voiceover)
- `public/index.html` — the AJK AI web app (Studio with the Voice & Dialogue card, History with clip joining, Plans & pricing, Buy Credits with Google Play + gateway instant checkout when available, Settings, Privacy)
- `public/admin.html` — the Admin Panel, served at `/admin` (includes credit-pack editing, pack-purchase approval, Play product IDs, credit-deficit display, billing/transactions)
- `public/nayapay-qr.jpg` — the owner's NayaPay QR code, shown on the Buy Credits page when NayaPay is selected
- `schema.sql` — schema reference (`server.js` applies migrations automatically on boot)
- `test.sh` — the automated test battery (original + monetization + prompt-language + credit-pack + clip-join + Play Billing/gateway + video-mode/image-to-video/watermark/migration + voice-system + tester-feedback tests; see its header for the server env it needs)
- `test-translate-stub.js` — local Google Translate stub used by `test.sh` (tests never call the real translate endpoint)
- `test-gateway-stub.js` — signs PayFast-shaped webhook bodies for `test.sh` (tests never call the real gateway)
- `test-fal-stub.js` — local fal.ai stub (TTS endpoints + lip-sync queue + media files) used by the voice tests in `test.sh` (tests never call the real fal API)
- `.env.example` — copy to `.env` and fill in (never commit the real one)
