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

## API verification (model & parameters)
Verified against fal.ai's official API docs on 2026-10-20 (no account needed):
- Model id: `minimax/h3/text-to-video`
- Inputs: `prompt` (required), `duration` (integer seconds, default 5),
  `aspect_ratio` (21:9 | 16:9 | 4:3 | 1:1 | 3:4 | 9:16, default 16:9),
  `resolution` (480P | 768P | 2K | 4K), `enable_safety_checker` (default true)
- Output: `{ video: { url, content_type, file_name, file_size } }`
- fal.ai's docs also state the key must be used through a **server-side proxy**, never client-side — which is exactly this architecture.

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
- `server.js` — auth, generate (idempotent), status polling, history, reports, config
- `schema.sql` — schema reference (`server.js` applies migrations automatically on boot)
- `test.sh` — the 19-test battery used above
- `.env.example` — copy to `.env` and fill in (never commit the real one)
