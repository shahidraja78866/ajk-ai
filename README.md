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
| Normal | Rs 1,500 | Rs 15,000 | 100 | 768P | H3 model, resolution `768P` |
| Pro | Rs 3,000 | Rs 30,000 | 120 | 2K | H3 model, resolution `2K` |
| Extra Pro | Rs 5,000 | Rs 50,000 | 120 | Native 4K | Kling O3 4K native-4K endpoint (no `resolution` param; 16:9/9:16/1:1 only) |

**Quality honesty:** on the H3 model, fal's own docs describe 2K/4K as
upscaling a 768P base — the UI labels Pro's quality simply "2K". Extra Pro's
4K is routed to the **native-4K endpoint** (`fal-ai/kling-video/o3/4k/text-to-video`,
verified against fal.ai's API docs 2026-10-22 — genuine native 4K, no upscaling
stage, flat $0.42/s). The endpoint id is configurable via `FAL_MODEL_4K` but the
verified id is the built-in default; it is not a guess. Requests at aspect
ratios the 4K endpoint can't render (only 16:9, 9:16, 1:1) fall back to H3 at
2K with the standard credit rate — never charged or recorded as 4K.

**Credit accounting (two buckets):**
- Every user has `free_credits` (the 100 sign-up credits — never expire) and
  `plan_credits` (granted by a subscription). `users.credits` is always their
  sum, so older code paths see one balance.
- Spending takes **plan credits first**. Refunds go back plan-bucket-first,
  capped at the plan's monthly grant, so a refund can't inflate plan credits.
- On activation and on each renewal month, plan credits **reset** to the
  plan's `credits_monthly` — unused plan credits do **not** roll over.
- Costs (rescaled ×10 in migration v5): 5s = 10 credits, 10s = 20 credits at
  plan quality — except native-4K generations, which cost **double** (5s = 20,
  10s = 40). If an Extra Pro user
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
When present, plan cards get monthly/yearly "Subscribe — Google Play"
buttons and pack cards a "Buy with Google Play" button: the flow fetches
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
| Normal monthly / yearly | `ajk_normal_monthly` / `ajk_normal_yearly` |
| Pro monthly / yearly | `ajk_pro_monthly` / `ajk_pro_yearly` |
| Extra Pro monthly / yearly | `ajk_extrapro_monthly` / `ajk_extrapro_yearly` |
| 50 / 100 / 250 credit packs | `credits_50` / `credits_100` / `credits_250` |

### Launch checklist — Google Play (owner steps, in order)

1. **Play Developer account** ($25 one-time, owner's own card) — does not
   exist yet; this is the one hard blocker for live testing.
2. Create the app in Play Console with a package name; set the SAME value
   as `PLAY_PACKAGE_NAME` in the server env (it must match exactly).
3. Create the 6 subscription products and 3 one-time products with the
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
- `server.js` — auth, generate (idempotent, plan-routed), status polling, history, reports, config, plans/subscriptions/payments, credit packs, clip joining (ffmpeg-static), Google Play Billing verification + RTDN + voided-purchase clawback, PayFast gateway checkout + signed IPN, admin API
- `public/index.html` — the AJK AI web app (Studio, History with clip joining, Plans & pricing, Buy Credits with Google Play + gateway instant checkout when available, Settings, Privacy)
- `public/admin.html` — the Admin Panel, served at `/admin` (includes credit-pack editing, pack-purchase approval, Play product IDs, credit-deficit display, billing/transactions)
- `public/nayapay-qr.jpg` — the owner's NayaPay QR code, shown on the Buy Credits page when NayaPay is selected
- `schema.sql` — schema reference (`server.js` applies migrations automatically on boot)
- `test.sh` — the automated test battery (original + monetization + prompt-language + credit-pack + clip-join + Play Billing/gateway tests; see its header for the server env it needs)
- `test-translate-stub.js` — local Google Translate stub used by `test.sh` (tests never call the real translate endpoint)
- `test-gateway-stub.js` — signs PayFast-shaped webhook bodies for `test.sh` (tests never call the real gateway)
- `.env.example` — copy to `.env` and fill in (never commit the real one)
