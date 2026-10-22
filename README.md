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
model at 2K with the **standard credit rate** (not doubled) — it is neither
charged nor recorded as 4K, and the response carries a `note` explaining this.

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

## Safety built in
- Key and JWT secret live only in `.env`; `/api/config` returns only public settings.
- Credits are deducted and the job recorded in **one atomic transaction** (double-spend safe).
- Failures refund exactly once (guarded `WHERE status NOT IN ('failed','completed')`).
- Rate limits: 300 req/15min global + 10 generations/user/hour; daily spending cap via `MAX_DAILY_CREDITS`.
- Blocked-words moderation runs before any charge; fal's safety checker runs too.

## Monetization (Phase 1 — plans, subscriptions, admin)

Three PKR subscription plans sit on top of the existing credit system.
Prices and credits are **defaults seeded into the `plans` table** — afterwards
they are edited in the Admin Panel and boot never overwrites an admin's edits.

| Plan | Monthly | Yearly | Credits/mo | Quality | Generation route |
|---|---|---|---|---|---|
| Normal | Rs 1,500 | Rs 15,000 | 5 | 768P | H3 model, resolution `768P` |
| Pro | Rs 3,000 | Rs 30,000 | 6 | 2K | H3 model, resolution `2K` |
| Extra Pro | Rs 5,000 | Rs 50,000 | 10 | Native 4K | Kling O3 4K native-4K endpoint (no `resolution` param; 16:9/9:16/1:1 only) |

**Quality honesty:** on the H3 model, fal's own docs describe 2K/4K as
upscaling a 768P base — the UI labels Pro's quality simply "2K". Extra Pro's
4K is routed to the **native-4K endpoint** (`fal-ai/kling-video/o3/4k/text-to-video`,
verified against fal.ai's API docs 2026-10-22 — genuine native 4K, no upscaling
stage, flat $0.42/s). The endpoint id is configurable via `FAL_MODEL_4K` but the
verified id is the built-in default; it is not a guess. Requests at aspect
ratios the 4K endpoint can't render (only 16:9, 9:16, 1:1) fall back to H3 at
2K with the standard credit rate — never charged or recorded as 4K.

**Credit accounting (two buckets):**
- Every user has `free_credits` (the 10 sign-up credits — never expire) and
  `plan_credits` (granted by a subscription). `users.credits` is always their
  sum, so older code paths see one balance.
- Spending takes **plan credits first**. Refunds go back plan-bucket-first,
  capped at the plan's monthly grant, so a refund can't inflate plan credits.
- On activation and on each renewal month, plan credits **reset** to the
  plan's `credits_monthly` — unused plan credits do **not** roll over.
- Costs: 5s = 1 credit, 10s = 2 credits at plan quality — except native-4K
  generations, which cost **double** (5s = 2, 10s = 4). If an Extra Pro user
  explicitly picks a lower resolution, normal rates and the H3 model apply.
  The same applies to the automatic fallback: a 4K-quality request at an
  aspect ratio the 4K endpoint can't render goes to H3 at 2K at the normal
  rate, and the row is recorded as H3/2K. The existing daily cap counts these
  weighted costs, and failed generations keep the exact-once auto-refund.

**Subscription lifecycle:** `active → canceled` (benefits continue to the
period end) `→ expired` (period end passes; unused plan credits are removed
lazily on the user's next request). `grace` is reserved for Phase 3 billing
retries. A new activation supersedes the previous subscription.

**Security rule:** plan credits can only appear through `activateSubscription`,
which is reachable **only** from a succeeded payment record or an admin
action. There is no user-facing activation endpoint.

**Payments (Phase 1):** real Google Play Billing arrives in Phase 3. For
testing there is an **admin-only** manual path —
`POST /api/admin/users/:id/manual-payment` — which records a payment with
provider `manual_test` (clearly marked, no real charge) and activates the
subscription from it. Users can read their own history at `GET /api/payments`.

**Admin:** set `ADMIN_EMAIL` in `.env`; that account gets `is_admin` (at
registration, login, or boot). Admin Panel: **`/admin`**. Admin API:
`GET /api/admin/users`, `GET|PUT /api/admin/plans(/:id)`,
`POST /api/admin/users/:id/manual-payment | activate | grant-renewal |
cancel-subscription`, `GET /api/admin/payments`, `GET /api/admin/revenue`
(totals by plan/status + monthly revenue, succeeded payments only).
All admin endpoints return 403 for non-admin users.

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
- `server.js` — auth, generate (idempotent, plan-routed), status polling, history, reports, config, plans/subscriptions/payments, admin API
- `public/index.html` — the AJK AI web app (Studio, History, Plans & pricing, Settings, Privacy)
- `public/admin.html` — the Admin Panel, served at `/admin`
- `schema.sql` — schema reference (`server.js` applies migrations automatically on boot)
- `test.sh` — the automated test battery (19 original + monetization tests; see its header for the server env it needs)
- `.env.example` — copy to `.env` and fill in (never commit the real one)
