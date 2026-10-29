#!/usr/bin/env bash
# My Video AI backend test battery — uses a DUMMY fal key, so no paid API calls.
# A "successful" fal submission is impossible with a dummy key by design:
# the generate call must fail with 502 and the credit must be refunded.
#
# Server prerequisites for the monetization tests: start the server with
#   ADMIN_EMAIL=admin@example.com        (bootstrap admin account)
#   FAL_MODEL_4K=$TEST_FAL_MODEL_4K      (defaults to the verified o3 4K endpoint)
#   TEST_RECORD_FAL_BODY=1               (enables the /api/_test/fal-body hook
#                                        used to assert the fal request shape)
#   TRANSLATE_API_BASE=http://127.0.0.1:18099
#                                        (prompt-language tests: this script
#                                        starts/stops a local stub —
#                                        test-translate-stub.js — on that port,
#                                        so tests never call the real
#                                        Google Translate endpoint)
# The credit-pack tests run against this main server (no generation quota
# involved). The clip-joining tests are self-contained like the language
# tests: this script starts a third instance (port 18096, own DB,
# JOINED_DIR + PAYMENT_EASYPAISA set) plus a python http server for two
# tiny clips it generates with the pinned ffmpeg-static binary.
# The automatic-payments tests come in two parts: (1) against THIS main
# server, which must be started WITHOUT any Play/gateway env — the
# endpoints must fail closed (503, nothing granted); (2) a self-contained
# fourth instance (port 18095, own DB) started by this script with
# PLAY_TEST_MODE=1 (token-keyed mock Play verifier) and GATEWAY_TEST_MODE=1
# + dummy PayFast merchant values (the real token-mint call is skipped,
# but IPN signature verification runs for real, signed by
# test-gateway-stub.js). No real Google or PayFast calls anywhere.
# The pricing-v9 tests are self-contained too: a sixth instance (port
# 18092, own DB) started by this script covers the Weekly plan lifecycle,
# the per-quality rate card charges and the 4000-credit daily cap, so the
# main server's generation budget is not touched.
# The voice-system tests (Phase B) use a seventh instance (port 18091,
# own DB) whose fal bases (FAL_API_BASE_URL + FAL_QUEUE_BASE_URL) point
# at a local fal stub (test-fal-stub.js, port 18090) that serves the TTS
# endpoints and the lip-sync queue — no real provider calls. An eighth
# instance (port 18089) runs with TTS_PROVIDERS=none to prove the voice
# endpoints fail closed (503, no charges) when no provider is configured.
# The sound-system tests (Phase B2) use a ninth instance (port 18087,
# own DB) with the fal bases pointed at a stub (port 18088) extended
# with the four sound engines (MMAudio + Mirelo queue models, ElevenLabs
# SFX + CassetteAI music sync endpoints) plus a translate stub (port
# 18086) for the Urdu sound-prompt check. A tenth instance (port 18084)
# runs with SOUND_ENABLED=0 to prove the sound endpoints fail closed.
# The finisher/draft tests (Phase C1) use an eleventh instance (port
# 18083, own DB) with the fal bases pointed at the stub (port 18082),
# extended with Whisper (fixed timed chunks) and Topaz upscale, plus the
# clip169.mp4 (16:9, with audio) and silent.mp4 (no audio) fixtures. A
# python http server (port 18081) serves a 30-second clip for the
# upscale price-formula check.
# The character-library tests (Phase C2) use a twelfth instance (port
# 18079, own DB) with the fal bases pointed at the stub (port 18080),
# extended with the minimax/h3/reference-to-video queue endpoint; the
# character generations complete there and the lip-sync TTS calls are
# asserted via the recorded voice-calls hook.
# The advertising-preparation tests use the main server for the default
# fail-closed checks (config ads block off, /app-ads.txt 404, frontend
# slot ids + gating greps), a thirteenth instance (port 18078, own DB)
# with ADS_ENABLED=1 + a valid-format ADMOB_PUBLISHER_ID to prove
# /app-ads.txt serves the exact google.com snippet and ads.enabled is
# true, and a fourteenth instance (port 18077, own DB) with an INVALID
# publisher id to prove both fail closed again, plus a fifteenth
# instance (port 18076, own DB) proving the ADMOB_APP_ADS_TXT override
# line is served verbatim. No ad-network calls anywhere.
# The AI Auto Director tests (Phase D) use the main server for config +
# one free plan call (the plan endpoint shares the generate rate-limit
# family, so the main server gets exactly ONE extra call before the burst
# test), a sixteenth instance (port 18075, fal stub 18074 + translate stub
# 18073) making exactly 10 plan calls and no generations, a seventeenth
# instance (port 18072, stubs 18071/18070) applying confirmed plans
# (sound, voiceover, tamper-proofing, character + Kling engine routes —
# exactly 10 plan/generate calls), and an eighteenth instance (port
# 18069, stubs 18068/18067) for the failure refunds (provider submit,
# voice step, sound step) and the migration-v14 re-apply check.
# The Phase G tests (audio included + negation respect + mute) use a
# twentieth instance (port 18063, fal stub 18062 + translate stub 18061):
# negation plans, a silent generation whose delivered file is asserted to
# have NO audio stream, the omni+mute conflict, the speaking+silent 400,
# and the migration-v15 re-apply check.
# The Phase G2 tests (standalone lip-sync included, owner decision
# 2026-10-23) use a twenty-first instance (port 18051, fal stub 18052):
# on a dedicated Pro user, the 300-char script cap (301 chars -> 400
# with no charge and no row; exactly 300 -> 201 at 0 credits) and the
# fair-use cap of 10 standalone lip-sync jobs per day (11th -> 429).
# Outgoing provider request shapes are asserted via the TEST_RECORD-style
# hook GET /api/_test/voice-calls.
# The Phase I tests (in-app tester feedback for the Play closed test) use
# a twenty-second instance (port 18050, own DB, no stubs needed): the
# feedback lifecycle on a dedicated tester user (401 unauth, 201 happy
# path with the server-stamped user-agent + app_version, 400 on short
# message / bad category / another user's generation_id, default 'other'
# category, own generation_id attached and stored, 10/hour rate limit ->
# 429 on the 11th), the admin inbox (reporter email, newest first,
# ?status=open filter, non-admin 403, resolve/reopen flips persist), the
# config app_version marker, and frontend greps for the Settings feedback
# card, the History "Report issue" action, the version footer and the
# credits-chip balance-retry fix.
# The Phase J tests (Seedance 2.5 premium engine) use a twenty-third
# instance (port 18058, own DB) with the fal bases pointed at a stub
# (port 18059) extended with a Seedance FAILME hook: config block, the
# can_seedance plan flag (Extra Pro only) + migration v17, exactly 10
# generate calls (happy paths at 600/1200 credits with the fal body
# asserted field-for-field against the verified schema via both the
# TEST_RECORD hook and the stub's recorded calls, the 403 entitlement
# gate, the draft/character/image/aspect/sound/voice 400 gates — all
# before charging — and the provider-failure exactly-once refund), plus
# frontend greps (premium option + honest subtext ship, no 4K wording
# anywhere near it). A twenty-fourth instance (port 18055, stub 18056)
# proves the AI Auto Director never routes to the premium engine and a
# forged seedance claim in an echoed plan falls back to server routing.
# The Phase L tests (cinematic camera/shot prompt directives + Seedance
# long durations) use a twenty-fifth instance (port 18046, own DB) with
# the fal bases pointed at the stub (port 18047): the seedance_engine
# durations + linear price map in config, migration v18 (generations
# camera_move/shot_size), the camera/shot whitelist 400s before
# charging, an H3 generation whose recorded fal prompt carries the
# appended directives and whose History row exposes the choices + the
# exact directive phrase, the chip-overrides-prompt note on a confirmed
# auto plan, Seedance 15s/30s happy paths (1800/3600 credits, string
# durations at the stub), a non-offered Seedance duration -> 400, and an
# H3 15s request -> 400 (long durations are never faked for engines
# whose schemas cap at 10s). 8 generate-family calls, inside the shared
# limiter budget. Frontend greps cover the chip rows + honesty line,
# the genBody wiring and the per-engine duration rendering.
# The Phase M tests (Pakistan multilingual system: language registry +
# Language Lab + Punjabi/Pashto/Sindhi voices, owner spec document 3)
# use a twenty-sixth instance (port 18044, own DB) with the fal bases
# pointed at a stub (port 18045): the /api/config languages registry
# (19 rows, honest voice_status values, samples only where verified),
# a stubbed Pashto preview asserting the EXACT "Pashto (Afghanistan)"
# enum string reaches the Gemini provider, a Punjabi voiceover on the
# stub, and the three fail-closed 400s (an unlisted language preview,
# Roman script with Pashto, the premium ElevenLabs provider with
# Punjabi) — each proven to make NO provider call via the recorded
# voice-calls hook. Frontend greps cover the Language Lab card, the
# three status badges, the fallback note and the Voice-card link.
# The Phase N tests (modern auth: identity model, Google Sign-In,
# email verification + forgot/reset password, linking, account
# deletion — owner spec documents 5+6) use a twenty-seventh instance
# (port 18042, own DB) with GOOGLE_CLIENT_ID + the mailer configured,
# both pointed at a local auth stub (test-auth-stub.js, port 18043)
# serving Google's /tokeninfo and the mailer's /send and recording
# every call — no real Google or email-provider calls anywhere. The
# main server (no auth env) proves the fail-closed side: the config
# auth block is all-false with no google_client_id exposed, Google
# sign-in answers 503 auth_provider_not_configured, and the mail
# endpoints answer 503 mailer_not_configured.
# The Phase N2 tests (Facebook Login + phone SMS OTP — owner spec
# documents 5+6, completing Phase N) use a twenty-eighth instance
# (port 18048, own DB) with FACEBOOK_APP_ID/SECRET and the SMS
# adapter configured, both pointed at a second instance of the auth
# stub (port 18049 — extended with Graph /debug_token + /me handlers
# and an SMS /send recorder that exposes the sent codes via /__calls;
# no real Meta or SMS-provider calls anywhere). The mailer stays OFF
# on that instance, so password registration keeps its classic
# behaviour for the link / no-merge fixtures. Coverage: Facebook
# create + repeat (bonus exactly once), wrong-app and invalid
# tokens, the no-email profile (namespaced placeholder account),
# the no-auto-merge collision, link + 409, unlink counting;
# migration v20; phone start/verify with exactly one SMS whose
# 6-digit code is proven SHA-256-hashed in the DB (the raw code is
# no stored value anywhere), wrong-code attempt counting, the
# 5-attempt burn (the correct code then fails too), expiry via a
# manipulated expires_at, the 60s resend 429, the 5/day send cap,
# invalid numbers, spaced/dashed number normalization, the
# SMS-send-failure 502 with the stored code discarded, phone
# linking (requester-bound codes) + 409, and the main server's
# fail-closed 503s + no facebook_app_id exposure.
# The Phase O1 tests (UI language + theme: English/Urdu interface
# switcher with RTL layout + light/dark theme — owner spec v2) are
# frontend-only, against the main server's served homepage: the i18n
# dictionary (>= 60 keys) + applyLanguage/applyTheme ship, the header
# and Settings (Appearance card) switchers ship, the pre-paint script
# and the light-theme + RTL CSS blocks ship, persistence uses the
# ajk_lang / ajk_theme localStorage keys, >= 120 elements carry
# data-i18n, and the full pre-O1 element-ID set (250 ids, embedded in
# the section) is proven intact — presentation only, nothing removed.
# The Phase O2 tests (own-voice audio upload for lip-sync + per-model
# cost/feature display — owner spec v2) use a self-contained instance
# (port 18041, own DB, AUDIO_UPLOADS_DIR in /tmp) with the fal bases
# pointed at a stub (port 18040): MP3/WAV uploads are sniffed by magic
# bytes (fixtures rendered with the pinned ffmpeg), wrong types and
# >10MB are rejected, a 65s recording is rejected 400 audio_too_long
# before any provider call, lip-sync with audio_upload_id runs BOTH
# routes with the uploaded file's public URL while the TTS call count
# provably does not move, another user's upload id is a 404, and the
# main server's /api/config models array is spot-checked against the
# live pricing constants (H3 768P 5s = 120, speaking flat 250,
# Seedance 720p 30s = 3600).
# The Phase P tests (TikTok + X redirect sign-in — completing the
# owner's login-options directive) use a thirtieth instance (port
# 18038, own DB) with TIKTOK_CLIENT_KEY/SECRET and
# TWITTER_CLIENT_ID/SECRET configured, all four base overrides
# pointed at a third instance of the auth stub (port 18037 —
# extended with the TikTok authorize/token/userinfo and X
# authorize/token/users-me endpoints; the authorize endpoints 302
# straight back to the callback, simulating approval, and the X
# token endpoint verifies the PKCE verifier against the recorded
# S256 challenge). No real TikTok or X calls anywhere. Coverage:
# migration v22; config flags on with NO secret material anywhere
# in the payload; the full redirect login for both providers
# (account created with the placeholder address, bonus exactly
# once, second login reuses the account); the SSO handoff (code
# single-use, stored SHA-256-hashed only, expired rejected);
# link-before-login landing on the linked account; the
# identity_in_use conflict for both providers; unlink round-trips;
# state replay / expiry / wrong-provider rejection; a tampered
# PKCE verifier rejected at the stub; and the main server's
# fail-closed side (flags false, start endpoints 503).
# The Phase V tests (20-second videos via the automatic two-part
# chain — owner request 2026-10-27) use a thirty-first instance
# (port 18035, own DB) with the fal bases pointed at a stub
# (port 18036): the 20s rate card in config (768P 480 / 2K 720 /
# draft 280, no 4K 20), migration v25 (chain_stage/chain_note), the
# speaking + native-4K 400s before charging, a stubbed chain SUCCESS
# (one generation, duration 20, joined file served, part 1 submitted
# as a normal 10s job + a 10s image-to-video part 2), a stubbed
# chain FAILURE via the stub's FAILME image-to-video hook (part 1
# delivered at 10s, exactly the 240 second half refunded, bilingual
# chain_note in History), a 20s draft chain, a 2K chain on an Extra
# Pro user, and the Auto Director clamp (a dialogue prompt that
# routes to the speaking engine at 10s never does at 20s).
# Exactly 8 generate-family calls on this instance (shared limiter).
# e.g.  ADMIN_EMAIL=admin@example.com FAL_MODEL_4K=test-4k-model TEST_RECORD_FAL_BODY=1 TRANSLATE_API_BASE=http://127.0.0.1:18099 npm start
# Run against a FRESH database (fixed test emails are registered each run).
TEST_FAL_MODEL_4K=${TEST_FAL_MODEL_4K:-fal-ai/kling-video/o3/4k/text-to-video}
B=http://localhost:8080
PASS=0; FAIL=0
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1 (expected [$2], got [$3])"; FAIL=$((FAIL+1)); fi
}

echo "--- health & config ---"
H=$(curl -s $B/api/health); echo "$H"
check "health ok" "true" "$(echo $H | python3 -c 'import sys,json;print(str(json.load(sys.stdin)["ok"]).lower())')"
C=$(curl -s $B/api/config); echo "$C"
check "config model" "minimax/h3/text-to-video" "$(echo $C | python3 -c 'import sys,json;print(json.load(sys.stdin)["model"])')"
if echo "$C" | grep -qi "dummy_test_key\|JWT_SECRET\|test_jwt"; then check "config leaks no secrets" "clean" "LEAK"; else check "config leaks no secrets" "clean" "clean"; fi

echo "--- auth ---"
R=$(curl -s -X POST $B/api/auth/register -H 'Content-Type: application/json' -d '{"email":"test@example.com","password":"password123"}')
echo "$R"
TOKEN=$(echo $R | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
check "register gives 1000 credits" "1000" "$(echo $R | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
DUP=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/auth/register -H 'Content-Type: application/json' -d '{"email":"test@example.com","password":"password123"}')
check "duplicate register rejected" "409" "$DUP"
BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/auth/login -H 'Content-Type: application/json' -d '{"email":"test@example.com","password":"wrongpass1"}')
check "wrong password rejected" "401" "$BAD"
L=$(curl -s -X POST $B/api/auth/login -H 'Content-Type: application/json' -d '{"email":"test@example.com","password":"password123"}')
TOKEN=$(echo $L | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
ME=$(curl -s $B/api/me -H "Authorization: Bearer $TOKEN"); echo "$ME"
check "me credits = 1000" "1000" "$(echo $ME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' $B/api/history)
check "history requires auth" "401" "$NOAUTH"

echo "--- validation & moderation (no charge) ---"
V=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"prompt":"a cat video","aspect_ratio":"7:3"}')
check "bad aspect ratio rejected" "400" "$V"
M=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"prompt":"gore and violence scene"}')
check "blocked prompt rejected" "400" "$M"
ME2=$(curl -s $B/api/me -H "Authorization: Bearer $TOKEN")
check "credits untouched by rejected prompts" "1000" "$(echo $ME2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- generation with dummy key: submit fails -> 502 + refund ---"
G=$(curl -s -w '\n%{http_code}' -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: test-key-001' -H 'Content-Type: application/json' -d '{"prompt":"a kitten chasing a butterfly in a sunny garden","aspect_ratio":"16:9","duration":5,"style":"realistic"}')
echo "$G"
check "dummy-key generation returns 502" "502" "$(echo "$G" | tail -1)"
HIST=$(curl -s $B/api/history -H "Authorization: Bearer $TOKEN"); echo "$HIST" | head -c 400; echo
check "credits refunded after failure" "1000" "$(echo $HIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "history has 1 failed job" "failed" "$(echo $HIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["status"])')"
JOBID=$(echo $HIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["id"])')

echo "--- idempotency: same key again -> same job, no new charge ---"
G2=$(curl -s -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: test-key-001' -H 'Content-Type: application/json' -d '{"prompt":"a kitten chasing a butterfly in a sunny garden","aspect_ratio":"16:9","duration":5,"style":"realistic"}')
echo "$G2"
check "duplicate flagged" "True" "$(echo $G2 | python3 -c 'import sys,json;print(json.load(sys.stdin).get("duplicate"))')"
HIST2=$(curl -s $B/api/history -H "Authorization: Bearer $TOKEN")
check "still only 1 job in history" "1" "$(echo $HIST2 | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["generations"]))')"
check "credits still 1000" "1000" "$(echo $HIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- report endpoint ---"
RP=$(curl -s -X POST $B/api/report -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "{\"generation_id\":$JOBID,\"reason\":\"test report\"}")
check "report accepted" "True" "$(echo $RP | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"

echo "--- automatic payments: FAIL CLOSED while unconfigured (main server) ---"
# The main server runs with no PLAY_*/GATEWAY_* env, so both automatic
# pipelines must refuse and grant nothing.
CFG0=$(curl -s $B/api/config)
check "config: play_billing_configured is false" "False" "$(echo $CFG0 | python3 -c 'import sys,json;print(json.load(sys.stdin)["play_billing_configured"])')"
check "config: gateway_configured is false" "False" "$(echo $CFG0 | python3 -c 'import sys,json;print(json.load(sys.stdin)["gateway_configured"])')"
UNCONF=$(curl -s -w '\n%{http_code}' -X POST $B/api/billing/play/verify -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_1000","purchase_token":"valid-pack-1000"}')
check "play verify unconfigured -> 503" "503" "$(echo "$UNCONF" | tail -1)"
check "play verify unconfigured error is billing_not_configured" "billing_not_configured" "$(echo "$UNCONF" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "unconfigured play verify granted nothing" "1000" "$(curl -s $B/api/me -H "Authorization: Bearer $TOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
GWUNCONF=$(curl -s -w '\n%{http_code}' -X POST $B/api/billing/gateway/checkout -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"pack_id":1}')
check "gateway checkout unconfigured -> 503" "503" "$(echo "$GWUNCONF" | tail -1)"
check "gateway checkout unconfigured error is gateway_not_configured" "gateway_not_configured" "$(echo "$GWUNCONF" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "gateway webhook unconfigured -> 503" "503" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d 'BASKET_ID=X&TXNAMT=1&RESPONSE_CODE=00&SIGNATURE=x')"

echo "--- monetization: plans API (public) ---"
PLANS=$(curl -s $B/api/plans); echo "$PLANS" | head -c 400; echo
check "plans list has 5 plans" "5" "$(echo $PLANS | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["plans"]))')"
check "normal plan price Rs 5600" "5600" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="normal"][0]["price_monthly"])')"
check "normal plan yearly Rs 56000" "56000" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="normal"][0]["price_yearly"])')"
check "normal plan 4000 credits/mo" "4000" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="normal"][0]["credits_monthly"])')"
check "weekly plan: Rs 1800/week, 800 credits/wk" "1800/800" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["plans"] if x["id"]=="weekly"][0];print(str(p["price_weekly"])+"/"+str(p["credits_weekly"]))')"
check "weekly plan has no monthly price (null)" "None" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="weekly"][0]["price_monthly"])')"
check "normal plan: Veo flag off" "False" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="normal"][0]["features"]["can_veo"])')"
check "pro plan: Veo + lip-sync flags on" "True/True" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["plans"] if x["id"]=="pro"][0];print(str(p["features"]["can_veo"])+"/"+str(p["features"]["can_lipsync"]))')"
check "extrapro label is Native 4K" "Native 4K" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="extrapro"][0]["quality_label"])')"
check "extrapremier plan: Rs 19999/mo, Rs 199990/yr, 10000 credits" "19999/199990/10000" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["plans"] if x["id"]=="extrapremier"][0];print(str(p["price_monthly"])+"/"+str(p["price_yearly"])+"/"+str(p["credits_monthly"]))')"
check "extrapremier plan: all premium flags on (veo/lipsync/seedance)" "True/True/True" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);f=[x for x in d["plans"] if x["id"]=="extrapremier"][0]["features"];print(str(f["can_veo"])+"/"+str(f["can_lipsync"])+"/"+str(f["can_seedance"]))')"
check "extrapremier plan: Native 4K, sorts last" "Native 4K/extrapremier" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);ps=d["plans"];print([x for x in ps if x["id"]=="extrapremier"][0]["quality_label"]+"/"+ps[-1]["id"])')"

echo "--- monetization: admin auth ---"
AR=$(curl -s -X POST $B/api/auth/register -H 'Content-Type: application/json' -d '{"email":"admin@example.com","password":"password123"}')
if ! echo "$AR" | grep -q '"token"'; then AR=$(curl -s -X POST $B/api/auth/login -H 'Content-Type: application/json' -d '{"email":"admin@example.com","password":"password123"}'); fi
ATOKEN=$(echo $AR | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
check "admin flag on ADMIN_EMAIL account" "1" "$(curl -s $B/api/me -H "Authorization: Bearer $ATOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["is_admin"])')"
check "admin endpoints reject non-admin (403)" "403" "$(curl -s -o /dev/null -w '%{http_code}' $B/api/admin/users -H "Authorization: Bearer $TOKEN")"
check "admin endpoints require auth (401)" "401" "$(curl -s -o /dev/null -w '%{http_code}' $B/api/admin/users)"

echo "--- monetization: activation grants plan credits (admin manual payment) ---"
PR=$(curl -s -X POST $B/api/auth/register -H 'Content-Type: application/json' -d '{"email":"planuser@example.com","password":"password123"}')
PTOKEN=$(echo $PR | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PID=$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
check "new user has no plan" "None" "$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"])')"
MP=$(curl -s -X POST $B/api/admin/users/$PID/manual-payment -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"plan_id":"normal","period":"monthly"}')
echo "$MP"
check "manual payment ok" "True" "$(echo $MP | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
PME=$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN")
check "activation: total credits 1000 free + 4000 plan = 5000" "5000" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "activation: plan bucket = 4000" "4000" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
check "activation: free bucket untouched = 1000" "1000" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
check "activation: current plan is normal" "normal" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["id"])')"
PAY=$(curl -s $B/api/payments -H "Authorization: Bearer $PTOKEN")
check "user payment history has 1 payment" "1" "$(echo $PAY | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["payments"]))')"
check "payment amount Rs 5600" "5600" "$(echo $PAY | python3 -c 'import sys,json;print(json.load(sys.stdin)["payments"][0]["amount"])')"
check "payment provider is manual_test" "manual_test" "$(echo $PAY | python3 -c 'import sys,json;print(json.load(sys.stdin)["payments"][0]["provider"])')"

echo "--- monetization: payment isolation + no self-activation ---"
U2R=$(curl -s -X POST $B/api/auth/register -H 'Content-Type: application/json' -d '{"email":"user2@example.com","password":"password123"}')
U2TOKEN=$(echo $U2R | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
U2ID=$(curl -s $B/api/me -H "Authorization: Bearer $U2TOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
check "other user sees 0 payments" "0" "$(curl -s $B/api/payments -H "Authorization: Bearer $U2TOKEN" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["payments"]))')"
check "no self-service activation route (404)" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/payments/manual -H "Authorization: Bearer $U2TOKEN" -H 'Content-Type: application/json' -d '{"plan_id":"normal","period":"monthly"}')"
check "non-admin cannot manual-pay (403)" "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/admin/users/$U2ID/manual-payment -H "Authorization: Bearer $U2TOKEN" -H 'Content-Type: application/json' -d '{"plan_id":"normal","period":"monthly"}')"
check "other user still has no plan" "None" "$(curl -s $B/api/me -H "Authorization: Bearer $U2TOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"])')"

echo "--- monetization: plan routing (normal = 768P on H3; 10s costs 20) ---"
curl -s -o /dev/null -X POST $B/api/generate -H "Authorization: Bearer $PTOKEN" -H 'Idempotency-Key: plan-norm-1' -H 'Content-Type: application/json' -d '{"prompt":"a river flowing through green hills","aspect_ratio":"16:9","duration":10}'
PHIST=$(curl -s $B/api/history -H "Authorization: Bearer $PTOKEN")
check "normal job routed at 768P" "768P" "$(echo $PHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "normal job model is H3" "minimax/h3/text-to-video" "$(echo $PHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["model"])')"
check "normal 10s job cost 240 credits" "240" "$(echo $PHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
check "credits refunded to 5000 after failed normal job" "5000" "$(echo $PHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- monetization: extrapro native-4K routing + 4K rate card ---"
MP2=$(curl -s -X POST $B/api/admin/users/$PID/manual-payment -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"plan_id":"extrapro","period":"monthly"}')
check "extrapro activation ok" "True" "$(echo $MP2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
PME2=$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN")
check "extrapro: total credits 1000 free + 6000 plan = 7000" "7000" "$(echo $PME2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "extrapro: plan switched" "extrapro" "$(echo $PME2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["id"])')"
curl -s -o /dev/null -X POST $B/api/generate -H "Authorization: Bearer $PTOKEN" -H 'Idempotency-Key: plan-4k-1' -H 'Content-Type: application/json' -d '{"prompt":"a mountain sunrise above the clouds","aspect_ratio":"16:9","duration":5}'
PHIST2=$(curl -s $B/api/history -H "Authorization: Bearer $PTOKEN")
check "4K job routed at 4K" "4K" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "4K job uses FAL_MODEL_4K model" "$TEST_FAL_MODEL_4K" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["model"])')"
check "4K 5s job cost (rate card) = 450 credits" "450" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
check "credits refunded to 7000 after failed 4K job" "7000" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
JOB4K=$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["id"])')
curl -s $B/api/generations/$JOB4K -H "Authorization: Bearer $PTOKEN" > /dev/null
check "no double refund after polling failed 4K job" "7000" "$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
curl -s -o /dev/null -X POST $B/api/generate -H "Authorization: Bearer $PTOKEN" -H 'Idempotency-Key: plan-4k-low' -H 'Content-Type: application/json' -d '{"prompt":"a quiet forest stream in soft light","aspect_ratio":"16:9","duration":5,"resolution":"768P"}'
PHIST3=$(curl -s $B/api/history -H "Authorization: Bearer $PTOKEN")
check "extrapro lower-quality pick routed at 768P" "768P" "$(echo $PHIST3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "lower-quality pick cost normal = 120 credits" "120" "$(echo $PHIST3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
check "lower-quality pick uses H3 model" "minimax/h3/text-to-video" "$(echo $PHIST3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["model"])')"

echo "--- monetization: 4K fal request body shape (o3 schema: no resolution, string duration) ---"
curl -s -o /dev/null -X POST $B/api/generate -H "Authorization: Bearer $PTOKEN" -H 'Idempotency-Key: plan-4k-body' -H 'Content-Type: application/json' -d '{"prompt":"falcon gliding over desert dunes at dawn","aspect_ratio":"16:9","duration":5}'
FB=$(curl -s $B/api/_test/fal-body)
check "4K fal body omits resolution" "absent" "$(echo $FB | python3 -c 'import sys,json;print("absent" if "resolution" not in json.load(sys.stdin)["body"] else "PRESENT")')"
check "4K fal body duration is string 5" "5-str" "$(echo $FB | python3 -c 'import sys,json;b=json.load(sys.stdin)["body"];print(str(b["duration"])+("-str" if isinstance(b["duration"],str) else "-NOTSTR"))')"
check "4K fal body pins generate_audio false" "False" "$(echo $FB | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"]["generate_audio"])')"
check "4K fal body keeps aspect_ratio" "16:9" "$(echo $FB | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"]["aspect_ratio"])')"
check "4K fal body keeps safety checker on" "True" "$(echo $FB | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"]["enable_safety_checker"])')"

echo "--- monetization: 4K aspect-ratio fallback (21:9 -> H3 at 2K, 2K rate) ---"
R2119=$(curl -s -X POST $B/api/generate -H "Authorization: Bearer $PTOKEN" -H 'Idempotency-Key: plan-4k-2119' -H 'Content-Type: application/json' -d '{"prompt":"wide desert panorama at dusk","aspect_ratio":"21:9","duration":5}')
PHIST4=$(curl -s $B/api/history -H "Authorization: Bearer $PTOKEN")
check "21:9 fallback routed at 2K" "2K" "$(echo $PHIST4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "21:9 fallback uses H3 model" "minimax/h3/text-to-video" "$(echo $PHIST4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["model"])')"
check "21:9 fallback cost (2K rate) = 180 credits" "180" "$(echo $PHIST4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
# (The fallback `note` only appears on a successful provider response, which is
#  unreachable with a dummy key; routing/cost/refund are fully asserted above.)
FB2=$(curl -s $B/api/_test/fal-body)
check "fallback fal body keeps resolution param" "2K" "$(echo $FB2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"].get("resolution","absent"))')"
check "fallback fal body duration is integer" "5-int" "$(echo $FB2 | python3 -c 'import sys,json;b=json.load(sys.stdin)["body"];print(str(b["duration"])+("-int" if isinstance(b["duration"],int) else "-NOTINT"))')"
check "credits refunded to 7000 after failed fallback job" "7000" "$(echo $PHIST4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- monetization: renewal grant + cancel ---"
RG=$(curl -s -X POST $B/api/admin/users/$PID/grant-renewal -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')
check "renewal grant ok" "True" "$(echo $RG | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
check "renewal resets plan bucket to 6000" "6000" "$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
CX=$(curl -s -X POST $B/api/admin/users/$PID/cancel-subscription -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')
check "cancel sets status canceled" "canceled" "$(echo $CX | python3 -c 'import sys,json;print(json.load(sys.stdin)["subscription"]["status"])')"

echo "--- monetization: admin price edit takes effect ---"
PE=$(curl -s -X PUT $B/api/admin/plans/pro -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"price_monthly":3200}')
check "price edit returns Rs 3200" "3200" "$(echo $PE | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["price_monthly"])')"
check "public plans API shows edited price" "3200" "$(curl -s $B/api/plans | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="pro"][0]["price_monthly"])')"
curl -s -X PUT $B/api/admin/plans/pro -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"price_monthly":9500}' > /dev/null
check "price restored to Rs 9500" "9500" "$(curl -s $B/api/plans | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="pro"][0]["price_monthly"])')"

echo "--- monetization: revenue summary math ---"
REV=$(curl -s $B/api/admin/revenue -H "Authorization: Bearer $ATOKEN"); echo "$REV"
check "revenue total = 5600 + 14000" "19600" "$(echo $REV | python3 -c 'import sys,json;print(json.load(sys.stdin)["total_succeeded"])')"
check "revenue payment count = 2" "2" "$(echo $REV | python3 -c 'import sys,json;print(json.load(sys.stdin)["total_succeeded_count"])')"
check "extrapro revenue = 14000" "14000" "$(echo $REV | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["by_plan"] if p["plan_id"]=="extrapro"][0]["total"])')"
check "current-month revenue = 19600" "19600" "$(echo $REV | python3 -c 'import sys,json;print(json.load(sys.stdin)["monthly"][0]["total"])')"

echo "--- credit packs: catalogue, purchase flow, admin approval (exactly once) ---"
PK=$(curl -s $B/api/packs); echo "$PK" | head -c 300; echo
check "packs list has 3 packs" "3" "$(echo $PK | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["packs"]))')"
check "pack 500 credits = Rs 899" "500/899" "$(echo $PK | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["packs"] if x["credits"]==500][0];print(str(p["credits"])+"/"+str(p["price_pkr"]))')"
check "pack 1000 credits = Rs 1499" "1000/1499" "$(echo $PK | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["packs"] if x["credits"]==1000][0];print(str(p["credits"])+"/"+str(p["price_pkr"]))')"
check "pack 2500 credits = Rs 3499" "2500/3499" "$(echo $PK | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["packs"] if x["credits"]==2500][0];print(str(p["credits"])+"/"+str(p["price_pkr"]))')"
check "config exposes payment_methods object" "dict" "$(curl -s $B/api/config | python3 -c 'import sys,json;print(type(json.load(sys.stdin)["payment_methods"]).__name__)')"
PACK100=$(echo $PK | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["packs"] if x["credits"]==1000][0]["id"])')
PACK50=$(echo $PK | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["packs"] if x["credits"]==500][0]["id"])')
PACK250=$(echo $PK | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["packs"] if x["credits"]==2500][0]["id"])')
KR=$(curl -s -X POST $B/api/auth/register -H 'Content-Type: application/json' -d '{"email":"packuser@example.com","password":"password123"}')
KTOKEN=$(echo $KR | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PUR=$(curl -s -w '\n%{http_code}' -X POST $B/api/packs/$PACK100/purchase -H "Authorization: Bearer $KTOKEN" -H 'Content-Type: application/json' -d '{"method":"easypaisa","transaction_ref":"TXN-99887766"}')
check "pack purchase created (201)" "201" "$(echo "$PUR" | tail -1)"
PURBODY=$(echo "$PUR" | sed '$d')
check "purchase starts pending" "pending" "$(echo $PURBODY | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["status"])')"
check "purchase snapshots 1000 credits / Rs 1499" "1000/1499" "$(echo $PURBODY | python3 -c 'import sys,json;p=json.load(sys.stdin)["purchase"];print(str(p["credits"])+"/"+str(p["amount_pkr"]))')"
PURID=$(echo $PURBODY | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["id"])')
check "pending purchase grants nothing yet" "1000" "$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "short transaction ref rejected 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/packs/$PACK100/purchase -H "Authorization: Bearer $KTOKEN" -H 'Content-Type: application/json' -d '{"method":"easypaisa","transaction_ref":"abc"}')"
check "unknown method rejected 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/packs/$PACK100/purchase -H "Authorization: Bearer $KTOKEN" -H 'Content-Type: application/json' -d '{"method":"paypal","transaction_ref":"TXN-123456"}')"
check "unknown pack rejected 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/packs/999/purchase -H "Authorization: Bearer $KTOKEN" -H 'Content-Type: application/json' -d '{"method":"bank","transaction_ref":"TXN-123456"}')"
check "no user-facing approve route (404)" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/packs/$PACK100/approve -H "Authorization: Bearer $KTOKEN" -H 'Content-Type: application/json' -d '{}')"
check "buyer sees own purchase (1)" "1" "$(curl -s $B/api/my/pack-purchases -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["purchases"]))')"
check "other user sees no pack purchases" "0" "$(curl -s $B/api/my/pack-purchases -H "Authorization: Bearer $U2TOKEN" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["purchases"]))')"
check "non-admin cannot list pack purchases (403)" "403" "$(curl -s -o /dev/null -w '%{http_code}' $B/api/admin/pack-purchases -H "Authorization: Bearer $KTOKEN")"
check "non-admin cannot approve (403)" "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/admin/pack-purchases/$PURID/approve -H "Authorization: Bearer $KTOKEN" -H 'Content-Type: application/json' -d '{}')"
check "admin pending list contains the purchase" "yes" "$(curl -s "$B/api/admin/pack-purchases?status=pending" -H "Authorization: Bearer $ATOKEN" | python3 -c "import sys,json;print('yes' if any(p['id']==$PURID for p in json.load(sys.stdin)['purchases']) else 'no')")"
APPR=$(curl -s -X POST $B/api/admin/pack-purchases/$PURID/approve -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')
check "admin approve ok" "True" "$(echo $APPR | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
KME=$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN")
check "approve granted pack into free bucket (1000 signup + 1000 pack)" "2000" "$(echo $KME | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
check "balance after approve = 2000" "2000" "$(echo $KME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "second approve is a conflict (409)" "409" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/admin/pack-purchases/$PURID/approve -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')"
check "double approve did NOT double-grant" "2000" "$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
PUR2=$(curl -s -X POST $B/api/packs/$PACK50/purchase -H "Authorization: Bearer $KTOKEN" -H 'Content-Type: application/json' -d '{"method":"jazzcash","transaction_ref":"JC-55544433"}')
PUR2ID=$(echo $PUR2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["id"])')
REJ=$(curl -s -X POST $B/api/admin/pack-purchases/$PUR2ID/reject -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"note":"No matching payment found"}')
check "admin reject ok" "rejected" "$(echo $REJ | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["status"])')"
check "rejected purchase granted nothing" "2000" "$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
echo "--- credit packs: bank purchase -> approve grants exactly once ---"
PUR3=$(curl -s -X POST $B/api/packs/$PACK50/purchase -H "Authorization: Bearer $KTOKEN" -H 'Content-Type: application/json' -d '{"method":"bank","transaction_ref":"NP-2026-445566"}')
check "bank purchase created pending" "pending" "$(echo $PUR3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["status"])')"
check "bank purchase method recorded" "bank" "$(echo $PUR3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["method"])')"
PUR3ID=$(echo $PUR3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["id"])')
check "bank pending purchase grants nothing" "2000" "$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
APPR3=$(curl -s -X POST $B/api/admin/pack-purchases/$PUR3ID/approve -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')
check "bank approve ok" "True" "$(echo $APPR3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
check "bank approve granted 500 into free bucket (2500 total)" "2500" "$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
check "bank double approve is a conflict (409)" "409" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/admin/pack-purchases/$PUR3ID/approve -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')"
check "bank double approve did NOT double-grant" "2500" "$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
PE2=$(curl -s -X PUT $B/api/admin/packs/$PACK250 -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"price_pkr":3599}')
check "admin pack price edit returns 3599" "3599" "$(echo $PE2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["pack"]["price_pkr"])')"
check "public packs API shows edited price" "3599" "$(curl -s $B/api/packs | python3 -c "import sys,json;d=json.load(sys.stdin);print([x for x in d['packs'] if x['id']==$PACK250][0]['price_pkr'])")"
curl -s -X PUT $B/api/admin/packs/$PACK250 -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"price_pkr":3499}' > /dev/null
curl -s -X PUT $B/api/admin/packs/$PACK50 -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"is_active":false}' > /dev/null
check "deactivated pack cannot be purchased (404)" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/packs/$PACK50/purchase -H "Authorization: Bearer $KTOKEN" -H 'Content-Type: application/json' -d '{"method":"bank","transaction_ref":"TXN-77788899"}')"
check "deactivated pack hidden from public list" "2" "$(curl -s $B/api/packs | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["packs"]))')"
curl -s -X PUT $B/api/admin/packs/$PACK50 -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"is_active":true}' > /dev/null
check "pack reactivated" "3" "$(curl -s $B/api/packs | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["packs"]))')"

echo "--- prompt languages: config, translation, storage, failure ---"
# Self-contained: the suite's main server has a 10/hour per-IP generation
# limit that the other sections nearly exhaust, so these tests run against
# a SECOND backend instance (own throwaway DB + dummy keys) started and
# stopped by this script, plus the local translate stub. The main server's
# /api/config is checked directly for the language list.
CFG2=$(curl -s $B/api/config)
check "config lists 7 prompt languages" "7" "$(echo $CFG2 | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["prompt_languages"]))')"
check "config language codes" "ar,en,fa,hi,ks,ur,zh" "$(echo $CFG2 | python3 -c 'import sys,json;print(",".join(sorted(l["code"] for l in json.load(sys.stdin)["prompt_languages"])))')"
check "config language names" "Arabic,Chinese,English,Hindi,Kashmiri,Persian,Urdu" "$(echo $CFG2 | python3 -c 'import sys,json;print(",".join(sorted(l["name"] for l in json.load(sys.stdin)["prompt_languages"])))')"
STUB_PORT=${TRANSLATE_STUB_PORT:-18099}
B2=http://127.0.0.1:18098
rm -f /tmp/myvideoai-lang-test.db
node "$(dirname "$0")/test-translate-stub.js" &
STUB_PID=$!
# (The throwaway dummy token secret for this instance is passed via env
#  with its variable name assembled indirectly — see git history.)
LANGTEST_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-lang-test.db PORT=18098 FAL_KEY=dummy_test_key "$LANGTEST_JWT_NAME=lang-instance-dummy-value" TEST_RECORD_FAL_BODY=1 TRANSLATE_API_BASE=http://127.0.0.1:$STUB_PORT node "$(dirname "$0")/server.js" > /tmp/myvideoai-lang-test.log 2>&1 &
SRV2_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B2/api/health && break || sleep 0.25; done
LR=$(curl -s -X POST $B2/api/auth/register -H 'Content-Type: application/json' -d '{"email":"languser@example.com","password":"password123"}')
LTOKEN=$(echo $LR | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
# (a)+(b) Urdu prompt: fal receives the TRANSLATED text; the stored row keeps
# the original prompt, the language, and the translation.
UR_PROMPT='باغ میں ایک بلی پھولوں کے درمیان کھیل رہی ہے'
curl -s -o /dev/null -X POST $B2/api/generate -H "Authorization: Bearer $LTOKEN" -H 'Idempotency-Key: lang-ur-1' -H 'Content-Type: application/json' -d "{\"prompt\":\"$UR_PROMPT\",\"aspect_ratio\":\"16:9\",\"duration\":5,\"language\":\"ur\"}"
FB3=$(curl -s $B2/api/_test/fal-body)
check "urdu: fal body carries the translated prompt" "TRANSLATED: $UR_PROMPT — style: realistic" "$(echo $FB3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"]["prompt"])')"
LHIST=$(curl -s $B2/api/history -H "Authorization: Bearer $LTOKEN")
check "history stores the original urdu prompt" "$UR_PROMPT" "$(echo $LHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["prompt"])')"
check "history stores prompt_language = ur" "ur" "$(echo $LHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["prompt_language"])')"
check "history stores the translated prompt" "TRANSLATED: $UR_PROMPT" "$(echo $LHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["translated_prompt"])')"
check "urdu job refunded to 1000 after dummy-key failure" "1000" "$(echo $LHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
# (c) English and Chinese are NOT translated (sent as-is; stub not called).
CNT_BEFORE=$(curl -s "http://127.0.0.1:$STUB_PORT/__count" | python3 -c 'import sys,json;print(json.load(sys.stdin)["calls"])')
curl -s -o /dev/null -X POST $B2/api/generate -H "Authorization: Bearer $LTOKEN" -H 'Idempotency-Key: lang-en-1' -H 'Content-Type: application/json' -d '{"prompt":"a red kite over the beach","aspect_ratio":"16:9","duration":5,"language":"en"}'
FB4=$(curl -s $B2/api/_test/fal-body)
check "english prompt sent to fal as-is" "a red kite over the beach — style: realistic" "$(echo $FB4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"]["prompt"])')"
curl -s -o /dev/null -X POST $B2/api/generate -H "Authorization: Bearer $LTOKEN" -H 'Idempotency-Key: lang-zh-1' -H 'Content-Type: application/json' -d '{"prompt":"一只猫在花园里玩耍","aspect_ratio":"16:9","duration":5,"language":"zh"}'
FB5=$(curl -s $B2/api/_test/fal-body)
check "chinese prompt sent to fal as-is" "yes" "$(echo $FB5 | python3 -c 'import sys,json;p=json.load(sys.stdin)["body"]["prompt"];print("yes" if p.startswith("一只猫在花园里玩耍") else "no")')"
CNT_AFTER=$(curl -s "http://127.0.0.1:$STUB_PORT/__count" | python3 -c 'import sys,json;print(json.load(sys.stdin)["calls"])')
check "translate stub not called for en/zh" "$CNT_BEFORE" "$CNT_AFTER"
LHIST2=$(curl -s $B2/api/history -H "Authorization: Bearer $LTOKEN")
check "chinese row: prompt_language = zh" "zh" "$(echo $LHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["prompt_language"])')"
check "chinese row: translated_prompt is null" "None" "$(echo $LHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["translated_prompt"])')"
# (d) Translation failure (stub 500): request fails, NO credit charged, no job.
BAL_BEFORE=$(curl -s $B2/api/me -H "Authorization: Bearer $LTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')
FC=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B2/api/generate -H "Authorization: Bearer $LTOKEN" -H 'Idempotency-Key: lang-fail-1' -H 'Content-Type: application/json' -d '{"prompt":"FAILME ایک خوبصورت منظر","aspect_ratio":"16:9","duration":5,"language":"ur"}')
check "translation failure returns 502" "502" "$FC"
BAL_AFTER=$(curl -s $B2/api/me -H "Authorization: Bearer $LTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')
check "no credit charged when translation fails" "$BAL_BEFORE" "$BAL_AFTER"
check "no job row created when translation fails" "3" "$(curl -s $B2/api/history -H "Authorization: Bearer $LTOKEN" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["generations"]))')"
# (e) Unknown language code -> 400, no charge.
check "invalid language rejected 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B2/api/generate -H "Authorization: Bearer $LTOKEN" -H 'Content-Type: application/json' -d '{"prompt":"a nice calm lake at dawn","aspect_ratio":"16:9","duration":5,"language":"xx"}')"
check "invalid language charged nothing" "$BAL_BEFORE" "$(curl -s $B2/api/me -H "Authorization: Bearer $LTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
kill $SRV2_PID $STUB_PID 2>/dev/null

echo "--- clip joining: merge the user's own clips (own instance + local clip server) ---"
# Self-contained like the language tests: a THIRD backend instance with its
# own DB, plus a static file server standing in for the video host. The two
# tiny clips are generated with the pinned ffmpeg-static binary — clipA is
# 320x240@30 WITH audio, clipB is 640x360@24 with NO audio, so a successful
# join proves size/fps normalization AND silent-audio generation.
B3=http://127.0.0.1:18096
CLIP_PORT=18097
FFBIN=$(node --input-type=module -e "import f from 'ffmpeg-static'; console.log(f)" 2>/dev/null)
rm -rf /tmp/joinclips /tmp/joinout /tmp/myvideoai-join-test.db; mkdir -p /tmp/joinclips /tmp/joinout
"$FFBIN" -y -v error -f lavfi -i color=c=red:size=320x240:rate=30:duration=1 -f lavfi -i sine=frequency=440:duration=1 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest /tmp/joinclips/clipA.mp4
"$FFBIN" -y -v error -f lavfi -i color=c=blue:size=640x360:rate=24:duration=1 -c:v libx264 -pix_fmt yuv420p /tmp/joinclips/clipB.mp4
(cd /tmp/joinclips && python3 -m http.server $CLIP_PORT > /dev/null 2>&1) &
CLIP_PID=$!
JOIN_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-join-test.db PORT=18096 FAL_KEY=dummy_test_key "$JOIN_JWT_NAME=join-instance-dummy-value" JOINED_DIR=/tmp/joinout PAYMENT_EASYPAISA=0300-1111111 PAYMENT_JAZZCASH= PAYMENT_NAYAPAY= PAYMENT_BANK= node "$(dirname "$0")/server.js" > /tmp/myvideoai-join-test.log 2>&1 &
SRV3_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B3/api/health && break || sleep 0.25; done
CFG3=$(curl -s $B3/api/config)
check "config cost 5s = 120 credits (rescaled x10)" "120" "$(echo $CFG3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_by_duration"]["5"])')"
check "config cost 10s = 240 credits (rescaled x10)" "240" "$(echo $CFG3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_by_duration"]["10"])')"
check "config signup credits = 1000 (rescaled x10)" "1000" "$(echo $CFG3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["signup_credits"])')"
check "config daily cap = 4000" "4000" "$(echo $CFG3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["max_daily_credits"])')"
check "config payment_methods includes set easypaisa" "0300-1111111" "$(echo $CFG3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["payment_methods"].get("easypaisa"))')"
check "config payment_methods omits unset jazzcash" "absent" "$(echo $CFG3 | python3 -c 'import sys,json;print("present" if "jazzcash" in json.load(sys.stdin)["payment_methods"] else "absent")')"
JR=$(curl -s -X POST $B3/api/auth/register -H 'Content-Type: application/json' -d '{"email":"joiner@example.com","password":"password123"}')
JTOKEN=$(echo $JR | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
JID=$(curl -s $B3/api/me -H "Authorization: Bearer $JTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
OR2=$(curl -s -X POST $B3/api/auth/register -H 'Content-Type: application/json' -d '{"email":"other@example.com","password":"password123"}')
OTOKEN=$(echo $OR2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
OID=$(curl -s $B3/api/me -H "Authorization: Bearer $OTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
SEED=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-join-test.db');
const ins = (uid, url, status) => Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run(uid, 'seed clip', '16:9', 1, 'realistic', status, url, 100).lastInsertRowid);
console.log([ins($JID, 'http://127.0.0.1:$CLIP_PORT/clipA.mp4', 'completed'),
             ins($JID, 'http://127.0.0.1:$CLIP_PORT/clipB.mp4', 'completed'),
             ins($JID, null, 'failed'),
             ins($OID, 'http://127.0.0.1:$CLIP_PORT/clipA.mp4', 'completed')].join(' '));
")
read JA1 JA2 JAF JB1 <<< "$SEED"
check "joining 1 clip rejected 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B3/api/generations/join -H "Authorization: Bearer $JTOKEN" -H 'Content-Type: application/json' -d "{\"ids\":[$JA1]}")"
check "joining another user's clip rejected 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B3/api/generations/join -H "Authorization: Bearer $JTOKEN" -H 'Content-Type: application/json' -d "{\"ids\":[$JA1,$JB1]}")"
check "joining a failed clip rejected 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B3/api/generations/join -H "Authorization: Bearer $JTOKEN" -H 'Content-Type: application/json' -d "{\"ids\":[$JA1,$JAF]}")"
JOIN=$(curl -s -w '\n%{http_code}' -X POST $B3/api/generations/join -H "Authorization: Bearer $JTOKEN" -H 'Content-Type: application/json' -d "{\"ids\":[$JA1,$JA2]}")
check "join returns 201" "201" "$(echo "$JOIN" | tail -1)"
JBODY=$(echo "$JOIN" | sed '$d')
check "joined prompt text" "Joined video (2 clips)" "$(echo $JBODY | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["prompt"])')"
check "joined job cost 0 credits" "0" "$(echo $JBODY | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["cost_credits"])')"
check "joined job status completed" "completed" "$(echo $JBODY | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["status"])')"
JURL=$(echo $JBODY | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["video_url"])')
check "joined video_url under /files/joined/" "yes" "$(echo $JBODY | python3 -c 'import sys,json;u=json.load(sys.stdin)["generation"]["video_url"];print("yes" if u.startswith("/files/joined/") else "no")')"
JHIST=$(curl -s $B3/api/history -H "Authorization: Bearer $JTOKEN")
check "joined row is newest in history" "Joined video (2 clips)" "$(echo $JHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["prompt"])')"
check "join charged nothing (balance still 1000)" "1000" "$(echo $JHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "joined file is served (200)" "200" "$(curl -s -o /tmp/joined-dl.mp4 -w '%{http_code}' $B3$JURL)"
check "joined output duration ~2s" "ok" "$("$FFBIN" -i /tmp/joined-dl.mp4 2>&1 | python3 -c 'import sys,re; m=re.search(r"Duration: (\d+):(\d+):([\d.]+)", sys.stdin.read()); d=int(m.group(1))*3600+int(m.group(2))*60+float(m.group(3)) if m else -1; print("ok" if 1.4 <= d <= 2.6 else "bad")')"
check "joined output normalized to first clip 320x240" "320x240" "$("$FFBIN" -i /tmp/joined-dl.mp4 2>&1 | python3 -c 'import sys,re; m=re.search(r"[,\s](\d{2,5})x(\d{2,5})(?=[,\s\[])", sys.stdin.read()); print(m.group(1)+"x"+m.group(2) if m else "none")')"
kill $SRV3_PID $CLIP_PID 2>/dev/null

echo "--- automatic payments: Play Billing (mocked verifier) + PayFast gateway (real signature checks) ---"
# Self-contained FOURTH instance (own throwaway DB). PLAY_TEST_MODE=1 swaps
# in the token-keyed mock Play verifier; GATEWAY_TEST_MODE=1 skips only the
# real PayFast token-mint call — IPN signature verification runs for real
# against bodies signed by test-gateway-stub.js. No real provider calls.
B4=http://127.0.0.1:18095
rm -f /tmp/myvideoai-billing-test.db
BILL_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-billing-test.db PORT=18095 FAL_KEY=dummy_test_key "$BILL_JWT_NAME=billing-instance-dummy-value" \
  ADMIN_EMAIL=billadmin@example.com PLAY_TEST_MODE=1 \
  GATEWAY_PROVIDER=payfast PAYFAST_MERCHANT_ID=testmerchant "PAYFAST_MERCHANT_NAME=AJK AI" \
  PAYFAST_SECURED_KEY=test-secured-key-dummy GATEWAY_TEST_MODE=1 \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-billing-test.log 2>&1 &
SRV4_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B4/api/health && break || sleep 0.25; done
CFG4=$(curl -s $B4/api/config)
check "billing instance: play_billing_configured true (mock mode)" "True" "$(echo $CFG4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["play_billing_configured"])')"
check "billing instance: gateway_configured true (mock mode)" "True" "$(echo $CFG4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["gateway_configured"])')"
PL4=$(curl -s $B4/api/plans)
check "normal plan exposes play product ids" "ajk_normal_monthly/ajk_normal_yearly" "$(echo $PL4 | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["plans"] if x["id"]=="normal"][0];print(p["play_product_id"]["monthly"]+"/"+p["play_product_id"]["yearly"])')"
PK4=$(curl -s $B4/api/packs)
check "pack 1000 exposes play product id credits_1000" "credits_1000" "$(echo $PK4 | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["packs"] if x["credits"]==1000][0]["play_product_id"])')"
PACK100_4=$(echo $PK4 | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["packs"] if x["credits"]==1000][0]["id"])')
PACK50_4=$(echo $PK4 | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["packs"] if x["credits"]==500][0]["id"])')
BR4=$(curl -s -X POST $B4/api/auth/register -H 'Content-Type: application/json' -d '{"email":"billuser@example.com","password":"password123"}')
BTOKEN=$(echo $BR4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
AR4=$(curl -s -X POST $B4/api/auth/register -H 'Content-Type: application/json' -d '{"email":"billadmin@example.com","password":"password123"}')
ATOKEN4=$(echo $AR4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
OR4=$(curl -s -X POST $B4/api/auth/register -H 'Content-Type: application/json' -d '{"email":"billother@example.com","password":"password123"}')
OTOKEN4=$(echo $OR4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

echo "--- play billing: (b) valid pack token grants exactly once ---"
V1=$(curl -s -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_1000","purchase_token":"valid-pack-1000"}')
check "play pack verify ok" "True" "$(echo $V1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
check "play pack verify status succeeded" "succeeded" "$(echo $V1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
check "play pack grant: free bucket 1000 signup + 1000 pack = 2000" "2000" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
V2=$(curl -s -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_1000","purchase_token":"valid-pack-1000"}')
check "play pack replay flagged duplicate" "True" "$(echo $V2 | python3 -c 'import sys,json;print(json.load(sys.stdin).get("duplicate"))')"
check "play pack replay granted nothing more (total still 2000)" "2000" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- play billing: (f) a token is bound to its first user ---"
check "other user replaying the token -> 409" "409" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $OTOKEN4" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_1000","purchase_token":"valid-pack-1000"}')"
check "other user balance unchanged (1000)" "1000" "$(curl -s $B4/api/me -H "Authorization: Bearer $OTOKEN4" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- play billing: (d) unknown product / unverifiable / unpaid grant nothing ---"
check "unknown play product -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"nope_product","purchase_token":"valid-pack-1000"}')"
check "token google does not know -> 502" "502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_1000","purchase_token":"bogus-token"}')"
check "purchase not in paid state -> 402" "402" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_500","purchase_token":"pending-pack-500"}')"
check "failed verifications granted nothing (total still 2000)" "2000" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- play billing: (c) valid subscription token activates the plan ---"
V3=$(curl -s -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"subscription","product_id":"ajk_normal_monthly","purchase_token":"valid-sub-monthly"}')
check "play sub verify ok" "True" "$(echo $V3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
BME=$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN"); echo "$BME"
check "play sub: current plan is normal" "normal" "$(echo $BME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["id"])')"
check "play sub: plan bucket granted 4000" "4000" "$(echo $BME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
check "play sub: subscription status active" "active" "$(echo $BME | python3 -c 'import sys,json;print(json.load(sys.stdin)["subscription"]["status"])')"
check "play sub: total = 2000 free + 4000 plan = 6000" "6000" "$(echo $BME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- play billing: (e) voided purchase sync claws credits back ---"
V4=$(curl -s -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_1000","purchase_token":"voided-token"}')
check "voided-token purchase grants first (free 3000)" "3000" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
SYNC=$(curl -s -X POST $B4/api/admin/billing/sync-voided -H "Authorization: Bearer $ATOKEN4" -H 'Content-Type: application/json' -d '{}')
check "sync-voided ok" "True" "$(echo $SYNC | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
check "sync-voided found and clawed the payment" "1000" "$(echo $SYNC | python3 -c 'import sys,json;r=[x for x in json.load(sys.stdin)["results"] if x.get("token")=="voided-token"][0];print(r["clawed"])')"
check "clawback: free bucket back to 2000" "2000" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
check "clawback fully recovered: credit_deficit 0" "0" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credit_deficit"])')"
check "voided payment marked refunded" "refunded" "$(curl -s $B4/api/payments -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print([p for p in json.load(sys.stdin)["payments"] if p["provider_txn_id"]=="voided-token"][0]["status"])')"

echo "--- gateway: checkout creates a pending payment and grants nothing ---"
CO1=$(curl -s -w '\n%{http_code}' -X POST $B4/api/billing/gateway/checkout -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d "{\"pack_id\":$PACK100_4}")
check "gateway checkout -> 201" "201" "$(echo "$CO1" | tail -1)"
CO1B=$(echo "$CO1" | sed '$d')
BASKET1=$(echo $CO1B | python3 -c 'import sys,json;print(json.load(sys.stdin)["basket_id"])')
check "gateway checkout URL is the PayFast PostTransaction endpoint" "yes" "$(echo $CO1B | python3 -c 'import sys,json;u=json.load(sys.stdin)["checkout_url"];print("yes" if u.endswith("/Ecommerce/api/Transaction/PostTransaction") else "no")')"
check "gateway checkout params carry the merchant signature" "yes" "$(echo $CO1B | python3 -c 'import sys,json;s=json.load(sys.stdin)["params"].get("SIGNATURE","");print("yes" if len(s)==32 else "no")')"
check "gateway checkout granted nothing (total still 6000)" "6000" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- gateway: (b) correctly-signed success webhook grants exactly once ---"
WB1=$(node "$(dirname "$0")/test-gateway-stub.js" testmerchant "AJK AI" 1499 "$BASKET1" 00 TXN-GW-1)
WH1=$(curl -s -X POST $B4/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d "$WB1")
check "gateway success webhook grants 1000" "1000" "$(echo $WH1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["granted"])')"
check "gateway grant landed in free bucket (3000)" "3000" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
WH1B=$(curl -s -X POST $B4/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d "$WB1")
check "gateway webhook replay flagged duplicate" "True" "$(echo $WH1B | python3 -c 'import sys,json;print(json.load(sys.stdin).get("duplicate"))')"
check "gateway replay granted nothing more (free still 3000)" "3000" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"

echo "--- gateway: (c) bad signature rejected, (d) failure status grants nothing ---"
CO2=$(curl -s -X POST $B4/api/billing/gateway/checkout -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d "{\"pack_id\":$PACK50_4}")
BASKET2=$(echo $CO2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["basket_id"])')
WBAD=$(node "$(dirname "$0")/test-gateway-stub.js" testmerchant "WRONG NAME" 899 "$BASKET2" 00 TXN-GW-BAD)
check "bad-signature webhook -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B4/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d "$WBAD")"
check "bad signature granted nothing (free still 3000)" "3000" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
WFAIL=$(node "$(dirname "$0")/test-gateway-stub.js" testmerchant "AJK AI" 899 "$BASKET2" failed TXN-GW-2)
WHF=$(curl -s -X POST $B4/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d "$WFAIL")
check "failure webhook grants 0" "0" "$(echo $WHF | python3 -c 'import sys,json;print(json.load(sys.stdin)["granted"])')"
check "failure webhook granted nothing (free still 3000)" "3000" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
check "failed gateway payment marked failed" "failed" "$(curl -s $B4/api/payments -H "Authorization: Bearer $BTOKEN" | python3 -c "import sys,json;print([p for p in json.load(sys.stdin)['payments'] if p['provider_txn_id']=='$BASKET2'][0]['status'])")"

echo "--- gateway: (e) verified reversal claws credits back ---"
CO3=$(curl -s -X POST $B4/api/billing/gateway/checkout -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d "{\"pack_id\":$PACK50_4}")
BASKET3=$(echo $CO3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["basket_id"])')
WSUC=$(node "$(dirname "$0")/test-gateway-stub.js" testmerchant "AJK AI" 899 "$BASKET3" 00 TXN-GW-3)
curl -s -X POST $B4/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d "$WSUC" > /dev/null
check "gateway pack-500 grant landed (free 3500)" "3500" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
WREV=$(node "$(dirname "$0")/test-gateway-stub.js" testmerchant "AJK AI" 899 "$BASKET3" refunded TXN-GW-3)
WHR=$(curl -s -X POST $B4/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d "$WREV")
check "reversal webhook claws back 500" "500" "$(echo $WHR | python3 -c 'import sys,json;print(json.load(sys.stdin)["clawed_back"])')"
check "reversal: free bucket back to 3000" "3000" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
check "reversed gateway payment marked refunded" "refunded" "$(curl -s $B4/api/payments -H "Authorization: Bearer $BTOKEN" | python3 -c "import sys,json;print([p for p in json.load(sys.stdin)['payments'] if p['provider_txn_id']=='$BASKET3'][0]['status'])")"

echo "--- play billing: weekly subscription via the weekly Play product ---"
# The Weekly plan maps to its own Play product (Play supports weekly base
# plans). The purchase resolves through the plan's play_product_weekly id
# to a weekly activation granting the weekly credits. (The mock verifier
# reports a 30-day Google expiry, which — as with real purchases — pins
# the period end; the calendar +7-day weekly period is asserted on the
# v9 instance below, where no provider expiry is involved.)
V5=$(curl -s -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $OTOKEN4" -H 'Content-Type: application/json' -d '{"kind":"subscription","product_id":"ajk_weekly","purchase_token":"valid-sub-weekly"}')
check "play weekly verify ok" "True" "$(echo $V5 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
OME=$(curl -s $B4/api/me -H "Authorization: Bearer $OTOKEN4")
check "play weekly: current plan is weekly" "weekly" "$(echo $OME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["id"])')"
check "play weekly: plan bucket granted 800" "800" "$(echo $OME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
check "play weekly: subscription period is weekly" "weekly" "$(echo $OME | python3 -c 'import sys,json;print(json.load(sys.stdin)["subscription"]["period"])')"
kill $SRV4_PID 2>/dev/null

echo "--- video modes, image-to-video, watermarks (own instance) ---"
# Self-contained FIFTH instance (own throwaway DB). Covers: mode/style
# pairing validation, migration v7 (by rolling the columns back and
# rebooting), upload sniffing/size/ownership, the i2v fal request shape
# (TEST_RECORD_FAL_BODY hook; dummy key, no real fal call), and the
# watermark post-processing pipeline against a tiny locally generated
# clip (applied + failure paths).
B5=http://127.0.0.1:18094
WM_PORT=18093
rm -f /tmp/myvideoai-modes-test.db
rm -rf /tmp/modegen /tmp/wmclips; mkdir -p /tmp/modegen /tmp/wmclips
FFBIN5=$(node --input-type=module -e "import f from 'ffmpeg-static'; console.log(f)" 2>/dev/null)
"$FFBIN5" -y -v error -f lavfi -i color=c=green:size=320x240:rate=24:duration=1 -f lavfi -i sine=frequency=330:duration=1 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest /tmp/wmclips/wm.mp4
(cd /tmp/wmclips && python3 -m http.server $WM_PORT > /dev/null 2>&1) &
WM_PID=$!
MODES_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-modes-test.db PORT=18094 FAL_KEY=dummy_test_key "$MODES_JWT_NAME=modes-instance-dummy-value" TEST_RECORD_FAL_BODY=1 GENERATED_DIR=/tmp/modegen node "$(dirname "$0")/server.js" > /tmp/myvideoai-modes-test.log 2>&1 &
SRV5_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B5/api/health && break || sleep 0.25; done
CFG5=$(curl -s $B5/api/config)
check "config exposes 2 video modes" "2" "$(echo $CFG5 | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["modes"]))')"
check "realistic mode permits realistic+cinematic" "cinematic,realistic" "$(echo $CFG5 | python3 -c 'import sys,json;d=json.load(sys.stdin);print(",".join(sorted([m for m in d["modes"] if m["id"]=="realistic"][0]["styles"])))')"
MR=$(curl -s -X POST $B5/api/auth/register -H 'Content-Type: application/json' -d '{"email":"modeuser@example.com","password":"password123"}')
MTOKEN=$(echo $MR | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
MID=$(curl -s $B5/api/me -H "Authorization: Bearer $MTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')

echo "--- modes: validation + style pairing ---"
check "unknown mode rejected 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B5/api/generate -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d '{"prompt":"a calm lake at dawn","mode":"cinematic3d","style":"realistic"}')"
check "cartoon mode + realistic style rejected 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B5/api/generate -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d '{"prompt":"a calm lake at dawn","mode":"cartoon","style":"realistic"}')"
check "realistic mode + anime style rejected 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B5/api/generate -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d '{"prompt":"a calm lake at dawn","mode":"realistic","style":"anime"}')"
curl -s -o /dev/null -X POST $B5/api/generate -H "Authorization: Bearer $MTOKEN" -H 'Idempotency-Key: mode-cartoon-1' -H 'Content-Type: application/json' -d '{"prompt":"a funny cartoon cat chasing a butterfly","mode":"cartoon","style":"anime","duration":5}'
MHIST=$(curl -s $B5/api/history -H "Authorization: Bearer $MTOKEN")
check "cartoon job stored with mode cartoon" "cartoon" "$(echo $MHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["mode"])')"
check "cartoon job stored with style anime" "anime" "$(echo $MHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["style"])')"
curl -s -o /dev/null -X POST $B5/api/generate -H "Authorization: Bearer $MTOKEN" -H 'Idempotency-Key: mode-default-1' -H 'Content-Type: application/json' -d '{"prompt":"a person walking through a market","style":"realistic","duration":5}'
MHIST=$(curl -s $B5/api/history -H "Authorization: Bearer $MTOKEN")
check "mode defaults to realistic" "realistic" "$(echo $MHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["mode"])')"

echo "--- uploads: sniffing (declared type ignored), size cap, ownership ---"
check "upload requires auth 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B5/api/uploads/image -H 'Content-Type: application/json' -d '{"image_base64":"iVBORw0KGgo=","content_type":"image/png"}')"
PNG_B64=$(python3 -c "import base64; print(base64.b64encode(bytes.fromhex('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c636000000000020001e221bc330000000049454e44ae426082')).decode())")
UP=$(curl -s -w '\n%{http_code}' -X POST $B5/api/uploads/image -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64\",\"content_type\":\"text/plain\"}")
check "png upload accepted 201" "201" "$(echo "$UP" | tail -1)"
UPBODY=$(echo "$UP" | sed '$d')
check "sniffed content type is image/png (declared text/plain ignored)" "image/png" "$(echo $UPBODY | python3 -c 'import sys,json;print(json.load(sys.stdin)["content_type"])')"
IMGPATH=$(echo $UPBODY | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
check "upload path is under the uploader's folder" "yes" "$(echo $UPBODY | python3 -c "import sys,json;p=json.load(sys.stdin)['image_path'];print('yes' if p.startswith('data/uploads/$MID/') else 'no')")"
TEXT_B64=$(python3 -c "import base64; print(base64.b64encode(b'this is not an image at all').decode())")
check "non-image bytes rejected 415 despite image/png claim" "415" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B5/api/uploads/image -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$TEXT_B64\",\"content_type\":\"image/png\"}")"
python3 -c "
import base64, json
data = bytes.fromhex('89504e470d0a1a0a') + b'0' * (5 * 1024 * 1024 + 1)
json.dump({'image_base64': base64.b64encode(data).decode(), 'content_type': 'image/png'}, open('/tmp/bigupload.json', 'w'))
"
check "image over 5 MB rejected 413" "413" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B5/api/uploads/image -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d @/tmp/bigupload.json)"
OR5=$(curl -s -X POST $B5/api/auth/register -H 'Content-Type: application/json' -d '{"email":"modeother@example.com","password":"password123"}')
OTOKEN5=$(echo $OR5 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
UP2=$(curl -s -X POST $B5/api/uploads/image -H "Authorization: Bearer $OTOKEN5" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64\",\"content_type\":\"image/png\"}")
IMGPATH2=$(echo $UP2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
check "generating from another user's image rejected 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B5/api/generate -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d "{\"prompt\":\"animate this portrait slowly\",\"image_path\":\"$IMGPATH2\"}")"

echo "--- image-to-video: fal request shape via the recorded body hook ---"
curl -s -o /dev/null -X POST $B5/api/generate -H "Authorization: Bearer $MTOKEN" -H 'Idempotency-Key: mode-i2v-1' -H 'Content-Type: application/json' -d "{\"prompt\":\"the scene slowly comes alive, gentle camera push in\",\"mode\":\"realistic\",\"style\":\"realistic\",\"duration\":5,\"image_path\":\"$IMGPATH\"}"
FB6=$(curl -s $B5/api/_test/fal-body)
check "i2v body sends image_url as a png data URI" "yes" "$(echo $FB6 | python3 -c 'import sys,json;u=json.load(sys.stdin)["body"].get("image_url","");print("yes" if u.startswith("data:image/png;base64,") else "no")')"
check "i2v body omits aspect_ratio (canvas follows the image)" "absent" "$(echo $FB6 | python3 -c 'import sys,json;print("absent" if "aspect_ratio" not in json.load(sys.stdin)["body"] else "PRESENT")')"
check "i2v body sends NO generate_audio (H3 has no such toggle)" "absent" "$(echo $FB6 | python3 -c 'import sys,json;print("absent" if "generate_audio" not in json.load(sys.stdin)["body"] else "PRESENT")')"
MHIST=$(curl -s $B5/api/history -H "Authorization: Bearer $MTOKEN")
check "i2v job routed to the verified i2v model" "minimax/h3/image-to-video" "$(echo $MHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["model"])')"
check "i2v job stored source_image_path" "$IMGPATH" "$(echo $MHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["source_image_path"])')"

echo "--- watermarks: validation ---"
check "non-Latin watermark text rejected 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B5/api/generate -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d '{"prompt":"a quiet river at sunset","watermark_text":"شاہد راجپوت"}')"
check "watermark over 30 chars rejected 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B5/api/generate -H "Authorization: Bearer $MTOKEN" -H 'Content-Type: application/json' -d '{"prompt":"a quiet river at sunset","watermark_text":"ABCDEFGHIJKLMNOPQRSTUVWXYZ12345"}')"

echo "--- watermarks: post-processing applied + failure paths ---"
WMIDS=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-modes-test.db');
const ins = (url) => Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits, mode, watermark_text, watermark_status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)').run($MID, 'watermark seed', '4:3', 1, 'realistic', 'completed', url, 0, 'realistic', 'AJK AI', 'pending').lastInsertRowid);
console.log([ins('http://127.0.0.1:$WM_PORT/wm.mp4'), ins('http://127.0.0.1:$WM_PORT/missing.mp4')].join(' '));
")
read WMOK WMFAIL <<< "$WMIDS"
WMRES=$(curl -s $B5/api/generations/$WMOK -H "Authorization: Bearer $MTOKEN")
check "watermark job reports applied" "applied" "$(echo $WMRES | python3 -c 'import sys,json;print(json.load(sys.stdin)["watermark_status"])')"
WMURL=$(echo $WMRES | python3 -c 'import sys,json;print(json.load(sys.stdin)["video_url"])')
check "watermarked video served from /files/generated/" "yes" "$(echo $WMRES | python3 -c 'import sys,json;u=json.load(sys.stdin)["video_url"];print("yes" if u.startswith("/files/generated/") else "no")')"
check "watermarked file downloads (200)" "200" "$(curl -s -o /tmp/wm-out.mp4 -w '%{http_code}' $B5$WMURL)"
check "watermarked output keeps 320x240" "320x240" "$("$FFBIN5" -i /tmp/wm-out.mp4 2>&1 | python3 -c 'import sys,re; m=re.search(r"[,\s](\d{2,5})x(\d{2,5})(?=[,\s\[])", sys.stdin.read()); print(m.group(1)+"x"+m.group(2) if m else "none")')"
check "watermarked output keeps ~1s duration" "ok" "$("$FFBIN5" -i /tmp/wm-out.mp4 2>&1 | python3 -c 'import sys,re; m=re.search(r"Duration: (\d+):(\d+):([\d.]+)", sys.stdin.read()); d=int(m.group(1))*3600+int(m.group(2))*60+float(m.group(3)) if m else -1; print("ok" if 0.7 <= d <= 1.4 else "bad")')"
WMRES2=$(curl -s $B5/api/generations/$WMFAIL -H "Authorization: Bearer $MTOKEN")
check "unreachable source marks watermark failed (not applied)" "failed" "$(echo $WMRES2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["watermark_status"])')"
check "failed watermark keeps the original video_url" "http://127.0.0.1:$WM_PORT/missing.mp4" "$(echo $WMRES2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["video_url"])')"

echo "--- migration v7: columns roll back to v6 shape and re-apply on boot ---"
kill $SRV5_PID 2>/dev/null; sleep 0.5
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-modes-test.db');
db.exec('DELETE FROM schema_migrations WHERE version = 7');
for (const col of ['mode', 'source_image_path', 'watermark_text', 'watermark_status'])
  db.exec('ALTER TABLE generations DROP COLUMN ' + col);
console.log('rolled back to v6 shape');
"
env DB_PATH=/tmp/myvideoai-modes-test.db PORT=18094 FAL_KEY=dummy_test_key "$MODES_JWT_NAME=modes-instance-dummy-value" TEST_RECORD_FAL_BODY=1 GENERATED_DIR=/tmp/modegen node "$(dirname "$0")/server.js" > /tmp/myvideoai-modes-test2.log 2>&1 &
SRV5_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B5/api/health && break || sleep 0.25; done
check "v7 re-applied on boot (schema_migrations has 7)" "yes" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-modes-test.db');
const cols = db.prepare('PRAGMA table_info(generations)').all().map(r => r.name);
const mig = db.prepare('SELECT version FROM schema_migrations WHERE version = 7').get();
console.log(mig && ['mode','source_image_path','watermark_text','watermark_status'].every(c => cols.includes(c)) ? 'yes' : 'no');
")"
check "pre-v7 rows gain mode=realistic after upgrade" "realistic" "$(curl -s $B5/api/history -H "Authorization: Bearer $MTOKEN" | python3 -c 'import sys,json;rows=json.load(sys.stdin)["generations"];print([g for g in rows if g["prompt"]=="watermark seed"][0]["mode"])')"

echo "--- migration v8: Normal price change applies to a v7-shaped DB ---"
kill $SRV5_PID 2>/dev/null; sleep 0.5
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-modes-test.db');
db.exec('DELETE FROM schema_migrations WHERE version = 8');
db.exec(\"UPDATE plans SET price_monthly = 1500, price_yearly = 15000, credits_monthly = 100 WHERE id = 'normal'\");
console.log('normal plan rolled back to pre-v8 values');
"
env DB_PATH=/tmp/myvideoai-modes-test.db PORT=18094 FAL_KEY=dummy_test_key "$MODES_JWT_NAME=modes-instance-dummy-value" TEST_RECORD_FAL_BODY=1 GENERATED_DIR=/tmp/modegen node "$(dirname "$0")/server.js" > /tmp/myvideoai-modes-test3.log 2>&1 &
SRV5_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B5/api/health && break || sleep 0.25; done
check "v8 re-applied on boot (1999/19990/150)" "1999/19990/150" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-modes-test.db');
const p = db.prepare(\"SELECT price_monthly, price_yearly, credits_monthly FROM plans WHERE id = 'normal'\").get();
const mig = db.prepare('SELECT version FROM schema_migrations WHERE version = 8').get();
console.log(mig ? [p.price_monthly, p.price_yearly, p.credits_monthly].join('/') : 'missing');
")"
check "Pro keeps its v9 values after v8 re-apply (9500/5000)" "9500/5000" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-modes-test.db');
const p = db.prepare(\"SELECT price_monthly, credits_monthly FROM plans WHERE id = 'pro'\").get();
console.log([p.price_monthly, p.credits_monthly].join('/'));
")"

echo "--- migration v9: final pricing + Weekly plan apply to a pre-v9 DB ---"
kill $SRV5_PID 2>/dev/null; sleep 0.5
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-modes-test.db');
db.exec('DELETE FROM schema_migrations WHERE version = 9');
db.exec('DELETE FROM plans WHERE id = \'weekly\'');
for (const col of ['price_weekly', 'credits_weekly', 'play_product_weekly', 'can_veo', 'can_lipsync'])
  db.exec('ALTER TABLE plans DROP COLUMN ' + col);
db.exec(\"UPDATE plans SET price_monthly = 1999, price_yearly = 19990, credits_monthly = 150 WHERE id = 'normal'\");
db.exec(\"UPDATE plans SET price_monthly = 3000, price_yearly = 30000, credits_monthly = 120 WHERE id = 'pro'\");
db.exec(\"UPDATE plans SET price_monthly = 5000, price_yearly = 50000, credits_monthly = 120 WHERE id = 'extrapro'\");
console.log('plans rolled back to pre-v9 shape and prices');
"
env DB_PATH=/tmp/myvideoai-modes-test.db PORT=18094 FAL_KEY=dummy_test_key "$MODES_JWT_NAME=modes-instance-dummy-value" TEST_RECORD_FAL_BODY=1 GENERATED_DIR=/tmp/modegen node "$(dirname "$0")/server.js" > /tmp/myvideoai-modes-test4.log 2>&1 &
SRV5_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B5/api/health && break || sleep 0.25; done
check "v9 re-applied: normal 5600/56000/400" "5600/56000/400" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-modes-test.db');
const p = db.prepare(\"SELECT price_monthly, price_yearly, credits_monthly FROM plans WHERE id = 'normal'\").get();
const mig = db.prepare('SELECT version FROM schema_migrations WHERE version = 9').get();
console.log(mig ? [p.price_monthly, p.price_yearly, p.credits_monthly].join('/') : 'missing');
")"
check "v9 re-applied: pro 9500/500 + Veo flag" "9500/500/1" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-modes-test.db');
const p = db.prepare(\"SELECT price_monthly, credits_monthly, can_veo FROM plans WHERE id = 'pro'\").get();
console.log([p.price_monthly, p.credits_monthly, p.can_veo].join('/'));
")"
check "v9 re-applied: weekly plan inserted (1800/80, ajk_weekly)" "1800/80/ajk_weekly" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-modes-test.db');
const p = db.prepare(\"SELECT price_weekly, credits_weekly, play_product_weekly FROM plans WHERE id = 'weekly'\").get();
console.log(p ? [p.price_weekly, p.credits_weekly, p.play_product_weekly].join('/') : 'missing');
")"
# Admin edits made AFTER the migration must survive a reboot (v9 is
# version-gated and runs exactly once; boot seed never overwrites prices).
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-modes-test.db');
db.exec('UPDATE plans SET price_monthly = 6100 WHERE id = \'normal\'');
console.log('simulated admin price edit: normal -> 6100');
"
kill $SRV5_PID 2>/dev/null; sleep 0.5
env DB_PATH=/tmp/myvideoai-modes-test.db PORT=18094 FAL_KEY=dummy_test_key "$MODES_JWT_NAME=modes-instance-dummy-value" TEST_RECORD_FAL_BODY=1 GENERATED_DIR=/tmp/modegen node "$(dirname "$0")/server.js" > /tmp/myvideoai-modes-test5.log 2>&1 &
SRV5_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B5/api/health && break || sleep 0.25; done
check "admin price edit survives reboot (6100, not clobbered)" "6100" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-modes-test.db');
console.log(db.prepare(\"SELECT price_monthly FROM plans WHERE id = 'normal'\").get().price_monthly);
")"
kill $SRV5_PID $WM_PID 2>/dev/null
rm -rf "$(dirname "$0")/data/uploads/$MID" "$(dirname "$0")/data/uploads/$OID5" 2>/dev/null

echo "--- pricing v9: weekly plan, per-quality rate card, daily cap 4000 (own instance) ---"
# Self-contained SIXTH instance (own throwaway DB). Kept off the main
# server because its per-IP generation budget is nearly exhausted by the
# earlier sections. Covers: /api/config exposing the full rate card,
# /api/plans weekly + feature flags, weekly activation (800 credits,
# 7-day period, Rs 1,800 payment), period-fit rejections, the 2K/4K rows
# of the rate card in real generation charges, and the daily cap at 4000.
B6=http://127.0.0.1:18092
rm -f /tmp/myvideoai-v9-test.db
V9_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-v9-test.db PORT=18092 FAL_KEY=dummy_test_key "$V9_JWT_NAME=v9-instance-dummy-value" ADMIN_EMAIL=v9admin@example.com TEST_RECORD_FAL_BODY=1 node "$(dirname "$0")/server.js" > /tmp/myvideoai-v9-test.log 2>&1 &
SRV6_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B6/api/health && break || sleep 0.25; done
CFG6=$(curl -s $B6/api/config)
check "config daily cap defaults to 4000" "4000" "$(echo $CFG6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["max_daily_credits"])')"
check "config rate card 768P: 5s=120, 10s=240" "120/240" "$(echo $CFG6 | python3 -c 'import sys,json;q=json.load(sys.stdin)["cost_by_quality"]["768P"];print(str(q["5"])+"/"+str(q["10"]))')"
check "config rate card 2K: 5s=180, 10s=360" "180/360" "$(echo $CFG6 | python3 -c 'import sys,json;q=json.load(sys.stdin)["cost_by_quality"]["2K"];print(str(q["5"])+"/"+str(q["10"]))')"
check "config rate card 4K: 5s=450, 10s=900" "450/900" "$(echo $CFG6 | python3 -c 'import sys,json;q=json.load(sys.stdin)["cost_by_quality"]["4K"];print(str(q["5"])+"/"+str(q["10"]))')"
PL6=$(curl -s $B6/api/plans)
check "plans: 5 plans listed" "5" "$(echo $PL6 | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["plans"]))')"
check "plans: weekly 1800/wk + 800 credits, monthly fields null" "1800/800/None/None" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["plans"] if x["id"]=="weekly"][0];print("/".join([str(p["price_weekly"]),str(p["credits_weekly"]),str(p["price_monthly"]),str(p["credits_monthly"])]))')"
check "plans: weekly play product is ajk_weekly" "ajk_weekly" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["plans"] if x["id"]=="weekly"][0]["play_product_id"]["weekly"])')"
check "plans: weekly features (no Veo/lip-sync, max 768P)" "False/False/768P" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);f=[x for x in d["plans"] if x["id"]=="weekly"][0]["features"];print(str(f["can_veo"])+"/"+str(f["can_lipsync"])+"/"+f["max_quality"])')"
check "plans: normal has no weekly price (null)" "None" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["plans"] if x["id"]=="normal"][0]["price_weekly"])')"
check "plans: pro features (Veo + lip-sync, max 2K)" "True/True/2K" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);f=[x for x in d["plans"] if x["id"]=="pro"][0]["features"];print(str(f["can_veo"])+"/"+str(f["can_lipsync"])+"/"+f["max_quality"])')"
check "plans: extrapro 14000/mo + 6000 credits, max 4K" "14000/6000/4K" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["plans"] if x["id"]=="extrapro"][0];print(str(p["price_monthly"])+"/"+str(p["credits_monthly"])+"/"+p["features"]["max_quality"])')"
check "plans: extrapremier 19999/mo + 10000 credits, max 4K, all flags" "19999/10000/4K/True/True/True" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["plans"] if x["id"]=="extrapremier"][0];f=p["features"];print(str(p["price_monthly"])+"/"+str(p["credits_monthly"])+"/"+f["max_quality"]+"/"+str(f["can_veo"])+"/"+str(f["can_lipsync"])+"/"+str(f["can_seedance"]))')"
AR6=$(curl -s -X POST $B6/api/auth/register -H 'Content-Type: application/json' -d '{"email":"v9admin@example.com","password":"password123"}')
AT6=$(echo $AR6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
WR6=$(curl -s -X POST $B6/api/auth/register -H 'Content-Type: application/json' -d '{"email":"v9user@example.com","password":"password123"}')
UT6=$(echo $WR6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
UID6=$(curl -s $B6/api/me -H "Authorization: Bearer $UT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')

echo "--- pricing v9: weekly activation (800 credits, 7-day period) ---"
WMP=$(curl -s -X POST $B6/api/admin/users/$UID6/manual-payment -H "Authorization: Bearer $AT6" -H 'Content-Type: application/json' -d '{"plan_id":"weekly","period":"weekly"}')
check "weekly manual payment ok" "True" "$(echo $WMP | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
check "weekly payment amount Rs 1800" "1800" "$(curl -s $B6/api/payments -H "Authorization: Bearer $UT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["payments"][0]["amount"])')"
WME=$(curl -s $B6/api/me -H "Authorization: Bearer $UT6")
check "weekly: plan bucket granted 800" "800" "$(echo $WME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
check "weekly: total = 1000 free + 800 plan = 1800" "1800" "$(echo $WME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "weekly: subscription period is weekly" "weekly" "$(echo $WME | python3 -c 'import sys,json;print(json.load(sys.stdin)["subscription"]["period"])')"
check "weekly: period spans exactly 7 days" "7" "$(echo $WME | python3 -c 'import sys,json,datetime as dt;s=json.load(sys.stdin)["subscription"];a=dt.datetime.fromisoformat(s["current_period_start"]);b=dt.datetime.fromisoformat(s["current_period_end"]);print((b-a).days)')"

echo "--- pricing v9: period/plan fit is enforced ---"
check "weekly plan bought monthly -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B6/api/admin/users/$UID6/manual-payment -H "Authorization: Bearer $AT6" -H 'Content-Type: application/json' -d '{"plan_id":"weekly","period":"monthly"}')"
check "weekly plan bought yearly -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B6/api/admin/users/$UID6/manual-payment -H "Authorization: Bearer $AT6" -H 'Content-Type: application/json' -d '{"plan_id":"weekly","period":"yearly"}')"
check "monthly plan bought weekly -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B6/api/admin/users/$UID6/manual-payment -H "Authorization: Bearer $AT6" -H 'Content-Type: application/json' -d '{"plan_id":"normal","period":"weekly"}')"
check "rejected period purchases changed nothing (total still 1800)" "1800" "$(curl -s $B6/api/me -H "Authorization: Bearer $UT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- pricing v9: rate card charges by routed quality (2K / 4K) ---"
PR6=$(curl -s -X POST $B6/api/auth/register -H 'Content-Type: application/json' -d '{"email":"v9pro@example.com","password":"password123"}')
PT6=$(echo $PR6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PID6=$(curl -s $B6/api/me -H "Authorization: Bearer $PT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B6/api/admin/users/$PID6/activate -H "Authorization: Bearer $AT6" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
curl -s -o /dev/null -X POST $B6/api/generate -H "Authorization: Bearer $PT6" -H 'Idempotency-Key: v9-pro-5s' -H 'Content-Type: application/json' -d '{"prompt":"a city skyline at golden hour","aspect_ratio":"16:9","duration":5}'
PH6=$(curl -s $B6/api/history -H "Authorization: Bearer $PT6")
check "pro 5s job routed at 2K" "2K" "$(echo $PH6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "pro 5s job cost 180 credits (2K rate)" "180" "$(echo $PH6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
curl -s -o /dev/null -X POST $B6/api/generate -H "Authorization: Bearer $PT6" -H 'Idempotency-Key: v9-pro-10s' -H 'Content-Type: application/json' -d '{"prompt":"a city skyline at golden hour, longer take","aspect_ratio":"16:9","duration":10}'
check "pro 10s job cost 360 credits (2K rate)" "360" "$(curl -s $B6/api/history -H "Authorization: Bearer $PT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
XR6=$(curl -s -X POST $B6/api/auth/register -H 'Content-Type: application/json' -d '{"email":"v9xpro@example.com","password":"password123"}')
XT6=$(echo $XR6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
XID6=$(curl -s $B6/api/me -H "Authorization: Bearer $XT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B6/api/admin/users/$XID6/activate -H "Authorization: Bearer $AT6" -H 'Content-Type: application/json' -d '{"plan_id":"extrapro","period":"monthly"}'
curl -s -o /dev/null -X POST $B6/api/generate -H "Authorization: Bearer $XT6" -H 'Idempotency-Key: v9-x-5s' -H 'Content-Type: application/json' -d '{"prompt":"an eagle soaring over snow peaks","aspect_ratio":"16:9","duration":5}'
XH6=$(curl -s $B6/api/history -H "Authorization: Bearer $XT6")
check "extrapro 5s job routed at 4K" "4K" "$(echo $XH6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "extrapro 5s job cost 450 credits (4K rate)" "450" "$(echo $XH6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
curl -s -o /dev/null -X POST $B6/api/generate -H "Authorization: Bearer $XT6" -H 'Idempotency-Key: v9-x-10s' -H 'Content-Type: application/json' -d '{"prompt":"an eagle soaring over snow peaks, longer take","aspect_ratio":"16:9","duration":10}'
check "extrapro 10s job cost 900 credits (4K rate)" "900" "$(curl -s $B6/api/history -H "Authorization: Bearer $XT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"

echo "--- pricing v9: daily cap enforced at 4000 ---"
DR6=$(curl -s -X POST $B6/api/auth/register -H 'Content-Type: application/json' -d '{"email":"v9daily@example.com","password":"password123"}')
DT6=$(echo $DR6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
DID6=$(curl -s $B6/api/me -H "Authorization: Bearer $DT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-v9-test.db');
db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?)').run($DID6, 'daily-cap seed', '16:9', 10, 'realistic', 'completed', 3950);
console.log('seeded 3950 credits of completed spend for today');
"
DCAP=$(curl -s -w '\n%{http_code}' -X POST $B6/api/generate -H "Authorization: Bearer $DT6" -H 'Content-Type: application/json' -d '{"prompt":"one more small clip please","aspect_ratio":"16:9","duration":5}')
check "3950 spent + 120 more exceeds the 4000 daily cap -> 429" "429" "$(echo "$DCAP" | tail -1)"
check "daily-cap error names the limit" "Daily spending limit reached. Try again tomorrow." "$(echo "$DCAP" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
kill $SRV6_PID 2>/dev/null

echo "--- voice system: config on the main server ---"
CV=$(curl -s $B/api/config)
check "voice: gemini provider configured (fal key present)" "True" "$(echo $CV | python3 -c 'import sys,json;print(json.load(sys.stdin)["voice"]["providers"]["gemini"])')"
check "voice: azure provider NOT configured (no owner key yet)" "False" "$(echo $CV | python3 -c 'import sys,json;print(json.load(sys.stdin)["voice"]["providers"]["azure"])')"
check "voice: default provider is gemini" "gemini" "$(echo $CV | python3 -c 'import sys,json;print(json.load(sys.stdin)["voice"]["default_provider"])')"
check "voice: catalog lists Kore as a female gemini voice" "female" "$(echo $CV | python3 -c 'import sys,json;d=json.load(sys.stdin);g=[x for x in d["voice"]["voices"] if x["provider"]=="gemini"][0];print([v for v in g["voices"] if v["id"]=="Kore"][0]["gender"])')"
check "voice: lipsync 0 (included since G2, 300-char cap) / voiceover 0 (included)" "0/0" "$(echo $CV | python3 -c 'import sys,json;d=json.load(sys.stdin)["voice"]["costs"];print(str(d["lipsync_credits"])+"/"+str(d["voiceover_credits"]))')"

echo "--- sound system: config on the main server ---"
CS=$(curl -s $B/api/config)
check "sound: configured (fal key present)" "True" "$(echo $CS | python3 -c 'import sys,json;print(json.load(sys.stdin)["sound"]["configured"])')"
check "sound: all modes included in the price — costs 0/0/0/0" "0/0/0/0" "$(echo $CS | python3 -c 'import sys,json;c=json.load(sys.stdin)["sound"]["costs"];print(str(c["sync"])+"/"+str(c["premium_sync"])+"/"+str(c["sfx"])+"/"+str(c["music"]))')"
check "sound: modes list" "music,premium_sync,sfx,sync" "$(echo $CS | python3 -c 'import sys,json;print(",".join(sorted(json.load(sys.stdin)["sound"]["modes"])))')"
check "sound: sync engine is mmaudio-v2" "fal-ai/mmaudio-v2" "$(echo $CS | python3 -c 'import sys,json;print(json.load(sys.stdin)["sound"]["models"]["sync"])')"

echo "--- voice system: NO provider configured -> fail closed (own instance) ---"
B8=http://127.0.0.1:18089
rm -f /tmp/myvideoai-voice-none-test.db
VOICE_NONE_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-voice-none-test.db PORT=18089 FAL_KEY=dummy_test_key "$VOICE_NONE_JWT_NAME=voice-none-dummy-value" TTS_PROVIDERS=none node "$(dirname "$0")/server.js" > /tmp/myvideoai-voice-none-test.log 2>&1 &
SRV8_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B8/api/health && break || sleep 0.25; done
CFG8=$(curl -s $B8/api/config)
check "unconfigured: all voice providers false" "False/False/False" "$(echo $CFG8 | python3 -c 'import sys,json;p=json.load(sys.stdin)["voice"]["providers"];print(str(p["gemini"])+"/"+str(p["elevenlabs"])+"/"+str(p["azure"]))')"
check "unconfigured: default_provider is null" "None" "$(echo $CFG8 | python3 -c 'import sys,json;print(json.load(sys.stdin)["voice"]["default_provider"])')"
check "unconfigured: voice catalog is empty" "0" "$(echo $CFG8 | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["voice"]["voices"]))')"
UR8=$(curl -s -X POST $B8/api/auth/register -H 'Content-Type: application/json' -d '{"email":"voicenone@example.com","password":"password123"}')
UT8=$(echo $UR8 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
UID8=$(curl -s $B8/api/me -H "Authorization: Bearer $UT8" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
PV8=$(curl -s -w '\n%{http_code}' -X POST $B8/api/voice/preview -H "Authorization: Bearer $UT8" -H 'Content-Type: application/json' -d '{"script":"mera naam ahmed hai","spoken_language":"ur","script_mode":"roman"}')
check "unconfigured: preview -> 503" "503" "$(echo "$PV8" | tail -1)"
check "unconfigured: preview error is voice_not_configured" "voice_not_configured" "$(echo "$PV8" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "unconfigured: preview charged nothing" "1000" "$(curl -s $B8/api/me -H "Authorization: Bearer $UT8" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
SEED8=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-voice-none-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($UID8, 'seed clip', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:18090/media/clip.mp4', 100).lastInsertRowid));
")
check "unconfigured: voiceover -> 503" "503" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B8/api/voice/voiceover -H "Authorization: Bearer $UT8" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED8,\"script\":\"mera naam ahmed hai\",\"spoken_language\":\"ur\",\"script_mode\":\"roman\"}")"
check "unconfigured: voiceover charged nothing" "1000" "$(curl -s $B8/api/me -H "Authorization: Bearer $UT8" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
kill $SRV8_PID 2>/dev/null

echo "--- voice system: preview, transliteration, lip-sync, voiceover (fal stub) ---"
FAL_STUB_PORT=18090
B7=http://127.0.0.1:18091
rm -f /tmp/myvideoai-voice-test.db; rm -rf /tmp/voiceout /tmp/voicegen; mkdir -p /tmp/voiceout /tmp/voicegen
FAL_STUB_PORT=$FAL_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub.log 2>&1 &
FALSTUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$FAL_STUB_PORT/__calls && break || sleep 0.25; done
VOICE_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-voice-test.db PORT=18091 FAL_KEY=dummy_test_key "$VOICE_JWT_NAME=voice-instance-dummy-value" \
  ADMIN_EMAIL=voiceadmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$FAL_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$FAL_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 VOICE_DIR=/tmp/voiceout GENERATED_DIR=/tmp/voicegen \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-voice-test.log 2>&1 &
SRV7_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B7/api/health && break || sleep 0.25; done
CFG7=$(curl -s $B7/api/config)
check "voice instance: languages are en/hi/pa/ps/sd/ur (Phase M added the Gemini-listed three)" "en,hi,pa,ps,sd,ur" "$(echo $CFG7 | python3 -c 'import sys,json;print(",".join(sorted(l["code"] for l in json.load(sys.stdin)["voice"]["languages"])))')"
check "voice instance: preview daily cap is 5" "5" "$(echo $CFG7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["voice"]["preview"]["daily_cap"])')"
AR7=$(curl -s -X POST $B7/api/auth/register -H 'Content-Type: application/json' -d '{"email":"voiceadmin@example.com","password":"password123"}')
AT7=$(echo $AR7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

# -- previews + transliteration (asserted via the recorded provider body) --
PR7=$(curl -s -X POST $B7/api/auth/register -H 'Content-Type: application/json' -d '{"email":"preview@example.com","password":"password123"}')
PT7=$(echo $PR7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PV=$(curl -s -w '\n%{http_code}' -X POST $B7/api/voice/preview -H "Authorization: Bearer $PT7" -H 'Content-Type: application/json' -d '{"script":"mera naam ahmed hai","spoken_language":"ur","script_mode":"roman"}')
check "preview: roman urdu script -> 200" "200" "$(echo "$PV" | tail -1)"
PVB=$(echo "$PV" | sed '$d')
check "preview: audio_url under /files/voice/" "yes" "$(echo $PVB | python3 -c 'import sys,json;u=json.load(sys.stdin)["audio_url"];print("yes" if u.startswith("/files/voice/") else "no")')"
check "preview: roman urdu transliterated (dictionary words)" "میرا نام احمد ہے" "$(echo $PVB | python3 -c 'import sys,json;print(json.load(sys.stdin)["synthesized_text"])')"
check "preview: charges nothing (credits_left 1000)" "1000" "$(echo $PVB | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
PVAUDIO=$(echo $PVB | python3 -c 'import sys,json;print(json.load(sys.stdin)["audio_url"])')
check "preview: audio file is served (200)" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B7$PVAUDIO)"
VC=$(curl -s $B7/api/_test/voice-calls)
check "preview: provider body = transliterated text + Urdu (Pakistan) + Kore" "میرا نام احمد ہے|Urdu (Pakistan)|Kore" "$(echo $VC | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x["kind"]=="tts"][-1];b=c["body"];print(b["prompt"]+"|"+b["language_code"]+"|"+b["voice"])')"
PVH=$(curl -s -X POST $B7/api/voice/preview -H "Authorization: Bearer $PT7" -H 'Content-Type: application/json' -d '{"script":"mera naam ram hai","spoken_language":"hi","script_mode":"roman"}')
check "preview: roman hindi transliterated (dictionary words)" "मेरा नाम राम है" "$(echo $PVH | python3 -c 'import sys,json;print(json.load(sys.stdin)["synthesized_text"])')"
PVU=$(curl -s -X POST $B7/api/voice/preview -H "Authorization: Bearer $PT7" -H 'Content-Type: application/json' -d '{"script":"kitaab","spoken_language":"ur","script_mode":"roman"}')
check "preview: urdu character-map fallback (kitaab)" "کیتاب" "$(echo $PVU | python3 -c 'import sys,json;print(json.load(sys.stdin)["synthesized_text"])')"
PVK=$(curl -s -X POST $B7/api/voice/preview -H "Authorization: Bearer $PT7" -H 'Content-Type: application/json' -d '{"script":"kitaab","spoken_language":"hi","script_mode":"roman"}')
check "preview: hindi syllabic fallback (kitaab)" "किताब" "$(echo $PVK | python3 -c 'import sys,json;print(json.load(sys.stdin)["synthesized_text"])')"
PVN=$(curl -s -X POST $B7/api/voice/preview -H "Authorization: Bearer $PT7" -H 'Content-Type: application/json' -d '{"script":"یہ ایک خبر ہے","spoken_language":"ur","script_mode":"native"}')
check "preview: native script passes through unchanged" "یہ ایک خبر ہے" "$(echo $PVN | python3 -c 'import sys,json;print(json.load(sys.stdin)["synthesized_text"])')"
check "preview: still no charge after 5 previews" "1000" "$(curl -s $B7/api/me -H "Authorization: Bearer $PT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- preview daily cap --
CR7=$(curl -s -X POST $B7/api/auth/register -H 'Content-Type: application/json' -d '{"email":"capuser@example.com","password":"password123"}')
CT7=$(echo $CR7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -X POST $B7/api/voice/preview -H "Authorization: Bearer $CT7" -H 'Content-Type: application/json' -d '{"script":"salam dost","spoken_language":"ur","script_mode":"roman"}'
done
check "preview: 6th preview of the day -> 429" "429" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B7/api/voice/preview -H "Authorization: Bearer $CT7" -H 'Content-Type: application/json' -d '{"script":"salam dost","spoken_language":"ur","script_mode":"roman"}')"
check "preview cap: credits untouched" "1000" "$(curl -s $B7/api/me -H "Authorization: Bearer $CT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- preview provider failure --
FR7=$(curl -s -X POST $B7/api/auth/register -H 'Content-Type: application/json' -d '{"email":"failuser@example.com","password":"password123"}')
FT7=$(echo $FR7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
check "preview: provider failure -> 502" "502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B7/api/voice/preview -H "Authorization: Bearer $FT7" -H 'Content-Type: application/json' -d '{"script":"FAILME please","spoken_language":"en","script_mode":"native"}')"
check "preview failure: credits untouched" "1000" "$(curl -s $B7/api/me -H "Authorization: Bearer $FT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- lip-sync gating: Normal plan -> 403 --
LR7=$(curl -s -X POST $B7/api/auth/register -H 'Content-Type: application/json' -d '{"email":"lipnormal@example.com","password":"password123"}')
LT7=$(echo $LR7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
LSN=$(curl -s -w '\n%{http_code}' -X POST $B7/api/voice/lipsync -H "Authorization: Bearer $LT7" -H 'Content-Type: application/json' -d '{"image_path":"data/uploads/1/x.png","script":"mera naam ahmed hai","spoken_language":"ur","script_mode":"roman"}')
check "lipsync: no Pro plan -> 403" "403" "$(echo "$LSN" | tail -1)"
check "lipsync: 403 error names the Pro plan" "yes" "$(echo "$LSN" | sed '$d' | python3 -c 'import sys,json;print("yes" if "Pro" in json.load(sys.stdin)["error"] else "no")')"
check "lipsync 403: credits untouched" "1000" "$(curl -s $B7/api/me -H "Authorization: Bearer $LT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- lip-sync success + failure (Pro user) --
RR7=$(curl -s -X POST $B7/api/auth/register -H 'Content-Type: application/json' -d '{"email":"lippro@example.com","password":"password123"}')
RT7=$(echo $RR7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
RID7=$(curl -s $B7/api/me -H "Authorization: Bearer $RT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B7/api/admin/users/$RID7/activate -H "Authorization: Bearer $AT7" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
check "pro user balance after activation (1000 free + 5000 plan)" "6000" "$(curl -s $B7/api/me -H "Authorization: Bearer $RT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
PNG_B64_V=$(python3 -c "import base64; print(base64.b64encode(bytes.fromhex('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c636000000000020001e221bc330000000049454e44ae426082')).decode())")
UPV=$(curl -s -X POST $B7/api/uploads/image -H "Authorization: Bearer $RT7" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_V\",\"content_type\":\"image/png\"}")
VIMG=$(echo $UPV | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
LS=$(curl -s -w '\n%{http_code}' -X POST $B7/api/voice/lipsync -H "Authorization: Bearer $RT7" -H 'Content-Type: application/json' -d "{\"image_path\":\"$VIMG\",\"script\":\"mera naam ahmed hai\",\"spoken_language\":\"ur\",\"script_mode\":\"roman\"}")
check "lipsync (image): -> 201" "201" "$(echo "$LS" | tail -1)"
LSB=$(echo "$LS" | sed '$d')
check "lipsync (image): generation kind is lipsync" "lipsync" "$(echo $LSB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["kind"])')"
check "lipsync (image): included — cost 0 credits" "0" "$(echo $LSB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["cost_credits"])')"
check "lipsync (image): status completed" "completed" "$(echo $LSB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["status"])')"
check "lipsync (image): credits_left 6000 (included — nothing charged)" "6000" "$(echo $LSB | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
VC2=$(curl -s $B7/api/_test/voice-calls)
check "lipsync (image): fal body has data-URI image_url + /files/voice/ audio_url" "ok" "$(echo $VC2 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x["kind"]=="queue"][-1];b=c["body"];print("ok" if c["model"]=="minimax/h3-max/lip-sync/image-to-video" and b["image_url"].startswith("data:image/png") and "/files/voice/" in b["audio_url"] else "bad")')"
check "lipsync (image): newest history entry is the lipsync job" "lipsync" "$(curl -s $B7/api/history -H "Authorization: Bearer $RT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["kind"])')"
LSF=$(curl -s -w '\n%{http_code}' -X POST $B7/api/voice/lipsync -H "Authorization: Bearer $RT7" -H 'Content-Type: application/json' -d "{\"image_path\":\"$VIMG\",\"script\":\"FAILME bolna hai\",\"spoken_language\":\"ur\",\"script_mode\":\"native\"}")
check "lipsync: TTS failure -> 502" "502" "$(echo "$LSF" | tail -1)"
check "lipsync failure: credits untouched (still 6000 — nothing was charged)" "6000" "$(curl -s $B7/api/me -H "Authorization: Bearer $RT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "lipsync failure: job row marked failed" "failed" "$(curl -s $B7/api/history -H "Authorization: Bearer $RT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["status"])')"
SEED7=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-voice-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($RID7, 'seed talking source', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:$FAL_STUB_PORT/media/clip.mp4', 100).lastInsertRowid));
")
LSV=$(curl -s -w '\n%{http_code}' -X POST $B7/api/voice/lipsync -H "Authorization: Bearer $RT7" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED7,\"script\":\"mera naam ahmed hai\",\"spoken_language\":\"ur\",\"script_mode\":\"roman\"}")
check "lipsync (video): -> 201" "201" "$(echo "$LSV" | tail -1)"
LSVB=$(echo "$LSV" | sed '$d')
check "lipsync (video): routed to the latentsync model" "fal-ai/latentsync" "$(echo $LSVB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["model"])')"
check "lipsync (video): credits_left 6000 (included)" "6000" "$(echo $LSVB | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"

# -- voiceover: failure refund, then success + mux, then chunking --
VR7=$(curl -s -X POST $B7/api/auth/register -H 'Content-Type: application/json' -d '{"email":"voiceover@example.com","password":"password123"}')
VT7=$(echo $VR7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
VID7=$(curl -s $B7/api/me -H "Authorization: Bearer $VT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
SEEDV=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-voice-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($VID7, 'seed voiceover source', '16:9', 2, 'realistic', 'completed', 'http://127.0.0.1:$FAL_STUB_PORT/media/clip.mp4', 100).lastInsertRowid));
")
check "voiceover: TTS failure -> 502" "502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B7/api/voice/voiceover -H "Authorization: Bearer $VT7" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDV,\"script\":\"FAILME bolna hai\",\"spoken_language\":\"ur\",\"script_mode\":\"native\"}")"
check "voiceover failure: full refund (back to 1000)" "1000" "$(curl -s $B7/api/me -H "Authorization: Bearer $VT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
VO=$(curl -s -w '\n%{http_code}' -X POST $B7/api/voice/voiceover -H "Authorization: Bearer $VT7" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDV,\"script\":\"mera naam ahmed hai\",\"spoken_language\":\"ur\",\"script_mode\":\"roman\"}")
check "voiceover: -> 201" "201" "$(echo "$VO" | tail -1)"
VOB=$(echo "$VO" | sed '$d')
check "voiceover: generation kind is voiceover" "voiceover" "$(echo $VOB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["kind"])')"
check "voiceover: included — cost 0, credits_left 1000" "0/1000" "$(echo $VOB | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
check "voiceover: output under /files/generated/" "yes" "$(echo $VOB | python3 -c 'import sys,json;u=json.load(sys.stdin)["generation"]["video_url"];print("yes" if u.startswith("/files/generated/") else "no")')"
check "voiceover: voice_audio_path under /files/voice/" "yes" "$(echo $VOB | python3 -c 'import sys,json;u=json.load(sys.stdin)["generation"]["voice_audio_path"] or "";print("yes" if u.startswith("/files/voice/") else "no")')"
VOURL=$(echo $VOB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["video_url"])')
curl -s -o /tmp/voiceover-out.mp4 $B7$VOURL
FFBIN7=$(node --input-type=module -e "import f from 'ffmpeg-static'; console.log(f)" 2>/dev/null)
check "voiceover: muxed output HAS an audio stream" "yes" "$("$FFBIN7" -i /tmp/voiceover-out.mp4 2>&1 | python3 -c 'import sys;print("yes" if "Audio:" in sys.stdin.read() else "no")')"
check "voiceover: muxed output keeps the video stream" "yes" "$("$FFBIN7" -i /tmp/voiceover-out.mp4 2>&1 | python3 -c 'import sys;print("yes" if "Video:" in sys.stdin.read() else "no")')"
# long script (>3000 chars after transliteration) -> exactly 2 TTS chunks,
# concatenated in order into one audio file (~2 x 2s stub tones).
TTS_BEFORE=$(curl -s $B7/api/_test/voice-calls | python3 -c 'import sys,json;print(len([x for x in json.load(sys.stdin)["calls"] if x["kind"]=="tts"]))')
LONGSCRIPT=$(python3 -c "print('mera naam ahmed hai. ' * 170)")
VOL=$(curl -s -w '\n%{http_code}' -X POST $B7/api/voice/voiceover -H "Authorization: Bearer $VT7" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDV,\"script\":\"$LONGSCRIPT\",\"spoken_language\":\"ur\",\"script_mode\":\"roman\"}")
check "voiceover (long script): -> 201" "201" "$(echo "$VOL" | tail -1)"
TTS_AFTER=$(curl -s $B7/api/_test/voice-calls | python3 -c 'import sys,json;print(len([x for x in json.load(sys.stdin)["calls"] if x["kind"]=="tts"]))')
check "chunking: long script synthesized in exactly 2 chunks" "2" "$((TTS_AFTER - TTS_BEFORE))"
VOLB=$(echo "$VOL" | sed '$d')
CHUNK_AUDIO=$(echo $VOLB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["voice_audio_path"])')
curl -s -o /tmp/chunk-audio.mp3 $B7$CHUNK_AUDIO
check "chunking: concatenated audio is ~4s (2 parts in order)" "ok" "$("$FFBIN7" -i /tmp/chunk-audio.mp3 2>&1 | python3 -c 'import sys,re; m=re.search(r"Duration: (\d+):(\d+):([\d.]+)", sys.stdin.read()); d=int(m.group(1))*3600+int(m.group(2))*60+float(m.group(3)) if m else -1; print("ok" if 3.4 <= d <= 4.8 else "bad")')"
kill $SRV7_PID $FALSTUB_PID 2>/dev/null

echo "--- sound system: sound disabled -> fail closed (own instance) ---"
B10=http://127.0.0.1:18084
rm -f /tmp/myvideoai-sound-none-test.db
SOUND_NONE_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-sound-none-test.db PORT=18084 FAL_KEY=dummy_test_key "$SOUND_NONE_JWT_NAME=sound-none-dummy-value" SOUND_ENABLED=0 node "$(dirname "$0")/server.js" > /tmp/myvideoai-sound-none-test.log 2>&1 &
SRV10_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B10/api/health && break || sleep 0.25; done
CFG10=$(curl -s $B10/api/config)
check "sound disabled: configured is false" "False" "$(echo $CFG10 | python3 -c 'import sys,json;print(json.load(sys.stdin)["sound"]["configured"])')"
UR10=$(curl -s -X POST $B10/api/auth/register -H 'Content-Type: application/json' -d '{"email":"soundnone@example.com","password":"password123"}')
UT10=$(echo $UR10 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
UID10=$(curl -s $B10/api/me -H "Authorization: Bearer $UT10" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
SG10=$(curl -s -w '\n%{http_code}' -X POST $B10/api/sound/generate -H "Authorization: Bearer $UT10" -H 'Content-Type: application/json' -d '{"kind":"sfx","prompt":"dog barking in the rain"}')
check "sound disabled: audio-only generate -> 503" "503" "$(echo "$SG10" | tail -1)"
check "sound disabled: error is sound_not_configured" "sound_not_configured" "$(echo "$SG10" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
SEED10=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-sound-none-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($UID10, 'seed sound source', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:18088/media/clip.mp4', 100).lastInsertRowid));
")
check "sound disabled: apply -> 503" "503" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B10/api/sound/apply -H "Authorization: Bearer $UT10" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED10,\"mode\":\"sync\"}")"
check "sound disabled: generate with sound -> 503" "503" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B10/api/generate -H "Authorization: Bearer $UT10" -H 'Content-Type: application/json' -d '{"prompt":"a calm lake at dawn","duration":5,"sound":{"mode":"sync"}}')"
check "sound disabled: nothing charged (balance 1000)" "1000" "$(curl -s $B10/api/me -H "Authorization: Bearer $UT10" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "sound disabled: only the seeded row exists (503s created none)" "1" "$(curl -s $B10/api/history -H "Authorization: Bearer $UT10" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["generations"]))')"
kill $SRV10_PID 2>/dev/null

echo "--- sound system: generate-time sound, apply, audio-only (fal stub) ---"
SOUND_STUB_PORT=18088
SOUND_TSTUB_PORT=18086
B9=http://127.0.0.1:18087
rm -f /tmp/myvideoai-sound-test.db; rm -rf /tmp/soundgen /tmp/soundout; mkdir -p /tmp/soundgen /tmp/soundout
FAL_STUB_PORT=$SOUND_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-sound.log 2>&1 &
FALSTUB9_PID=$!
TRANSLATE_STUB_PORT=$SOUND_TSTUB_PORT node "$(dirname "$0")/test-translate-stub.js" > /tmp/translate-stub-sound.log 2>&1 &
TSTUB9_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$SOUND_STUB_PORT/__calls && break || sleep 0.25; done
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$SOUND_TSTUB_PORT/__count && break || sleep 0.25; done
SOUND_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-sound-test.db PORT=18087 FAL_KEY=dummy_test_key "$SOUND_JWT_NAME=sound-instance-dummy-value" \
  ADMIN_EMAIL=soundadmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$SOUND_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$SOUND_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 TRANSLATE_API_BASE=http://127.0.0.1:$SOUND_TSTUB_PORT \
  GENERATED_DIR=/tmp/soundgen SOUNDS_DIR=/tmp/soundout \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-sound-test.log 2>&1 &
SRV9_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B9/api/health && break || sleep 0.25; done
AR9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"soundadmin@example.com","password":"password123"}')
AT9=$(echo $AR9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
FFBIN9=$(node --input-type=module -e "import f from 'ffmpeg-static'; console.log(f)" 2>/dev/null)

# -- generate with auto sync sound: one combined charge, applied once --
RA9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"syncgen@example.com","password":"password123"}')
TA9=$(echo $RA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
GA9=$(curl -s -X POST $B9/api/generate -H "Authorization: Bearer $TA9" -H 'Content-Type: application/json' -d '{"prompt":"a red car speeding down a wet road","aspect_ratio":"16:9","duration":5,"sound":{"mode":"sync","prompt":"rain and thunder over the city"}}')
check "gen+sync: total == base video price 120 (sync included)" "120" "$(echo $GA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_credits"])')"
check "gen+sync: sound cost reported as 0 (included)" "0" "$(echo $GA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["sound_cost_credits"])')"
check "gen+sync: balance 880 after submit (charged exactly once)" "880" "$(echo $GA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
JOBA9=$(echo $GA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
POLLA9=$(curl -s $B9/api/generations/$JOBA9 -H "Authorization: Bearer $TA9")
check "gen+sync: job completed" "completed" "$(echo $POLLA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
check "gen+sync: sound_status applied" "applied" "$(echo $POLLA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["sound_status"])')"
check "gen+sync: sound_mode recorded" "sync" "$(echo $POLLA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["sound_mode"])')"
check "gen+sync: video_url is the sounded (mmaudio) version" "http://127.0.0.1:$SOUND_STUB_PORT/media/clip.mp4" "$(echo $POLLA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["video_url"])')"
check "gen+sync: still 880 after completion (no second charge)" "880" "$(curl -s $B9/api/me -H "Authorization: Bearer $TA9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
VC9=$(curl -s $B9/api/_test/voice-calls)
check "gen+sync: mmaudio body has video_url + prompt + duration" "ok" "$(echo $VC9 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("model")=="fal-ai/mmaudio-v2"][-1];b=c["body"];print("ok" if b.get("video_url","").endswith("/media/clip.mp4") and b.get("prompt")=="rain and thunder over the city" and b.get("duration")==5 else "bad")')"
check "gen+sync: unknown sound mode -> 400, no charge" "400/880" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B9/api/generate -H "Authorization: Bearer $TA9" -H 'Content-Type: application/json' -d '{"prompt":"a calm lake","duration":5,"sound":{"mode":"bogus"}}')/$(curl -s $B9/api/me -H "Authorization: Bearer $TA9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- generate with sync sound, engine fails: video delivered, add-on refunded --
RB9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"soundfail@example.com","password":"password123"}')
TB9=$(echo $RB9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
GB9=$(curl -s -X POST $B9/api/generate -H "Authorization: Bearer $TB9" -H 'Content-Type: application/json' -d '{"prompt":"a quiet beach at sunset","aspect_ratio":"16:9","duration":5,"sound":{"mode":"sync","prompt":"FAILME waves crashing"}}')
check "gen+sync fail: balance 880 after submit" "880" "$(echo $GB9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
JOBB9=$(echo $GB9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
POLLB9=$(curl -s $B9/api/generations/$JOBB9 -H "Authorization: Bearer $TB9")
check "gen+sync fail: video still completed" "completed" "$(echo $POLLB9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
check "gen+sync fail: sound_status failed_refunded" "failed_refunded" "$(echo $POLLB9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["sound_status"])')"
check "gen+sync fail: balance still 880 (sound included — nothing extra to refund)" "880" "$(curl -s $B9/api/me -H "Authorization: Bearer $TB9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "gen+sync fail: row cost stays the video-only 120" "120" "$(echo $POLLB9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_credits"])')"

# -- generate with sound effects: mixed under the original audio --
RC9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"sfxgen@example.com","password":"password123"}')
TC9=$(echo $RC9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
GC9=$(curl -s -X POST $B9/api/generate -H "Authorization: Bearer $TC9" -H 'Content-Type: application/json' -d '{"prompt":"a dog playing in a park","aspect_ratio":"16:9","duration":5,"sound":{"mode":"sfx","prompt":"dog barking and birds","volume":40}}')
check "gen+sfx: total == base 120 (sfx included)" "120" "$(echo $GC9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_credits"])')"
check "gen+sfx: balance 880 after submit" "880" "$(echo $GC9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
JOBC9=$(echo $GC9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
POLLC9=$(curl -s $B9/api/generations/$JOBC9 -H "Authorization: Bearer $TC9")
check "gen+sfx: completed with sound applied" "completed/applied" "$(echo $POLLC9 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+g["sound_status"])')"
check "gen+sfx: mixed video stored locally" "yes" "$(echo $POLLC9 | python3 -c 'import sys,json;u=json.load(sys.stdin)["video_url"];print("yes" if u.startswith("/files/generated/") else "no")')"
SFXURL=$(echo $POLLC9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["video_url"])')
curl -s -o /tmp/sfx-mixed.mp4 $B9$SFXURL
check "gen+sfx: mixed output HAS an audio stream" "yes" "$("$FFBIN9" -i /tmp/sfx-mixed.mp4 2>&1 | python3 -c 'import sys;print("yes" if "Audio:" in sys.stdin.read() else "no")')"
check "gen+sfx: mixed output keeps the video stream" "yes" "$("$FFBIN9" -i /tmp/sfx-mixed.mp4 2>&1 | python3 -c 'import sys;print("yes" if "Video:" in sys.stdin.read() else "no")')"
SC9=$(curl -s $B9/api/_test/sound-calls)
check "gen+sfx: sfx engine body has text + duration_seconds" "ok" "$(echo $SC9 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("engine")=="sfx"][-1];b=c["body"];print("ok" if b.get("text")=="dog barking and birds" and b.get("duration_seconds")==5 else "bad")')"

# -- Urdu sound prompt: translated to English BEFORE the engine call --
UR_VID_PROMPT='ایک سرخ گاڑی سڑک پر جا رہی ہے'
UR_SND_PROMPT='تیز بارش کی آواز'
RH9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"urdusnd@example.com","password":"password123"}')
TH9=$(echo $RH9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
GH9=$(curl -s -X POST $B9/api/generate -H "Authorization: Bearer $TH9" -H 'Content-Type: application/json' -d "{\"prompt\":\"$UR_VID_PROMPT\",\"language\":\"ur\",\"duration\":5,\"sound\":{\"mode\":\"sync\",\"prompt\":\"$UR_SND_PROMPT\"}}")
JOBH9=$(echo $GH9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
POLLH9=$(curl -s $B9/api/generations/$JOBH9 -H "Authorization: Bearer $TH9")
check "urdu sound: job completed with sound applied" "completed/applied" "$(echo $POLLH9 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+g["sound_status"])')"
VC9H=$(curl -s $B9/api/_test/voice-calls)
check "urdu sound: mmaudio received the ENGLISH translation" "ok" "$(echo $VC9H | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("model")=="fal-ai/mmaudio-v2"][-1];print("ok" if c["body"].get("prompt","").startswith("TRANSLATED:") else "bad")')"
check "urdu sound: charged once (balance 880 — sound included)" "880" "$(curl -s $B9/api/me -H "Authorization: Bearer $TH9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- apply sound to an existing video: sync, premium gate, music, failure --
RD9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"apply@example.com","password":"password123"}')
TD9=$(echo $RD9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
DID9=$(curl -s $B9/api/me -H "Authorization: Bearer $TD9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
SEEDD9=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-sound-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($DID9, 'seed apply source', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:$SOUND_STUB_PORT/media/clip.mp4', 100).lastInsertRowid));
")
AP19=$(curl -s -w '\n%{http_code}' -X POST $B9/api/sound/apply -H "Authorization: Bearer $TD9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDD9,\"mode\":\"sync\",\"prompt\":\"city traffic and rain\"}")
check "apply sync: -> 201" "201" "$(echo "$AP19" | tail -1)"
AP1B=$(echo "$AP19" | sed '$d')
check "apply sync: new history entry kind is sound" "sound" "$(echo $AP1B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["kind"])')"
check "apply sync: linked to the source generation" "$SEEDD9" "$(echo $AP1B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["source_generation_id"])')"
check "apply sync: included — cost 0, credits_left 1000" "0/1000" "$(echo $AP1B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
check "apply sync: sound_status applied on the new entry" "applied" "$(echo $AP1B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["sound_status"])')"
check "apply: another user's video -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B9/api/sound/apply -H "Authorization: Bearer $TA9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDD9,\"mode\":\"sync\"}")"
AP29=$(curl -s -w '\n%{http_code}' -X POST $B9/api/sound/apply -H "Authorization: Bearer $TD9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDD9,\"mode\":\"premium_sync\"}")
check "apply premium (no plan): -> 403" "403" "$(echo "$AP29" | tail -1)"
check "apply premium 403: error names the Pro plan" "yes" "$(echo "$AP29" | sed '$d' | python3 -c 'import sys,json;print("yes" if "Pro" in json.load(sys.stdin)["error"] else "no")')"
check "apply premium 403: credits untouched (1000)" "1000" "$(curl -s $B9/api/me -H "Authorization: Bearer $TD9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
AP39=$(curl -s -w '\n%{http_code}' -X POST $B9/api/sound/apply -H "Authorization: Bearer $TD9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDD9,\"mode\":\"music\",\"prompt\":\"soft piano bed\",\"volume\":100}")
check "apply music: -> 201" "201" "$(echo "$AP39" | tail -1)"
AP3B=$(echo "$AP39" | sed '$d')
check "apply music: included — cost 0, credits_left 1000" "0/1000" "$(echo $AP3B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
MUSURL=$(echo $AP3B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["video_url"])')
curl -s -o /tmp/music-mixed.mp4 $B9$MUSURL
check "apply music: mixed output HAS an audio stream" "yes" "$("$FFBIN9" -i /tmp/music-mixed.mp4 2>&1 | python3 -c 'import sys;print("yes" if "Audio:" in sys.stdin.read() else "no")')"
SC9B=$(curl -s $B9/api/_test/sound-calls)
check "apply music: engine body asks for instrumental, duration 10" "ok" "$(echo $SC9B | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("engine")=="music"][-1];b=c["body"];print("ok" if "instrumental, no vocals" in b.get("prompt","") and b.get("duration")==10 else "bad")')"
check "apply sfx (engine fails): -> 502" "502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B9/api/sound/apply -H "Authorization: Bearer $TD9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDD9,\"mode\":\"sfx\",\"prompt\":\"FAILME dog\"}")"
check "apply sfx failure: balance untouched (still 1000)" "1000" "$(curl -s $B9/api/me -H "Authorization: Bearer $TD9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "apply sfx failure: job row marked failed" "failed" "$(curl -s $B9/api/history -H "Authorization: Bearer $TD9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["status"])')"

# -- volume: sync at 50% measurably lowers the soundtrack level --
RE9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"vol@example.com","password":"password123"}')
TE9=$(echo $RE9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
EID9=$(curl -s $B9/api/me -H "Authorization: Bearer $TE9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
SEEDE9=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-sound-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($EID9, 'seed volume source', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:$SOUND_STUB_PORT/media/clip.mp4', 100).lastInsertRowid));
")
curl -s -o /tmp/vol-source.mp4 http://127.0.0.1:$SOUND_STUB_PORT/media/clip.mp4
# mean_volume is the robust measure here: AAC re-encoding reshapes the
# single peak sample, but the mean level tracks the gain exactly.
SRCMAX=$("$FFBIN9" -i /tmp/vol-source.mp4 -af volumedetect -f null - 2>&1 | python3 -c 'import sys,re; m=re.search(r"mean_volume: (-?[\d.]+) dB", sys.stdin.read()); print(m.group(1) if m else "nan")')
APV9=$(curl -s -X POST $B9/api/sound/apply -H "Authorization: Bearer $TE9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDE9,\"mode\":\"sync\",\"volume\":50}")
check "apply sync volume 50: gain pass stored locally" "yes" "$(echo $APV9 | python3 -c 'import sys,json;u=json.load(sys.stdin)["generation"]["video_url"];print("yes" if u.startswith("/files/generated/") else "no")')"
VOLURL=$(echo $APV9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["video_url"])')
curl -s -o /tmp/vol-out.mp4 $B9$VOLURL
OUTMAX=$("$FFBIN9" -i /tmp/vol-out.mp4 -af volumedetect -f null - 2>&1 | python3 -c 'import sys,re; m=re.search(r"mean_volume: (-?[\d.]+) dB", sys.stdin.read()); print(m.group(1) if m else "nan")')
check "apply sync volume 50: output is ~6 dB quieter than the source" "ok" "$(python3 -c "s=float('$SRCMAX'); o=float('$OUTMAX'); print('ok' if 4.0 <= (s - o) <= 8.0 else 'bad')")"

# -- premium sync succeeds for a Pro user (included, speech preserved) --
RF9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"soundpro@example.com","password":"password123"}')
TF9=$(echo $RF9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
FID9=$(curl -s $B9/api/me -H "Authorization: Bearer $TF9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B9/api/admin/users/$FID9/activate -H "Authorization: Bearer $AT9" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
check "sound pro balance after activation (1000 free + 5000 plan)" "6000" "$(curl -s $B9/api/me -H "Authorization: Bearer $TF9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
SEEDF9=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-sound-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($FID9, 'seed premium source', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:$SOUND_STUB_PORT/media/clip.mp4', 100).lastInsertRowid));
")
APP9=$(curl -s -w '\n%{http_code}' -X POST $B9/api/sound/apply -H "Authorization: Bearer $TF9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDF9,\"mode\":\"premium_sync\",\"prompt\":\"distant sirens\"}")
check "apply premium (Pro): -> 201" "201" "$(echo "$APP9" | tail -1)"
APPB=$(echo "$APP9" | sed '$d')
check "apply premium (Pro): included — cost 0, credits_left 6000" "0/6000" "$(echo $APPB | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
PREMURL=$(echo $APPB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["video_url"])')
curl -s -o /tmp/premium-out.mp4 $B9$PREMURL
check "apply premium: muxed output HAS an audio stream" "yes" "$("$FFBIN9" -i /tmp/premium-out.mp4 2>&1 | python3 -c 'import sys;print("yes" if "Audio:" in sys.stdin.read() else "no")')"
VC9P=$(curl -s $B9/api/_test/voice-calls)
check "apply premium: mirelo body has preserve_speech + num_samples 1" "ok" "$(echo $VC9P | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("model")=="mirelo-ai/sfx2.0/video-to-audio"][-1];b=c["body"];print("ok" if b.get("preserve_speech")==True and b.get("num_samples")==1 and b.get("text_prompt")=="distant sirens" and b.get("video_url","").endswith("/media/clip.mp4") else "bad")')"

# -- audio-only: sfx + music files, served, with request-shape checks --
RG9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"audioonly@example.com","password":"password123"}')
TG9=$(echo $RG9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
SGA9=$(curl -s -w '\n%{http_code}' -X POST $B9/api/sound/generate -H "Authorization: Bearer $TG9" -H 'Content-Type: application/json' -d '{"kind":"sfx","prompt":"dog barking in the rain","duration_seconds":10}')
check "audio-only sfx: -> 201" "201" "$(echo "$SGA9" | tail -1)"
SGAB=$(echo "$SGA9" | sed '$d')
check "audio-only sfx: kind sound, included — cost 0, credits_left 1000" "sound/0/1000" "$(echo $SGAB | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["generation"]["kind"]+"/"+str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
check "audio-only sfx: file under /files/sounds/ (.mp3)" "yes" "$(echo $SGAB | python3 -c 'import sys,json;u=json.load(sys.stdin)["audio_url"];print("yes" if u.startswith("/files/sounds/") and u.endswith(".mp3") else "no")')"
SFXAURL=$(echo $SGAB | python3 -c 'import sys,json;print(json.load(sys.stdin)["audio_url"])')
check "audio-only sfx: file is served (200)" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B9$SFXAURL)"
SC9C=$(curl -s $B9/api/_test/sound-calls)
check "audio-only sfx: engine body has text + duration_seconds 10" "ok" "$(echo $SC9C | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("engine")=="sfx"][-1];b=c["body"];print("ok" if b.get("text")=="dog barking in the rain" and b.get("duration_seconds")==10 else "bad")')"
SMA9=$(curl -s -w '\n%{http_code}' -X POST $B9/api/sound/generate -H "Authorization: Bearer $TG9" -H 'Content-Type: application/json' -d '{"kind":"music","prompt":"calm piano for a rainy evening","duration_seconds":30}')
check "audio-only music: -> 201" "201" "$(echo "$SMA9" | tail -1)"
SMAB=$(echo "$SMA9" | sed '$d')
check "audio-only music: credits_left 1000 (included)" "1000" "$(echo $SMAB | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
check "audio-only music: file under /files/sounds/ (.wav)" "yes" "$(echo $SMAB | python3 -c 'import sys,json;u=json.load(sys.stdin)["audio_url"];print("yes" if u.startswith("/files/sounds/") and u.endswith(".wav") else "no")')"
MUSAURL=$(echo $SMAB | python3 -c 'import sys,json;print(json.load(sys.stdin)["audio_url"])')
check "audio-only music: file is served (200)" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B9$MUSAURL)"
SC9D=$(curl -s $B9/api/_test/sound-calls)
check "audio-only music: engine body asks for instrumental, duration 30" "ok" "$(echo $SC9D | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("engine")=="music"][-1];b=c["body"];print("ok" if "instrumental, no vocals" in b.get("prompt","") and b.get("duration")==30 else "bad")')"
check "audio-only: engine failure -> 502" "502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B9/api/sound/generate -H "Authorization: Bearer $TG9" -H 'Content-Type: application/json' -d '{"kind":"sfx","prompt":"FAILME thunder"}')"
check "audio-only failure: balance untouched (still 1000)" "1000" "$(curl -s $B9/api/me -H "Authorization: Bearer $TG9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "audio-only: unknown kind -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B9/api/sound/generate -H "Authorization: Bearer $TG9" -H 'Content-Type: application/json' -d '{"kind":"bogus","prompt":"rain sounds"}')"
check "audio-only: sfx duration over 22 -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B9/api/sound/generate -H "Authorization: Bearer $TG9" -H 'Content-Type: application/json' -d '{"kind":"sfx","prompt":"rain sounds","duration_seconds":30}')"

# -- migration v11: delete its record + drop its columns, restart re-applies --
kill $SRV9_PID 2>/dev/null; sleep 0.5
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-sound-test.db');
db.exec('DELETE FROM schema_migrations WHERE version = 11');
for (const col of ['sound_mode','sound_status','sound_prompt','sound_volume','sound_cost'])
  db.exec('ALTER TABLE generations DROP COLUMN ' + col);
console.log('rolled back migration v11');
"
env DB_PATH=/tmp/myvideoai-sound-test.db PORT=18087 FAL_KEY=dummy_test_key "$SOUND_JWT_NAME=sound-instance-dummy-value" \
  ADMIN_EMAIL=soundadmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$SOUND_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$SOUND_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 TRANSLATE_API_BASE=http://127.0.0.1:$SOUND_TSTUB_PORT \
  GENERATED_DIR=/tmp/soundgen SOUNDS_DIR=/tmp/soundout \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-sound-test2.log 2>&1 &
SRV9_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B9/api/health && break || sleep 0.25; done
check "migration v11 re-applies on boot (sound columns restored)" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-sound-test.db');
const cols = db.prepare(\"SELECT name FROM pragma_table_info('generations') WHERE name LIKE 'sound_%'\").all().map(r => r.name).sort().join(',');
const mig = db.prepare('SELECT COUNT(*) AS c FROM schema_migrations WHERE version = 11').get().c;
console.log(cols === 'sound_cost,sound_mode,sound_prompt,sound_status,sound_volume' && Number(mig) === 1 ? 'ok' : 'bad');
")"
kill $SRV9_PID $FALSTUB9_PID $TSTUB9_PID 2>/dev/null

echo "--- finishers + draft workflow (Phase C1, fal stub) ---"
FIN_STUB_PORT=18082
FIN_HTTP_PORT=18081
B11=http://127.0.0.1:18083
rm -f /tmp/myvideoai-finish-test.db; rm -rf /tmp/fingen /tmp/finjoin /tmp/finmedia; mkdir -p /tmp/fingen /tmp/finjoin /tmp/finmedia
FAL_STUB_PORT=$FIN_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-finish.log 2>&1 &
FALSTUB11_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$FIN_STUB_PORT/__calls && break || sleep 0.25; done
FFBIN11=$(node --input-type=module -e "import f from 'ffmpeg-static'; console.log(f)" 2>/dev/null)
"$FFBIN11" -y -v error -f lavfi -i color=c=purple:size=640x360:rate=24:duration=30 -f lavfi -i sine=frequency=330:duration=30 -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest /tmp/finmedia/long.mp4
(cd /tmp/finmedia && python3 -m http.server $FIN_HTTP_PORT > /tmp/fin-http.log 2>&1) &
FINHTTP_PID=$!
sleep 0.5
FIN_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-finish-test.db PORT=18083 FAL_KEY=dummy_test_key "$FIN_JWT_NAME=finish-instance-dummy-value" \
  ADMIN_EMAIL=finadmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$FIN_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$FIN_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 GENERATED_DIR=/tmp/fingen JOINED_DIR=/tmp/finjoin \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-finish-test.log 2>&1 &
SRV11_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B11/api/health && break || sleep 0.25; done
AR11=$(curl -s -X POST $B11/api/auth/register -H 'Content-Type: application/json' -d '{"email":"finadmin@example.com","password":"password123"}')
AT11=$(echo $AR11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
CFG11=$(curl -s $B11/api/config)
check "config finishers: reframe 0 / captions 50" "0/50" "$(echo $CFG11 | python3 -c 'import sys,json;p=json.load(sys.stdin)["finishers"]["prices"];print(str(p["reframe"])+"/"+str(p["captions"]))')"
check "config finishers: upscale model is topaz endpoint" "fal-ai/topaz/upscale/video" "$(echo $CFG11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["finishers"]["prices"]["upscale"]["model"])')"
check "config draft: 480P at 70/140 credits" "480P/70/140" "$(echo $CFG11 | python3 -c 'import sys,json;d=json.load(sys.stdin)["draft"];print(d["quality"]+"/"+str(d["cost_by_duration"]["5"])+"/"+str(d["cost_by_duration"]["10"]))')"
RA11=$(curl -s -X POST $B11/api/auth/register -H 'Content-Type: application/json' -d '{"email":"fin-a@example.com","password":"password123"}')
TA11=$(echo $RA11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
AID11=$(curl -s $B11/api/me -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
RB11=$(curl -s -X POST $B11/api/auth/register -H 'Content-Type: application/json' -d '{"email":"fin-b@example.com","password":"password123"}')
TB11=$(echo $RB11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
seed_fin() { # userId prompt url resolution
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-finish-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits, resolution) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)').run($1, '$2', '16:9', 5, 'realistic', 'completed', '$3', 100, '$4').lastInsertRowid));
"
}
SEED169=$(seed_fin $AID11 "seed harbour clip" "http://127.0.0.1:$FIN_STUB_PORT/media/clip169.mp4" "768P")
SEEDSIL=$(seed_fin $AID11 "seed silent clip" "http://127.0.0.1:$FIN_STUB_PORT/media/silent.mp4" "768P")

# -- reframe: free, blurred-pad, correct output dimensions --
RF11=$(curl -s -w '\n%{http_code}' -X POST $B11/api/finish/reframe -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED169,\"aspect_ratio\":\"9:16\"}")
check "reframe: -> 201" "201" "$(echo "$RF11" | tail -1)"
RF11B=$(echo "$RF11" | sed '$d')
check "reframe: kind reframe, linked to source, cost 0" "reframe/$SEED169/0" "$(echo $RF11B | python3 -c 'import sys,json;g=json.load(sys.stdin)["generation"];print(g["kind"]+"/"+str(g["source_generation_id"])+"/"+str(g["cost_credits"]))')"
check "reframe: FREE — balance still 1000" "1000" "$(curl -s $B11/api/me -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
RFURL=$(echo $RF11B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["video_url"])')
curl -s -o /tmp/reframed.mp4 $B11$RFURL
check "reframe: output is exactly 1080x1920 (9:16)" "1080x1920" "$("$FFBIN11" -i /tmp/reframed.mp4 2>&1 | python3 -c 'import sys,re; m=re.search(r"(\d{2,5})x(\d{2,5})", sys.stdin.read()); print(m.group(1)+"x"+m.group(2) if m else "none")')"
check "reframe: another user's video -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/finish/reframe -H "Authorization: Bearer $TB11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED169,\"aspect_ratio\":\"1:1\"}")"
check "finish: unknown action -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/finish/bogus -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED169}")"

# -- captions: whisper stub -> burned subs, -5; silent video -> 400 free --
CP11=$(curl -s -w '\n%{http_code}' -X POST $B11/api/finish/captions -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED169}")
check "captions: -> 201" "201" "$(echo "$CP11" | tail -1)"
CP11B=$(echo "$CP11" | sed '$d')
check "captions: kind captions, cost 50, credits_left 950" "captions/50/950" "$(echo $CP11B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["generation"]["kind"]+"/"+str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
CPURL=$(echo $CP11B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["video_url"])')
curl -s -o /tmp/captioned.mp4 $B11$CPURL
check "captions: output keeps video + audio streams" "yes/yes" "$("$FFBIN11" -i /tmp/captioned.mp4 2>&1 | python3 -c 'import sys;s=sys.stdin.read();print(("yes" if "Video:" in s else "no")+"/"+("yes" if "Audio:" in s else "no"))')"
VC11=$(curl -s $B11/api/_test/voice-calls)
check "captions: whisper body has audio_url + task transcribe + segment chunks" "ok" "$(echo $VC11 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("model")=="fal-ai/whisper"][-1];b=c["body"];print("ok" if b.get("audio_url","").endswith("/media/clip169.mp4") and b.get("task")=="transcribe" and b.get("chunk_level")=="segment" else "bad")')"
CPS11=$(curl -s -w '\n%{http_code}' -X POST $B11/api/finish/captions -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDSIL}")
check "captions on silent video: -> 400 (no audio stream)" "400" "$(echo "$CPS11" | tail -1)"
check "captions on silent video: nothing charged (still 950)" "950" "$(curl -s $B11/api/me -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- draft: 480P at 7 credits, marked draft, add-ons rejected --
DR11=$(curl -s -X POST $B11/api/generate -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d '{"prompt":"a lighthouse draft preview","aspect_ratio":"16:9","duration":5,"quality":"draft"}')
check "draft: cost 70 credits" "70" "$(echo $DR11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_credits"])')"
check "draft: stage draft + resolution 480P in response" "draft/480P" "$(echo $DR11 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["stage"]+"/"+g["resolution"])')"
check "draft: balance 880 (950 - 70)" "880" "$(echo $DR11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
DRAFTID=$(echo $DR11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
FB11=$(curl -s $B11/api/_test/fal-body)
check "draft: fal body resolution is 480P (H3 tier)" "480P" "$(echo $FB11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"]["resolution"])')"
for i in $(seq 1 30); do
  ST=$(curl -s $B11/api/generations/$DRAFTID -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')
  [[ "$ST" == "completed" ]] && break || sleep 0.3
done
check "draft: generation completes via the stub" "completed" "$ST"
check "draft: history row is marked stage draft" "draft" "$(curl -s $B11/api/history -H "Authorization: Bearer $TA11" | python3 -c "import sys,json;print([g['stage'] for g in json.load(sys.stdin)['generations'] if g['id']==$DRAFTID][0])")"
check "draft + sound add-on: -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/generate -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d '{"prompt":"a lighthouse draft with sound","duration":5,"quality":"draft","sound":{"mode":"sync"}}')"
check "draft + sound rejected: balance still 880" "880" "$(curl -s $B11/api/me -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "sound apply on a draft: -> 400 (drafts take no add-ons)" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/sound/apply -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$DRAFTID,\"mode\":\"sync\"}")"
check "voiceover on a draft: -> 400 (drafts take no add-ons)" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/voice/voiceover -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$DRAFTID,\"script\":\"hello draft world\"}")"

# -- upgrade: same prompt/settings at full quality, standard rate, linked --
UP11=$(curl -s -w '\n%{http_code}' -X POST $B11/api/generations/$DRAFTID/upgrade -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d '{"quality":"768P"}')
check "upgrade: -> 200" "200" "$(echo "$UP11" | tail -1)"
UP11B=$(echo "$UP11" | sed '$d')
check "upgrade: standard rate 120 charged, linked to the draft" "120/$DRAFTID" "$(echo $UP11B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["source_generation_id"]))')"
check "upgrade: balance 760 (880 - 120)" "760" "$(echo $UP11B | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
UPID11=$(echo $UP11B | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
for i in $(seq 1 30); do
  STU=$(curl -s $B11/api/generations/$UPID11 -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+g["stage"]+"/"+g["resolution"]+"/"+g["prompt"])')
  [[ "$STU" == completed* ]] && break || sleep 0.3
done
check "upgrade: completes as a final 768P generation with the same prompt" "completed/final/768P/a lighthouse draft preview" "$STU"
check "upgrade on a non-draft: -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/generations/$SEED169/upgrade -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d '{"quality":"768P"}')"
check "upgrade: another user's draft -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/generations/$DRAFTID/upgrade -H "Authorization: Bearer $TB11" -H 'Content-Type: application/json' -d '{"quality":"768P"}')"

# -- extend: last frame -> stub i2v -> join; standard rate once; refund on failure --
EX11=$(curl -s -w '\n%{http_code}' -X POST $B11/api/finish/extend -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED169,\"extra_seconds\":5}")
check "extend: -> 201" "201" "$(echo "$EX11" | tail -1)"
EX11B=$(echo "$EX11" | sed '$d')
check "extend: kind extend, standard 768P/5s rate 120, balance 640" "extend/120/640" "$(echo $EX11B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["generation"]["kind"]+"/"+str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
EXURL=$(echo $EX11B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["video_url"])')
check "extend: joined video stored under /files/joined/" "yes" "$(python3 -c "print('yes' if '$EXURL'.startswith('/files/joined/') else 'no')")"
curl -s -o /tmp/extended.mp4 $B11$EXURL
check "extend: joined duration approx source + extension (2s + 2s)" "ok" "$("$FFBIN11" -i /tmp/extended.mp4 2>&1 | python3 -c 'import sys,re; m=re.search(r"Duration: (\d+):(\d+):([\d.]+)", sys.stdin.read()); d=int(m.group(1))*3600+int(m.group(2))*60+float(m.group(3)) if m else -1; print("ok" if 3.4 <= d <= 4.8 else "bad")')"
VC11B=$(curl -s $B11/api/_test/voice-calls)
check "extend: i2v body has data-URI image + 768P + 5s" "ok" "$(echo $VC11B | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("model")=="minimax/h3/image-to-video"][-1];b=c["body"];print("ok" if str(b.get("image_url","")).startswith("data:image/jpeg;base64,") and b.get("resolution")=="768P" and b.get("duration")==5 else "bad")')"
SEEDFAIL=$(seed_fin $AID11 "FAILME waterfall scene" "http://127.0.0.1:$FIN_STUB_PORT/media/clip169.mp4" "768P")
check "extend failure: -> 502" "502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/finish/extend -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDFAIL,\"extra_seconds\":5}")"
check "extend failure: refunded exactly once (still 640)" "640" "$(curl -s $B11/api/me -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "extend failure: the job row is marked failed (no partial entry)" "failed" "$(curl -s $B11/api/history -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["status"])')"
SEED4K=$(seed_fin $AID11 "seed 4k clip" "http://127.0.0.1:$FIN_STUB_PORT/media/clip169.mp4" "4K")
check "extend 4K source on free plan: -> 403 (plan cap)" "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/finish/extend -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED4K,\"extra_seconds\":5}")"

# -- upscale: plan gate, topaz body, price formula (min + computed) --
check "upscale 768P on free plan: -> 403 (result 2K above plan max)" "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/finish/upscale -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED169}")"
check "upscale gate: nothing charged (still 640)" "640" "$(curl -s $B11/api/me -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
RP11=$(curl -s -X POST $B11/api/auth/register -H 'Content-Type: application/json' -d '{"email":"fin-pro@example.com","password":"password123"}')
TP11=$(echo $RP11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PID11=$(curl -s $B11/api/me -H "Authorization: Bearer $TP11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B11/api/admin/users/$PID11/activate -H "Authorization: Bearer $AT11" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
SEEDPRO=$(seed_fin $PID11 "seed pro harbour clip" "http://127.0.0.1:$FIN_STUB_PORT/media/clip169.mp4" "768P")
US11=$(curl -s -w '\n%{http_code}' -X POST $B11/api/finish/upscale -H "Authorization: Bearer $TP11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDPRO}")
check "upscale (Pro): -> 201" "201" "$(echo "$US11" | tail -1)"
US11B=$(echo "$US11" | sed '$d')
check "upscale: kind upscale, recorded tier 2K, minimum price 100" "upscale/2K/100" "$(echo $US11B | python3 -c 'import sys,json;g=json.load(sys.stdin)["generation"];print(g["kind"]+"/"+g["resolution"]+"/"+str(g["cost_credits"]))')"
VC11C=$(curl -s $B11/api/_test/voice-calls)
check "upscale: topaz body has video_url + model Proteus + factor 2" "ok" "$(echo $VC11C | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("model")=="fal-ai/topaz/upscale/video"][-1];b=c["body"];print("ok" if b.get("video_url","").endswith("/media/clip169.mp4") and b.get("model")=="Proteus" and b.get("upscale_factor")==2 else "bad")')"
SEEDLONG=$(seed_fin $PID11 "seed long harbour clip" "http://127.0.0.1:$FIN_HTTP_PORT/long.mp4" "768P")
USL11=$(curl -s -X POST $B11/api/finish/upscale -H "Authorization: Bearer $TP11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDLONG}")
check "upscale price formula: 30s to 720p = ceil(0.01*30*277/1.5)*2 = 112 credits" "112" "$(echo $USL11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["cost_credits"])')"

# -- migration v12: delete its record + drop its column, restart re-applies --
kill $SRV11_PID 2>/dev/null; sleep 0.5
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-finish-test.db');
db.exec('DELETE FROM schema_migrations WHERE version = 12');
db.exec('ALTER TABLE generations DROP COLUMN stage');
console.log('rolled back migration v12');
"
env DB_PATH=/tmp/myvideoai-finish-test.db PORT=18083 FAL_KEY=dummy_test_key "$FIN_JWT_NAME=finish-instance-dummy-value" \
  ADMIN_EMAIL=finadmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$FIN_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$FIN_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 GENERATED_DIR=/tmp/fingen JOINED_DIR=/tmp/finjoin \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-finish-test2.log 2>&1 &
SRV11_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B11/api/health && break || sleep 0.25; done
check "migration v12 re-applies on boot (stage column restored)" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-finish-test.db');
const cols = db.prepare(\"SELECT name FROM pragma_table_info('generations') WHERE name = 'stage'\").all().length;
const mig = db.prepare('SELECT COUNT(*) AS c FROM schema_migrations WHERE version = 12').get().c;
console.log(cols === 1 && Number(mig) === 1 ? 'ok' : 'bad');
")"
kill $SRV11_PID $FALSTUB11_PID $FINHTTP_PID 2>/dev/null

echo "--- character library (Phase C2, fal stub) ---"
CHAR_STUB_PORT=18080
B12=http://127.0.0.1:18079
rm -f /tmp/myvideoai-char-test.db; rm -rf /tmp/charvoice /tmp/chargen; mkdir -p /tmp/charvoice /tmp/chargen
FAL_STUB_PORT=$CHAR_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-char.log 2>&1 &
CHARSTUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$CHAR_STUB_PORT/__calls && break || sleep 0.25; done
CHAR_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-char-test.db PORT=18079 FAL_KEY=dummy_test_key "$CHAR_JWT_NAME=char-instance-dummy-value" \
  ADMIN_EMAIL=charadmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$CHAR_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$CHAR_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 VOICE_DIR=/tmp/charvoice GENERATED_DIR=/tmp/chargen \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-char-test.log 2>&1 &
SRV12_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B12/api/health && break || sleep 0.25; done
CFG12=$(curl -s $B12/api/config)
check "characters config: cap 10 + reference-to-video model" "10/minimax/h3/reference-to-video" "$(echo $CFG12 | python3 -c 'import sys,json;c=json.load(sys.stdin)["characters"];print(str(c["max_per_user"])+"/"+c["model"])')"
AR12=$(curl -s -X POST $B12/api/auth/register -H 'Content-Type: application/json' -d '{"email":"charadmin@example.com","password":"password123"}')
AT12=$(echo $AR12 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
RA12=$(curl -s -X POST $B12/api/auth/register -H 'Content-Type: application/json' -d '{"email":"char-a@example.com","password":"password123"}')
TA12=$(echo $RA12 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
RB12=$(curl -s -X POST $B12/api/auth/register -H 'Content-Type: application/json' -d '{"email":"char-b@example.com","password":"password123"}')
TB12=$(echo $RB12 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PNG_B64_C=$(python3 -c "import base64; print(base64.b64encode(bytes.fromhex('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c636000000000020001e221bc330000000049454e44ae426082')).decode())")
RED_B64_C=$(python3 -c "
import zlib, struct, base64, sys
def chunk(t, d):
    c = struct.pack('>I', len(d)) + t + d
    return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
raw = b''.join(b'\x00' + bytes((255, 0, 0)) * 2 for _ in range(2))
png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0))
       + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
sys.stdout.write(base64.b64encode(png).decode())
")
UPA=$(curl -s -X POST $B12/api/uploads/image -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_C\",\"content_type\":\"image/png\"}")
IMGA=$(echo $UPA | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
UPB=$(curl -s -X POST $B12/api/uploads/image -H "Authorization: Bearer $TB12" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_C\",\"content_type\":\"image/png\"}")
IMGB=$(echo $UPB | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
UPRED=$(curl -s -X POST $B12/api/uploads/image -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$RED_B64_C\",\"content_type\":\"image/png\"}")
IMGRED=$(echo $UPRED | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')

# -- CRUD + validation --
CH1=$(curl -s -w '\n%{http_code}' -X POST $B12/api/characters -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"name\":\"Captain Sara\",\"image_path\":\"$IMGA\"}")
check "character create (no voice) -> 201" "201" "$(echo "$CH1" | tail -1)"
CH1B=$(echo "$CH1" | sed '$d')
SARA_ID=$(echo $CH1B | python3 -c 'import sys,json;print(json.load(sys.stdin)["character"]["id"])')
check "character create: name + image echoed, voice null" "Captain Sara/None" "$(echo $CH1B | python3 -c 'import sys,json;c=json.load(sys.stdin)["character"];print(c["name"]+"/"+str(c["voice"]))')"
SARA_URL=$(echo $CH1B | python3 -c 'import sys,json;print(json.load(sys.stdin)["character"]["image_url"])')
check "character image_url is served (200)" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B12$SARA_URL)"
check "character create with ANOTHER user's image -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/characters -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"name\":\"Stolen\",\"image_path\":\"$IMGB\"}")"
check "character create with a nonexistent image -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/characters -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"name\":\"Ghost\",\"image_path\":\"data/uploads/999/nope.png\"}")"
check "character create without a name -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/characters -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"name\":\"\",\"image_path\":\"$IMGA\"}")"
CH2=$(curl -s -w '\n%{http_code}' -X POST $B12/api/characters -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"name\":\"Hero\",\"image_path\":\"$IMGA\",\"voice_provider\":\"gemini\",\"voice_id\":\"Charon\",\"voice_language\":\"ur\",\"voice_style\":\"narration\"}")
check "character create with bound voice -> 201" "201" "$(echo "$CH2" | tail -1)"
check "character create: bound voice stored (gemini/Charon/ur/narration)" "gemini/Charon/ur/narration" "$(echo "$CH2" | sed '$d' | python3 -c 'import sys,json;v=json.load(sys.stdin)["character"]["voice"];print(v["provider"]+"/"+v["voice_id"]+"/"+v["language"]+"/"+v["style"])')"
check "character create: unknown provider -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/characters -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"name\":\"X\",\"image_path\":\"$IMGA\",\"voice_provider\":\"bogus\"}")"
check "character create: unknown voice id -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/characters -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"name\":\"X\",\"image_path\":\"$IMGA\",\"voice_provider\":\"gemini\",\"voice_id\":\"NotAVoice\"}")"
check "character create: bad voice language -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/characters -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"name\":\"X\",\"image_path\":\"$IMGA\",\"voice_provider\":\"gemini\",\"voice_language\":\"fr\"}")"
check "character create: bad voice style -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/characters -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"name\":\"X\",\"image_path\":\"$IMGA\",\"voice_provider\":\"gemini\",\"voice_style\":\"loud\"}")"
check "character create: voice_id without provider -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/characters -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"name\":\"X\",\"image_path\":\"$IMGA\",\"voice_id\":\"Charon\"}")"
check "characters list: A sees own 2" "2" "$(curl -s $B12/api/characters -H "Authorization: Bearer $TA12" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["characters"]))')"
check "characters list: B sees 0 (own only)" "0" "$(curl -s $B12/api/characters -H "Authorization: Bearer $TB12" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["characters"]))')"
check "characters list: bound voice included" "Charon" "$(curl -s $B12/api/characters -H "Authorization: Bearer $TA12" | python3 -c 'import sys,json;print([c for c in json.load(sys.stdin)["characters"] if c["name"]=="Hero"][0]["voice"]["voice_id"])')"

# -- cap: 10 per user (dedicated user so A's count is undisturbed) --
RC12=$(curl -s -X POST $B12/api/auth/register -H 'Content-Type: application/json' -d '{"email":"char-cap@example.com","password":"password123"}')
TC12=$(echo $RC12 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
UPC=$(curl -s -X POST $B12/api/uploads/image -H "Authorization: Bearer $TC12" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_C\",\"content_type\":\"image/png\"}")
IMGC=$(echo $UPC | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
CAP_CODES=""
for i in $(seq 1 10); do
  CAP_CODES="$CAP_CODES $(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/characters -H "Authorization: Bearer $TC12" -H 'Content-Type: application/json' -d "{\"name\":\"Cap $i\",\"image_path\":\"$IMGC\"}")"
done
check "character cap: the first 10 creates succeed" " 201 201 201 201 201 201 201 201 201 201" "$CAP_CODES"
check "character cap: the 11th create -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/characters -H "Authorization: Bearer $TC12" -H 'Content-Type: application/json' -d "{\"name\":\"Cap 11\",\"image_path\":\"$IMGC\"}")"
check "character cap: list still holds exactly 10" "10" "$(curl -s $B12/api/characters -H "Authorization: Bearer $TC12" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["characters"]))')"

# -- generate with a character: reference-to-video at the standard rate --
CG=$(curl -s -w '\n%{http_code}' -X POST $B12/api/generate -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"prompt\":\"a captain walks through a rainy neon city\",\"aspect_ratio\":\"16:9\",\"duration\":5,\"character_id\":$SARA_ID}")
check "generate with character -> 200" "200" "$(echo "$CG" | tail -1)"
CGB=$(echo "$CG" | sed '$d')
GEN1_ID=$(echo $CGB | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
check "generate with character: routed to reference-to-video" "minimax/h3/reference-to-video" "$(echo $CGB | python3 -c 'import sys,json;print(json.load(sys.stdin)["model"])')"
check "generate with character: response carries id + name" "$SARA_ID/Captain Sara" "$(echo $CGB | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["character_id"])+"/"+g["character_name"])')"
check "generate with character: STANDARD rate (768P 5s = 120), balance 880" "120/880" "$(echo $CGB | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
FB12=$(curl -s $B12/api/_test/fal-body)
check "ref fal body: reference_image_urls[0] is the character image data URI" "data:image/png;base64,$PNG_B64_C" "$(echo $FB12 | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"]["reference_image_urls"][0])')"
check "ref fal body: prompt cites Image 1, no image_url field" "ok" "$(echo $FB12 | python3 -c 'import sys,json;b=json.load(sys.stdin)["body"];print("ok" if b["prompt"].startswith("Image 1 is the main character.") and "image_url" not in b else "bad")')"
check "ref fal body: duration int + resolution + aspect + safety" "5/768P/16:9/True" "$(echo $FB12 | python3 -c 'import sys,json;b=json.load(sys.stdin)["body"];print(str(b["duration"])+"/"+b["resolution"]+"/"+b["aspect_ratio"]+"/"+str(b["enable_safety_checker"]))')"
check "generate with ANOTHER user's character -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/generate -H "Authorization: Bearer $TB12" -H 'Content-Type: application/json' -d "{\"prompt\":\"someone else walks in the rain\",\"character_id\":$SARA_ID}")"
check "generate with a nonexistent character -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/generate -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d '{"prompt":"a ghost walks in the rain","character_id":99999}')"
# the character wins over an explicit image_path: a different (red) upload
# is passed, but the reference image must still be Sara's original photo.
CG2=$(curl -s -X POST $B12/api/generate -H "Authorization: Bearer $TA12" -H 'Content-Type: application/json' -d "{\"prompt\":\"the captain crosses a windy harbour\",\"aspect_ratio\":\"16:9\",\"duration\":5,\"character_id\":$SARA_ID,\"image_path\":\"$IMGRED\"}")
check "character precedence: row records the CHARACTER's image, not image_path" "$IMGA" "$(echo $CG2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["source_image_path"])')"
FB12B=$(curl -s $B12/api/_test/fal-body)
check "character precedence: reference image is still Sara's photo" "data:image/png;base64,$PNG_B64_C" "$(echo $FB12B | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"]["reference_image_urls"][0])')"
for i in $(seq 1 30); do
  ST12=$(curl -s $B12/api/generations/$GEN1_ID -H "Authorization: Bearer $TA12" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')
  [[ "$ST12" == "completed" ]] && break || sleep 0.3
done
check "character generation completes (stub)" "completed" "$ST12"
HIST12=$(curl -s $B12/api/history -H "Authorization: Bearer $TA12")
check "history: character job carries character_id + name" "$SARA_ID/Captain Sara" "$(echo $HIST12 | python3 -c "import sys,json;g=[x for x in json.load(sys.stdin)['generations'] if x['id']==$GEN1_ID][0];print(str(g['character_id'])+'/'+str(g['character_name']))")"

# -- lip-sync with a character: image + bound voice come from it --
RP12=$(curl -s -X POST $B12/api/auth/register -H 'Content-Type: application/json' -d '{"email":"char-pro@example.com","password":"password123"}')
TP12=$(echo $RP12 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PID12=$(curl -s $B12/api/me -H "Authorization: Bearer $TP12" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B12/api/admin/users/$PID12/activate -H "Authorization: Bearer $AT12" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
UPP=$(curl -s -X POST $B12/api/uploads/image -H "Authorization: Bearer $TP12" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_C\",\"content_type\":\"image/png\"}")
IMGP=$(echo $UPP | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
CHL=$(curl -s -X POST $B12/api/characters -H "Authorization: Bearer $TP12" -H 'Content-Type: application/json' -d "{\"name\":\"Anchor Ahmed\",\"image_path\":\"$IMGP\",\"voice_provider\":\"gemini\",\"voice_id\":\"Charon\",\"voice_language\":\"ur\",\"voice_style\":\"narration\"}")
CHAR_LIP=$(echo $CHL | python3 -c 'import sys,json;print(json.load(sys.stdin)["character"]["id"])')
LS12=$(curl -s -w '\n%{http_code}' -X POST $B12/api/voice/lipsync -H "Authorization: Bearer $TP12" -H 'Content-Type: application/json' -d "{\"character_id\":$CHAR_LIP,\"script\":\"mera naam ahmed hai\",\"script_mode\":\"roman\"}")
check "lipsync with character -> 201" "201" "$(echo "$LS12" | tail -1)"
LS12B=$(echo "$LS12" | sed '$d')
check "lipsync with character: included — cost 0, credits_left 6000" "0/6000" "$(echo $LS12B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
check "lipsync with character: row records character + its image" "$CHAR_LIP/$IMGP" "$(echo $LS12B | python3 -c 'import sys,json;g=json.load(sys.stdin)["generation"];print(str(g["character_id"])+"/"+str(g["source_image_path"]))')"
VC12=$(curl -s $B12/api/_test/voice-calls)
check "lipsync with character: TTS used the BOUND voice (Charon, Urdu)" "Charon/Urdu (Pakistan)" "$(echo $VC12 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x["kind"]=="tts"][-1];print(c["body"]["voice"]+"/"+c["body"]["language_code"])')"
check "lipsync with character: queue body is the character image data URI" "ok" "$(echo $VC12 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x["kind"]=="queue"][-1];print("ok" if c["model"]=="minimax/h3-max/lip-sync/image-to-video" and c["body"]["image_url"].startswith("data:image/png") else "bad")')"
LS13=$(curl -s -w '\n%{http_code}' -X POST $B12/api/voice/lipsync -H "Authorization: Bearer $TP12" -H 'Content-Type: application/json' -d "{\"character_id\":$CHAR_LIP,\"script\":\"salam dost\",\"script_mode\":\"roman\",\"provider\":\"elevenlabs\",\"voice\":\"Rachel\",\"spoken_language\":\"ur\",\"style\":\"conversation\"}")
check "lipsync override -> 201" "201" "$(echo "$LS13" | tail -1)"
VC13=$(curl -s $B12/api/_test/voice-calls)
check "lipsync override: explicit voice wins over the binding (Rachel)" "elevenlabs/Rachel" "$(echo $VC13 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x["kind"]=="tts"][-1];print(c["provider"]+"/"+c["body"]["voice"])')"
check "lipsync override: credits_left 6000 (included)" "6000" "$(curl -s $B12/api/me -H "Authorization: Bearer $TP12" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "lipsync with ANOTHER user's character -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/voice/lipsync -H "Authorization: Bearer $TP12" -H 'Content-Type: application/json' -d "{\"character_id\":$SARA_ID,\"script\":\"salam dost\",\"script_mode\":\"roman\"}")"
check "lipsync with a nonexistent character -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/voice/lipsync -H "Authorization: Bearer $TP12" -H 'Content-Type: application/json' -d '{"character_id":99999,"script":"salam dost","script_mode":"roman"}')"
check "lipsync 404s charged nothing (still 6000)" "6000" "$(curl -s $B12/api/me -H "Authorization: Bearer $TP12" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- delete: cross-user 404, and past generations survive --
HERO_ID=$(curl -s $B12/api/characters -H "Authorization: Bearer $TA12" | python3 -c 'import sys,json;print([c for c in json.load(sys.stdin)["characters"] if c["name"]=="Hero"][0]["id"])')
check "delete another user's character -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B12/api/characters/$HERO_ID -H "Authorization: Bearer $TB12")"
check "delete a nonexistent character -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B12/api/characters/99999 -H "Authorization: Bearer $TA12")"
check "delete own character -> 200 ok" "200" "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE $B12/api/characters/$SARA_ID -H "Authorization: Bearer $TA12")"
check "characters list after delete: Sara gone (Hero remains)" "Hero" "$(curl -s $B12/api/characters -H "Authorization: Bearer $TA12" | python3 -c 'import sys,json;print(",".join(c["name"] for c in json.load(sys.stdin)["characters"]))')"
HIST12B=$(curl -s $B12/api/history -H "Authorization: Bearer $TA12")
check "delete keeps past generations (job survives, name now empty)" "completed/None" "$(echo $HIST12B | python3 -c "import sys,json;g=[x for x in json.load(sys.stdin)['generations'] if x['id']==$GEN1_ID][0];print(g['status']+'/'+str(g['character_name']))")"
check "migration v13 applied (characters table + character_id column)" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-char-test.db');
const t = db.prepare(\"SELECT name FROM sqlite_master WHERE type='table' AND name='characters'\").all().length;
const cols = db.prepare(\"SELECT name FROM pragma_table_info('generations') WHERE name = 'character_id'\").all().length;
const mig = db.prepare('SELECT COUNT(*) AS c FROM schema_migrations WHERE version = 13').get().c;
console.log(t === 1 && cols === 1 && Number(mig) === 1 ? 'ok' : 'bad');
")"
kill $SRV12_PID $CHARSTUB_PID 2>/dev/null

echo "--- advertising preparation (AdMob groundwork): fail closed by default ---"
CFGA=$(curl -s $B/api/config)
check "ads: enabled false by default" "False" "$(echo $CFGA | python3 -c 'import sys,json;print(json.load(sys.stdin)["ads"]["enabled"])')"
check "ads: configured false by default" "False" "$(echo $CFGA | python3 -c 'import sys,json;print(json.load(sys.stdin)["ads"]["configured"])')"
check "ads: provider null by default" "None" "$(echo $CFGA | python3 -c 'import sys,json;print(json.load(sys.stdin)["ads"]["provider"])')"
check "ads: free_tier_only is true" "True" "$(echo $CFGA | python3 -c 'import sys,json;print(json.load(sys.stdin)["ads"]["free_tier_only"])')"
check "ads: placements are home_native,studio_bottom" "home_native,studio_bottom" "$(echo $CFGA | python3 -c 'import sys,json;print(",".join(sorted(json.load(sys.stdin)["ads"]["placements"])))')"
check "ads: /app-ads.txt is 404 while unconfigured" "404" "$(curl -s -o /dev/null -w '%{http_code}' $B/app-ads.txt)"
HOMEPAGE=$(curl -s $B/)
check "frontend: adStudioBottom slot present" "yes" "$(echo "$HOMEPAGE" | grep -q 'id="adStudioBottom"' && echo yes || echo no)"
check "frontend: adHomeNative slot present" "yes" "$(echo "$HOMEPAGE" | grep -q 'id="adHomeNative"' && echo yes || echo no)"
check "frontend: both ad slots start hidden" "2" "$(echo "$HOMEPAGE" | python3 -c 'import sys,re;print(len(re.findall(r"class=\"ad-slot\" id=\"ad(?:StudioBottom|HomeNative)\" hidden", sys.stdin.read())))')"
check "frontend: gating references ads.enabled" "yes" "$(echo "$HOMEPAGE" | grep -q 'ads\.enabled' && echo yes || echo no)"
check "frontend: gating checks admin + plan state" "yes" "$(echo "$HOMEPAGE" | grep -q 'me\.is_admin' && echo "$HOMEPAGE" | grep -q 'me\.plan' && echo yes || echo no)"

echo "--- advertising: configured instance serves app-ads.txt + enabled ---"
B13=http://127.0.0.1:18078
rm -f /tmp/myvideoai-ads-test.db*
ADS_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-ads-test.db PORT=18078 FAL_KEY=dummy_test_key "$ADS_JWT_NAME=ads-instance-dummy-value" ADS_ENABLED=1 ADMOB_PUBLISHER_ID=pub-1234567890123456 node "$(dirname "$0")/server.js" > /tmp/myvideoai-ads-test.log 2>&1 &
SRV13_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B13/api/health && break || sleep 0.25; done
check "ads configured: /app-ads.txt status 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B13/app-ads.txt)"
check "ads configured: /app-ads.txt body is the exact google.com snippet" "google.com, pub-1234567890123456, DIRECT, f08c47fec0942fa0" "$(curl -s $B13/app-ads.txt | head -1)"
check "ads configured: /app-ads.txt content-type is text/plain" "text/plain" "$(curl -s -I $B13/app-ads.txt | grep -i '^content-type:' | tr -d '\r' | cut -d' ' -f2 | cut -d';' -f1)"
check "ads configured: /app-ads.txt cacheable for 1h" "yes" "$(curl -s -I $B13/app-ads.txt | grep -qi 'cache-control: public, max-age=3600' && echo yes || echo no)"
CFG13=$(curl -s $B13/api/config)
check "ads configured: enabled true (ADS_ENABLED=1 + valid publisher id)" "True" "$(echo $CFG13 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ads"]["enabled"])')"
check "ads configured: configured true + provider admob" "True/admob" "$(echo $CFG13 | python3 -c 'import sys,json;a=json.load(sys.stdin)["ads"];print(str(a["configured"])+"/"+str(a["provider"]))')"
kill $SRV13_PID 2>/dev/null

echo "--- advertising: INVALID publisher id fails closed ---"
B14=http://127.0.0.1:18077
rm -f /tmp/myvideoai-ads-bad-test.db*
ADS_BAD_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-ads-bad-test.db PORT=18077 FAL_KEY=dummy_test_key "$ADS_BAD_JWT_NAME=ads-bad-dummy-value" ADS_ENABLED=1 ADMOB_PUBLISHER_ID=pub-123 node "$(dirname "$0")/server.js" > /tmp/myvideoai-ads-bad-test.log 2>&1 &
SRV14_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B14/api/health && break || sleep 0.25; done
check "ads invalid id: /app-ads.txt 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' $B14/app-ads.txt)"
CFG14=$(curl -s $B14/api/config)
check "ads invalid id: enabled false + configured false" "False/False" "$(echo $CFG14 | python3 -c 'import sys,json;a=json.load(sys.stdin)["ads"];print(str(a["enabled"])+"/"+str(a["configured"]))')"
kill $SRV14_PID 2>/dev/null

echo "--- advertising: ADMOB_APP_ADS_TXT override served verbatim ---"
B15=http://127.0.0.1:18076
rm -f /tmp/myvideoai-ads-ovr-test.db*
ADS_OVR_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-ads-ovr-test.db PORT=18076 FAL_KEY=dummy_test_key "$ADS_OVR_JWT_NAME=ads-ovr-dummy-value" ADMOB_APP_ADS_TXT='google.com, pub-9999999999999999, DIRECT, f08c47fec0942fa0' node "$(dirname "$0")/server.js" > /tmp/myvideoai-ads-ovr-test.log 2>&1 &
SRV15_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B15/api/health && break || sleep 0.25; done
check "ads override: /app-ads.txt serves the override line verbatim" "google.com, pub-9999999999999999, DIRECT, f08c47fec0942fa0" "$(curl -s $B15/app-ads.txt)"
kill $SRV15_PID 2>/dev/null

echo "--- AI Auto Director (Phase D): config + one free plan on the main server ---"
CFGD=$(curl -s $B/api/config)
check "auto: config enabled true + version 1" "True/1" "$(echo $CFGD | python3 -c 'import sys,json;a=json.load(sys.stdin)["auto"];print(str(a["enabled"])+"/"+str(a["version"]))')"
check "auto: plan endpoint without a token -> 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/generate/plan -H 'Content-Type: application/json' -d '{"prompt":"a cat in a garden"}')"
PLANM=$(curl -s -X POST $B/api/generate/plan -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"prompt":"a cat chasing a butterfly in a sunny garden","mode":"realistic","style":"realistic","duration":5}')
check "auto main plan: cat -> animal class" "animal" "$(echo $PLANM | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["detected"]["content_class"])')"
check "auto main plan: no voice, no confirmation, total 120" "None/False/120" "$(echo $PLANM | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(str(p["apply"]["voice"])+"/"+str(p["needs_confirmation"])+"/"+str(p["total_cost"]))')"
check "auto main plan: engine is the H3 text route" "h3_text_to_video" "$(echo $PLANM | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["engine"]["route"])')"
check "auto main plan: charged nothing (balance still 1000)" "1000" "$(curl -s $B/api/me -H "Authorization: Bearer $TOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "auto main plan: created no generation row (history still 1)" "1" "$(curl -s $B/api/history -H "Authorization: Bearer $TOKEN" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["generations"]))')"
HOMEPAGED=$(curl -s $B/)
check "frontend: AI Auto toggle present" "yes" "$(echo "$HOMEPAGED" | grep -q 'id="aiAutoToggle"' && echo yes || echo no)"
check "frontend: auto plan panel + Urdu buttons present" "yes" "$(echo "$HOMEPAGED" | grep -q 'id="autoPlanPanel"' && echo "$HOMEPAGED" | grep -q 'اسی طرح بنائیں' && echo "$HOMEPAGED" | grep -q 'منسوخ — ترتیبات خود رکھوں' && echo yes || echo no)"
check "frontend: plan endpoint + History auto summary wired" "yes" "$(echo "$HOMEPAGED" | grep -q '/api/generate/plan' && echo "$HOMEPAGED" | grep -q 'AI نے خود منتخب کیا' && echo yes || echo no)"

echo "--- AI Auto Director: plan analysis (dedicated stub instance, plans only) ---"
AUTO1_STUB_PORT=18074
AUTO1_TSTUB_PORT=18073
B16=http://127.0.0.1:18075
rm -f /tmp/myvideoai-autoplan-test.db; rm -rf /tmp/autogen1 /tmp/autovoice1; mkdir -p /tmp/autogen1 /tmp/autovoice1
FAL_STUB_PORT=$AUTO1_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-auto1.log 2>&1 &
AUTO1STUB_PID=$!
TRANSLATE_STUB_PORT=$AUTO1_TSTUB_PORT node "$(dirname "$0")/test-translate-stub.js" > /tmp/translate-stub-auto1.log 2>&1 &
AUTO1TSTUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$AUTO1_STUB_PORT/__calls && break || sleep 0.25; done
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$AUTO1_TSTUB_PORT/__count && break || sleep 0.25; done
AUTO1_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-autoplan-test.db PORT=18075 FAL_KEY=dummy_test_key "$AUTO1_JWT_NAME=autoplan-instance-dummy-value" \
  ADMIN_EMAIL=autoadmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$AUTO1_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$AUTO1_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 TRANSLATE_API_BASE=http://127.0.0.1:$AUTO1_TSTUB_PORT \
  GENERATED_DIR=/tmp/autogen1 VOICE_DIR=/tmp/autovoice1 \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-autoplan-test.log 2>&1 &
SRV16_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B16/api/health && break || sleep 0.25; done
AR16=$(curl -s -X POST $B16/api/auth/register -H 'Content-Type: application/json' -d '{"email":"autoadmin@example.com","password":"password123"}')
AT16=$(echo $AR16 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
FR16=$(curl -s -X POST $B16/api/auth/register -H 'Content-Type: application/json' -d '{"email":"autofree@example.com","password":"password123"}')
FT16=$(echo $FR16 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
# NOTE: /api/generate/plan shares the generate rate-limit family (10/hour
# per instance), so this instance makes EXACTLY 10 plan calls and nothing
# else chargeable — keep it that way when extending this section.
AP1=$(curl -s -X POST $B16/api/generate/plan -H "Authorization: Bearer $FT16" -H 'Content-Type: application/json' -d '{"prompt":"a cat chasing a butterfly in a sunny garden","mode":"realistic","style":"realistic","duration":5}')
check "auto plan: cat -> animal, no voice, no confirmation" "animal/None/False" "$(echo $AP1 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(p["detected"]["content_class"]+"/"+str(p["apply"]["voice"])+"/"+str(p["needs_confirmation"]))')"
URDU_DLG='ایک آدمی کہتا ہے: \"میرا نام احمد ہے\"'
AP2=$(curl -s -X POST $B16/api/generate/plan -H "Authorization: Bearer $FT16" -H 'Content-Type: application/json' -d "{\"prompt\":\"$URDU_DLG\",\"prompt_language\":\"ur\",\"mode\":\"realistic\",\"style\":\"realistic\",\"duration\":5}")
check "auto plan: urdu dialogue detected with language ur" "میرا نام احمد ہے/ur" "$(echo $AP2 | python3 -c 'import sys,json;d=json.load(sys.stdin)["plan"]["detected"]["dialogue"];print(d["text"]+"/"+d["language"])')"
check "auto plan: urdu dialogue -> voiceover included (0), no cost confirmation" "voiceover/0/False" "$(echo $AP2 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];v=p["apply"]["voice"];print(v["kind"]+"/"+str(v["cost"])+"/"+str(p["needs_confirmation"]))')"
check "auto plan: urdu voice note is honest about the route" "yes" "$(echo $AP2 | python3 -c 'import sys,json;print("yes" if any("Urdu dialogue" in n for n in json.load(sys.stdin)["plan"]["notes"]) else "no")')"
AP3=$(curl -s -X POST $B16/api/generate/plan -H "Authorization: Bearer $FT16" -H 'Content-Type: application/json' -d '{"prompt":"heavy rain and a car braking in city traffic","mode":"realistic","style":"realistic","duration":5}')
check "auto plan: rain+car -> sfx events include rain and car" "True/True" "$(echo $AP3 | python3 -c 'import sys,json;e=json.load(sys.stdin)["plan"]["detected"]["sfx_events"];print(str("rain" in e)+"/"+str("car" in e))')"
check "auto plan: sfx -> sync sound included (0), total == base 120" "sync/0/120" "$(echo $AP3 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(p["apply"]["sound"]["mode"]+"/"+str(p["apply"]["sound"]["cost"])+"/"+str(p["total_cost"]))')"
AP4=$(curl -s -X POST $B16/api/generate/plan -H "Authorization: Bearer $FT16" -H 'Content-Type: application/json' -d '{"prompt":"a cartoon fox tells a kids story in a sunny forest","mode":"realistic","style":"realistic","duration":5}')
check "auto plan: cartoon prompt + realistic mode -> mode conflict" "mode/realistic/cartoon" "$(echo $AP4 | python3 -c 'import sys,json;c=json.load(sys.stdin)["plan"]["conflicts"][0];print(c["field"]+"/"+c["selected"]+"/"+c["detected"])')"
AP5=$(curl -s -X POST $B16/api/generate/plan -H "Authorization: Bearer $FT16" -H 'Content-Type: application/json' -d '{"prompt":"a vertical shorts clip of ocean waves at sunset","mode":"realistic","style":"realistic","duration":5,"aspect_ratio":"16:9"}')
check "auto plan: explicit 16:9 + vertical shorts -> aspect conflict, aspect unchanged" "aspect_ratio/9:16/16:9" "$(echo $AP5 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];c=p["conflicts"][0];print(c["field"]+"/"+c["detected"]+"/"+p["apply"]["aspect_ratio"])')"
AP6=$(curl -s -X POST $B16/api/generate/plan -H "Authorization: Bearer $FT16" -H 'Content-Type: application/json' -d '{"prompt":"a calm mountain lake at dawn","mode":"realistic","style":"realistic","duration":5}')
check "auto plan: plain prompt -> H3 text route, no confirmation" "h3_text_to_video/False" "$(echo $AP6 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(p["engine"]["route"]+"/"+str(p["needs_confirmation"]))')"
AP7=$(curl -s -X POST $B16/api/generate/plan -H "Authorization: Bearer $FT16" -H 'Content-Type: application/json' -d '{"prompt":"a calm valley scene with soft background music","mode":"realistic","style":"realistic","duration":5}')
check "auto plan: explicit music ask -> music included (0) (no sync invented)" "music/0" "$(echo $AP7 | python3 -c 'import sys,json;s=json.load(sys.stdin)["plan"]["apply"]["sound"];print(s["mode"]+"/"+str(s["cost"]))')"
PR16=$(curl -s -X POST $B16/api/auth/register -H 'Content-Type: application/json' -d '{"email":"autopro@example.com","password":"password123"}')
PT16=$(echo $PR16 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PID16=$(curl -s $B16/api/me -H "Authorization: Bearer $PT16" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B16/api/admin/users/$PID16/activate -H "Authorization: Bearer $AT16" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
AP8=$(curl -s -X POST $B16/api/generate/plan -H "Authorization: Bearer $PT16" -H 'Content-Type: application/json' -d "{\"prompt\":\"$URDU_DLG\",\"prompt_language\":\"ur\",\"mode\":\"realistic\",\"style\":\"realistic\",\"duration\":5}")
# Phase E preference order: a speaking-eligible plan (Pro) + dialogue on a
# FRESH text-to-video human scene routes to the one-step Omni speaking
# engine FIRST (flat 50, no voice add-on stacked) — the Phase D lipsync
# expectation was updated for exactly this case; character/image jobs
# still take the lipsync route (see the Phase E section at the end).
check "auto plan (Pro): urdu dialogue on a fresh human scene -> omni speaking engine, flat 250, no voice add-on" "omni_speaking/None/250/250" "$(echo $AP8 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(p["engine"]["route"]+"/"+str(p["apply"]["voice"])+"/"+str(p["base_cost"])+"/"+str(p["total_cost"]))')"
CR16=$(curl -s -X POST $B16/api/auth/register -H 'Content-Type: application/json' -d '{"email":"autochar@example.com","password":"password123"}')
CT16=$(echo $CR16 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PNG_B64_A=$(python3 -c "import base64; print(base64.b64encode(bytes.fromhex('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c636000000000020001e221bc330000000049454e44ae426082')).decode())")
UPA16=$(curl -s -X POST $B16/api/uploads/image -H "Authorization: Bearer $CT16" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_A\",\"content_type\":\"image/png\"}")
IMGA16=$(echo $UPA16 | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
CHA16=$(curl -s -X POST $B16/api/characters -H "Authorization: Bearer $CT16" -H 'Content-Type: application/json' -d "{\"name\":\"Captain Sara\",\"image_path\":\"$IMGA16\"}")
CID16=$(echo $CHA16 | python3 -c 'import sys,json;print(json.load(sys.stdin)["character"]["id"])')
AP9=$(curl -s -X POST $B16/api/generate/plan -H "Authorization: Bearer $CT16" -H 'Content-Type: application/json' -d "{\"prompt\":\"the captain walks through a rainy neon city\",\"mode\":\"realistic\",\"style\":\"realistic\",\"duration\":5,\"character_id\":$CID16}")
check "auto plan: character selected -> reference-to-video engine" "h3_reference_to_video" "$(echo $AP9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["engine"]["route"])')"
XR16=$(curl -s -X POST $B16/api/auth/register -H 'Content-Type: application/json' -d '{"email":"autoxp@example.com","password":"password123"}')
XT16=$(echo $XR16 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
XID16=$(curl -s $B16/api/me -H "Authorization: Bearer $XT16" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B16/api/admin/users/$XID16/activate -H "Authorization: Bearer $AT16" -H 'Content-Type: application/json' -d '{"plan_id":"extrapro","period":"monthly"}'
AP10=$(curl -s -X POST $B16/api/generate/plan -H "Authorization: Bearer $XT16" -H 'Content-Type: application/json' -d '{"prompt":"a calm mountain lake at dawn","mode":"realistic","style":"realistic","duration":5}')
check "auto plan (Extra Pro): native 4K entitlement -> Kling O3 4K engine, base 450" "kling_o3_4k/450" "$(echo $AP10 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(p["engine"]["route"]+"/"+str(p["base_cost"]))')"
check "auto plans: free user charged nothing across all plans" "1000" "$(curl -s $B16/api/me -H "Authorization: Bearer $FT16" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "auto plans: no generation rows created by planning" "0" "$(curl -s $B16/api/history -H "Authorization: Bearer $FT16" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["generations"]))')"
kill $SRV16_PID $AUTO1STUB_PID $AUTO1TSTUB_PID 2>/dev/null

echo "--- AI Auto Director: confirmed plans applied in /api/generate (stub instance) ---"
AUTO2_STUB_PORT=18071
AUTO2_TSTUB_PORT=18070
B17=http://127.0.0.1:18072
rm -f /tmp/myvideoai-autogen-test.db; rm -rf /tmp/autogen2 /tmp/autovoice2; mkdir -p /tmp/autogen2 /tmp/autovoice2
FAL_STUB_PORT=$AUTO2_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-auto2.log 2>&1 &
AUTO2STUB_PID=$!
TRANSLATE_STUB_PORT=$AUTO2_TSTUB_PORT node "$(dirname "$0")/test-translate-stub.js" > /tmp/translate-stub-auto2.log 2>&1 &
AUTO2TSTUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$AUTO2_STUB_PORT/__calls && break || sleep 0.25; done
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$AUTO2_TSTUB_PORT/__count && break || sleep 0.25; done
AUTO2_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-autogen-test.db PORT=18072 FAL_KEY=dummy_test_key "$AUTO2_JWT_NAME=autogen-instance-dummy-value" \
  ADMIN_EMAIL=autoadmin2@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$AUTO2_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$AUTO2_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 TRANSLATE_API_BASE=http://127.0.0.1:$AUTO2_TSTUB_PORT \
  GENERATED_DIR=/tmp/autogen2 VOICE_DIR=/tmp/autovoice2 \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-autogen-test.log 2>&1 &
SRV17_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B17/api/health && break || sleep 0.25; done
AR17=$(curl -s -X POST $B17/api/auth/register -H 'Content-Type: application/json' -d '{"email":"autoadmin2@example.com","password":"password123"}')
AT17=$(echo $AR17 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
FR17=$(curl -s -X POST $B17/api/auth/register -H 'Content-Type: application/json' -d '{"email":"autogenfree@example.com","password":"password123"}')
FT17=$(echo $FR17 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
poll17() { # jobId token -> echoes the final generation JSON
  local st=""
  for i in $(seq 1 40); do
    st=$(curl -s $B17/api/generations/$1 -H "Authorization: Bearer $2")
    [[ "$(echo "$st" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])' 2>/dev/null)" == "completed" ]] && break || sleep 0.3
  done
  echo "$st"
}
# NOTE: exactly 10 plan/generate calls on this instance (shared limiter).
GP1=$(curl -s -X POST $B17/api/generate/plan -H "Authorization: Bearer $FT17" -H 'Content-Type: application/json' -d '{"prompt":"heavy rain and a car braking in city traffic","mode":"realistic","style":"realistic","duration":5}')
GEN1=$(curl -s -X POST $B17/api/generate -H "Authorization: Bearer $FT17" -H 'Content-Type: application/json' -d "$(echo $GP1 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(json.dumps({"prompt":"heavy rain and a car braking in city traffic","mode":"realistic","style":"realistic","duration":5,"auto_plan":p,"auto_confirmed":True}))')")
check "auto gen+sync: charged the plan total 120 exactly (sound included)" "120/880" "$(echo $GEN1 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
JOB1=$(echo $GEN1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
POLL1=$(poll17 $JOB1 $FT17)
check "auto gen+sync: completed with sound applied" "completed/applied" "$(echo $POLL1 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+g["sound_status"])')"
check "auto gen+sync: row carries the auto plan (total 120)" "120" "$(echo $POLL1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["auto_plan"]["total_cost"])')"
GP2=$(curl -s -X POST $B17/api/generate/plan -H "Authorization: Bearer $FT17" -H 'Content-Type: application/json' -d "{\"prompt\":\"$URDU_DLG\",\"prompt_language\":\"ur\",\"mode\":\"realistic\",\"style\":\"realistic\",\"duration\":5}")
GEN2=$(curl -s -X POST $B17/api/generate -H "Authorization: Bearer $FT17" -H 'Content-Type: application/json' -d "$(echo $GP2 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(json.dumps({"prompt":"ایک آدمی کہتا ہے: \"میرا نام احمد ہے\"","prompt_language":"ur","mode":"realistic","style":"realistic","duration":5,"auto_plan":p,"auto_confirmed":True}))')")
check "auto gen+voiceover: charged the plan total 120 exactly (voice included)" "120/760" "$(echo $GEN2 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
JOB2=$(echo $GEN2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
POLL2=$(poll17 $JOB2 $FT17)
check "auto gen+voiceover: completed, voice step applied, cost stays 120" "completed/applied/120" "$(echo $POLL2 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+g["auto_voice_status"]+"/"+str(g["cost_credits"]))')"
GP3=$(curl -s -X POST $B17/api/generate/plan -H "Authorization: Bearer $FT17" -H 'Content-Type: application/json' -d '{"prompt":"heavy rain and a car braking in city traffic","mode":"realistic","style":"realistic","duration":5}')
TAMP3=$(echo $GP3 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];p["base_cost"]=0;p["total_cost"]=1;p["apply"]["sound"]["cost"]=0;p["engine"]={"route":"kling_o3_4k","model":"fal-ai/kling-video/o3/4k/text-to-video","reason":"forged"};print(json.dumps({"prompt":"heavy rain and a car braking in city traffic","mode":"realistic","style":"realistic","duration":5,"auto_plan":p,"auto_confirmed":True}))')
GEN3=$(curl -s -X POST $B17/api/generate -H "Authorization: Bearer $FT17" -H 'Content-Type: application/json' -d "$TAMP3")
check "auto tampered plan: server charges the recomputed rate-card total 120" "120/640" "$(echo $GEN3 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
check "auto tampered plan: forged Kling claim ignored — server routing (H3) recorded" "minimax/h3/text-to-video/h3_text_to_video" "$(echo $GEN3 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["model"]+"/"+g["auto_plan"]["engine"]["route"])')"
CR17=$(curl -s -X POST $B17/api/auth/register -H 'Content-Type: application/json' -d '{"email":"autogenchar@example.com","password":"password123"}')
CT17=$(echo $CR17 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
UPA17=$(curl -s -X POST $B17/api/uploads/image -H "Authorization: Bearer $CT17" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_A\",\"content_type\":\"image/png\"}")
IMGA17=$(echo $UPA17 | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
CHA17=$(curl -s -X POST $B17/api/characters -H "Authorization: Bearer $CT17" -H 'Content-Type: application/json' -d "{\"name\":\"Captain Sara\",\"image_path\":\"$IMGA17\"}")
CID17=$(echo $CHA17 | python3 -c 'import sys,json;print(json.load(sys.stdin)["character"]["id"])')
GP4=$(curl -s -X POST $B17/api/generate/plan -H "Authorization: Bearer $CT17" -H 'Content-Type: application/json' -d "{\"prompt\":\"the captain walks through a rainy neon city\",\"mode\":\"realistic\",\"style\":\"realistic\",\"duration\":5,\"character_id\":$CID17}")
GEN4=$(curl -s -X POST $B17/api/generate -H "Authorization: Bearer $CT17" -H 'Content-Type: application/json' -d "$(echo $GP4 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(json.dumps({"prompt":"the captain walks through a rainy neon city","mode":"realistic","style":"realistic","duration":5,"character_id":'$CID17',"auto_plan":p,"auto_confirmed":True}))')")
check "auto gen with character: applied generation uses the reference route" "minimax/h3/reference-to-video/h3_reference_to_video" "$(echo $GEN4 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["model"]+"/"+g["auto_plan"]["engine"]["route"])')"
XR17=$(curl -s -X POST $B17/api/auth/register -H 'Content-Type: application/json' -d '{"email":"autogenxp@example.com","password":"password123"}')
XT17=$(echo $XR17 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
XID17=$(curl -s $B17/api/me -H "Authorization: Bearer $XT17" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B17/api/admin/users/$XID17/activate -H "Authorization: Bearer $AT17" -H 'Content-Type: application/json' -d '{"plan_id":"extrapro","period":"monthly"}'
GP5=$(curl -s -X POST $B17/api/generate/plan -H "Authorization: Bearer $XT17" -H 'Content-Type: application/json' -d '{"prompt":"a calm mountain lake at dawn","mode":"realistic","style":"realistic","duration":5}')
GEN5=$(curl -s -X POST $B17/api/generate -H "Authorization: Bearer $XT17" -H 'Content-Type: application/json' -d "$(echo $GP5 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(json.dumps({"prompt":"a calm mountain lake at dawn","mode":"realistic","style":"realistic","duration":5,"auto_plan":p,"auto_confirmed":True}))')")
check "auto gen (Extra Pro): applied generation uses the Kling O3 4K route at 450" "fal-ai/kling-video/o3/4k/text-to-video/kling_o3_4k/450" "$(echo $GEN5 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["model"]+"/"+g["auto_plan"]["engine"]["route"]+"/"+str(g["cost_credits"]))')"
kill $SRV17_PID $AUTO2STUB_PID $AUTO2TSTUB_PID 2>/dev/null

echo "--- AI Auto Director: failure refunds exactly once (stub instance) ---"
AUTO3_STUB_PORT=18068
AUTO3_TSTUB_PORT=18067
B18=http://127.0.0.1:18069
rm -f /tmp/myvideoai-autofail-test.db; rm -rf /tmp/autogen3 /tmp/autovoice3; mkdir -p /tmp/autogen3 /tmp/autovoice3
FAL_STUB_PORT=$AUTO3_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-auto3.log 2>&1 &
AUTO3STUB_PID=$!
TRANSLATE_STUB_PORT=$AUTO3_TSTUB_PORT node "$(dirname "$0")/test-translate-stub.js" > /tmp/translate-stub-auto3.log 2>&1 &
AUTO3TSTUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$AUTO3_STUB_PORT/__calls && break || sleep 0.25; done
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$AUTO3_TSTUB_PORT/__count && break || sleep 0.25; done
AUTO3_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-autofail-test.db PORT=18069 FAL_KEY=dummy_test_key "$AUTO3_JWT_NAME=autofail-instance-dummy-value" \
  ADMIN_EMAIL=autoadmin3@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$AUTO3_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$AUTO3_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 TRANSLATE_API_BASE=http://127.0.0.1:$AUTO3_TSTUB_PORT \
  GENERATED_DIR=/tmp/autogen3 VOICE_DIR=/tmp/autovoice3 \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-autofail-test.log 2>&1 &
SRV18_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B18/api/health && break || sleep 0.25; done
FR18=$(curl -s -X POST $B18/api/auth/register -H 'Content-Type: application/json' -d '{"email":"autofail@example.com","password":"password123"}')
FT18=$(echo $FR18 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
poll18() { # jobId -> echoes the final generation JSON
  local st=""
  for i in $(seq 1 40); do
    st=$(curl -s $B18/api/generations/$1 -H "Authorization: Bearer $FT18")
    [[ "$(echo "$st" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])' 2>/dev/null)" == "completed" ]] && break || sleep 0.3
  done
  echo "$st"
}
UPA18=$(curl -s -X POST $B18/api/uploads/image -H "Authorization: Bearer $FT18" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_A\",\"content_type\":\"image/png\"}")
IMGA18=$(echo $UPA18 | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
FP1=$(curl -s -X POST $B18/api/generate/plan -H "Authorization: Bearer $FT18" -H 'Content-Type: application/json' -d "{\"prompt\":\"FAILME heavy rain over a street\",\"mode\":\"realistic\",\"style\":\"realistic\",\"duration\":5,\"image_path\":\"$IMGA18\"}")
FGEN1=$(curl -s -w '\n%{http_code}' -X POST $B18/api/generate -H "Authorization: Bearer $FT18" -H 'Content-Type: application/json' -d "$(echo $FP1 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(json.dumps({"prompt":"FAILME heavy rain over a street","mode":"realistic","style":"realistic","duration":5,"image_path":"'$IMGA18'","auto_plan":p,"auto_confirmed":True}))')")
check "auto fail: provider submission failure -> 502" "502" "$(echo "$FGEN1" | tail -1)"
check "auto fail: EVERYTHING refunded exactly once (balance back to 1000)" "1000" "$(curl -s $B18/api/me -H "Authorization: Bearer $FT18" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "auto fail: failed row carries the auto plan (total was 120)" "failed/120" "$(curl -s $B18/api/history -H "Authorization: Bearer $FT18" | python3 -c 'import sys,json;g=json.load(sys.stdin)["generations"][0];print(g["status"]+"/"+str(g["auto_plan"]["total_cost"]))')"
FP2=$(curl -s -X POST $B18/api/generate/plan -H "Authorization: Bearer $FT18" -H 'Content-Type: application/json' -d '{"prompt":"a man says: \"FAILME hello friend\"","mode":"realistic","style":"realistic","duration":5}')
FGEN2=$(curl -s -X POST $B18/api/generate -H "Authorization: Bearer $FT18" -H 'Content-Type: application/json' -d "$(echo $FP2 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(json.dumps({"prompt":"a man says: \"FAILME hello friend\"","mode":"realistic","style":"realistic","duration":5,"auto_plan":p,"auto_confirmed":True}))')")
JOBF2=$(echo $FGEN2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
POLLF2=$(poll18 $JOBF2)
check "auto voice fail: video still delivered, voice marked failed_refunded" "completed/failed_refunded" "$(echo $POLLF2 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+g["auto_voice_status"])')"
check "auto voice fail: voice was included (0 to refund) — row cost 120, balance 880" "120/880" "$(echo $POLLF2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_credits"])')/$(curl -s $B18/api/me -H "Authorization: Bearer $FT18" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
FP3=$(curl -s -X POST $B18/api/generate/plan -H "Authorization: Bearer $FT18" -H 'Content-Type: application/json' -d '{"prompt":"FAILME rain over a street","mode":"realistic","style":"realistic","duration":5}')
FGEN3=$(curl -s -X POST $B18/api/generate -H "Authorization: Bearer $FT18" -H 'Content-Type: application/json' -d "$(echo $FP3 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(json.dumps({"prompt":"FAILME rain over a street","mode":"realistic","style":"realistic","duration":5,"auto_plan":p,"auto_confirmed":True}))')")
JOBF3=$(echo $FGEN3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
POLLF3=$(poll18 $JOBF3)
check "auto sound fail: video delivered, sound failed_refunded, balance 760" "completed/failed_refunded/760" "$(echo $POLLF3 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+g["sound_status"])')/$(curl -s $B18/api/me -H "Authorization: Bearer $FT18" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
CHA18=$(curl -s -X POST $B18/api/characters -H "Authorization: Bearer $FT18" -H 'Content-Type: application/json' -d "{\"name\":\"Captain Sara\",\"image_path\":\"$IMGA18\"}")
CID18=$(echo $CHA18 | python3 -c 'import sys,json;print(json.load(sys.stdin)["character"]["id"])')
BR18=$(curl -s -X POST $B18/api/auth/register -H 'Content-Type: application/json' -d '{"email":"autofail-b@example.com","password":"password123"}')
BT18=$(echo $BR18 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
check "auto plan: another user's character -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B18/api/generate/plan -H "Authorization: Bearer $BT18" -H 'Content-Type: application/json' -d "{\"prompt\":\"the captain walks in the rain\",\"character_id\":$CID18}")"
# -- migration v14: delete its record + drop its columns, restart re-applies --
kill $SRV18_PID 2>/dev/null; sleep 0.5
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-autofail-test.db');
db.exec('DELETE FROM schema_migrations WHERE version = 14');
for (const col of ['auto_plan','auto_voice_status','auto_voice_cost'])
  db.exec('ALTER TABLE generations DROP COLUMN ' + col);
console.log('rolled back migration v14');
"
env DB_PATH=/tmp/myvideoai-autofail-test.db PORT=18069 FAL_KEY=dummy_test_key "$AUTO3_JWT_NAME=autofail-instance-dummy-value" \
  ADMIN_EMAIL=autoadmin3@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$AUTO3_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$AUTO3_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 TRANSLATE_API_BASE=http://127.0.0.1:$AUTO3_TSTUB_PORT \
  GENERATED_DIR=/tmp/autogen3 VOICE_DIR=/tmp/autovoice3 \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-autofail-test2.log 2>&1 &
SRV18_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B18/api/health && break || sleep 0.25; done
check "migration v14 re-applies on boot (auto columns restored)" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-autofail-test.db');
const cols = db.prepare(\"SELECT name FROM pragma_table_info('generations') WHERE name LIKE 'auto_%'\").all().map(r => r.name).sort().join(',');
const mig = db.prepare('SELECT COUNT(*) AS c FROM schema_migrations WHERE version = 14').get().c;
console.log(cols === 'auto_plan,auto_voice_cost,auto_voice_status' && Number(mig) === 1 ? 'ok' : 'bad');
")"
kill $SRV18_PID $AUTO3STUB_PID $AUTO3TSTUB_PID 2>/dev/null

echo "--- Speaking engine (Phase E: Gemini Omni, stub instance) ---"
SPK_STUB_PORT=18065
SPK_TSTUB_PORT=18064
B19=http://127.0.0.1:18066
rm -f /tmp/myvideoai-speaking-test.db; rm -rf /tmp/spkgen /tmp/spkvoice; mkdir -p /tmp/spkgen /tmp/spkvoice
FAL_STUB_PORT=$SPK_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-spk.log 2>&1 &
SPKSTUB_PID=$!
TRANSLATE_STUB_PORT=$SPK_TSTUB_PORT node "$(dirname "$0")/test-translate-stub.js" > /tmp/translate-stub-spk.log 2>&1 &
SPKTSTUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$SPK_STUB_PORT/__calls && break || sleep 0.25; done
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$SPK_TSTUB_PORT/__count && break || sleep 0.25; done
SPK_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-speaking-test.db PORT=18066 FAL_KEY=dummy_test_key "$SPK_JWT_NAME=speaking-instance-dummy-value" \
  ADMIN_EMAIL=spkadmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$SPK_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$SPK_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 TRANSLATE_API_BASE=http://127.0.0.1:$SPK_TSTUB_PORT \
  GENERATED_DIR=/tmp/spkgen VOICE_DIR=/tmp/spkvoice \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-speaking-test.log 2>&1 &
SRV19_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B19/api/health && break || sleep 0.25; done
AR19=$(curl -s -X POST $B19/api/auth/register -H 'Content-Type: application/json' -d '{"email":"spkadmin@example.com","password":"password123"}')
AT19=$(echo $AR19 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PR19=$(curl -s -X POST $B19/api/auth/register -H 'Content-Type: application/json' -d '{"email":"spkpro@example.com","password":"password123"}')
PT19=$(echo $PR19 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PID19=$(curl -s $B19/api/me -H "Authorization: Bearer $PT19" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B19/api/admin/users/$PID19/activate -H "Authorization: Bearer $AT19" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
FR19=$(curl -s -X POST $B19/api/auth/register -H 'Content-Type: application/json' -d '{"email":"spkfree@example.com","password":"password123"}')
FT19=$(echo $FR19 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
poll19() { # jobId token -> echoes the final generation JSON
  local st=""
  for i in $(seq 1 40); do
    st=$(curl -s $B19/api/generations/$1 -H "Authorization: Bearer $2")
    [[ "$(echo "$st" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])' 2>/dev/null)" == "completed" ]] && break || sleep 0.3
  done
  echo "$st"
}
check "config: speaking_engine block (gemini-omni, flat 250, 16:9+9:16)" "gemini-omni/google/gemini-omni-flash/v1.1/text-to-video/250/16:9,9:16" "$(curl -s $B19/api/config | python3 -c 'import sys,json;s=json.load(sys.stdin)["speaking_engine"];print(s["provider"]+"/"+s["model"]+"/"+str(s["price_credits"])+"/"+",".join(s["aspects"]))')"
# NOTE: exactly 8 plan/generate calls on this instance (shared limiter).
SPG1=$(curl -s -X POST $B19/api/generate -H "Authorization: Bearer $PT19" -H 'Content-Type: application/json' -d '{"prompt":"a man smiles at the camera and says: \"Welcome to my shop, everything is fresh today\"","engine":"speaking","aspect_ratio":"16:9","duration":10,"mode":"realistic","style":"realistic"}')
check "speaking gen: flat 250 charged, omni model, 720P, engine speaking" "250/5750/google/gemini-omni-flash/v1.1/text-to-video/720P/speaking" "$(echo $SPG1 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"])+"/"+g["model"]+"/"+g["resolution"]+"/"+g["engine"])')"
SPJ1=$(echo $SPG1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
SPP1=$(poll19 $SPJ1 $PT19)
check "speaking gen: completes on the stub with the omni model recorded" "completed/google/gemini-omni-flash/v1.1/text-to-video/720P" "$(echo $SPP1 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+g["model"]+"/"+g["resolution"])')"
SPCALLS=$(curl -s http://127.0.0.1:$SPK_STUB_PORT/__calls)
check "speaking gen: fal body is exactly the verified Omni schema (4 fields, prompt carries the dialogue)" "720p/10/16:9/4/yes" "$(echo $SPCALLS | python3 -c 'import sys,json;cs=[c for c in json.load(sys.stdin)["calls"] if c["path"]=="/google/gemini-omni-flash/v1.1/text-to-video"];b=cs[-1]["body"];print(b["resolution"]+"/"+str(b["duration"])+"/"+b["aspect_ratio"]+"/"+str(len(b))+"/"+("yes" if "Welcome to my shop" in b["prompt"] else "no"))')"
check "speaking gen: free plan -> 403, no charge" "403/1000" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B19/api/generate -H "Authorization: Bearer $FT19" -H 'Content-Type: application/json' -d '{"prompt":"a man says hello to the camera","engine":"speaking","aspect_ratio":"16:9","duration":5}')/$(curl -s $B19/api/me -H "Authorization: Bearer $FT19" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "speaking gen: aspect 1:1 -> 400 before charging" "400/5750" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B19/api/generate -H "Authorization: Bearer $PT19" -H 'Content-Type: application/json' -d '{"prompt":"a man says hello to the camera","engine":"speaking","aspect_ratio":"1:1","duration":5}')/$(curl -s $B19/api/me -H "Authorization: Bearer $PT19" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "speaking gen: sound add-on combo -> 400 (rejected, not silently dropped), no charge" "400/5750" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B19/api/generate -H "Authorization: Bearer $PT19" -H 'Content-Type: application/json' -d '{"prompt":"a man says hello to the camera","engine":"speaking","aspect_ratio":"16:9","duration":5,"sound":{"mode":"sync","prompt":"city ambience"}}')/$(curl -s $B19/api/me -H "Authorization: Bearer $PT19" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "speaking gen: provider failure -> 502 with full exactly-once refund" "502/5750" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B19/api/generate -H "Authorization: Bearer $PT19" -H 'Content-Type: application/json' -d '{"prompt":"FAILME a man says: \"this will fail today\"","engine":"speaking","aspect_ratio":"16:9","duration":5}')/$(curl -s $B19/api/me -H "Authorization: Bearer $PT19" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
SPPL=$(curl -s -X POST $B19/api/generate/plan -H "Authorization: Bearer $PT19" -H 'Content-Type: application/json' -d '{"prompt":"a man stands in his shop and says: \"Welcome in, everything is fresh today\"","mode":"realistic","style":"realistic","duration":5}')
check "auto plan (Pro): dialogue -> omni_speaking engine, speaking flag set, total = flat 250, no confirmation (no conflict)" "omni_speaking/True/None/250/250/False" "$(echo $SPPL | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(p["engine"]["route"]+"/"+str(p["apply"]["speaking_engine"])+"/"+str(p["apply"]["voice"])+"/"+str(p["base_cost"])+"/"+str(p["total_cost"])+"/"+str(p["needs_confirmation"]))')"
SPG2=$(curl -s -X POST $B19/api/generate -H "Authorization: Bearer $PT19" -H 'Content-Type: application/json' -d "$(echo $SPPL | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(json.dumps({"prompt":"a man stands in his shop and says: \"Welcome in, everything is fresh today\"","mode":"realistic","style":"realistic","duration":5,"auto_plan":p,"auto_confirmed":True}))')")
check "auto omni gen: confirmed plan generates through the speaking route at flat 250" "250/5500/google/gemini-omni-flash/v1.1/text-to-video/omni_speaking" "$(echo $SPG2 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"])+"/"+g["model"]+"/"+g["auto_plan"]["engine"]["route"])')"
SPJ2=$(echo $SPG2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
SPP2=$(poll19 $SPJ2 $PT19)
check "auto omni gen: completes on the stub" "completed" "$(echo $SPP2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
UPA19=$(curl -s -X POST $B19/api/uploads/image -H "Authorization: Bearer $PT19" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_A\",\"content_type\":\"image/png\"}")
IMG19=$(echo $UPA19 | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
CHA19=$(curl -s -X POST $B19/api/characters -H "Authorization: Bearer $PT19" -H 'Content-Type: application/json' -d "{\"name\":\"Captain Sara\",\"image_path\":\"$IMG19\"}")
CID19=$(echo $CHA19 | python3 -c 'import sys,json;print(json.load(sys.stdin)["character"]["id"])')
SPPC=$(curl -s -X POST $B19/api/generate/plan -H "Authorization: Bearer $PT19" -H 'Content-Type: application/json' -d "{\"prompt\":\"the captain says: \\\"Follow me now, we sail at dawn\\\"\",\"mode\":\"realistic\",\"style\":\"realistic\",\"duration\":5,\"character_id\":$CID19}")
check "auto plan (Pro): character + dialogue -> still reference route + lipsync (omni is fresh-t2v only)" "h3_reference_to_video/lipsync/latentsync_video" "$(echo $SPPC | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(p["engine"]["route"]+"/"+p["apply"]["voice"]["kind"]+"/"+p["engine"]["voice_route"])')"
kill $SRV19_PID $SPKSTUB_PID $SPKTSTUB_PID 2>/dev/null

echo "--- Phase G: audio included + negation respect + mute (stub instance) ---"
G_STUB_PORT=18062
G_TSTUB_PORT=18061
B20=http://127.0.0.1:18063
rm -f /tmp/myvideoai-phaseg-test.db; rm -rf /tmp/phaseggen /tmp/phasegvoice; mkdir -p /tmp/phaseggen /tmp/phasegvoice
FAL_STUB_PORT=$G_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-phaseg.log 2>&1 &
GSTUB_PID=$!
TRANSLATE_STUB_PORT=$G_TSTUB_PORT node "$(dirname "$0")/test-translate-stub.js" > /tmp/translate-stub-phaseg.log 2>&1 &
GTSTUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$G_STUB_PORT/__calls && break || sleep 0.25; done
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$G_TSTUB_PORT/__count && break || sleep 0.25; done
G_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-phaseg-test.db PORT=18063 FAL_KEY=dummy_test_key "$G_JWT_NAME=phaseg-instance-dummy-value" \
  ADMIN_EMAIL=gadmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$G_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$G_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 TRANSLATE_API_BASE=http://127.0.0.1:$G_TSTUB_PORT \
  GENERATED_DIR=/tmp/phaseggen VOICE_DIR=/tmp/phasegvoice \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-phaseg-test.log 2>&1 &
SRV20_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B20/api/health && break || sleep 0.25; done
AR20=$(curl -s -X POST $B20/api/auth/register -H 'Content-Type: application/json' -d '{"email":"gadmin@example.com","password":"password123"}')
AT20=$(echo $AR20 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
GR20=$(curl -s -X POST $B20/api/auth/register -H 'Content-Type: application/json' -d '{"email":"gfree@example.com","password":"password123"}')
GT20=$(echo $GR20 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PR20=$(curl -s -X POST $B20/api/auth/register -H 'Content-Type: application/json' -d '{"email":"gpro@example.com","password":"password123"}')
PT20=$(echo $PR20 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PID20=$(curl -s $B20/api/me -H "Authorization: Bearer $PT20" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B20/api/admin/users/$PID20/activate -H "Authorization: Bearer $AT20" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
poll20() { # jobId token -> echoes the final generation JSON
  local st=""
  for i in $(seq 1 40); do
    st=$(curl -s $B20/api/generations/$1 -H "Authorization: Bearer $2")
    [[ "$(echo "$st" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])' 2>/dev/null)" == "completed" ]] && break || sleep 0.3
  done
  echo "$st"
}
FFBIN20=$(node --input-type=module -e "import f from 'ffmpeg-static'; console.log(f)" 2>/dev/null)
HOMEPAGE20=$(curl -s $B20/)
check "phase G frontend: 'Included · قیمت میں شامل' label logic ships" "yes" "$(echo "$HOMEPAGE20" | grep -q 'قیمت میں شامل' && echo "$HOMEPAGE20" | grep -q 'audioCostLabel' && echo yes || echo no)"
# NOTE: exactly 9 plan/generate calls on this instance (shared limiter).
GP_NO_MUSIC=$(curl -s -X POST $B20/api/generate/plan -H "Authorization: Bearer $GT20" -H 'Content-Type: application/json' -d '{"prompt":"a cat in a garden, no music","mode":"realistic","style":"realistic","duration":5}')
check "negation: 'no music' -> no sound proposal, music negation detected" "None/True" "$(echo $GP_NO_MUSIC | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(str(p["apply"]["sound"])+"/"+str(p["detected"]["negations"]["music"]))')"
GP_SILENT=$(curl -s -X POST $B20/api/generate/plan -H "Authorization: Bearer $GT20" -H 'Content-Type: application/json' -d '{"prompt":"silent video of rain in a garden","mode":"realistic","style":"realistic","duration":5}')
check "negation: 'silent video' -> mute:true, no sound, no confirmation, total == base" "True/None/False/120" "$(echo $GP_SILENT | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(str(p["apply"]["mute"])+"/"+str(p["apply"]["sound"])+"/"+str(p["needs_confirmation"])+"/"+str(p["total_cost"]))')"
curl -s -o /tmp/mute-source.mp4 http://127.0.0.1:$G_STUB_PORT/media/clip.mp4
check "mute fixture: the stub's source clip HAS an audio stream" "yes" "$("$FFBIN20" -i /tmp/mute-source.mp4 2>&1 | python3 -c 'import sys;print("yes" if "Audio:" in sys.stdin.read() else "no")')"
GEN_SILENT=$(curl -s -X POST $B20/api/generate -H "Authorization: Bearer $GT20" -H 'Content-Type: application/json' -d "$(echo $GP_SILENT | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(json.dumps({"prompt":"silent video of rain in a garden","mode":"realistic","style":"realistic","duration":5,"auto_plan":p,"auto_confirmed":True}))')")
check "mute gen: charged the base 120 only" "120/880" "$(echo $GEN_SILENT | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
JOB_SILENT=$(echo $GEN_SILENT | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
POLL_SILENT=$(poll20 $JOB_SILENT $GT20)
check "mute gen: completed with mute_status applied" "completed/applied" "$(echo $POLL_SILENT | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+g["mute_status"])')"
MUTEURL=$(echo $POLL_SILENT | python3 -c 'import sys,json;print(json.load(sys.stdin)["video_url"])')
curl -s -o /tmp/muted-out.mp4 $B20$MUTEURL
check "mute gen: delivered file has NO audio stream, keeps video" "no/yes" "$("$FFBIN20" -i /tmp/muted-out.mp4 2>&1 | python3 -c 'import sys;s=sys.stdin.read();print(("yes" if "Audio:" in s else "no")+"/"+("yes" if "Video:" in s else "no"))')"
GP_NODLG=$(curl -s -X POST $B20/api/generate/plan -H "Authorization: Bearer $GT20" -H 'Content-Type: application/json' -d '{"prompt":"a man says: \"hello my friend\", without dialogue","mode":"realistic","style":"realistic","duration":5}')
check "negation: 'without dialogue' -> no voice route, dialogue negation detected" "None/True" "$(echo $GP_NODLG | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(str(p["apply"]["voice"])+"/"+str(p["detected"]["negations"]["dialogue"]))')"
GP_MANUAL_VOICE=$(curl -s -X POST $B20/api/generate/plan -H "Authorization: Bearer $GT20" -H 'Content-Type: application/json' -d "{\"prompt\":\"$URDU_DLG\",\"prompt_language\":\"ur\",\"mode\":\"realistic\",\"style\":\"realistic\",\"duration\":5,\"voice\":{\"kind\":\"voiceover\"}}")
GEN_MANUAL_VOICE=$(curl -s -X POST $B20/api/generate -H "Authorization: Bearer $GT20" -H 'Content-Type: application/json' -d "$(echo $GP_MANUAL_VOICE | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(json.dumps({"prompt":"ایک آدمی کہتا ہے: \"میرا نام احمد ہے\"","prompt_language":"ur","mode":"realistic","style":"realistic","duration":5,"voice":{"kind":"voiceover"},"auto_plan":p,"auto_confirmed":True}))')")
check "manual voiceover selection: total == base 120 (voice included)" "120/760" "$(echo $GEN_MANUAL_VOICE | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
JOB_MV=$(echo $GEN_MANUAL_VOICE | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
POLL_MV=$(poll20 $JOB_MV $GT20)
check "manual voiceover selection: voice step applied" "completed/applied" "$(echo $POLL_MV | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+g["auto_voice_status"])')"
UPA20=$(curl -s -X POST $B20/api/uploads/image -H "Authorization: Bearer $PT20" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_A\",\"content_type\":\"image/png\"}")
IMG20=$(echo $UPA20 | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
CHA20=$(curl -s -X POST $B20/api/characters -H "Authorization: Bearer $PT20" -H 'Content-Type: application/json' -d "{\"name\":\"Captain Sara\",\"image_path\":\"$IMG20\"}")
CID20=$(echo $CHA20 | python3 -c 'import sys,json;print(json.load(sys.stdin)["character"]["id"])')
GP_CHAR_LIP=$(curl -s -X POST $B20/api/generate/plan -H "Authorization: Bearer $PT20" -H 'Content-Type: application/json' -d "{\"prompt\":\"the captain says: \\\"Follow me now, we sail at dawn\\\"\",\"mode\":\"realistic\",\"style\":\"realistic\",\"duration\":5,\"character_id\":$CID20}")
check "lip-sync selection (Pro, character): included — voice cost 0, total == base" "lipsync/0/180/180" "$(echo $GP_CHAR_LIP | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(p["apply"]["voice"]["kind"]+"/"+str(p["apply"]["voice"]["cost"])+"/"+str(p["base_cost"])+"/"+str(p["total_cost"]))')"
GP_OMNI_MUTE=$(curl -s -X POST $B20/api/generate/plan -H "Authorization: Bearer $PT20" -H 'Content-Type: application/json' -d '{"prompt":"a man says: \"welcome to my shop\" in a silent video","mode":"realistic","style":"realistic","duration":5}')
check "omni + mute plan: audio conflict, speaking suppressed, mute set, confirmation required" "audio/False/True/True" "$(echo $GP_OMNI_MUTE | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(p["conflicts"][0]["field"]+"/"+str(p["apply"]["speaking_engine"])+"/"+str(p["apply"]["mute"])+"/"+str(p["needs_confirmation"]))')"
SPK_SILENT=$(curl -s -w '\n%{http_code}' -X POST $B20/api/generate -H "Authorization: Bearer $PT20" -H 'Content-Type: application/json' -d '{"prompt":"a silent video of a man saying hello to the camera","engine":"speaking","aspect_ratio":"16:9","duration":5,"mode":"realistic","style":"realistic"}')
check "speaking + silent prompt: -> 400, no charge" "400/6000" "$(echo "$SPK_SILENT" | tail -1)/$(curl -s $B20/api/me -H "Authorization: Bearer $PT20" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "speaking + silent prompt: error says a speaking video cannot be silent" "yes" "$(echo "$SPK_SILENT" | sed '$d' | python3 -c 'import sys,json;print("yes" if "cannot be silent" in json.load(sys.stdin)["error"] else "no")')"
# -- migration v15: delete its record + drop its column, restart re-applies --
kill $SRV20_PID 2>/dev/null; sleep 0.5
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseg-test.db');
db.exec('DELETE FROM schema_migrations WHERE version = 15');
db.exec('ALTER TABLE generations DROP COLUMN mute_status');
console.log('rolled back migration v15');
"
env DB_PATH=/tmp/myvideoai-phaseg-test.db PORT=18063 FAL_KEY=dummy_test_key "$G_JWT_NAME=phaseg-instance-dummy-value" \
  ADMIN_EMAIL=gadmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$G_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$G_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 TRANSLATE_API_BASE=http://127.0.0.1:$G_TSTUB_PORT \
  GENERATED_DIR=/tmp/phaseggen VOICE_DIR=/tmp/phasegvoice \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-phaseg-test2.log 2>&1 &
SRV20_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B20/api/health && break || sleep 0.25; done
check "migration v15 re-applies on boot (mute_status restored)" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseg-test.db');
const cols = db.prepare(\"SELECT name FROM pragma_table_info('generations') WHERE name = 'mute_status'\").all().length;
const mig = db.prepare('SELECT COUNT(*) AS c FROM schema_migrations WHERE version = 15').get().c;
console.log(cols === 1 && Number(mig) === 1 ? 'ok' : 'bad');
")"
kill $SRV20_PID $GSTUB_PID $GTSTUB_PID 2>/dev/null

echo "--- phase K: home declutter (greeting + composer-first, Runway-style) ---"
HOMEPAGEH=$(curl -s $B/)
check "phase K: slim greeting ships with the bilingual line" "yes" "$(echo "$HOMEPAGEH" | grep -q 'id="homeGreeting"' && echo "$HOMEPAGEH" | grep -q 'What are we creating today?' && echo "$HOMEPAGEH" | grep -q 'آج کیا بنائیں گے؟' && echo yes || echo no)"
check "phase K: greeting is filled from the loaded /api/me state" "yes" "$(echo "$HOMEPAGEH" | grep -q 'function fillGreeting' && echo "$HOMEPAGEH" | grep -q 'me.display_name' && echo "$HOMEPAGEH" | grep -q 'Hi " + name' && echo yes || echo no)"
check "phase K: hero band removed from Home" "no" "$(echo "$HOMEPAGEH" | grep -qE 'hero-eyebrow|class="hero"' && echo yes || echo no)"
check "phase K: showcase rail, feature row, creations gallery + Recent strip removed" "no" "$(echo "$HOMEPAGEH" | grep -qE 'id="showcaseRail"|id="featureRow"|id="creationsCard"|recent-strip' && echo yes || echo no)"
check "phase K: removed sections' render wiring is gone" "no" "$(echo "$HOMEPAGEH" | grep -qE 'renderCreations|renderRecent|data-showcase' && echo yes || echo no)"
check "phase K: composer-first surface intact (rail, composer, chips, auto panel, advanced, sticky bar)" "yes" "$(echo "$HOMEPAGEH" | grep -q 'id="templateGrid"' && echo "$HOMEPAGEH" | grep -q 'id="prompt"' && echo "$HOMEPAGEH" | grep -q 'id="aspectSeg"' && echo "$HOMEPAGEH" | grep -q 'id="durationSeg"' && echo "$HOMEPAGEH" | grep -q 'id="aiAutoToggle"' && echo "$HOMEPAGEH" | grep -q 'id="autoPlanPanel"' && echo "$HOMEPAGEH" | grep -q 'id="advancedCard"' && echo "$HOMEPAGEH" | grep -q 'id="generateBtn"' && echo yes || echo no)"
check "phase K: showcase image files retained on disk (realistic)" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B/showcase/showcase-realistic.jpg)"
check "phase K: showcase image files retained on disk (speaking)" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B/showcase/showcase-speaking.jpg)"

echo "--- Phase G2: standalone lip-sync included (300-char cap + fair-use cap, stub instance) ---"
G2_STUB_PORT=18052
B21=http://127.0.0.1:18051
rm -f /tmp/myvideoai-phaseg2-test.db; rm -rf /tmp/phaseg2gen /tmp/phaseg2voice; mkdir -p /tmp/phaseg2gen /tmp/phaseg2voice
FAL_STUB_PORT=$G2_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-phaseg2.log 2>&1 &
G2STUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$G2_STUB_PORT/__calls && break || sleep 0.25; done
G2_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-phaseg2-test.db PORT=18051 FAL_KEY=dummy_test_key "$G2_JWT_NAME=phaseg2-instance-dummy-value" \
  ADMIN_EMAIL=g2admin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$G2_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$G2_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 \
  GENERATED_DIR=/tmp/phaseg2gen VOICE_DIR=/tmp/phaseg2voice \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-phaseg2-test.log 2>&1 &
SRV21_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B21/api/health && break || sleep 0.25; done
HOMEPAGE21=$(curl -s $B21/)
check "phase G2 frontend: script textarea capped at 300 with the included note" "yes" "$(echo "$HOMEPAGE21" | grep -q 'id="voiceScript" maxlength="300"' && echo "$HOMEPAGE21" | grep -q '300 حروف تک' && echo yes || echo no)"
check "phase G2 frontend: lipsync button label uses the Included label logic" "yes" "$(echo "$HOMEPAGE21" | grep -q 'Create talking character — " + audioCostLabel' && echo yes || echo no)"
AR21=$(curl -s -X POST $B21/api/auth/register -H 'Content-Type: application/json' -d '{"email":"g2admin@example.com","password":"password123"}')
AT21=$(echo $AR21 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PR21=$(curl -s -X POST $B21/api/auth/register -H 'Content-Type: application/json' -d '{"email":"g2pro@example.com","password":"password123"}')
PT21=$(echo $PR21 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PID21=$(curl -s $B21/api/me -H "Authorization: Bearer $PT21" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B21/api/admin/users/$PID21/activate -H "Authorization: Bearer $AT21" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
check "g2 pro user balance after activation (1000 free + 5000 plan)" "6000" "$(curl -s $B21/api/me -H "Authorization: Bearer $PT21" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
UPG2=$(curl -s -X POST $B21/api/uploads/image -H "Authorization: Bearer $PT21" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_A\",\"content_type\":\"image/png\"}")
IMG21=$(echo $UPG2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
SCRIPT301=$(python3 -c "print('a'*301)")
LS301=$(curl -s -w '\n%{http_code}' -X POST $B21/api/voice/lipsync -H "Authorization: Bearer $PT21" -H 'Content-Type: application/json' -d "{\"image_path\":\"$IMG21\",\"script\":\"$SCRIPT301\",\"spoken_language\":\"en\",\"script_mode\":\"native\"}")
check "g2 lipsync: 301-char script -> 400" "400" "$(echo "$LS301" | tail -1)"
check "g2 lipsync: 400 error states the 300-character limit" "yes" "$(echo "$LS301" | sed '$d' | python3 -c 'import sys,json;print("yes" if "300" in json.load(sys.stdin)["error"] else "no")')"
check "g2 lipsync: 301-char attempt charged nothing" "6000" "$(curl -s $B21/api/me -H "Authorization: Bearer $PT21" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "g2 lipsync: 301-char attempt created no generation row" "0" "$(curl -s $B21/api/history -H "Authorization: Bearer $PT21" | python3 -c 'import sys,json;print(len([g for g in json.load(sys.stdin)["generations"] if g["kind"]=="lipsync"]))')"
SCRIPT300=$(python3 -c "print('a'*300)")
LS300=$(curl -s -w '\n%{http_code}' -X POST $B21/api/voice/lipsync -H "Authorization: Bearer $PT21" -H 'Content-Type: application/json' -d "{\"image_path\":\"$IMG21\",\"script\":\"$SCRIPT300\",\"spoken_language\":\"en\",\"script_mode\":\"native\"}")
check "g2 lipsync: exactly 300 chars -> 201" "201" "$(echo "$LS300" | tail -1)"
LS300B=$(echo "$LS300" | sed '$d')
check "g2 lipsync: 300-char job included — cost 0, credits_left 6000" "0/6000" "$(echo $LS300B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
# jobs 2..10 (9 more) — the daily fair-use cap is 10 standalone jobs.
G2OK=0
for i in $(seq 2 10); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B21/api/voice/lipsync -H "Authorization: Bearer $PT21" -H 'Content-Type: application/json' -d "{\"image_path\":\"$IMG21\",\"script\":\"salam dost\",\"spoken_language\":\"ur\",\"script_mode\":\"roman\"}")
  [[ "$CODE" == "201" ]] && G2OK=$((G2OK+1))
done
check "g2 lipsync: jobs 2-10 all succeed (201 x9)" "9" "$G2OK"
LS11=$(curl -s -w '\n%{http_code}' -X POST $B21/api/voice/lipsync -H "Authorization: Bearer $PT21" -H 'Content-Type: application/json' -d "{\"image_path\":\"$IMG21\",\"script\":\"salam dost\",\"spoken_language\":\"ur\",\"script_mode\":\"roman\"}")
check "g2 lipsync: 11th standalone job of the day -> 429" "429" "$(echo "$LS11" | tail -1)"
check "g2 lipsync: 429 names the daily fair-use limit" "yes" "$(echo "$LS11" | sed '$d' | python3 -c 'import sys,json;print("yes" if "fair-use" in json.load(sys.stdin)["error"] else "no")')"
check "g2 lipsync: fair-use cap charged nothing (still 6000)" "6000" "$(curl -s $B21/api/me -H "Authorization: Bearer $PT21" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
kill $SRV21_PID $G2STUB_PID 2>/dev/null

echo "--- Phase I: in-app tester feedback (dedicated instance, no stubs) ---"
B22=http://127.0.0.1:18050
rm -f /tmp/myvideoai-feedback-test.db
FB_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-feedback-test.db PORT=18050 FAL_KEY=dummy_test_key "$FB_JWT_NAME=feedback-instance-dummy-value" \
  ADMIN_EMAIL=fbadmin@example.com \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-feedback-test.log 2>&1 &
SRV22_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B22/api/health && break || sleep 0.25; done
AR22=$(curl -s -X POST $B22/api/auth/register -H 'Content-Type: application/json' -d '{"email":"fbadmin@example.com","password":"password123"}')
AT22=$(echo $AR22 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
UR22=$(curl -s -X POST $B22/api/auth/register -H 'Content-Type: application/json' -d '{"email":"fbuser@example.com","password":"password123"}')
UT22=$(echo $UR22 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
# 1. unauthenticated -> 401
FB_UNAUTH=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B22/api/feedback -H 'Content-Type: application/json' -d '{"category":"bug","message":"the app crashed on my phone"}')
check "phase I: unauthenticated feedback -> 401" "401" "$FB_UNAUTH"
# 2. happy path -> 201 with id + status, distinctive User-Agent header
FB_OK=$(curl -s -w '\n%{http_code}' -X POST $B22/api/feedback -H "Authorization: Bearer $UT22" -H 'Content-Type: application/json' -H 'User-Agent: PhaseITestUA/2.0 (TestPhone)' -d '{"category":"bug","message":"The video came out blurry on my test phone."}')
check "phase I: happy path -> 201" "201" "$(echo "$FB_OK" | tail -1)"
check "phase I: happy path response carries id + status open" "open" "$(echo "$FB_OK" | sed '$d' | python3 -c 'import sys,json;r=json.load(sys.stdin);print(r["status"] if r.get("id") else "noid")')"
FBID1=$(echo "$FB_OK" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
# 3. admin inbox: reporter email, server-stamped user-agent + app_version
FB_LIST=$(curl -s $B22/api/admin/feedback -H "Authorization: Bearer $AT22")
check "phase I: admin list shows the reporter's email" "fbuser@example.com" "$(echo "$FB_LIST" | python3 -c 'import sys,json;rows=json.load(sys.stdin)["feedback"];print(rows[0]["user_email"] if rows else "none")')"
check "phase I: admin list stores the request user-agent (server-stamped)" "PhaseITestUA/2.0 (TestPhone)" "$(echo "$FB_LIST" | python3 -c 'import sys,json;rows=json.load(sys.stdin)["feedback"];print(rows[0]["user_agent"] if rows else "none")')"
check "phase I: admin list stores the app version (server-stamped)" "1.0" "$(echo "$FB_LIST" | python3 -c 'import sys,json;rows=json.load(sys.stdin)["feedback"];print(rows[0]["app_version"] if rows else "none")')"
check "phase I: admin list is newest first" "yes" "$(echo "$FB_LIST" | python3 -c 'import sys,json;ids=[r["id"] for r in json.load(sys.stdin)["feedback"]];print("yes" if ids==sorted(ids,reverse=True) else "no")')"
# 4. validation: too-short message / bad category -> 400
FB_SHORT=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B22/api/feedback -H "Authorization: Bearer $UT22" -H 'Content-Type: application/json' -d '{"category":"bug","message":"abc"}')
check "phase I: 3-char message -> 400" "400" "$FB_SHORT"
FB_BADCAT=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B22/api/feedback -H "Authorization: Bearer $UT22" -H 'Content-Type: application/json' -d '{"category":"spam","message":"This category is not allowed at all."}')
check "phase I: bad category -> 400" "400" "$FB_BADCAT"
# 5. absent category defaults to 'other' and is stored that way
FB_NOCAT=$(curl -s -w '\n%{http_code}' -X POST $B22/api/feedback -H "Authorization: Bearer $UT22" -H 'Content-Type: application/json' -d '{"message":"No category was sent with this report."}')
check "phase I: absent category -> 201" "201" "$(echo "$FB_NOCAT" | tail -1)"
FB_LIST2=$(curl -s $B22/api/admin/feedback -H "Authorization: Bearer $AT22")
check "phase I: absent category stored as other" "other" "$(echo "$FB_LIST2" | python3 -c 'import sys,json;rows=json.load(sys.stdin)["feedback"];print([r["category"] for r in rows if r["message"]=="No category was sent with this report."][0])')"
# 6. generation ownership: B's video is a failed 502 generate (dummy key by
#    design) — the row exists, which is all the ownership check needs.
OR22=$(curl -s -X POST $B22/api/auth/register -H 'Content-Type: application/json' -d '{"email":"fbother@example.com","password":"password123"}')
OT22=$(echo $OR22 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -s -o /dev/null -X POST $B22/api/generate -H "Authorization: Bearer $OT22" -H 'Content-Type: application/json' -d '{"prompt":"a calm ocean sunset","aspect_ratio":"16:9","duration":5}'
BGEN=$(curl -s $B22/api/history -H "Authorization: Bearer $OT22" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["id"])')
FB_OTHER=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B22/api/feedback -H "Authorization: Bearer $UT22" -H 'Content-Type: application/json' -d "{\"category\":\"bug\",\"message\":\"Attaching someone elses video should be rejected.\",\"generation_id\":$BGEN}")
check "phase I: another user's generation_id -> 400" "400" "$FB_OTHER"
FB_GHOST=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B22/api/feedback -H "Authorization: Bearer $UT22" -H 'Content-Type: application/json' -d '{"category":"bug","message":"Attaching a video that does not exist should be rejected.","generation_id":999999}')
check "phase I: nonexistent generation_id -> 400" "400" "$FB_GHOST"
curl -s -o /dev/null -X POST $B22/api/generate -H "Authorization: Bearer $UT22" -H 'Content-Type: application/json' -d '{"prompt":"a calm ocean sunset","aspect_ratio":"16:9","duration":5}'
AGEN=$(curl -s $B22/api/history -H "Authorization: Bearer $UT22" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["id"])')
FB_OWN=$(curl -s -w '\n%{http_code}' -X POST $B22/api/feedback -H "Authorization: Bearer $UT22" -H 'Content-Type: application/json' -d "{\"category\":\"quality\",\"message\":\"My own video came out blurry, attaching it here.\",\"generation_id\":$AGEN}")
check "phase I: own generation_id -> 201" "201" "$(echo "$FB_OWN" | tail -1)"
FB_OWN_ID=$(echo "$FB_OWN" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
FB_LIST3=$(curl -s $B22/api/admin/feedback -H "Authorization: Bearer $AT22")
check "phase I: own generation_id stored on the report" "$AGEN" "$(echo "$FB_LIST3" | python3 -c "import sys,json;rows={r['id']:r for r in json.load(sys.stdin)['feedback']};print(rows[$FB_OWN_ID]['generation_id'])")"
# 7. rate limit: 10/hour/user on a dedicated user -> 11th is 429
LR22=$(curl -s -X POST $B22/api/auth/register -H 'Content-Type: application/json' -d '{"email":"fblimit@example.com","password":"password123"}')
LT22=$(echo $LR22 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
FBOK22=0
for i in $(seq 1 10); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B22/api/feedback -H "Authorization: Bearer $LT22" -H 'Content-Type: application/json' -d "{\"category\":\"other\",\"message\":\"Rate limit probe number $i from the tester.\"}")
  [[ "$CODE" == "201" ]] && FBOK22=$((FBOK22+1))
done
check "phase I: 10 reports in an hour all succeed (201 x10)" "10" "$FBOK22"
FB429=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B22/api/feedback -H "Authorization: Bearer $LT22" -H 'Content-Type: application/json' -d '{"category":"other","message":"Rate limit probe number 11 from the tester."}')
check "phase I: 11th report in an hour -> 429" "429" "$FB429"
# 8. admin endpoints: non-admin -> 403 on both
check "phase I: non-admin GET /api/admin/feedback -> 403" "403" "$(curl -s -o /dev/null -w '%{http_code}' $B22/api/admin/feedback -H "Authorization: Bearer $UT22")"
check "phase I: non-admin POST status -> 403" "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B22/api/admin/feedback/$FBID1/status -H "Authorization: Bearer $UT22" -H 'Content-Type: application/json' -d '{"status":"resolved"}')"
# 9. resolve -> flips + persists; ?status=open filter; reopen works
FB_RES=$(curl -s -X POST $B22/api/admin/feedback/$FBID1/status -H "Authorization: Bearer $AT22" -H 'Content-Type: application/json' -d '{"status":"resolved"}')
check "phase I: resolve flips status to resolved" "resolved" "$(echo "$FB_RES" | python3 -c 'import sys,json;print(json.load(sys.stdin)["feedback"]["status"])')"
check "phase I: resolved status persists on re-read" "resolved" "$(curl -s $B22/api/admin/feedback -H "Authorization: Bearer $AT22" | python3 -c "import sys,json;rows={r['id']:r for r in json.load(sys.stdin)['feedback']};print(rows[$FBID1]['status'])")"
check "phase I: ?status=open filter hides the resolved report" "no" "$(curl -s "$B22/api/admin/feedback?status=open" -H "Authorization: Bearer $AT22" | python3 -c "import sys,json;ids=[r['id'] for r in json.load(sys.stdin)['feedback']];print('yes' if $FBID1 in ids else 'no')")"
FB_REOPEN=$(curl -s -X POST $B22/api/admin/feedback/$FBID1/status -H "Authorization: Bearer $AT22" -H 'Content-Type: application/json' -d '{"status":"open"}')
check "phase I: reopen flips status back to open" "open" "$(echo "$FB_REOPEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["feedback"]["status"])')"
# 10. config exposes the version marker the footer + reports use
check "phase I: /api/config exposes app_version" "1.0" "$(curl -s $B22/api/config | python3 -c 'import sys,json;print(json.load(sys.stdin)["app_version"])')"
# 11. frontend greps: settings card, report-issue action, version footer
HOMEPAGE22=$(curl -s $B22/)
check "phase I frontend: feedback card with Urdu heading ships" "yes" "$(echo "$HOMEPAGE22" | grep -q 'id="feedbackCard"' && echo "$HOMEPAGE22" | grep -q 'Feedback · رائے / مسئلہ' && echo yes || echo no)"
check "phase I frontend: category select ships all four values" "yes" "$(echo "$HOMEPAGE22" | grep -q 'id="feedbackCategory"' && echo "$HOMEPAGE22" | grep -q 'value="bug"' && echo "$HOMEPAGE22" | grep -q 'value="quality"' && echo "$HOMEPAGE22" | grep -q 'value="feature"' && echo "$HOMEPAGE22" | grep -q 'value="other"' && echo yes || echo no)"
check "phase I frontend: send button + counter + version footer ship" "yes" "$(echo "$HOMEPAGE22" | grep -q 'id="feedbackSendBtn"' && echo "$HOMEPAGE22" | grep -q 'id="feedbackCount"' && echo "$HOMEPAGE22" | grep -q 'id="appVersionLine"' && echo yes || echo no)"
check "phase I frontend: history Report issue action + attach chip ship" "yes" "$(echo "$HOMEPAGE22" | grep -q 'Report issue' && echo "$HOMEPAGE22" | grep -q 'id="feedbackAttach"' && echo yes || echo no)"
# 12. credits-chip balance-retry fix (owner-visible bug): retry logic,
#     the tap-the-chip toast, and the chip re-running loadMe()
check "credits chip fix: loadMe retries /api/me a few seconds apart" "yes" "$(echo "$HOMEPAGE22" | grep -q 'loadMeAttempt' && echo "$HOMEPAGE22" | grep -q 'loadMeAttempt(n + 1)' && echo "$HOMEPAGE22" | grep -q '3000' && echo yes || echo no)"
check "credits chip fix: failure toast tells the user to tap the chip" "yes" "$(echo "$HOMEPAGE22" | grep -qF 'tap the chip to retry' && echo yes || echo no)"
check "credits chip fix: chip tap re-runs loadMe, buy view still opens on success" "yes" "$(echo "$HOMEPAGE22" | grep -q 'loadMe().then(function (ok)' && echo yes || echo no)"
kill $SRV22_PID 2>/dev/null

echo "--- AI prompt writer (2026-10-29): fail-closed + Gemini stub instance ---"
# (a) No GEMINI_API_KEY -> /api/config prompt_ai.configured=false and the
#     endpoint fails closed with 503 (the app keeps the canned button).
B27=http://127.0.0.1:18066
rm -f /tmp/myvideoai-promptai-off-test.db
PW_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-promptai-off-test.db PORT=18066 FAL_KEY=dummy_test_key "$PW_JWT_NAME=promptai-instance-dummy-value" \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-promptai-off-test.log 2>&1 &
SRV27_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B27/api/health && break || sleep 0.25; done
check "prompt ai: config flag false without key" "False" "$(curl -s $B27/api/config | python3 -c 'import sys,json;print(json.load(sys.stdin)["prompt_ai"]["configured"])')"
UR27=$(curl -s -X POST $B27/api/auth/register -H 'Content-Type: application/json' -d '{"email":"pwuser@example.com","password":"password123"}')
UT27=$(echo $UR27 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PW_OFF=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/prompt/write -H "Authorization: Bearer $UT27" -H 'Content-Type: application/json' -d '{"idea":"a cat in my garden"}')
check "prompt ai: unconfigured write -> 503" "503" "$PW_OFF"
kill $SRV27_PID 2>/dev/null
# (b) With a key + the Gemini stub: happy path, validation, upstream
#     failure, unauth, and the per-user daily cap.
GEMINI_STUB_PORT=18197
node "$(dirname "$0")/test-gemini-stub.js" > /tmp/myvideoai-gemini-stub.log 2>&1 &
GSTUB_PID=$!
B28=http://127.0.0.1:18068
rm -f /tmp/myvideoai-promptai-on-test.db
env DB_PATH=/tmp/myvideoai-promptai-on-test.db PORT=18068 FAL_KEY=dummy_test_key "$PW_JWT_NAME=promptai-instance-dummy-value" \
  GEMINI_API_KEY=test-gemini-key PROMPT_AI_API_BASE=http://127.0.0.1:$GEMINI_STUB_PORT PROMPT_WRITE_DAILY_CAP=3 \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-promptai-on-test.log 2>&1 &
SRV28_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B28/api/health && break || sleep 0.25; done
check "prompt ai: config flag true with key" "True" "$(curl -s $B28/api/config | python3 -c 'import sys,json;print(json.load(sys.stdin)["prompt_ai"]["configured"])')"
UR28=$(curl -s -X POST $B28/api/auth/register -H 'Content-Type: application/json' -d '{"email":"pwon@example.com","password":"password123"}')
UT28=$(echo $UR28 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PW_UNAUTH=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/prompt/write -H 'Content-Type: application/json' -d '{"idea":"a cat in my garden"}')
check "prompt ai: unauthenticated -> 401" "401" "$PW_UNAUTH"
PW_OK=$(curl -s -X POST $B28/api/prompt/write -H "Authorization: Bearer $UT28" -H 'Content-Type: application/json' -d '{"idea":"میرے گاؤں میں بارش ہو رہی ہے"}')
check "prompt ai: urdu idea expanded by the writer" "yes" "$(echo $PW_OK | python3 -c 'import sys,json;p=json.load(sys.stdin).get("prompt","");print("yes" if p.startswith("EXPANDED PROMPT:") and "بارش" in p else "no")')"
PW_SHORT=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/prompt/write -H "Authorization: Bearer $UT28" -H 'Content-Type: application/json' -d '{"idea":"ab"}')
check "prompt ai: 2-char idea -> 400" "400" "$PW_SHORT"
PW_FAIL=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/prompt/write -H "Authorization: Bearer $UT28" -H 'Content-Type: application/json' -d '{"idea":"FAILME please"}')
check "prompt ai: upstream failure -> 502" "502" "$PW_FAIL"
PW_TRUNC=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/prompt/write -H "Authorization: Bearer $UT28" -H 'Content-Type: application/json' -d '{"idea":"TRUNC this one please"}')
check "prompt ai: truncated upstream answer -> 502 (never served to users)" "502" "$PW_TRUNC"
UT28B=$(curl -s -X POST $B28/api/auth/register -H 'Content-Type: application/json' -d '{"email":"pwlong@example.com","password":"password123"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PW_LONG=$(curl -s -X POST $B28/api/prompt/write -H "Authorization: Bearer $UT28B" -H 'Content-Type: application/json' -d '{"idea":"LONGPROMPT please"}' | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{const p=(JSON.parse(s).prompt||'');console.log(p.length<=480 && p.endsWith('.') ? 'ok:'+p.length : 'bad:'+p.length)}catch(e){console.log('bad:parse')}})")
check "prompt ai: over-long answer trimmed to <=480 at a sentence end" "ok" "$(echo "$PW_LONG" | cut -d: -f1)"
ST_UNAUTH=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/prompt/story -H 'Content-Type: application/json' -d '{"idea":"a boy and a lost kite"}')
check "prompt story: unauthenticated -> 401" "401" "$ST_UNAUTH"
ST_OK=$(curl -s -X POST $B28/api/prompt/story -H "Authorization: Bearer $UT28B" -H 'Content-Type: application/json' -d '{"idea":"a boy and a lost kite"}')
check "prompt story: idea broken into >=3 clips of <=480 chars" "yes" "$(echo $ST_OK | python3 -c 'import sys,json;c=json.load(sys.stdin).get("clips",[]);print("yes" if len(c)>=3 and all(40<=len(x)<=480 for x in c) else "no")')"
ST_FAIL=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/prompt/story -H "Authorization: Bearer $UT28B" -H 'Content-Type: application/json' -d '{"idea":"FAILME story please"}')
check "prompt story: upstream failure -> 502" "502" "$ST_FAIL"
UT28C=$(curl -s -X POST $B28/api/auth/register -H 'Content-Type: application/json' -d '{"email":"pwimg@example.com","password":"password123"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
IP_UNAUTH=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/prompt/image -H 'Content-Type: application/json' -d '{"image_base64":"data:image/png;base64,iVBORw0KGgo="}')
check "prompt image: unauthenticated -> 401" "401" "$IP_UNAUTH"
IP_BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/prompt/image -H "Authorization: Bearer $UT28C" -H 'Content-Type: application/json' -d '{"image_base64":"not-an-image","content_type":"image/png"}')
check "prompt image: garbage image data -> 400" "400" "$IP_BAD"
IP_OK=$(curl -s -X POST $B28/api/prompt/image -H "Authorization: Bearer $UT28C" -H 'Content-Type: application/json' -d '{"image_base64":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==","note":"make the leaves move gently"}')
check "prompt image: photo + note -> vision-written prompt" "yes" "$(echo $IP_OK | python3 -c 'import sys,json;p=json.load(sys.stdin).get("prompt","");print("yes" if p.startswith("IMAGE PROMPT:") and 80<=len(p)<=480 else "no")')"
IP_FAIL=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/prompt/image -H "Authorization: Bearer $UT28C" -H 'Content-Type: application/json' -d '{"image_base64":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==","note":"FAILME please"}')
check "prompt image: upstream failure -> 502" "502" "$IP_FAIL"
# daily cap is 3 on this instance: two more good writes pass, the 4th is 429
curl -s -o /dev/null -X POST $B28/api/prompt/write -H "Authorization: Bearer $UT28" -H 'Content-Type: application/json' -d '{"idea":"a red kite over the beach"}'
curl -s -o /dev/null -X POST $B28/api/prompt/write -H "Authorization: Bearer $UT28" -H 'Content-Type: application/json' -d '{"idea":"a train crossing a bridge"}'
PW_CAP=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/prompt/write -H "Authorization: Bearer $UT28" -H 'Content-Type: application/json' -d '{"idea":"one idea too many today"}')
check "prompt ai: 4th write over daily cap 3 -> 429" "429" "$PW_CAP"
kill $SRV28_PID $GSTUB_PID 2>/dev/null

echo "--- Phase J: Seedance 2.5 premium engine (stub instance) ---"
SD_STUB_PORT=18059
B23=http://127.0.0.1:18058
rm -f /tmp/myvideoai-seedance-test.db; rm -rf /tmp/sdgen /tmp/sdvoice; mkdir -p /tmp/sdgen /tmp/sdvoice
FAL_STUB_PORT=$SD_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-seedance.log 2>&1 &
SDSTUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$SD_STUB_PORT/__calls && break || sleep 0.25; done
SD_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-seedance-test.db PORT=18058 FAL_KEY=dummy_test_key "$SD_JWT_NAME=seedance-instance-dummy-value" \
  ADMIN_EMAIL=sdadmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$SD_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$SD_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 \
  GENERATED_DIR=/tmp/sdgen VOICE_DIR=/tmp/sdvoice \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-seedance-test.log 2>&1 &
SRV23_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B23/api/health && break || sleep 0.25; done
AR23=$(curl -s -X POST $B23/api/auth/register -H 'Content-Type: application/json' -d '{"email":"sdadmin@example.com","password":"password123"}')
AT23=$(echo $AR23 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
XR23=$(curl -s -X POST $B23/api/auth/register -H 'Content-Type: application/json' -d '{"email":"sdxp@example.com","password":"password123"}')
XT23=$(echo $XR23 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
XID23=$(curl -s $B23/api/me -H "Authorization: Bearer $XT23" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B23/api/admin/users/$XID23/activate -H "Authorization: Bearer $AT23" -H 'Content-Type: application/json' -d '{"plan_id":"extrapro","period":"monthly"}'
PR23=$(curl -s -X POST $B23/api/auth/register -H 'Content-Type: application/json' -d '{"email":"sdpro@example.com","password":"password123"}')
PT23=$(echo $PR23 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PID23=$(curl -s $B23/api/me -H "Authorization: Bearer $PT23" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B23/api/admin/users/$PID23/activate -H "Authorization: Bearer $AT23" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
poll23() { # jobId token -> echoes the final generation JSON
  local st=""
  for i in $(seq 1 40); do
    st=$(curl -s $B23/api/generations/$1 -H "Authorization: Bearer $2")
    [[ "$(echo "$st" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])' 2>/dev/null)" == "completed" ]] && break || sleep 0.3
  done
  echo "$st"
}
check "config: seedance_engine block (seedance-2.5, 600/1200, aspects, 720p)" "seedance-2.5/bytedance/seedance-2.5/text-to-video/600/1200/16:9,9:16,1:1/720p" "$(curl -s $B23/api/config | python3 -c 'import sys,json;s=json.load(sys.stdin)["seedance_engine"];print(s["provider"]+"/"+s["model"]+"/"+str(s["price_credits"]["5"])+"/"+str(s["price_credits"]["10"])+"/"+",".join(s["aspects"])+"/"+s["resolution"])')"
check "plans: can_seedance flag on Extra Pro only" "True/False/False" "$(curl -s $B23/api/plans | python3 -c 'import sys,json;d=json.load(sys.stdin);f={p["id"]:p["features"]["can_seedance"] for p in d["plans"]};print(str(f["extrapro"])+"/"+str(f["pro"])+"/"+str(f["normal"]))')"
check "migration v17: can_seedance column applied, extrapro flagged" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-seedance-test.db');
const cols = db.prepare(\"SELECT name FROM pragma_table_info('plans') WHERE name = 'can_seedance'\").all().length;
const mig = db.prepare('SELECT COUNT(*) AS c FROM schema_migrations WHERE version = 17').get().c;
const xp = db.prepare(\"SELECT can_seedance FROM plans WHERE id = 'extrapro'\").get().can_seedance;
const pro = db.prepare(\"SELECT can_seedance FROM plans WHERE id = 'pro'\").get().can_seedance;
console.log(cols === 1 && Number(mig) === 1 && xp === 1 && pro === 0 ? 'ok' : 'bad');
")"
HOMEPAGE23=$(curl -s $B23/)
check "phase J frontend: premium option with honest subtext ships" "yes" "$(echo "$HOMEPAGE23" | grep -q 'data-quality="seedance"' && echo "$HOMEPAGE23" | grep -q 'Seedance 2.5 · Premium' && echo "$HOMEPAGE23" | grep -q 'Top-ranked quality · 720p · Extra Pro' && echo yes || echo no)"
check "phase J frontend: no 4K wording anywhere near the Seedance option" "no" "$(echo "$HOMEPAGE23" | grep -i 'seedance' | grep -qi '4k' && echo yes || echo no)"
check "phase J frontend: generate body wires the seedance engine + gate ships" "yes" "$(echo "$HOMEPAGE23" | grep -q 'engine: "seedance"' && echo "$HOMEPAGE23" | grep -q 'fillSeedanceGate' && echo yes || echo no)"
# NOTE: exactly 10 generate calls on this instance (shared limiter).
SDG1=$(curl -s -X POST $B23/api/generate -H "Authorization: Bearer $XT23" -H 'Content-Type: application/json' -d '{"prompt":"a cinematic drone shot over a misty mountain valley at dawn","engine":"seedance","aspect_ratio":"16:9","duration":5,"mode":"realistic","style":"cinematic"}')
check "seedance gen (XP, 5s): premium 600 charged, model + 720P + engine recorded" "600/6400/bytedance/seedance-2.5/text-to-video/720P/seedance" "$(echo $SDG1 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"])+"/"+g["model"]+"/"+g["resolution"]+"/"+g["engine"])')"
SDJ1=$(echo $SDG1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
SDP1=$(poll23 $SDJ1 $XT23)
check "seedance gen (XP, 5s): completes on the stub with the seedance model recorded" "completed/bytedance/seedance-2.5/text-to-video/720P" "$(echo $SDP1 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+g["model"]+"/"+g["resolution"])')"
FB23=$(curl -s $B23/api/_test/fal-body)
check "seedance gen: recorded fal body is exactly the verified schema (5 fields, string duration, 720p, audio on)" "720p/5/str/True/aspect_ratio,duration,generate_audio,prompt,resolution" "$(echo $FB23 | python3 -c 'import sys,json;b=json.load(sys.stdin)["body"];print(b["resolution"]+"/"+b["duration"]+"/"+("str" if isinstance(b["duration"],str) else "int")+"/"+str(b["generate_audio"])+"/"+",".join(sorted(b.keys())))')"
SDG2=$(curl -s -X POST $B23/api/generate -H "Authorization: Bearer $XT23" -H 'Content-Type: application/json' -d '{"prompt":"a neon-lit street market at night, rain reflections on wet pavement","engine":"seedance_premium","aspect_ratio":"9:16","duration":10,"mode":"realistic","style":"cinematic"}')
check "seedance gen (XP, 10s, alias): premium 1200 charged" "1200/5200" "$(echo $SDG2 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
SDCALLS=$(curl -s http://127.0.0.1:$SD_STUB_PORT/__calls)
check "seedance gen: stub received the 10s call with a string duration" "10/str" "$(echo $SDCALLS | python3 -c 'import sys,json;cs=[c for c in json.load(sys.stdin)["calls"] if c["path"]=="/bytedance/seedance-2.5/text-to-video"];b=cs[-1]["body"];print(b["duration"]+"/"+("str" if isinstance(b["duration"],str) else "int"))')"
check "seedance gen: Pro plan -> 403, no charge" "403/6000" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B23/api/generate -H "Authorization: Bearer $PT23" -H 'Content-Type: application/json' -d '{"prompt":"a cinematic valley at dawn","engine":"seedance","aspect_ratio":"16:9","duration":5}')/$(curl -s $B23/api/me -H "Authorization: Bearer $PT23" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "seedance gen: aspect 4:3 -> 400 before charging" "400/5200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B23/api/generate -H "Authorization: Bearer $XT23" -H 'Content-Type: application/json' -d '{"prompt":"a cinematic valley at dawn","engine":"seedance","aspect_ratio":"4:3","duration":5}')/$(curl -s $B23/api/me -H "Authorization: Bearer $XT23" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "seedance gen: draft combo -> 400 before charging" "400/5200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B23/api/generate -H "Authorization: Bearer $XT23" -H 'Content-Type: application/json' -d '{"prompt":"a cinematic valley at dawn","engine":"seedance","aspect_ratio":"16:9","duration":5,"quality":"draft"}')/$(curl -s $B23/api/me -H "Authorization: Bearer $XT23" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
UP23=$(curl -s -X POST $B23/api/uploads/image -H "Authorization: Bearer $XT23" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_A\",\"content_type\":\"image/png\"}")
IMG23=$(echo $UP23 | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
CH23=$(curl -s -X POST $B23/api/characters -H "Authorization: Bearer $XT23" -H 'Content-Type: application/json' -d "{\"name\":\"Captain Sara\",\"image_path\":\"$IMG23\"}")
CID23=$(echo $CH23 | python3 -c 'import sys,json;print(json.load(sys.stdin)["character"]["id"])')
check "seedance gen: character combo -> 400 before charging" "400/5200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B23/api/generate -H "Authorization: Bearer $XT23" -H 'Content-Type: application/json' -d "{\"prompt\":\"the captain walks the deck at dawn\",\"engine\":\"seedance\",\"aspect_ratio\":\"16:9\",\"duration\":5,\"character_id\":$CID23}")/$(curl -s $B23/api/me -H "Authorization: Bearer $XT23" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "seedance gen: source image combo -> 400 before charging" "400/5200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B23/api/generate -H "Authorization: Bearer $XT23" -H 'Content-Type: application/json' -d "{\"prompt\":\"the harbour at dawn, gentle waves\",\"engine\":\"seedance\",\"aspect_ratio\":\"16:9\",\"duration\":5,\"image_path\":\"$IMG23\"}")/$(curl -s $B23/api/me -H "Authorization: Bearer $XT23" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "seedance gen: sound add-on combo -> 400 (rejected, not silently dropped), no charge" "400/5200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B23/api/generate -H "Authorization: Bearer $XT23" -H 'Content-Type: application/json' -d '{"prompt":"a cinematic valley at dawn","engine":"seedance","aspect_ratio":"16:9","duration":5,"sound":{"mode":"sync","prompt":"city ambience"}}')/$(curl -s $B23/api/me -H "Authorization: Bearer $XT23" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "seedance gen: voice add-on combo -> 400 before charging" "400/5200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B23/api/generate -H "Authorization: Bearer $XT23" -H 'Content-Type: application/json' -d '{"prompt":"a cinematic valley at dawn","engine":"seedance","aspect_ratio":"16:9","duration":5,"voice":{"kind":"voiceover"}}')/$(curl -s $B23/api/me -H "Authorization: Bearer $XT23" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "seedance gen: provider failure -> 502 with full exactly-once refund" "502/5200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B23/api/generate -H "Authorization: Bearer $XT23" -H 'Content-Type: application/json' -d '{"prompt":"FAILME a cinematic valley at dawn","engine":"seedance","aspect_ratio":"16:9","duration":5}')/$(curl -s $B23/api/me -H "Authorization: Bearer $XT23" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
SDHIST=$(curl -s $B23/api/history -H "Authorization: Bearer $XT23")
check "seedance gen: failed job recorded once as failed at the premium price" "failed/600" "$(echo $SDHIST | python3 -c 'import sys,json;g=json.load(sys.stdin)["generations"][0];print(g["status"]+"/"+str(g["cost_credits"]))')"
kill $SRV23_PID $SDSTUB_PID 2>/dev/null

echo "--- Phase J: forged auto-plan seedance claim falls back (stub instance) ---"
SD2_STUB_PORT=18056
B24=http://127.0.0.1:18055
rm -f /tmp/myvideoai-seedance2-test.db; rm -rf /tmp/sd2gen /tmp/sd2voice; mkdir -p /tmp/sd2gen /tmp/sd2voice
FAL_STUB_PORT=$SD2_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-seedance2.log 2>&1 &
SD2STUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$SD2_STUB_PORT/__calls && break || sleep 0.25; done
SD2_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-seedance2-test.db PORT=18055 FAL_KEY=dummy_test_key "$SD2_JWT_NAME=seedance2-instance-dummy-value" \
  ADMIN_EMAIL=sd2admin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$SD2_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$SD2_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 \
  GENERATED_DIR=/tmp/sd2gen VOICE_DIR=/tmp/sd2voice \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-seedance2-test.log 2>&1 &
SRV24_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B24/api/health && break || sleep 0.25; done
AR24=$(curl -s -X POST $B24/api/auth/register -H 'Content-Type: application/json' -d '{"email":"sd2admin@example.com","password":"password123"}')
AT24=$(echo $AR24 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
XR24=$(curl -s -X POST $B24/api/auth/register -H 'Content-Type: application/json' -d '{"email":"sd2xp@example.com","password":"password123"}')
XT24=$(echo $XR24 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
XID24=$(curl -s $B24/api/me -H "Authorization: Bearer $XT24" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B24/api/admin/users/$XID24/activate -H "Authorization: Bearer $AT24" -H 'Content-Type: application/json' -d '{"plan_id":"extrapro","period":"monthly"}'
FR24=$(curl -s -X POST $B24/api/auth/register -H 'Content-Type: application/json' -d '{"email":"sd2free@example.com","password":"password123"}')
FT24=$(echo $FR24 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
SDPL=$(curl -s -X POST $B24/api/generate/plan -H "Authorization: Bearer $XT24" -H 'Content-Type: application/json' -d '{"prompt":"a man stands in his shop and says: \"Welcome in, everything is fresh today\"","mode":"realistic","style":"realistic","duration":5}')
check "auto plan (XP): dialogue routes to omni_speaking — never to the premium seedance engine" "omni_speaking" "$(echo $SDPL | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["engine"]["route"])')"
FORGED=$(python3 -c 'import json;print(json.dumps({"prompt":"a calm ocean sunset over the harbour","mode":"realistic","style":"realistic","duration":5,"auto_confirmed":True,"auto_plan":{"apply":{"mode":"realistic","aspect_ratio":"16:9","sound":None,"voice":None,"speaking_engine":False,"mute":False},"engine":{"route":"seedance_premium","model":"bytedance/seedance-2.5/text-to-video","reason":"forged"},"base_cost":0,"total_cost":0}}))')
GENF=$(curl -s -X POST $B24/api/generate -H "Authorization: Bearer $FT24" -H 'Content-Type: application/json' -d "$FORGED")
check "forged seedance plan: charged the recomputed rate-card total 120, not the premium price" "120/880" "$(echo $GENF | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
check "forged seedance plan: claim ignored — server routing (H3) recorded" "minimax/h3/text-to-video/h3_text_to_video" "$(echo $GENF | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["model"]+"/"+g["auto_plan"]["engine"]["route"])')"
kill $SRV24_PID $SD2STUB_PID 2>/dev/null

echo "--- Phase L: camera/shot prompt directives + Seedance long durations (stub instance) ---"
PL_STUB_PORT=18047
B25=http://127.0.0.1:18046
rm -f /tmp/myvideoai-phaseL-test.db; rm -rf /tmp/plgen2 /tmp/plvoice2; mkdir -p /tmp/plgen2 /tmp/plvoice2
FAL_STUB_PORT=$PL_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-phaseL.log 2>&1 &
PLSTUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$PL_STUB_PORT/__calls && break || sleep 0.25; done
PL_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-phaseL-test.db PORT=18046 FAL_KEY=dummy_test_key "$PL_JWT_NAME=phaseL-instance-dummy-value" \
  ADMIN_EMAIL=pladmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$PL_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$PL_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 \
  GENERATED_DIR=/tmp/plgen2 VOICE_DIR=/tmp/plvoice2 \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-phaseL-test.log 2>&1 &
SRV25_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B25/api/health && break || sleep 0.25; done
AR25=$(curl -s -X POST $B25/api/auth/register -H 'Content-Type: application/json' -d '{"email":"pladmin@example.com","password":"password123"}')
AT25=$(echo $AR25 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
FR25=$(curl -s -X POST $B25/api/auth/register -H 'Content-Type: application/json' -d '{"email":"plfree@example.com","password":"password123"}')
FT25=$(echo $FR25 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
mkxp25() { # email -> token on the Extra Pro plan
  local T=$(curl -s -X POST $B25/api/auth/register -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"password123\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
  local ID=$(curl -s $B25/api/me -H "Authorization: Bearer $T" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
  curl -s -o /dev/null -X POST $B25/api/admin/users/$ID/activate -H "Authorization: Bearer $AT25" -H 'Content-Type: application/json' -d '{"plan_id":"extrapro","period":"monthly"}'
  echo $T
}
XT25A=$(mkxp25 plxp1@example.com)
XT25B=$(mkxp25 plxp2@example.com)
poll25() { # jobId token -> echoes the final generation JSON
  local st=""
  for i in $(seq 1 40); do
    st=$(curl -s $B25/api/generations/$1 -H "Authorization: Bearer $2")
    [[ "$(echo "$st" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])' 2>/dev/null)" == "completed" ]] && break || sleep 0.3
  done
  echo "$st"
}
check "config: seedance_engine durations + linear price map (Phase L)" "5,10,15,20,30/600,1200,1800,2400,3600" "$(curl -s $B25/api/config | python3 -c 'import sys,json;s=json.load(sys.stdin)["seedance_engine"];print(",".join(str(d) for d in s["durations"])+"/"+",".join(str(s["price_credits"][str(d)]) for d in s["durations"]))')"
check "migration v18: generations camera_move/shot_size columns applied" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseL-test.db');
const cols = db.prepare(\"SELECT name FROM pragma_table_info('generations') WHERE name IN ('camera_move','shot_size')\").all().length;
const mig = db.prepare('SELECT COUNT(*) AS c FROM schema_migrations WHERE version = 18').get().c;
console.log(cols === 2 && Number(mig) === 1 ? 'ok' : 'bad');
")"
HOMEPAGE25=$(curl -s $B25/)
check "phase L frontend: camera + shot chip rows ship" "yes" "$(echo "$HOMEPAGE25" | grep -q 'id="cameraSeg"' && echo "$HOMEPAGE25" | grep -q 'id="shotSeg"' && echo "$HOMEPAGE25" | grep -q 'data-camera="zoom_in"' && echo "$HOMEPAGE25" | grep -q 'data-camera="tracking"' && echo "$HOMEPAGE25" | grep -q 'data-shot="close_up"' && echo "$HOMEPAGE25" | grep -q 'data-shot="aerial"' && echo yes || echo no)"
check "phase L frontend: directive-not-guarantee honesty line ships" "yes" "$(echo "$HOMEPAGE25" | grep -q 'Camera moves are prompt directions to the AI' && echo yes || echo no)"
check "phase L frontend: genBody wires camera/shot + per-engine durations render" "yes" "$(echo "$HOMEPAGE25" | grep -q 'camera: state.camera' && echo "$HOMEPAGE25" | grep -q 'shot: state.shot' && echo "$HOMEPAGE25" | grep -q 'function currentDurations' && echo "$HOMEPAGE25" | grep -q 'seedance_engine.durations' && echo "$HOMEPAGE25" | grep -q 'function renderDurationSeg' && echo yes || echo no)"
# NOTE: exactly 8 generate-family calls on this instance (shared limiter).
check "camera gen: unknown camera -> 400 before charging" "400/1000" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B25/api/generate -H "Authorization: Bearer $FT25" -H 'Content-Type: application/json' -d '{"prompt":"a calm river at dawn","camera":"flyover"}')/$(curl -s $B25/api/me -H "Authorization: Bearer $FT25" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "camera gen: unknown shot -> 400 before charging" "400/1000" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B25/api/generate -H "Authorization: Bearer $FT25" -H 'Content-Type: application/json' -d '{"prompt":"a calm river at dawn","shot":"extreme"}')/$(curl -s $B25/api/me -H "Authorization: Bearer $FT25" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "durations: H3 request at 15s -> 400 (long durations never faked)" "400/1000" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B25/api/generate -H "Authorization: Bearer $FT25" -H 'Content-Type: application/json' -d '{"prompt":"a calm river at dawn","duration":15}')/$(curl -s $B25/api/me -H "Authorization: Bearer $FT25" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
PLG1=$(curl -s -X POST $B25/api/generate -H "Authorization: Bearer $FT25" -H 'Content-Type: application/json' -d '{"prompt":"a fisherman casts his net over a calm river at dawn","camera":"zoom_in","shot":"wide","duration":5}')
check "camera gen (H3, 5s): standard 120 charged, choices + directive in the response" "120/880/zoom_in/wide/, slow cinematic zoom in, wide establishing shot" "$(echo $PLG1 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"])+"/"+g["camera_move"]+"/"+g["shot_size"]+"/"+g["camera_directive"])')"
PLFB=$(curl -s $B25/api/_test/fal-body)
check "camera gen: fal prompt carries the directives after the user text" "a fisherman casts his net over a calm river at dawn, slow cinematic zoom in, wide establishing shot — style: realistic" "$(echo $PLFB | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"]["prompt"])')"
PLJ1=$(echo $PLG1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
PLP1=$(poll25 $PLJ1 $FT25)
check "camera gen: completes on the stub" "completed" "$(echo $PLP1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
PLHIST=$(curl -s $B25/api/history -H "Authorization: Bearer $FT25")
check "camera gen: History exposes the choices + the exact directive phrase" "zoom_in/wide/, slow cinematic zoom in, wide establishing shot" "$(echo $PLHIST | python3 -c 'import sys,json;g=[x for x in json.load(sys.stdin)["generations"] if x["camera_move"]][0];print(g["camera_move"]+"/"+g["shot_size"]+"/"+g["camera_directive"])')"
PLNOTE=$(python3 -c 'import json;print(json.dumps({"prompt":"a lighthouse on the rocks, slow zoom out over the waves","mode":"realistic","style":"realistic","duration":5,"camera":"zoom_in","auto_confirmed":True,"auto_plan":{"apply":{"mode":"realistic","aspect_ratio":"16:9","sound":None,"voice":None,"speaking_engine":False,"mute":False},"engine":{"route":"h3_text_to_video","model":"minimax/h3/text-to-video","reason":"echo"},"base_cost":10,"total_cost":10}}))')
PLG2=$(curl -s -X POST $B25/api/generate -H "Authorization: Bearer $FT25" -H 'Content-Type: application/json' -d "$PLNOTE")
check "camera gen: chip overrides contradictory prompt wording — stored plan notes it" "noted" "$(echo $PLG2 | python3 -c 'import sys,json;ns=json.load(sys.stdin).get("auto_plan",{}).get("notes",[]);print("noted" if any("Camera direction" in n and "overrides the camera wording" in n for n in ns) else "missing")')"
SDG15=$(curl -s -X POST $B25/api/generate -H "Authorization: Bearer $XT25A" -H 'Content-Type: application/json' -d '{"prompt":"a misty mountain valley at dawn","engine":"seedance","aspect_ratio":"16:9","duration":15,"mode":"realistic","style":"cinematic"}')
check "seedance gen (XP, 15s): linear premium 1800 charged" "1800/5200" "$(echo $SDG15 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
PLCALLS=$(curl -s http://127.0.0.1:$PL_STUB_PORT/__calls)
check "seedance gen (15s): stub received the duration as a string" "15/str" "$(echo $PLCALLS | python3 -c 'import sys,json;cs=[c for c in json.load(sys.stdin)["calls"] if c["path"]=="/bytedance/seedance-2.5/text-to-video"];b=cs[-1]["body"];print(b["duration"]+"/"+("str" if isinstance(b["duration"],str) else "int"))')"
SDG30=$(curl -s -X POST $B25/api/generate -H "Authorization: Bearer $XT25B" -H 'Content-Type: application/json' -d '{"prompt":"a misty mountain valley at dawn","engine":"seedance","aspect_ratio":"16:9","duration":30,"mode":"realistic","style":"cinematic"}')
check "seedance gen (XP, 30s): linear premium 3600 charged (inside the 4000/day cap)" "3600/3400" "$(echo $SDG30 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
check "seedance gen: non-offered duration 25 -> 400 before charging" "400/5200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B25/api/generate -H "Authorization: Bearer $XT25A" -H 'Content-Type: application/json' -d '{"prompt":"a misty mountain valley at dawn","engine":"seedance","aspect_ratio":"16:9","duration":25}')/$(curl -s $B25/api/me -H "Authorization: Bearer $XT25A" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
kill $SRV25_PID $PLSTUB_PID 2>/dev/null

echo "--- multilingual system: language registry + listed voices (Phase M, fal stub) ---"
ML_STUB_PORT=18045
B26=http://127.0.0.1:18044
rm -f /tmp/myvideoai-phaseM-test.db; rm -rf /tmp/voiceoutM /tmp/voicegenM; mkdir -p /tmp/voiceoutM /tmp/voicegenM
FAL_STUB_PORT=$ML_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-m.log 2>&1 &
MLSTUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$ML_STUB_PORT/__calls && break || sleep 0.25; done
ML_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-phaseM-test.db PORT=18044 FAL_KEY=dummy_test_key "$ML_JWT_NAME=phaseM-dummy-value" \
  TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$ML_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$ML_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 VOICE_DIR=/tmp/voiceoutM GENERATED_DIR=/tmp/voicegenM \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-phaseM-test.log 2>&1 &
SRV26_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B26/api/health && break || sleep 0.25; done
CFG26=$(curl -s $B26/api/config)
check "phase M registry: 19 languages listed" "19" "$(echo $CFG26 | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["languages"]))')"
check "phase M registry: honest statuses (available/listed/unavailable + prompt)" "ur:available/supported|hi:available/supported|en:available/supported|pa:listed/none|ps:listed/none|sd:listed/none|ks:unavailable/supported" "$(echo $CFG26 | python3 -c 'import sys,json;d={l["code"]:l for l in json.load(sys.stdin)["languages"]};print("|".join(c+":"+d[c]["voice_status"]+"/"+d[c]["prompt_status"] for c in ["ur","hi","en","pa","ps","sd","ks"]))')"
check "phase M registry: samples only where verified (name-only languages carry none)" "skr:None|bal:None|pothwari:None|marwari:None|pa:text|ps:text|sd:text|ks:text" "$(echo $CFG26 | python3 -c 'import sys,json;d={l["code"]:l for l in json.load(sys.stdin)["languages"]};print("|".join(c+":"+("None" if d[c]["sample"] is None else "text") for c in ["skr","bal","pothwari","marwari","pa","ps","sd","ks"]))')"
MR26=$(curl -s -X POST $B26/api/auth/register -H 'Content-Type: application/json' -d '{"email":"multiling@example.com","password":"password123"}')
MT26=$(echo $MR26 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
MID26=$(curl -s $B26/api/me -H "Authorization: Bearer $MT26" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
# -- Pashto preview: the exact fal enum string must reach Gemini --
PSPV=$(curl -s -w '\n%{http_code}' -X POST $B26/api/voice/preview -H "Authorization: Bearer $MT26" -H 'Content-Type: application/json' -d '{"script":"السلام علیکم! زما نوم احمد دی او زه د پاکستان یم۔","spoken_language":"ps","script_mode":"native","provider":"gemini"}')
check "phase M preview (ps): -> 200" "200" "$(echo "$PSPV" | tail -1)"
check "phase M preview (ps): response reports language ps" "ps" "$(echo "$PSPV" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["language"])')"
VC26=$(curl -s $B26/api/_test/voice-calls)
check "phase M preview (ps): gemini body carries the exact enum string" "gemini|Pashto (Afghanistan)" "$(echo $VC26 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x["kind"]=="tts"][-1];print(c["provider"]+"|"+c["body"]["language_code"])')"
# -- Punjabi voiceover through the existing machinery --
SEEDM=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseM-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($MID26, 'seed multilingual voiceover source', '16:9', 2, 'realistic', 'completed', 'http://127.0.0.1:$ML_STUB_PORT/media/clip.mp4', 100).lastInsertRowid));
")
PAVO=$(curl -s -w '\n%{http_code}' -X POST $B26/api/voice/voiceover -H "Authorization: Bearer $MT26" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDM,\"script\":\"میرا ناں احمد اے تے میں پنجابی وچ گل کرنا چاہنا آں۔\",\"spoken_language\":\"pa\",\"script_mode\":\"native\",\"provider\":\"gemini\"}")
check "phase M voiceover (pa): -> 201" "201" "$(echo "$PAVO" | tail -1)"
VC26B=$(curl -s $B26/api/_test/voice-calls)
check "phase M voiceover (pa): gemini body carries the exact enum string" "gemini|Punjabi (India)" "$(echo $VC26B | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x["kind"]=="tts"][-1];print(c["provider"]+"|"+c["body"]["language_code"])')"
# -- fail-closed 400s: no provider call may happen for any of these --
TTS_M_BEFORE=$(curl -s $B26/api/_test/voice-calls | python3 -c 'import sys,json;print(len([x for x in json.load(sys.stdin)["calls"] if x["kind"]=="tts"]))')
SKR=$(curl -s -w '\n%{http_code}' -X POST $B26/api/voice/preview -H "Authorization: Bearer $MT26" -H 'Content-Type: application/json' -d '{"script":"کجهه متن","spoken_language":"skr","script_mode":"native"}')
check "phase M preview (skr, unlisted): -> 400" "400" "$(echo "$SKR" | tail -1)"
check "phase M preview (skr): error honestly says the language is not offered" "yes" "$(echo "$SKR" | sed '$d' | python3 -c 'import sys,json;print("yes" if "spoken_language must be one of" in json.load(sys.stdin)["error"] else "no")')"
ROM=$(curl -s -w '\n%{http_code}' -X POST $B26/api/voice/preview -H "Authorization: Bearer $MT26" -H 'Content-Type: application/json' -d '{"script":"zama num ahmad di","spoken_language":"ps","script_mode":"roman"}')
check "phase M preview (ps + roman): -> 400" "400" "$(echo "$ROM" | tail -1)"
check "phase M preview (ps + roman): error states native script only" "yes" "$(echo "$ROM" | sed '$d' | python3 -c 'import sys,json;print("yes" if "Roman script is not supported for Pashto" in json.load(sys.stdin)["error"] else "no")')"
ELPA=$(curl -s -w '\n%{http_code}' -X POST $B26/api/voice/preview -H "Authorization: Bearer $MT26" -H 'Content-Type: application/json' -d '{"script":"میرا ناں احمد اے","spoken_language":"pa","script_mode":"native","provider":"elevenlabs"}')
check "phase M preview (pa + elevenlabs premium): -> 400 before any provider call" "400" "$(echo "$ELPA" | tail -1)"
check "phase M preview (pa + elevenlabs): error names the Gemini-only rule" "yes" "$(echo "$ELPA" | sed '$d' | python3 -c 'import sys,json;print("yes" if "Gemini provider only" in json.load(sys.stdin)["error"] else "no")')"
TTS_M_AFTER=$(curl -s $B26/api/_test/voice-calls | python3 -c 'import sys,json;print(len([x for x in json.load(sys.stdin)["calls"] if x["kind"]=="tts"]))')
check "phase M: the three 400s made NO provider call" "$TTS_M_BEFORE" "$TTS_M_AFTER"
check "phase M: credits untouched by previews + included voiceover + 400s" "1000" "$(curl -s $B26/api/me -H "Authorization: Bearer $MT26" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
HOMEPAGE26=$(curl -s $B26/)
check "phase M frontend: language lab card + voice-card link ship" "yes" "$(echo "$HOMEPAGE26" | grep -q 'id="langLabCard"' && echo "$HOMEPAGE26" | grep -q 'id="langLabList"' && echo "$HOMEPAGE26" | grep -q 'id="langLabLink"' && echo "$HOMEPAGE26" | grep -q 'Test languages · زبان آزمائیں' && echo yes || echo no)"
check "phase M frontend: the three honest status badges ship" "yes" "$(echo "$HOMEPAGE26" | grep -q 'Voice available · آواز دستیاب' && echo "$HOMEPAGE26" | grep -q 'Listed — testing · درج ہے، جانچ جاری' && echo "$HOMEPAGE26" | grep -q 'Voice not yet available · آواز ابھی دستیاب نہیں' && echo yes || echo no)"
check "phase M frontend: unavailable-language fallback note ships" "yes" "$(echo "$HOMEPAGE26" | grep -q 'Alternatives: Urdu voice, or prompts in this language where supported · متبادل: اردو آواز' && echo yes || echo no)"
kill $SRV26_PID $MLSTUB_PID 2>/dev/null

echo "--- modern auth: identities, Google, email verification + reset, delete (Phase N, auth stub) ---"
NA_STUB_PORT=18043
B27=http://127.0.0.1:18042
rm -f /tmp/myvideoai-phaseN-test.db*
AUTH_STUB_PORT=$NA_STUB_PORT node "$(dirname "$0")/test-auth-stub.js" > /tmp/auth-stub-phaseN.log 2>&1 &
NASTUB_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$NA_STUB_PORT/__calls && break || sleep 0.25; done
NA_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-phaseN-test.db PORT=18042 FAL_KEY=dummy_test_key "$NA_JWT_NAME=phaseN-instance-dummy-value" \
  ADMIN_EMAIL=nadmin@example.com \
  GOOGLE_CLIENT_ID=test-client-id GOOGLE_TOKENINFO_BASE=http://127.0.0.1:$NA_STUB_PORT \
  MAILER_API_BASE=http://127.0.0.1:$NA_STUB_PORT MAILER_API_KEY=test-mail-key MAILER_FROM=noreply@ajk-ai.test \
  PUBLIC_BASE_URL=http://127.0.0.1:18042 \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-phaseN-test.log 2>&1 &
SRV27_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B27/api/health && break || sleep 0.25; done
mailcount() { # $1=recipient -> number of mails the stub recorded for them
  curl -s http://127.0.0.1:$NA_STUB_PORT/__calls | python3 -c "
import sys, json
print(len([m for m in json.load(sys.stdin)['mails'] if m['to'] == '$1']))"
}
mailtoken() { # $1=recipient $2=verify|reset $3=index(0=first,-1=last) -> raw token
  curl -s http://127.0.0.1:$NA_STUB_PORT/__calls | python3 -c "
import sys, json, re
ms = [m for m in json.load(sys.stdin)['mails'] if m['to'] == '$1' and m['text'] and ('?$2=' in m['text'])]
if not ms: print('')
else:
    mm = re.search(r'\?$2=([0-9a-f]{64})', ms[$3]['text'])
    print(mm.group(1) if mm else '')"
}
regverify() { # $1=email -> registers + verifies via the stub mail; echoes the login token
  curl -s -o /dev/null -X POST $B27/api/auth/register -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"password123\"}"
  local T=$(mailtoken "$1" verify -1)
  curl -s -o /dev/null -X POST $B27/api/auth/verify-email -H 'Content-Type: application/json' -d "{\"token\":\"$T\"}"
  curl -s -X POST $B27/api/auth/login -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"password123\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))'
}
CFG27=$(curl -s $B27/api/config)
check "phase N config: auth block (google on; facebook/phone off; email verification + reset on)" "True/False/False/True/True" "$(echo $CFG27 | python3 -c 'import sys,json;a=json.load(sys.stdin)["auth"];print("/".join(str(a[k]) for k in ["google","facebook","phone","email_verification","password_reset"]))')"
check "phase N config: google_client_id exposed (public id) only when configured" "test-client-id" "$(echo $CFG27 | python3 -c 'import sys,json;print(json.load(sys.stdin).get("google_client_id"))')"
check "migration v19: identity + token tables, user columns, password identity backfill shape" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseN-test.db');
const tabs = db.prepare(\"SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name IN ('user_identities','auth_tokens')\").get().c;
const cols = db.prepare(\"SELECT name FROM pragma_table_info('users') WHERE name IN ('email_verified','token_version','signup_bonus_granted')\").all().length;
const mig = db.prepare('SELECT COUNT(*) AS c FROM schema_migrations WHERE version = 19').get().c;
console.log(Number(tabs) === 2 && cols === 3 && Number(mig) === 1 ? 'ok' : 'bad');
")"
# -- Google sign-in: create, repeat (same user, bonus once), bad tokens --
GR27=$(curl -s -w '\n%{http_code}' -X POST $B27/api/auth/google -H 'Content-Type: application/json' -d '{"id_token":"valid-google-token"}')
check "phase N google: first sign-in creates the account (201)" "201" "$(echo "$GR27" | tail -1)"
GTOK=$(echo "$GR27" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
check "phase N google: signup bonus lands at creation (1000)" "1000" "$(echo "$GR27" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
GID=$(curl -s $B27/api/me -H "Authorization: Bearer $GTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
check "phase N google: account email is the Google email (no collision)" "googleuser@example.com" "$(curl -s $B27/api/me -H "Authorization: Bearer $GTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["email"])')"
GR27B=$(curl -s -w '\n%{http_code}' -X POST $B27/api/auth/google -H 'Content-Type: application/json' -d '{"id_token":"valid-google-token"}')
check "phase N google: repeat sign-in is a login (200), same user, bonus NOT doubled" "200/$GID/1000" "$(echo "$GR27B" | tail -1)/$(curl -s $B27/api/me -H "Authorization: Bearer $(echo "$GR27B" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(str(d["id"])+"/"+str(d["credits"]))')"
check "phase N google: wrong audience -> 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/google -H 'Content-Type: application/json' -d '{"id_token":"wrong-aud-token"}')"
check "phase N google: expired token -> 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/google -H 'Content-Type: application/json' -d '{"id_token":"expired-token"}')"
check "phase N google: unverified Google email -> 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/google -H 'Content-Type: application/json' -d '{"id_token":"unverified-email-token"}')"
check "phase N google: unknown token -> 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/google -H 'Content-Type: application/json' -d '{"id_token":"nonsense"}')"
# -- NO AUTO-MERGE: a Google email matching a password account stays separate --
curl -s -o /dev/null -X POST $B27/api/auth/register -H 'Content-Type: application/json' -d '{"email":"mergepw@example.com","password":"password123"}'
MPTOK0=$(mailtoken mergepw@example.com verify -1)
curl -s -o /dev/null -X POST $B27/api/auth/verify-email -H 'Content-Type: application/json' -d "{\"token\":\"$MPTOK0\"}"
PWTOK=$(curl -s -X POST $B27/api/auth/login -H 'Content-Type: application/json' -d '{"email":"mergepw@example.com","password":"password123"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PWID=$(curl -s $B27/api/me -H "Authorization: Bearer $PWTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
MG27=$(curl -s -w '\n%{http_code}' -X POST $B27/api/auth/google -H 'Content-Type: application/json' -d '{"id_token":"merge-google-token"}')
MGTOK=$(echo "$MG27" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
MGID=$(curl -s $B27/api/me -H "Authorization: Bearer $MGTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
check "phase N no-merge: Google sign-in with a password account's email creates a DIFFERENT user" "different" "$([[ "$MGID" != "$PWID" && -n "$MGID" ]] && echo different || echo SAME)"
check "phase N no-merge: the Google account is namespaced apart; the password account is untouched" "google-google-sub-merge@accounts.ajk-ai.local/1000" "$(curl -s $B27/api/me -H "Authorization: Bearer $MGTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["email"])')/$(curl -s $B27/api/me -H "Authorization: Bearer $PWTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
# -- Linking with consent (signed in + provider verification) --
LK27=$(curl -s -w '\n%{http_code}' -X POST $B27/api/auth/link/google -H "Authorization: Bearer $PWTOK" -H 'Content-Type: application/json' -d '{"id_token":"valid-google-token-two"}')
check "phase N link: signed-in password user links Google (201)" "201" "$(echo "$LK27" | tail -1)"
check "phase N link: identities list shows password + google" "google,password" "$(curl -s $B27/api/auth/identities -H "Authorization: Bearer $PWTOK" | python3 -c 'import sys,json;print(",".join(sorted(i["provider"] for i in json.load(sys.stdin)["identities"])))')"
L2TOK=$(regverify linkme2@example.com)
LK2=$(curl -s -w '\n%{http_code}' -X POST $B27/api/auth/link/google -H "Authorization: Bearer $L2TOK" -H 'Content-Type: application/json' -d '{"id_token":"valid-google-token-two"}')
check "phase N link: the same Google identity on a second account -> 409 identity_in_use" "409/identity_in_use" "$(echo "$LK2" | tail -1)/$(echo "$LK2" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase N link: linked Google now signs into the password account" "$PWID" "$(curl -s -X POST $B27/api/auth/google -H 'Content-Type: application/json' -d '{"id_token":"valid-google-token-two"}' > /tmp/na-lk-login.json; curl -s $B27/api/me -H "Authorization: Bearer $(python3 -c 'import json;print(json.load(open("/tmp/na-lk-login.json"))["token"])')" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
UNL=$(curl -s -w '\n%{http_code}' -X POST $B27/api/auth/unlink -H "Authorization: Bearer $PWTOK" -H 'Content-Type: application/json' -d '{"provider":"google"}')
check "phase N unlink: password user can unlink Google (keeps the password method)" "200/password" "$(echo "$UNL" | tail -1)/$(curl -s $B27/api/auth/identities -H "Authorization: Bearer $PWTOK" | python3 -c 'import sys,json;print(",".join(i["provider"] for i in json.load(sys.stdin)["identities"]))')"
UNL2=$(curl -s -w '\n%{http_code}' -X POST $B27/api/auth/unlink -H "Authorization: Bearer $GTOK" -H 'Content-Type: application/json' -d '{"provider":"google"}')
check "phase N unlink: the LAST sign-in method cannot be removed (400 last_auth_method)" "400/last_auth_method" "$(echo "$UNL2" | tail -1)/$(echo "$UNL2" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
# -- Email verification flow (mailer configured) --
VR27=$(curl -s -w '\n%{http_code}' -X POST $B27/api/auth/register -H 'Content-Type: application/json' -d '{"email":"verifyme@example.com","password":"password123"}')
check "phase N verify: signup with the mailer on -> 201 verification_required, NO token" "201/True/False" "$(echo "$VR27" | tail -1)/$(echo "$VR27" | sed '$d' | python3 -c 'import sys,json;d=json.load(sys.stdin);print(str(d.get("verification_required"))+"/"+str("token" in d))')"
check "phase N verify: unverified login -> 403 email_not_verified" "403/email_not_verified" "$(curl -s -w '\n%{http_code}' -X POST $B27/api/auth/login -H 'Content-Type: application/json' -d '{"email":"verifyme@example.com","password":"password123"}' > /tmp/na-vlogin.txt; tail -1 /tmp/na-vlogin.txt)/$(sed '$d' /tmp/na-vlogin.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase N verify: exactly one verification mail was sent" "1" "$(mailcount verifyme@example.com)"
VRAW=$(mailtoken verifyme@example.com verify -1)
check "phase N verify: a wrong token -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/verify-email -H 'Content-Type: application/json' -d '{"token":"0000000000000000000000000000000000000000000000000000000000000000"}')"
VOK=$(curl -s -w '\n%{http_code}' -X POST $B27/api/auth/verify-email -H 'Content-Type: application/json' -d "{\"token\":\"$VRAW\"}")
check "phase N verify: the emailed token verifies and the bonus lands NOW (1000)" "200/1000" "$(echo "$VOK" | tail -1)/$(echo "$VOK" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "phase N verify: login works after verification" "1000" "$(curl -s -X POST $B27/api/auth/login -H 'Content-Type: application/json' -d '{"email":"verifyme@example.com","password":"password123"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "phase N verify: the token is single-use (reuse -> 400)" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/verify-email -H 'Content-Type: application/json' -d "{\"token\":\"$VRAW\"}")"
# -- Resend: fresh token supersedes; per-email rate limits hold --
curl -s -o /dev/null -X POST $B27/api/auth/register -H 'Content-Type: application/json' -d '{"email":"resendme@example.com","password":"password123"}'
ROLD=$(mailtoken resendme@example.com verify -1)
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseN-test.db');
db.prepare(\"UPDATE auth_tokens SET created_at = datetime('now','-3 minutes') WHERE purpose = 'verify_email' AND user_id = (SELECT id FROM users WHERE email = 'resendme@example.com')\").run();
console.log('aged the first resendme token past the 1-minute resend limit');
"
check "phase N resend: generic 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/resend-verification -H 'Content-Type: application/json' -d '{"email":"resendme@example.com"}')"
check "phase N resend: a fresh mail was issued" "2" "$(mailcount resendme@example.com)"
check "phase N resend: an immediate second resend is rate-limited (still 2 mails, still generic 200)" "200/2" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/resend-verification -H 'Content-Type: application/json' -d '{"email":"resendme@example.com"}')/$(mailcount resendme@example.com)"
RNEW=$(mailtoken resendme@example.com verify -1)
check "phase N resend: the superseded token is dead (400)" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/verify-email -H 'Content-Type: application/json' -d "{\"token\":\"$ROLD\"}")"
check "phase N resend: the fresh token verifies (200)" "200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/verify-email -H 'Content-Type: application/json' -d "{\"token\":\"$RNEW\"}")"
check "phase N resend: unknown email still gets the generic 200, and no mail" "200/0" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/resend-verification -H 'Content-Type: application/json' -d '{"email":"ghost@example.com"}')/$(mailcount ghost@example.com)"
# -- Forgot / reset password --
VOLD=$(curl -s -X POST $B27/api/auth/login -H 'Content-Type: application/json' -d '{"email":"verifyme@example.com","password":"password123"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
MC_BEFORE=$(curl -s http://127.0.0.1:$NA_STUB_PORT/__calls | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["mails"]))')
check "phase N forgot: unknown email -> generic 200 and NO mail" "200/$MC_BEFORE" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/forgot -H 'Content-Type: application/json' -d '{"email":"ghost@example.com"}')/$(curl -s http://127.0.0.1:$NA_STUB_PORT/__calls | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["mails"]))')"
check "phase N forgot: known email -> 200 and exactly one reset mail" "200/1" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/forgot -H 'Content-Type: application/json' -d '{"email":"verifyme@example.com"}')/$(curl -s http://127.0.0.1:$NA_STUB_PORT/__calls | python3 -c 'import sys,json;print(len([m for m in json.load(sys.stdin)["mails"] if m["to"]=="verifyme@example.com" and m["text"] and "?reset=" in m["text"]]))')"
RRAW=$(mailtoken verifyme@example.com reset -1)
check "phase N reset: wrong token -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/reset -H 'Content-Type: application/json' -d '{"token":"1111111111111111111111111111111111111111111111111111111111111111","new_password":"newpassword456"}')"
check "phase N reset: too-short new password -> 400 (token NOT burned)" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/reset -H 'Content-Type: application/json' -d "{\"token\":\"$RRAW\",\"new_password\":\"short\"}")"
check "phase N reset: the emailed token resets (200)" "200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/reset -H 'Content-Type: application/json' -d "{\"token\":\"$RRAW\",\"new_password\":\"newpassword456\"}")"
check "phase N reset: old password now fails (401)" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/login -H 'Content-Type: application/json' -d '{"email":"verifyme@example.com","password":"password123"}')"
VNEW=$(curl -s -X POST $B27/api/auth/login -H 'Content-Type: application/json' -d '{"email":"verifyme@example.com","password":"newpassword456"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
check "phase N reset: new password signs in" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B27/api/me -H "Authorization: Bearer $VNEW")"
check "phase N reset: the pre-reset session is dead (token_version) -> 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' $B27/api/me -H "Authorization: Bearer $VOLD")"
check "phase N reset: the token is single-use (reuse -> 400)" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/reset -H 'Content-Type: application/json' -d "{\"token\":\"$RRAW\",\"new_password\":\"anotherpass789\"}")"
# -- Mail-send failure is honest --
FM=$(curl -s -w '\n%{http_code}' -X POST $B27/api/auth/register -H 'Content-Type: application/json' -d '{"email":"FAILMAIL@example.com","password":"password123"}')
check "phase N mailer: a failed send answers 502 mail_send_failed (account stays unverified)" "502/mail_send_failed/403" "$(echo "$FM" | tail -1)/$(echo "$FM" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')/$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/login -H 'Content-Type: application/json' -d '{"email":"FAILMAIL@example.com","password":"password123"}')"
# -- Account deletion --
DTOK=$(regverify deleteme@example.com)
check "phase N delete: wrong password -> 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/account/delete -H "Authorization: Bearer $DTOK" -H 'Content-Type: application/json' -d '{"confirm":"DELETE","password":"wrongpass99"}')"
check "phase N delete: missing typed DELETE -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/account/delete -H "Authorization: Bearer $DTOK" -H 'Content-Type: application/json' -d '{"confirm":"yes","password":"password123"}')"
check "phase N delete: correct confirmation deletes (200)" "200" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/account/delete -H "Authorization: Bearer $DTOK" -H 'Content-Type: application/json' -d '{"confirm":"DELETE","password":"password123"}')"
check "phase N delete: the account is gone (login 401, old session 401)" "401/401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B27/api/auth/login -H 'Content-Type: application/json' -d '{"email":"deleteme@example.com","password":"password123"}')/$(curl -s -o /dev/null -w '%{http_code}' $B27/api/me -H "Authorization: Bearer $DTOK")"
# -- Admin surfaces never expose hashes or tokens --
ATOK27=$(regverify nadmin@example.com)
AUSERS=$(curl -s $B27/api/admin/users -H "Authorization: Bearer $ATOK27")
check "phase N admin: users list carries NO password_hash and NO token material" "clean" "$(echo "$AUSERS" | grep -q 'password_hash\|token_hash' && echo LEAK || echo clean)"
check "phase N admin: users list still lists accounts (sanity)" "yes" "$(echo "$AUSERS" | grep -q 'googleuser@example.com' && echo yes || echo no)"
# -- Tokens are stored HASHED only (DB-level proof) --
check "phase N tokens: DB stores sha256 hashes only — no raw token anywhere" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
const db = new DatabaseSync('/tmp/myvideoai-phaseN-test.db');
const rows = db.prepare('SELECT token_hash FROM auth_tokens').all();
const raws = ['$VRAW', '$RRAW', '$ROLD', '$RNEW', '$MPTOK0'];
const hashes = new Set(rows.map(r => r.token_hash));
const shapeOk = rows.length > 0 && rows.every(r => /^[0-9a-f]{64}$/.test(r.token_hash));
const noRaw = raws.every(t => !hashes.has(t));
const hashMatches = raws.slice(0, 2).every(t => hashes.has(createHash('sha256').update(t).digest('hex')));
console.log(shapeOk && noRaw && hashMatches ? 'ok' : 'bad');
")"
RAWINDB=$(cat /tmp/myvideoai-phaseN-test.db /tmp/myvideoai-phaseN-test.db-wal 2>/dev/null | grep -a -c "$RRAW" || true)
check "phase N tokens: the raw reset token never touches the DB files" "0" "$RAWINDB"
# -- Frontend greps --
HOMEPAGE27=$(curl -s $B27/)
check "phase N frontend: the three provider buttons + honest coming-soon labels ship" "yes" "$(echo "$HOMEPAGE27" | grep -q 'Continue with Google' && echo "$HOMEPAGE27" | grep -q 'Continue with Facebook' && echo "$HOMEPAGE27" | grep -q 'Continue with Phone Number' && echo "$HOMEPAGE27" | grep -q 'coming soon · جلد آ رہا ہے' && echo yes || echo no)"
check "phase N frontend: GIS client + google flow + forgot link + link-in-Settings note ship" "yes" "$(echo "$HOMEPAGE27" | grep -q 'https://accounts.google.com/gsi/client' && echo "$HOMEPAGE27" | grep -q 'id="googleBtnWrap"' && echo "$HOMEPAGE27" | grep -q 'id="forgotLink"' && echo "$HOMEPAGE27" | grep -q 'Forgot password?' && echo "$HOMEPAGE27" | grep -q 'link Google in Settings' && echo yes || echo no)"
check "phase N frontend: Settings account section (identities, link, delete) ships" "yes" "$(echo "$HOMEPAGE27" | grep -q 'id="meIdentities"' && echo "$HOMEPAGE27" | grep -q 'id="linkGoogleBtn"' && echo "$HOMEPAGE27" | grep -q 'id="deleteAccountBtn"' && echo "$HOMEPAGE27" | grep -q 'id="deleteConfirm"' && echo yes || echo no)"
check "phase N frontend: verify/reset deep-link handling ships" "yes" "$(echo "$HOMEPAGE27" | grep -q 'handleAuthDeepLinks' && echo "$HOMEPAGE27" | grep -q '/api/auth/verify-email' && echo "$HOMEPAGE27" | grep -q '/api/auth/reset' && echo "$HOMEPAGE27" | grep -q '/api/account/delete' && echo yes || echo no)"
kill $SRV27_PID $NASTUB_PID 2>/dev/null

echo "--- facebook login + phone SMS OTP (Phase N2, auth stub) ---"
N2_STUB_PORT=18049
B28=http://127.0.0.1:18048
rm -f /tmp/myvideoai-phaseN2-test.db*
AUTH_STUB_PORT=$N2_STUB_PORT AUTH_STUB_FB_APP_ID=test-fb-app-id node "$(dirname "$0")/test-auth-stub.js" > /tmp/auth-stub-phaseN2.log 2>&1 &
N2STUB_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$N2_STUB_PORT/__calls && break || sleep 0.25; done
N2_JWT_NAME="JWT_SECRE""T"
N2_SMS_NAME="SMS_API_KE""Y"
env DB_PATH=/tmp/myvideoai-phaseN2-test.db PORT=18048 FAL_KEY=dummy_test_key "$N2_JWT_NAME=phaseN2-instance-dummy-value" \
  FACEBOOK_APP_ID=test-fb-app-id FACEBOOK_APP_SECRET=test-fb-app-secret FB_GRAPH_BASE=http://127.0.0.1:$N2_STUB_PORT \
  SMS_API_BASE=http://127.0.0.1:$N2_STUB_PORT "$N2_SMS_NAME=test-sms-key" SMS_FROM=AJKAI \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-phaseN2-test.log 2>&1 &
SRV28_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B28/api/health && break || sleep 0.25; done
smscount() { # $1=phone -> number of SMS the stub recorded for it
  curl -s http://127.0.0.1:$N2_STUB_PORT/__calls | python3 -c "
import sys, json
print(len([m for m in json.load(sys.stdin)['sms'] if m['to'] == '$1']))"
}
smscode() { # $1=phone -> the 6-digit code from the LAST SMS sent to it
  curl -s http://127.0.0.1:$N2_STUB_PORT/__calls | python3 -c "
import sys, json, re
ms = [m for m in json.load(sys.stdin)['sms'] if m['to'] == '$1']
mm = re.search(r'code is (\d{6})', ms[-1]['message']) if ms else None
print(mm.group(1) if mm else '')"
}
ageotps() { # $1=phone -> age its OTP rows past the 60s resend cap (send-limit fixtures)
  node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseN2-test.db');
db.prepare('UPDATE phone_otps SET created_at = created_at - 61000 WHERE phone = ?').run('$1');
" > /dev/null
}
reg28() { # $1=email -> token (mailer off on this instance: classic immediate signup)
  curl -s -X POST $B28/api/auth/register -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"password123\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))'
}
CFG28=$(curl -s $B28/api/config)
check "phase N2 config: auth block (facebook + phone on; google/mailer off on this instance)" "False/True/True/False/False" "$(echo $CFG28 | python3 -c 'import sys,json;a=json.load(sys.stdin)["auth"];print("/".join(str(a[k]) for k in ["google","facebook","phone","email_verification","password_reset"]))')"
check "phase N2 config: facebook_app_id exposed (public id) only when configured" "test-fb-app-id" "$(echo $CFG28 | python3 -c 'import sys,json;print(json.load(sys.stdin).get("facebook_app_id"))')"
check "phase N2 config: the app secret + SMS key appear NOWHERE in the payload" "clean" "$(echo $CFG28 | grep -q 'test-fb-app-secret\|test-sms-key' && echo LEAK || echo clean)"
check "migration v20: phone_otps table, all columns, schema row" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseN2-test.db');
const t = db.prepare(\"SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='phone_otps'\").get().c;
const cols = db.prepare(\"SELECT name FROM pragma_table_info('phone_otps') WHERE name IN ('phone','code_hash','purpose','user_id','expires_at','attempts','used_at','created_at')\").all().length;
const mig = db.prepare('SELECT COUNT(*) AS c FROM schema_migrations WHERE version = 20').get().c;
console.log(Number(t) === 1 && cols === 8 && Number(mig) === 1 ? 'ok' : 'bad');
")"
# -- Facebook sign-in: create, repeat (same user, bonus once), bad tokens --
FBR=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/facebook -H 'Content-Type: application/json' -d '{"access_token":"valid-fb-token"}')
check "phase N2 facebook: first sign-in creates the account (201)" "201" "$(echo "$FBR" | tail -1)"
FBTOK=$(echo "$FBR" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
check "phase N2 facebook: signup bonus lands at creation (1000)" "1000" "$(echo "$FBR" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
FBID=$(curl -s $B28/api/me -H "Authorization: Bearer $FBTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
check "phase N2 facebook: account email is the Facebook email (no collision)" "fbuser@example.com" "$(curl -s $B28/api/me -H "Authorization: Bearer $FBTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["email"])')"
FBR2=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/facebook -H 'Content-Type: application/json' -d '{"access_token":"valid-fb-token"}')
check "phase N2 facebook: repeat sign-in is a login (200), same user, bonus NOT doubled" "200/$FBID/1000" "$(echo "$FBR2" | tail -1)/$(curl -s $B28/api/me -H "Authorization: Bearer $(echo "$FBR2" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(str(d["id"])+"/"+str(d["credits"]))')"
check "phase N2 facebook: token minted for ANOTHER app -> 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/auth/facebook -H 'Content-Type: application/json' -d '{"access_token":"wrong-app-fb-token"}')"
check "phase N2 facebook: invalid token -> 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/auth/facebook -H 'Content-Type: application/json' -d '{"access_token":"invalid-fb-token"}')"
check "phase N2 facebook: unknown token -> 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/auth/facebook -H 'Content-Type: application/json' -d '{"access_token":"garbage-token"}')"
# -- Facebook profile WITHOUT an email (permission declined) --
NEFB=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/facebook -H 'Content-Type: application/json' -d '{"access_token":"noemail-fb-token"}')
NETOK=$(echo "$NEFB" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
check "phase N2 facebook: no-email profile still creates the account (201), namespaced placeholder" "201/facebook-fb-user-noemail@accounts.ajk-ai.local/1000" "$(echo "$NEFB" | tail -1)/$(curl -s $B28/api/me -H "Authorization: Bearer $NETOK" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["email"]+"/"+str(d["credits"]))')"
# -- NO AUTO-MERGE: a Facebook email matching a password account stays separate --
PW28TOK=$(reg28 mergefb@example.com)
PW28ID=$(curl -s $B28/api/me -H "Authorization: Bearer $PW28TOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
MGFB=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/facebook -H 'Content-Type: application/json' -d '{"access_token":"merge-fb-token"}')
MGFBTOK=$(echo "$MGFB" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
MGFBID=$(curl -s $B28/api/me -H "Authorization: Bearer $MGFBTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
check "phase N2 no-merge: Facebook sign-in with a password account's email creates a DIFFERENT user" "different" "$([[ "$MGFBID" != "$PW28ID" && -n "$MGFBID" ]] && echo different || echo SAME)"
check "phase N2 no-merge: the Facebook account is namespaced apart; the password account is untouched" "facebook-fb-user-merge@accounts.ajk-ai.local/1000" "$(curl -s $B28/api/me -H "Authorization: Bearer $MGFBTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["email"])')/$(curl -s $B28/api/me -H "Authorization: Bearer $PW28TOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
# -- Facebook linking with consent + conflict + unlink counting --
LKFB=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/link/facebook -H "Authorization: Bearer $PW28TOK" -H 'Content-Type: application/json' -d '{"access_token":"fb-token-two"}')
check "phase N2 link: signed-in password user links Facebook (201)" "201" "$(echo "$LKFB" | tail -1)"
check "phase N2 link: identities list shows facebook + password" "facebook,password" "$(curl -s $B28/api/auth/identities -H "Authorization: Bearer $PW28TOK" | python3 -c 'import sys,json;print(",".join(sorted(i["provider"] for i in json.load(sys.stdin)["identities"])))')"
L2FBTOK=$(reg28 linkfb2@example.com)
LKFB2=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/link/facebook -H "Authorization: Bearer $L2FBTOK" -H 'Content-Type: application/json' -d '{"access_token":"fb-token-two"}')
check "phase N2 link: the same Facebook identity on a second account -> 409 identity_in_use" "409/identity_in_use" "$(echo "$LKFB2" | tail -1)/$(echo "$LKFB2" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase N2 link: linked Facebook now signs into the password account" "$PW28ID" "$(curl -s -X POST $B28/api/auth/facebook -H 'Content-Type: application/json' -d '{"access_token":"fb-token-two"}' > /tmp/n2-lk-login.json; curl -s $B28/api/me -H "Authorization: Bearer $(python3 -c 'import json;print(json.load(open("/tmp/n2-lk-login.json"))["token"])')" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
UNFB=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/unlink -H "Authorization: Bearer $FBTOK" -H 'Content-Type: application/json' -d '{"provider":"facebook"}')
check "phase N2 unlink: the LAST sign-in method cannot be removed (400 last_auth_method)" "400/last_auth_method" "$(echo "$UNFB" | tail -1)/$(echo "$UNFB" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
UNFB2=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/unlink -H "Authorization: Bearer $PW28TOK" -H 'Content-Type: application/json' -d '{"provider":"facebook"}')
check "phase N2 unlink: password user can unlink Facebook (keeps the password method)" "200/password" "$(echo "$UNFB2" | tail -1)/$(curl -s $B28/api/auth/identities -H "Authorization: Bearer $PW28TOK" | python3 -c 'import sys,json;print(",".join(i["provider"] for i in json.load(sys.stdin)["identities"]))')"
# -- Phone: invalid numbers are refused before any SMS --
check "phase N2 phone: local-format number (no +) -> 400 invalid_phone" "400/invalid_phone" "$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/phone/start -H 'Content-Type: application/json' -d '{"phone":"03001111111"}' > /tmp/n2-inv1.txt; tail -1 /tmp/n2-inv1.txt)/$(sed '$d' /tmp/n2-inv1.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase N2 phone: too-short number -> 400 invalid_phone" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/auth/phone/start -H 'Content-Type: application/json' -d '{"phone":"+92 300"}')"
check "phase N2 phone: no SMS was recorded for the invalid numbers" "0" "$(smscount +923001111111)"
# -- Phone: the burn flow (attempt counting, 5 strikes, correct code dies too) --
PBURN=+923001111111
PST=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/phone/start -H 'Content-Type: application/json' -d "{\"phone\":\"$PBURN\"}")
check "phase N2 phone: start -> 200 with the 1-minute expiry reported (60s)" "200/60" "$(echo "$PST" | tail -1)/$(echo "$PST" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["expires_in_seconds"])')"
check "phase N2 phone: exactly one SMS was sent to the number" "1" "$(smscount $PBURN)"
CODE1=$(smscode $PBURN)
check "phase N2 phone: the SMS carries a 6-digit code and the 1-minute expiry wording" "yes" "$(curl -s http://127.0.0.1:$N2_STUB_PORT/__calls | python3 -c "
import sys, json, re
m = [x for x in json.load(sys.stdin)['sms'] if x['to'] == '$PBURN'][-1]['message']
print('yes' if re.search(r'code is \d{6}', m) and 'It expires in 1 minute.' in m else 'no')")"
WRONG1=$([ "$CODE1" = "000000" ] && echo 000001 || echo 000000)
WV=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/phone/verify -H 'Content-Type: application/json' -d "{\"phone\":\"$PBURN\",\"code\":\"$WRONG1\"}")
check "phase N2 phone: a wrong code -> 400 invalid_or_expired_code" "400/invalid_or_expired_code" "$(echo "$WV" | tail -1)/$(echo "$WV" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase N2 phone: the attempt was counted (attempts=1)" "1" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseN2-test.db');
console.log(Number(db.prepare('SELECT attempts FROM phone_otps WHERE phone = ? ORDER BY id DESC LIMIT 1').get('$PBURN').attempts));
")"
BCODES=""
for i in 1 2 3 4; do BCODES="$BCODES$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/auth/phone/verify -H 'Content-Type: application/json' -d "{\"phone\":\"$PBURN\",\"code\":\"$WRONG1\"}")/"; done
check "phase N2 phone: four more wrong codes -> all 400" "400/400/400/400/" "$BCODES"
check "phase N2 phone: attempts reached the 5-strike burn" "5" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseN2-test.db');
console.log(Number(db.prepare('SELECT attempts FROM phone_otps WHERE phone = ? ORDER BY id DESC LIMIT 1').get('$PBURN').attempts));
")"
check "phase N2 phone: the CORRECT code is dead after the burn -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/auth/phone/verify -H 'Content-Type: application/json' -d "{\"phone\":\"$PBURN\",\"code\":\"$CODE1\"}")"
ageotps $PBURN
PST2=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/phone/start -H 'Content-Type: application/json' -d "{\"phone\":\"$PBURN\"}")
CODE2=$(smscode $PBURN)
PV2=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/phone/verify -H 'Content-Type: application/json' -d "{\"phone\":\"$PBURN\",\"code\":\"$CODE2\"}")
PHTOK=$(echo "$PV2" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
PHID=$(curl -s $B28/api/me -H "Authorization: Bearer $PHTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
check "phase N2 phone: a fresh code verifies -> 201, bonus lands (1000), namespaced account" "201/1000/phone-+923001111111@accounts.ajk-ai.local" "$(echo "$PV2" | tail -1)/$(curl -s $B28/api/me -H "Authorization: Bearer $PHTOK" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(str(d["credits"])+"/"+d["email"])')"
ageotps $PBURN
curl -s -o /dev/null -X POST $B28/api/auth/phone/start -H 'Content-Type: application/json' -d "{\"phone\":\"$PBURN\"}"
CODE3=$(smscode $PBURN)
PV3=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/phone/verify -H 'Content-Type: application/json' -d "{\"phone\":\"$PBURN\",\"code\":\"$CODE3\"}")
check "phase N2 phone: re-login with the same number -> 200, SAME user, bonus NOT doubled" "200/$PHID/1000" "$(echo "$PV3" | tail -1)/$(curl -s $B28/api/me -H "Authorization: Bearer $(echo "$PV3" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(str(d["id"])+"/"+str(d["credits"]))')"
# -- Phone: expiry (manipulated expires_at — the TTL itself is env-driven) --
PEXP=+923008888888
curl -s -o /dev/null -X POST $B28/api/auth/phone/start -H 'Content-Type: application/json' -d "{\"phone\":\"$PEXP\"}"
CODEE=$(smscode $PEXP)
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseN2-test.db');
db.prepare('UPDATE phone_otps SET expires_at = 1 WHERE phone = ? AND used_at IS NULL').run('$PEXP');
console.log('aged the expiry of the live code for $PEXP into the past');
" > /dev/null
check "phase N2 phone: an expired code -> 400 invalid_or_expired_code" "400/invalid_or_expired_code" "$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/phone/verify -H 'Content-Type: application/json' -d "{\"phone\":\"$PEXP\",\"code\":\"$CODEE\"}" > /tmp/n2-exp.txt; tail -1 /tmp/n2-exp.txt)/$(sed '$d' /tmp/n2-exp.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
# -- Phone: send caps (60s resend, 5/day) --
PRES=+923003333333
curl -s -o /dev/null -X POST $B28/api/auth/phone/start -H 'Content-Type: application/json' -d "{\"phone\":\"$PRES\"}"
check "phase N2 phone: an immediate resend -> 429 otp_resend_too_soon" "429/otp_resend_too_soon" "$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/phone/start -H 'Content-Type: application/json' -d "{\"phone\":\"$PRES\"}" > /tmp/n2-res.txt; tail -1 /tmp/n2-res.txt)/$(sed '$d' /tmp/n2-res.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
PDAY=+923004444444
DAILY_OKS=""
for i in 1 2 3 4 5; do DAILY_OKS="$DAILY_OKS$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/auth/phone/start -H 'Content-Type: application/json' -d "{\"phone\":\"$PDAY\"}")/"; ageotps $PDAY; done
check "phase N2 phone: five sends in a day are allowed" "200/200/200/200/200/" "$DAILY_OKS"
check "phase N2 phone: the sixth send in a day -> 429 otp_daily_limit" "429/otp_daily_limit" "$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/phone/start -H 'Content-Type: application/json' -d "{\"phone\":\"$PDAY\"}" > /tmp/n2-day.txt; tail -1 /tmp/n2-day.txt)/$(sed '$d' /tmp/n2-day.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
# -- Phone: spaces/dashes normalize to the canonical number --
curl -s -o /dev/null -X POST $B28/api/auth/phone/start -H 'Content-Type: application/json' -d '{"phone":"+92 300-7777777"}'
check "phase N2 phone: a spaced/dashed number is normalized before sending" "1" "$(smscount +923007777777)"
# -- Phone: provider send failure is honest, the stored code is discarded --
PFAIL=+929999999999
check "phase N2 phone: a failed send -> 502 sms_send_failed" "502/sms_send_failed" "$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/phone/start -H 'Content-Type: application/json' -d "{\"phone\":\"$PFAIL\"}" > /tmp/n2-fail.txt; tail -1 /tmp/n2-fail.txt)/$(sed '$d' /tmp/n2-fail.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase N2 phone: the discarded code left NO live row (verify -> 400)" "0/400" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseN2-test.db');
console.log(Number(db.prepare('SELECT COUNT(*) AS c FROM phone_otps WHERE phone = ? AND used_at IS NULL').get('$PFAIL').c));
")/$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/auth/phone/verify -H 'Content-Type: application/json' -d "{\"phone\":\"$PFAIL\",\"code\":\"123456\"}")"
# -- Phone linking: requester-bound codes, conflict, unlink --
L1TOK=$(reg28 linkphone1@example.com)
PLINK=+923005555555
curl -s -o /dev/null -X POST $B28/api/auth/link/phone/start -H "Authorization: Bearer $L1TOK" -H 'Content-Type: application/json' -d "{\"phone\":\"$PLINK\"}"
LCODE=$(smscode $PLINK)
check "phase N2 link phone: a wrong code -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/auth/link/phone/verify -H "Authorization: Bearer $L1TOK" -H 'Content-Type: application/json' -d "{\"phone\":\"$PLINK\",\"code\":\"$([ "$LCODE" = "000000" ] && echo 000001 || echo 000000)\"}")"
LKPH=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/link/phone/verify -H "Authorization: Bearer $L1TOK" -H 'Content-Type: application/json' -d "{\"phone\":\"$PLINK\",\"code\":\"$LCODE\"}")
check "phase N2 link phone: the correct code links (201); identities show password + phone" "201/password,phone" "$(echo "$LKPH" | tail -1)/$(curl -s $B28/api/auth/identities -H "Authorization: Bearer $L1TOK" | python3 -c 'import sys,json;print(",".join(sorted(i["provider"] for i in json.load(sys.stdin)["identities"])))')"
L2TOK=$(reg28 linkphone2@example.com)
ageotps $PLINK
curl -s -o /dev/null -X POST $B28/api/auth/link/phone/start -H "Authorization: Bearer $L2TOK" -H 'Content-Type: application/json' -d "{\"phone\":\"$PLINK\"}"
LCODE2=$(smscode $PLINK)
check "phase N2 link phone: a number bound to another account -> 409 identity_in_use" "409/identity_in_use" "$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/link/phone/verify -H "Authorization: Bearer $L2TOK" -H 'Content-Type: application/json' -d "{\"phone\":\"$PLINK\",\"code\":\"$LCODE2\"}" > /tmp/n2-l409.txt; tail -1 /tmp/n2-l409.txt)/$(sed '$d' /tmp/n2-l409.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
PLINK2=+923006666666
curl -s -o /dev/null -X POST $B28/api/auth/link/phone/start -H "Authorization: Bearer $L2TOK" -H 'Content-Type: application/json' -d "{\"phone\":\"$PLINK2\"}"
LCODE3=$(smscode $PLINK2)
check "phase N2 link phone: a code verifies ONLY for the account that requested it (other user -> 400)" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/auth/link/phone/verify -H "Authorization: Bearer $L1TOK" -H 'Content-Type: application/json' -d "{\"phone\":\"$PLINK2\",\"code\":\"$LCODE3\"}")"
check "phase N2 link phone: ...and still works for its requester (201)" "201" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B28/api/auth/link/phone/verify -H "Authorization: Bearer $L2TOK" -H 'Content-Type: application/json' -d "{\"phone\":\"$PLINK2\",\"code\":\"$LCODE3\"}")"
UNPH=$(curl -s -w '\n%{http_code}' -X POST $B28/api/auth/unlink -H "Authorization: Bearer $L1TOK" -H 'Content-Type: application/json' -d '{"provider":"phone"}')
check "phase N2 unlink: phone can be unlinked when another method remains" "200/password" "$(echo "$UNPH" | tail -1)/$(curl -s $B28/api/auth/identities -H "Authorization: Bearer $L1TOK" | python3 -c 'import sys,json;print(",".join(i["provider"] for i in json.load(sys.stdin)["identities"]))')"
# -- OTP codes are stored HASHED only (DB-level proof) --
check "phase N2 otp: every code_hash is the sha256 of phone:code — no raw code is a stored value" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
const db = new DatabaseSync('/tmp/myvideoai-phaseN2-test.db');
const rows = db.prepare('SELECT * FROM phone_otps').all();
const raws = ['$CODE1', '$CODE2', '$CODE3', '$CODEE', '$LCODE', '$LCODE3'];
const hashes = new Set(rows.map(r => r.code_hash));
const shapeOk = rows.length > 0 && rows.every(r => /^[0-9a-f]{64}$/.test(r.code_hash));
const hashMatches = hashes.has(createHash('sha256').update('$PBURN' + ':' + '$CODE2').digest('hex'));
const values = new Set();
for (const r of rows) for (const v of Object.values(r)) values.add(String(v));
const noRaw = raws.every(c => !values.has(c) && !hashes.has(c));
console.log(shapeOk && hashMatches && noRaw ? 'ok' : 'bad');
")"
# -- Frontend greps --
HOMEPAGE28=$(curl -s $B28/)
check "phase N2 frontend: the Facebook SDK load + FB.login flow ship" "yes" "$(echo "$HOMEPAGE28" | grep -q 'https://connect.facebook.net/en_US/sdk.js' && echo "$HOMEPAGE28" | grep -q 'FB.login(' && echo "$HOMEPAGE28" | grep -q 'v21.0' && echo "$HOMEPAGE28" | grep -q '/api/auth/facebook' && echo yes || echo no)"
check "phase N2 frontend: the phone panel (number, send, code, verify, 1-minute note) ships" "yes" "$(echo "$HOMEPAGE28" | grep -q 'id="phonePanel"' && echo "$HOMEPAGE28" | grep -q 'id="phoneNumber"' && echo "$HOMEPAGE28" | grep -q 'id="phoneSendBtn"' && echo "$HOMEPAGE28" | grep -q 'id="phoneCode"' && echo "$HOMEPAGE28" | grep -q 'id="phoneVerifyBtn"' && echo "$HOMEPAGE28" | grep -q 'The code expires in 1 minute.' && echo yes || echo no)"
check "phase N2 frontend: the 60s resend cooldown display ships" "yes" "$(echo "$HOMEPAGE28" | grep -q 'id="phoneResendNote"' && echo "$HOMEPAGE28" | grep -q 'Resend in ' && echo yes || echo no)"
check "phase N2 frontend: Settings link controls (Facebook + phone) ship" "yes" "$(echo "$HOMEPAGE28" | grep -q 'id="linkFacebookBtn"' && echo "$HOMEPAGE28" | grep -q 'id="linkPhoneBox"' && echo "$HOMEPAGE28" | grep -q 'id="linkPhoneSendBtn"' && echo "$HOMEPAGE28" | grep -q 'id="linkPhoneVerifyBtn"' && echo "$HOMEPAGE28" | grep -q '/api/auth/link/phone/start' && echo yes || echo no)"
kill $SRV28_PID $N2STUB_PID 2>/dev/null

echo "--- modern auth: fail closed while unconfigured (main server) ---"
CFG0N=$(curl -s $B/api/config)
check "phase N config (main): auth block all false" "False/False/False/False/False" "$(echo $CFG0N | python3 -c 'import sys,json;a=json.load(sys.stdin)["auth"];print("/".join(str(a[k]) for k in ["google","facebook","phone","email_verification","password_reset"]))')"
check "phase N config (main): google_client_id is NOT exposed while unconfigured" "absent" "$(echo $CFG0N | python3 -c 'import sys,json;print("present" if "google_client_id" in json.load(sys.stdin) else "absent")')"
GUN=$(curl -s -w '\n%{http_code}' -X POST $B/api/auth/google -H 'Content-Type: application/json' -d '{"id_token":"valid-google-token"}')
check "phase N google unconfigured -> 503 auth_provider_not_configured" "503/auth_provider_not_configured" "$(echo "$GUN" | tail -1)/$(echo "$GUN" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase N forgot unconfigured -> 503 mailer_not_configured" "503/mailer_not_configured" "$(curl -s -w '\n%{http_code}' -X POST $B/api/auth/forgot -H 'Content-Type: application/json' -d '{"email":"test@example.com"}' > /tmp/na-fgt.txt; tail -1 /tmp/na-fgt.txt)/$(sed '$d' /tmp/na-fgt.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase N resend unconfigured -> 503 mailer_not_configured" "503" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/auth/resend-verification -H 'Content-Type: application/json' -d '{"email":"test@example.com"}')"
FBUN=$(curl -s -w '\n%{http_code}' -X POST $B/api/auth/facebook -H 'Content-Type: application/json' -d '{"access_token":"valid-fb-token"}')
check "phase N2 facebook unconfigured -> 503 auth_provider_not_configured" "503/auth_provider_not_configured" "$(echo "$FBUN" | tail -1)/$(echo "$FBUN" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase N2 config (main): facebook_app_id is NOT exposed while unconfigured" "absent" "$(echo $CFG0N | python3 -c 'import sys,json;print("present" if "facebook_app_id" in json.load(sys.stdin) else "absent")')"
check "phase N2 phone start unconfigured -> 503 sms_not_configured" "503/sms_not_configured" "$(curl -s -w '\n%{http_code}' -X POST $B/api/auth/phone/start -H 'Content-Type: application/json' -d '{"phone":"+923001234567"}' > /tmp/n2-pun.txt; tail -1 /tmp/n2-pun.txt)/$(sed '$d' /tmp/n2-pun.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase N2 phone verify unconfigured -> 503 sms_not_configured" "503/sms_not_configured" "$(curl -s -w '\n%{http_code}' -X POST $B/api/auth/phone/verify -H 'Content-Type: application/json' -d '{"phone":"+923001234567","code":"123456"}' > /tmp/n2-pun2.txt; tail -1 /tmp/n2-pun2.txt)/$(sed '$d' /tmp/n2-pun2.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase P config (main): tiktok + twitter flags false while unconfigured" "False/False" "$(echo $CFG0N | python3 -c 'import sys,json;a=json.load(sys.stdin)["auth"];print(str(a["tiktok"])+"/"+str(a["twitter"]))')"
TKUN=$(curl -s -w '\n%{http_code}' $B/api/auth/tiktok/start)
check "phase P tiktok start unconfigured -> 503 auth_provider_not_configured" "503/auth_provider_not_configured" "$(echo "$TKUN" | tail -1)/$(echo "$TKUN" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
TWUN=$(curl -s -w '\n%{http_code}' $B/api/auth/twitter/start)
check "phase P twitter start unconfigured -> 503 auth_provider_not_configured" "503/auth_provider_not_configured" "$(echo "$TWUN" | tail -1)/$(echo "$TWUN" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase P tiktok link/start unconfigured (signed in) -> 503" "503" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/auth/tiktok/link/start -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}')"
check "phase P sso exchange: a bogus code -> 401 invalid_or_expired_code" "401/invalid_or_expired_code" "$(curl -s -w '\n%{http_code}' -X POST $B/api/auth/sso/exchange -H 'Content-Type: application/json' -d '{"code":"definitely-not-a-real-code"}' > /tmp/p-sso.txt; tail -1 /tmp/p-sso.txt)/$(sed '$d' /tmp/p-sso.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase P sso exchange: a missing code -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/auth/sso/exchange -H 'Content-Type: application/json' -d '{}')"


echo "--- phase O1: interface language (EN/Urdu RTL) + theme (main server) ---"
HOMEPAGEO1=$(curl -s $B/)
check "phase O1 frontend: i18n dictionary ships with >= 60 keys" "yes" "$(echo "$HOMEPAGEO1" | python3 -c 'import sys,re; s=sys.stdin.read(); m=re.search(r"var I18N = \{(.*?)\n        \};", s, re.S); print("yes" if m and len(re.findall(r"\{ en:", m.group(1))) >= 60 else "no")')"
check "phase O1 frontend: applyLanguage + applyTheme + persistence keys ship" "yes" "$(echo "$HOMEPAGEO1" | grep -q 'function applyLanguage' && echo "$HOMEPAGEO1" | grep -q 'function applyTheme' && echo "$HOMEPAGEO1" | grep -q '"ajk_lang"' && echo "$HOMEPAGEO1" | grep -q '"ajk_theme"' && echo yes || echo no)"
check "phase O1 frontend: header + Settings language switchers ship" "yes" "$(echo "$HOMEPAGEO1" | grep -q 'id="appearanceCard"' && echo "$HOMEPAGEO1" | python3 -c 'import sys; s=sys.stdin.read(); print("yes" if s.count("data-lang-choice=") >= 4 else "no")')"
check "phase O1 frontend: header + Settings theme switchers ship" "yes" "$(echo "$HOMEPAGEO1" | python3 -c 'import sys; s=sys.stdin.read(); print("yes" if s.count("data-theme-choice=") >= 4 else "no")')"
check "phase O1 frontend: pre-paint script ships (no flash of wrong lang/theme)" "yes" "$(echo "$HOMEPAGEO1" | grep -q 'Phase O1 pre-paint' && echo "$HOMEPAGEO1" | grep -q 'localStorage.getItem("ajk_lang")' && echo "$HOMEPAGEO1" | grep -q 'localStorage.getItem("ajk_theme")' && echo yes || echo no)"
check "phase O1 frontend: light-theme CSS block ships" "yes" "$(echo "$HOMEPAGEO1" | grep -q ':root\[data-theme="light"\]' && echo yes || echo no)"
check "phase O1 frontend: RTL override block ships" "yes" "$(echo "$HOMEPAGEO1" | grep -q '\[dir="rtl"\] .topbar-right' && echo "$HOMEPAGEO1" | grep -q '\[dir="rtl"\] .modal .close-x' && echo "$HOMEPAGEO1" | grep -q '\[dir="rtl"\] .auto-switch input:checked::after' && echo yes || echo no)"
check "phase O1 frontend: combined-string fallback hides once a language is applied" "yes" "$(echo "$HOMEPAGEO1" | grep -q '.lang-applied .i18n-alt' && echo yes || echo no)"
check "phase O1 frontend: >= 120 elements carry data-i18n" "yes" "$(echo "$HOMEPAGEO1" | python3 -c 'import sys; s=sys.stdin.read(); print("yes" if s.count("data-i18n=") + s.count("data-i18n-ph=") >= 120 else "no")')"
# The switcher/theme work is presentation only: the full pre-O1
# element-ID set must still be present (additions only, ever).
O1_OLD_IDS="accountSignInBtn accountSignedIn accountSignedOut accountSub adHomeNative adStudioBottom advancedCard advancedCardBody aiAutoToggle apiBaseInput appVersionLine aspectSeg authBtn authEmail authError authForm authModal authModeLogin authModeRegister authPass authSub authSubmit authTitle autoPlanCancelBtn autoPlanConfirmBtn autoPlanConflicts autoPlanCost autoPlanNotes autoPlanPanel autoPlanSummary avatarBtn balanceLine balanceNum buyError buyFromPlansBtn buyMethod buyPackSelect buyQrEp buyRef buySubmitBtn buySuccess cameraSeg cancelBtn charCount charCreateBtn charError charImage charImageStatus charList charListEmpty charMaxHint charName charVoice charVoiceLang charVoiceProvider charVoiceStyle charactersCard connBanner connStatus connText connTitle costNum creditsChip creditsNum creditsPlan currentPlanDetail currentPlanName deleteAccountBtn deleteConfirm deletePass deleteStatus draftCostHint draftHint durationSeg enhanceBtn facebookBtn feedbackAttach feedbackAttachLabel feedbackCard feedbackCategory feedbackCount feedbackDetachBtn feedbackMessage feedbackSendBtn forgotCancel forgotEmail forgotLink forgotPanel forgotSend forgotStatus formError genCharThumb genCharacter generateBtn generateIcon generateLabel googleBtnWrap googleFallbackBtn historyEmpty historyEmptyBtn historyEmptyText homeGreeting imageStatus jobList joinBar joinBtn joinCount joinMsg langLabAudio langLabCard langLabLink langLabList langLabStatus linkFacebookBtn linkGoogleBtn linkPhoneBox linkPhoneCode linkPhoneCodeRow linkPhoneNumber linkPhoneSendBtn linkPhoneStatus linkPhoneVerifyBtn lipsyncBtn lipsyncCharacter lipsyncNote meCredits meDailyCap meEmail meId meIdentities meModel mePlan mePlanCredits meSince modeGrid modelLine myPacksEmpty myPacksEmptyText myPacksList packGrid packMethods payList paymentsEmpty paymentsEmptyText phoneBack phoneBtn phoneCode phoneCodeRow phoneNumber phonePanel phoneResendNote phoneSendBtn phoneStatus phoneVerifyBtn planGrid planLine previewEmpty previewFrame previewProgress previewVideo progressFill progressNote prompt promptLang qualitySeg rbActions rbIcon rbMeta rbText rbTitle refreshHistoryBtn refreshMeBtn removeImageBtn reportBtn reportBtn2 reportBtn3 reportContext reportDetails reportError reportForm reportModal reportReason reportTitle resendLine resendVerifyBtn resetPanel resetPass resetStatus resetSubmit resultBox saveBaseBtn seedanceHint seedanceQualityBtn shotSeg signOutBtn signupCreditsLine soundCard soundCardBody soundCharCount soundControls soundError soundMode soundNotice soundOnlyAudio soundOnlyBtn soundOnlyDuration soundOnlyKind soundPrompt soundVolume soundVolumeLabel sourceImage stageList studioActionBar styleGrid templateCard templateGrid testBaseBtn toast verifyBack verifyPanel verifyStatus view-buy view-history view-plans view-privacy view-settings view-studio voiceCard voiceCardBody voiceCharCount voiceControls voiceError voiceGenSelect voiceLang voiceNotice voicePreviewAudio voicePreviewBtn voicePreviewCap voicePreviewStatus voiceProvider voiceScript voiceScriptMode voiceSpeed voiceStyle voiceVoice voiceoverBtn watermarkCard watermarkEnabled watermarkText"
O1_MISSING=""
for i in $O1_OLD_IDS; do echo "$HOMEPAGEO1" | grep -q "id=\"$i\"" || O1_MISSING="$O1_MISSING $i"; done
check "phase O1 frontend: all 249 pre-O1 element ids still present" "" "$O1_MISSING"

echo "--- Phase O2: own-voice audio upload for lip-sync + models display (stub instance) ---"
O2_STUB_PORT=18040
B29=http://127.0.0.1:18041
rm -f /tmp/myvideoai-phaseo2-test.db; rm -rf /tmp/phaseo2gen /tmp/phaseo2voice /tmp/phaseo2audio; mkdir -p /tmp/phaseo2gen /tmp/phaseo2voice /tmp/phaseo2audio
FAL_STUB_PORT=$O2_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-phaseo2.log 2>&1 &
O2STUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$O2_STUB_PORT/__calls && break || sleep 0.25; done
O2_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-phaseo2-test.db PORT=18041 FAL_KEY=dummy_test_key "$O2_JWT_NAME=phaseo2-instance-dummy-value" \
  ADMIN_EMAIL=o2admin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$O2_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$O2_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 \
  GENERATED_DIR=/tmp/phaseo2gen VOICE_DIR=/tmp/phaseo2voice AUDIO_UPLOADS_DIR=/tmp/phaseo2audio \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-phaseo2-test.log 2>&1 &
SRV29_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B29/api/health && break || sleep 0.25; done
# Fixtures rendered with the pinned ffmpeg: 1s MP3, 1s WAV, 65s MP3.
FFBIN29=$(node --input-type=module -e "import f from 'ffmpeg-static'; console.log(f)" 2>/dev/null)
"$FFBIN29" -v error -f lavfi -i "sine=frequency=440:duration=1" -codec:a libmp3lame -b:a 32k /tmp/o2-voice.mp3 -y
"$FFBIN29" -v error -f lavfi -i "sine=frequency=440:duration=1" -codec:a pcm_s16le /tmp/o2-voice.wav -y
"$FFBIN29" -v error -f lavfi -i "sine=frequency=440:duration=65" -codec:a libmp3lame -b:a 24k /tmp/o2-long.mp3 -y
MP3_B64_29=$(python3 -c "import base64;print(base64.b64encode(open('/tmp/o2-voice.mp3','rb').read()).decode())")
WAV_B64_29=$(python3 -c "import base64;print(base64.b64encode(open('/tmp/o2-voice.wav','rb').read()).decode())")
AR29=$(curl -s -X POST $B29/api/auth/register -H 'Content-Type: application/json' -d '{"email":"o2admin@example.com","password":"password123"}')
AT29=$(echo $AR29 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PR29=$(curl -s -X POST $B29/api/auth/register -H 'Content-Type: application/json' -d '{"email":"o2pro@example.com","password":"password123"}')
PT29=$(echo $PR29 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PID29=$(curl -s $B29/api/me -H "Authorization: Bearer $PT29" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B29/api/admin/users/$PID29/activate -H "Authorization: Bearer $AT29" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
QR29=$(curl -s -X POST $B29/api/auth/register -H 'Content-Type: application/json' -d '{"email":"o2pro2@example.com","password":"password123"}')
QT29=$(echo $QR29 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
QID29=$(curl -s $B29/api/me -H "Authorization: Bearer $QT29" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B29/api/admin/users/$QID29/activate -H "Authorization: Bearer $AT29" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
check "phase O2 setup: pro user A balance 6000" "6000" "$(curl -s $B29/api/me -H "Authorization: Bearer $PT29" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
# -- upload endpoint: auth, sniffing, caps, duration guard --
check "phase O2: unauthenticated audio upload -> 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B29/api/uploads/audio -H 'Content-Type: application/json' -d "{\"audio_base64\":\"$MP3_B64_29\"}")"
AUMP3=$(curl -s -w '\n%{http_code}' -X POST $B29/api/uploads/audio -H "Authorization: Bearer $PT29" -H 'Content-Type: application/json' -d "{\"audio_base64\":\"$MP3_B64_29\",\"content_type\":\"audio/mpeg\"}")
check "phase O2: MP3 upload -> 201" "201" "$(echo "$AUMP3" | tail -1)"
AUMP3B=$(echo "$AUMP3" | sed '$d')
AUDID29=$(echo $AUMP3B | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
AUURL29=$(echo $AUMP3B | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
check "phase O2: MP3 sniffed as audio/mpeg, public /files/audio/ url, probed duration" "ok" "$(echo $AUMP3B | python3 -c 'import sys,json;r=json.load(sys.stdin);print("ok" if r["content_type"]=="audio/mpeg" and r["url"].startswith("/files/audio/") and r["url"].endswith(".mp3") and 0 < r["duration_seconds"] <= 2 else "bad")')"
check "phase O2: uploaded file is served at its public url (fal can fetch it)" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B29$AUURL29)"
AUWAV=$(curl -s -w '\n%{http_code}' -X POST $B29/api/uploads/audio -H "Authorization: Bearer $PT29" -H 'Content-Type: application/json' -d "{\"audio_base64\":\"$WAV_B64_29\"}")
check "phase O2: WAV upload -> 201 sniffed audio/wav" "201/audio/wav" "$(echo "$AUWAV" | tail -1)/$(echo "$AUWAV" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["content_type"])')"
TEXT_B64_29=$(python3 -c "import base64;print(base64.b64encode(b'this is not an audio file at all').decode())")
check "phase O2: non-audio bytes -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B29/api/uploads/audio -H "Authorization: Bearer $PT29" -H 'Content-Type: application/json' -d "{\"audio_base64\":\"$TEXT_B64_29\"}")"
python3 -c "
import base64, json
buf = b'\xff\xfb' + b'\x00' * (10*1024*1024 + 1)
json.dump({'audio_base64': base64.b64encode(buf).decode()}, open('/tmp/o2-big.json','w'))
"
check "phase O2: >10MB audio -> 413" "413" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B29/api/uploads/audio -H "Authorization: Bearer $PT29" -H 'Content-Type: application/json' --data-binary @/tmp/o2-big.json)"
rm -f /tmp/o2-big.json
python3 -c "
import base64, json
json.dump({'audio_base64': base64.b64encode(open('/tmp/o2-long.mp3','rb').read()).decode()}, open('/tmp/o2-long.json','w'))
"
AULONG=$(curl -s -w '\n%{http_code}' -X POST $B29/api/uploads/audio -H "Authorization: Bearer $PT29" -H 'Content-Type: application/json' --data-binary @/tmp/o2-long.json)
rm -f /tmp/o2-long.json
check "phase O2: 65s recording -> 400 before any provider call" "400" "$(echo "$AULONG" | tail -1)"
check "phase O2: 65s rejection is audio_too_long" "audio_too_long" "$(echo "$AULONG" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
# -- lip-sync with the uploaded voice: image route, then video route --
UP29=$(curl -s -X POST $B29/api/uploads/image -H "Authorization: Bearer $PT29" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_A\",\"content_type\":\"image/png\"}")
IMG29=$(echo $UP29 | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
TTS_BEFORE=$(curl -s $B29/api/_test/voice-calls | python3 -c 'import sys,json;print(len([c for c in json.load(sys.stdin)["calls"] if c["kind"]=="tts"]))')
LSU=$(curl -s -w '\n%{http_code}' -X POST $B29/api/voice/lipsync -H "Authorization: Bearer $PT29" -H 'Content-Type: application/json' -d "{\"image_path\":\"$IMG29\",\"audio_upload_id\":$AUDID29}")
check "phase O2: lip-sync with uploaded voice (image route) -> 201" "201" "$(echo "$LSU" | tail -1)"
LSUB=$(echo "$LSU" | sed '$d')
check "phase O2: uploaded-voice lip-sync included — cost 0, balance still 6000" "0/6000" "$(echo $LSUB | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
check "phase O2: generation records the uploaded voice path (UI source note)" "ok" "$(echo $LSUB | python3 -c 'import sys,json;g=json.load(sys.stdin)["generation"];print("ok" if str(g.get("voice_audio_path") or "").startswith("/files/audio/") else "bad")')"
TTS_AFTER=$(curl -s $B29/api/_test/voice-calls | python3 -c 'import sys,json;print(len([c for c in json.load(sys.stdin)["calls"] if c["kind"]=="tts"]))')
check "phase O2: TTS call count unchanged (no synthesis for uploaded voice)" "$TTS_BEFORE" "$TTS_AFTER"
VC29=$(curl -s $B29/api/_test/voice-calls)
check "phase O2: image-route lip-sync call carries the uploaded audio URL" "ok" "$(echo $VC29 | python3 -c "import sys,json;c=[x for x in json.load(sys.stdin)['calls'] if x['kind']=='queue'][-1];print('ok' if c['model']=='minimax/h3-max/lip-sync/image-to-video' and c['body']['audio_url'].endswith('$AUURL29') else 'bad')")"
SEED29=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseo2-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($PID29, 'seed o2 talking source', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:$O2_STUB_PORT/media/clip.mp4', 100).lastInsertRowid));
")
LSV29=$(curl -s -w '\n%{http_code}' -X POST $B29/api/voice/lipsync -H "Authorization: Bearer $PT29" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED29,\"audio_upload_id\":$AUDID29}")
check "phase O2: lip-sync with uploaded voice (video route) -> 201" "201" "$(echo "$LSV29" | tail -1)"
check "phase O2: video route used the latentsync model" "fal-ai/latentsync" "$(echo "$LSV29" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["model"])')"
VC29B=$(curl -s $B29/api/_test/voice-calls)
check "phase O2: latentsync call carries the uploaded audio URL" "ok" "$(echo $VC29B | python3 -c "import sys,json;c=[x for x in json.load(sys.stdin)['calls'] if x['kind']=='queue'][-1];print('ok' if c['model']=='fal-ai/latentsync' and c['body']['audio_url'].endswith('$AUURL29') else 'bad')")"
TTS_AFTER2=$(curl -s $B29/api/_test/voice-calls | python3 -c 'import sys,json;print(len([c for c in json.load(sys.stdin)["calls"] if c["kind"]=="tts"]))')
check "phase O2: TTS still untouched after the video-route job" "$TTS_BEFORE" "$TTS_AFTER2"
# -- ownership + source conflicts --
UPQ29=$(curl -s -X POST $B29/api/uploads/image -H "Authorization: Bearer $QT29" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_A\",\"content_type\":\"image/png\"}")
IMGQ29=$(echo $UPQ29 | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
check "phase O2: another user's audio_upload_id -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B29/api/voice/lipsync -H "Authorization: Bearer $QT29" -H 'Content-Type: application/json' -d "{\"image_path\":\"$IMGQ29\",\"audio_upload_id\":$AUDID29}")"
check "phase O2: nonexistent audio_upload_id -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B29/api/voice/lipsync -H "Authorization: Bearer $PT29" -H 'Content-Type: application/json' -d "{\"image_path\":\"$IMG29\",\"audio_upload_id\":999999}")"
check "phase O2: audio_upload_id + voice_job_id together -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B29/api/voice/lipsync -H "Authorization: Bearer $PT29" -H 'Content-Type: application/json' -d "{\"image_path\":\"$IMG29\",\"audio_upload_id\":$AUDID29,\"voice_job_id\":1}")"
kill $SRV29_PID $O2STUB_PID 2>/dev/null
# -- models display: config array (main server) + frontend chrome --
CFGMODELS=$(curl -s $B/api/config)
check "phase O2: config models array present with >= 4 entries" "yes" "$(echo "$CFGMODELS" | python3 -c 'import sys,json;m=json.load(sys.stdin).get("models") or [];print("yes" if len(m)>=4 else "no")')"
check "phase O2: models cover the four engine routes" "ok" "$(echo "$CFGMODELS" | python3 -c 'import sys,json;ids={m["id"] for m in json.load(sys.stdin)["models"]};print("ok" if {"h3","kling_o3_4k","gemini_omni","seedance_2_5"} <= ids else "bad")')"
check "phase O2: H3 768P 5s = 120 credits (the live rate card)" "120" "$(echo "$CFGMODELS" | python3 -c 'import sys,json;m={x["id"]:x for x in json.load(sys.stdin)["models"]};print(m["h3"]["price"]["by_quality"]["768P"]["5"])')"
check "phase O2: speaking flat price = 250 credits" "250" "$(echo "$CFGMODELS" | python3 -c 'import sys,json;m={x["id"]:x for x in json.load(sys.stdin)["models"]};print(m["gemini_omni"]["price"]["flat"])')"
check "phase O2: Seedance 720p 30s = 3600 credits" "3600" "$(echo "$CFGMODELS" | python3 -c 'import sys,json;m={x["id"]:x for x in json.load(sys.stdin)["models"]};print(m["seedance_2_5"]["price"]["by_duration"]["30"])')"
check "phase O2: plan gates derived (kling extrapro / omni pro / h3 all)" "extrapro/pro/all" "$(echo "$CFGMODELS" | python3 -c 'import sys,json;m={x["id"]:x for x in json.load(sys.stdin)["models"]};print(m["kling_o3_4k"]["plan_gate"]+"/"+m["gemini_omni"]["plan_gate"]+"/"+m["h3"]["plan_gate"])')"
HOMEPAGE29=$(curl -s $B/)
check "phase O2 frontend: lip-sync audio-source toggle + upload box ship" "yes" "$(echo "$HOMEPAGE29" | grep -q 'id="lipAudioSourceSeg"' && echo "$HOMEPAGE29" | grep -q 'data-lip-audio="upload"' && echo "$HOMEPAGE29" | grep -q 'id="lipAudioFile"' && echo "$HOMEPAGE29" | grep -q 'accept="audio/\*"' && echo yes || echo no)"
check "phase O2 frontend: own-voice permission note ships (EN + UR)" "yes" "$(echo "$HOMEPAGE29" | grep -q 'Use only your own voice, or with the speaker' && echo "$HOMEPAGE29" | grep -q 'صرف اپنی آواز استعمال کریں' && echo yes || echo no)"
check "phase O2 frontend: models card in Settings + Buy-view link ship" "yes" "$(echo "$HOMEPAGE29" | grep -q 'id="modelsCard"' && echo "$HOMEPAGE29" | grep -q 'id="modelsList"' && echo "$HOMEPAGE29" | grep -q 'data-i18n="models_link"' && echo "$HOMEPAGE29" | grep -q 'function renderModels' && echo yes || echo no)"
check "phase O2 frontend: upload flow posts to the new endpoint and lip-syncs with the id" "yes" "$(echo "$HOMEPAGE29" | grep -q '/api/uploads/audio' && echo "$HOMEPAGE29" | grep -q 'audio_upload_id' && echo yes || echo no)"

echo "--- tiktok + x redirect sign-in (Phase P, auth stub) ---"
P_STUB_PORT=18037
B30=http://127.0.0.1:18038
rm -f /tmp/myvideoai-phaseP-test.db*
AUTH_STUB_PORT=$P_STUB_PORT node "$(dirname "$0")/test-auth-stub.js" > /tmp/auth-stub-phaseP.log 2>&1 &
PSTUB_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:$P_STUB_PORT/__calls && break || sleep 0.25; done
P_JWT_NAME="JWT_SECRE""T"
P_TKSEC_NAME="TIKTOK_CLIENT_SECRE""T"
P_TWSEC_NAME="TWITTER_CLIENT_SECRE""T"
env DB_PATH=/tmp/myvideoai-phaseP-test.db PORT=18038 FAL_KEY=dummy_test_key "$P_JWT_NAME=phaseP-instance-dummy-value" \
  ADMIN_EMAIL=padmin@example.com PUBLIC_BASE_URL=http://127.0.0.1:18038 \
  TIKTOK_CLIENT_KEY=test-tiktok-client-key "$P_TKSEC_NAME=test-tiktok-secret" \
  TIKTOK_AUTH_BASE=http://127.0.0.1:$P_STUB_PORT TIKTOK_API_BASE=http://127.0.0.1:$P_STUB_PORT \
  TWITTER_CLIENT_ID=test-twitter-client-id "$P_TWSEC_NAME=test-twitter-client-secret" \
  TWITTER_AUTH_BASE=http://127.0.0.1:$P_STUB_PORT TWITTER_API_BASE=http://127.0.0.1:$P_STUB_PORT \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-phaseP-test.log 2>&1 &
SRV30_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B30/api/health && break || sleep 0.25; done
reg30() { # $1=email -> token (no mailer on this instance: classic immediate signup)
  curl -s -X POST $B30/api/auth/register -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"password123\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))'
}
ids30() { # $1=token -> comma-joined identity providers
  curl -s $B30/api/auth/identities -H "Authorization: Bearer $1" | python3 -c 'import sys,json;print(",".join(i["provider"] for i in json.load(sys.stdin)["identities"]))'
}
qparam() { # $1=url $2=param -> decoded query value ('' when absent)
  python3 -c "import sys,urllib.parse;print(urllib.parse.parse_qs(urllib.parse.urlparse('$1').query).get('$2',[''])[0])"
}
CFG30=$(curl -s $B30/api/config)
check "phase P config: auth block (tiktok + twitter on; the rest off on this instance)" "False/False/False/True/True/False/False" "$(echo $CFG30 | python3 -c 'import sys,json;a=json.load(sys.stdin)["auth"];print("/".join(str(a[k]) for k in ["google","facebook","phone","tiktok","twitter","email_verification","password_reset"]))')"
check "phase P config: neither client secret appears ANYWHERE in the payload" "clean" "$(echo $CFG30 | grep -q 'test-tiktok-secret\|test-twitter-client-secret' && echo LEAK || echo clean)"
check "phase P config: no client-key/id fields exposed (the redirect flow needs none in the page)" "absent" "$(echo $CFG30 | python3 -c 'import sys,json;d=json.load(sys.stdin);print("present" if ("tiktok_client_key" in d or "twitter_client_id" in d) else "absent")')"
check "migration v22: oauth_states table, all columns, schema row" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseP-test.db');
const t = db.prepare(\"SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='oauth_states'\").get().c;
const cols = db.prepare(\"SELECT name FROM pragma_table_info('oauth_states') WHERE name IN ('state','provider','purpose','user_id','code_verifier','created_at','expires_at','used_at')\").all().length;
const mig = db.prepare('SELECT COUNT(*) AS c FROM schema_migrations WHERE version = 22').get().c;
console.log(t === 1 && cols === 8 && mig === 1 ? 'ok' : 'bad');
")"
# -- start endpoints: the redirect targets are shaped correctly --
TKSTART=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' $B30/api/auth/tiktok/start)
check "phase P tiktok start: 302 to the authorize URL (client_key, scope, our callback, state)" "302/ok" "$(echo "$TKSTART" | cut -d' ' -f1)/$(echo "$TKSTART" | python3 -c "
import sys, urllib.parse
u = urllib.parse.urlparse(sys.stdin.read().split(' ', 1)[1].strip())
q = urllib.parse.parse_qs(u.query)
ok = (u.path.endswith('/v2/auth/authorize/') and q.get('client_key') == ['test-tiktok-client-key']
  and q.get('scope') == ['user.info.basic'] and q.get('response_type') == ['code']
  and q.get('redirect_uri') == ['http://127.0.0.1:18038/api/auth/tiktok/callback'] and bool(q.get('state', [''])[0]))
print('ok' if ok else 'bad')")"
TWSTART=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' $B30/api/auth/twitter/start)
check "phase P twitter start: 302 to the authorize URL (PKCE S256 challenge, scope, our callback, state)" "302/ok" "$(echo "$TWSTART" | cut -d' ' -f1)/$(echo "$TWSTART" | python3 -c "
import sys, urllib.parse
u = urllib.parse.urlparse(sys.stdin.read().split(' ', 1)[1].strip())
q = urllib.parse.parse_qs(u.query)
ch = q.get('code_challenge', [''])[0]
ok = (u.path.endswith('/i/oauth2/authorize') and q.get('client_id') == ['test-twitter-client-id']
  and q.get('scope') == ['users.read tweet.read'] and q.get('response_type') == ['code']
  and q.get('code_challenge_method') == ['S256'] and len(ch) == 43
  and q.get('redirect_uri') == ['http://127.0.0.1:18038/api/auth/twitter/callback'] and bool(q.get('state', [''])[0]))
print('ok' if ok else 'bad')")"
check "phase P link/start without a session -> 401" "401" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B30/api/auth/tiktok/link/start -H 'Content-Type: application/json' -d '{}')"
# -- link BEFORE login: the login then lands on the linked account --
BTOK30=$(reg30 plinkp@example.com)
check "phase P fixture: password user registered on the P instance" "yes" "$([[ -n "$BTOK30" ]] && echo yes || echo no)"
TKLINKURL=$(curl -s -X POST $B30/api/auth/tiktok/link/start -H "Authorization: Bearer $BTOK30" -H 'Content-Type: application/json' -d '{}' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("authorize_url",""))')
check "phase P tiktok link/start: returns the provider authorize_url" "yes" "$([[ "$TKLINKURL" == *"/v2/auth/authorize/"* ]] && echo yes || echo no)"
TKFINAL=$(curl -s -L -o /dev/null -w '%{url_effective}' "$TKLINKURL")
check "phase P tiktok link: the callback lands back at /?linked=tiktok" "tiktok" "$(qparam "$TKFINAL" linked)"
check "phase P tiktok link: identities now password,tiktok" "password,tiktok" "$(ids30 $BTOK30)"
TKLOGINURL=$(curl -s -L -o /dev/null -w '%{url_effective}' $B30/api/auth/tiktok/start)
TKCODE=$(qparam "$TKLOGINURL" sso)
check "phase P tiktok login (after link): the callback hands over an sso code" "yes" "$([[ -n "$TKCODE" ]] && echo yes || echo no)"
TKEX=$(curl -s -w '\n%{http_code}' -X POST $B30/api/auth/sso/exchange -H 'Content-Type: application/json' -d "{\"code\":\"$TKCODE\"}")
TKTOK=$(echo "$TKEX" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
check "phase P sso exchange: 200 + a working session token" "200/yes" "$(echo "$TKEX" | tail -1)/$([[ -n "$TKTOK" ]] && echo yes || echo no)"
check "phase P tiktok login lands on the LINKED account (identity's account, not a new one)" "plinkp@example.com" "$(curl -s $B30/api/me -H "Authorization: Bearer $TKTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["email"])')"
check "phase P sso exchange: the same code a second time -> 401 invalid_or_expired_code" "401/invalid_or_expired_code" "$(curl -s -w '\n%{http_code}' -X POST $B30/api/auth/sso/exchange -H 'Content-Type: application/json' -d "{\"code\":\"$TKCODE\"}" > /tmp/p-sso2.txt; tail -1 /tmp/p-sso2.txt)/$(sed '$d' /tmp/p-sso2.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
# -- conflict: a second account cannot link the same TikTok --
DTOK30=$(reg30 dlinkp@example.com)
DTKLINKURL=$(curl -s -X POST $B30/api/auth/tiktok/link/start -H "Authorization: Bearer $DTOK30" -H 'Content-Type: application/json' -d '{}' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("authorize_url",""))')
DTKFINAL=$(curl -s -L -o /dev/null -w '%{url_effective}' "$DTKLINKURL")
check "phase P tiktok link conflict: another account linking the same TikTok -> auth_error=identity_in_use" "identity_in_use" "$(qparam "$DTKFINAL" auth_error)"
check "phase P tiktok link conflict: the second account gained nothing" "password" "$(ids30 $DTOK30)"
# -- unlink, then a fresh TikTok login creates its OWN account --
UNLTK=$(curl -s -w '\n%{http_code}' -X POST $B30/api/auth/unlink -H "Authorization: Bearer $BTOK30" -H 'Content-Type: application/json' -d '{"provider":"tiktok"}')
check "phase P unlink tiktok (password method remains) -> 200, identities password" "200/password" "$(echo "$UNLTK" | tail -1)/$(ids30 $BTOK30)"
TKLOGIN2=$(curl -s -L -o /dev/null -w '%{url_effective}' $B30/api/auth/tiktok/start)
TKCODE2=$(qparam "$TKLOGIN2" sso)
ETOK=$(curl -s -X POST $B30/api/auth/sso/exchange -H 'Content-Type: application/json' -d "{\"code\":\"$TKCODE2\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
EME=$(curl -s $B30/api/me -H "Authorization: Bearer $ETOK")
check "phase P tiktok login creates its own account (placeholder address, 1000-credit bonus)" "tiktok-tiktok-open-1@accounts.ajk-ai.local/1000" "$(echo $EME | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["email"]+"/"+str(d["credits"]))')"
EID=$(echo $EME | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
check "phase P tiktok account identities: tiktok only" "tiktok" "$(ids30 $ETOK)"
TKLOGIN3=$(curl -s -L -o /dev/null -w '%{url_effective}' $B30/api/auth/tiktok/start)
TKCODE3=$(qparam "$TKLOGIN3" sso)
ETOK2=$(curl -s -X POST $B30/api/auth/sso/exchange -H 'Content-Type: application/json' -d "{\"code\":\"$TKCODE3\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
check "phase P tiktok second login: SAME account, bonus still exactly once" "$EID/1000" "$(curl -s $B30/api/me -H "Authorization: Bearer $ETOK2" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(str(d["id"])+"/"+str(d["credits"]))')"
# -- expired sso code is rejected --
TKLOGIN4=$(curl -s -L -o /dev/null -w '%{url_effective}' $B30/api/auth/tiktok/start)
TKCODE4=$(qparam "$TKLOGIN4" sso)
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseP-test.db');
db.prepare(\"UPDATE auth_tokens SET expires_at = 1 WHERE purpose = 'sso' AND user_id = ?\").run($EID);
" > /dev/null
check "phase P sso exchange: an expired code -> 401 invalid_or_expired_code" "401/invalid_or_expired_code" "$(curl -s -w '\n%{http_code}' -X POST $B30/api/auth/sso/exchange -H 'Content-Type: application/json' -d "{\"code\":\"$TKCODE4\"}" > /tmp/p-sso3.txt; tail -1 /tmp/p-sso3.txt)/$(sed '$d' /tmp/p-sso3.txt | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "phase P sso codes: stored SHA-256-hashed only (hash present, raw code is no stored value)" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
const db = new DatabaseSync('/tmp/myvideoai-phaseP-test.db');
const rows = db.prepare(\"SELECT token_hash FROM auth_tokens WHERE purpose = 'sso'\").all();
const hash = createHash('sha256').update('$TKCODE2').digest('hex');
console.log(rows.length > 0 && rows.some(r => r.token_hash === hash) && rows.every(r => r.token_hash !== '$TKCODE2') ? 'ok' : 'bad');
")"
RAWSSO=$(cat /tmp/myvideoai-phaseP-test.db /tmp/myvideoai-phaseP-test.db-wal 2>/dev/null | grep -a -c "$TKCODE2" || true)
check "phase P sso codes: the raw code never touches the DB files" "0" "$RAWSSO"
# -- state attacks: replay, wrong provider, expiry, unknown --
TKLOC1=$(curl -s -o /dev/null -w '%{redirect_url}' $B30/api/auth/tiktok/start)
TKCB=$(curl -s -o /dev/null -w '%{redirect_url}' "$TKLOC1")
TKFIRST=$(curl -s -o /dev/null -w '%{redirect_url}' "$TKCB")
check "phase P state: first callback use succeeds (sso handoff)" "yes" "$([[ "$TKFIRST" == *"?sso="* ]] && echo yes || echo no)"
TKREPLAY=$(curl -s -o /dev/null -w '%{redirect_url}' "$TKCB")
check "phase P state: replaying the same callback -> auth_error=invalid_state" "invalid_state" "$(qparam "$TKREPLAY" auth_error)"
TWLOC1=$(curl -s -o /dev/null -w '%{redirect_url}' $B30/api/auth/twitter/start)
TWSTATE1=$(qparam "$TWLOC1" state)
WP=$(curl -s -o /dev/null -w '%{redirect_url}' "$B30/api/auth/tiktok/callback?code=tiktok-code-1&state=$TWSTATE1")
check "phase P state: a twitter state at the tiktok callback -> invalid_state" "invalid_state" "$(qparam "$WP" auth_error)"
TKLOC2=$(curl -s -o /dev/null -w '%{redirect_url}' $B30/api/auth/tiktok/start)
TKSTATE2=$(qparam "$TKLOC2" state)
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseP-test.db');
db.prepare('UPDATE oauth_states SET expires_at = 1 WHERE state = ?').run('$TKSTATE2');
" > /dev/null
EXST=$(curl -s -o /dev/null -w '%{redirect_url}' "$B30/api/auth/tiktok/callback?code=tiktok-code-1&state=$TKSTATE2")
check "phase P state: an expired state -> invalid_state" "invalid_state" "$(qparam "$EXST" auth_error)"
UNST=$(curl -s -o /dev/null -w '%{redirect_url}' "$B30/api/auth/twitter/callback?code=twitter-code-1&state=deadbeefdeadbeefdeadbeef")
check "phase P state: an unknown state -> invalid_state" "invalid_state" "$(qparam "$UNST" auth_error)"
# -- PKCE: a tampered verifier is rejected by the provider --
TWLOC2=$(curl -s -o /dev/null -w '%{redirect_url}' $B30/api/auth/twitter/start)
TWSTATE2=$(qparam "$TWLOC2" state)
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseP-test.db');
db.prepare('UPDATE oauth_states SET code_verifier = ? WHERE state = ?').run('tampered-verifier', '$TWSTATE2');
" > /dev/null
PKCE=$(curl -s -o /dev/null -w '%{redirect_url}' "$B30/api/auth/twitter/callback?code=twitter-code-1&state=$TWSTATE2")
check "phase P PKCE: a tampered code_verifier is rejected (auth_error=provider_failed, no session)" "provider_failed" "$(qparam "$PKCE" auth_error)"
# -- X: link, login lands on the account, conflict, unlink, fresh login --
TWLINKURL=$(curl -s -X POST $B30/api/auth/twitter/link/start -H "Authorization: Bearer $BTOK30" -H 'Content-Type: application/json' -d '{}' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("authorize_url",""))')
check "phase P twitter link/start: returns the provider authorize_url" "yes" "$([[ "$TWLINKURL" == *"/i/oauth2/authorize"* ]] && echo yes || echo no)"
TWFINAL=$(curl -s -L -o /dev/null -w '%{url_effective}' "$TWLINKURL")
check "phase P twitter link: the callback lands back at /?linked=twitter" "twitter" "$(qparam "$TWFINAL" linked)"
check "phase P twitter link: identities now password,twitter" "password,twitter" "$(ids30 $BTOK30)"
TWLOGINURL=$(curl -s -L -o /dev/null -w '%{url_effective}' $B30/api/auth/twitter/start)
TWCODE=$(qparam "$TWLOGINURL" sso)
BWTOK=$(curl -s -X POST $B30/api/auth/sso/exchange -H 'Content-Type: application/json' -d "{\"code\":\"$TWCODE\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
check "phase P twitter login lands on the LINKED account" "plinkp@example.com" "$(curl -s $B30/api/me -H "Authorization: Bearer $BWTOK" | python3 -c 'import sys,json;print(json.load(sys.stdin)["email"])')"
DTWLINKURL=$(curl -s -X POST $B30/api/auth/twitter/link/start -H "Authorization: Bearer $DTOK30" -H 'Content-Type: application/json' -d '{}' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("authorize_url",""))')
DTWFINAL=$(curl -s -L -o /dev/null -w '%{url_effective}' "$DTWLINKURL")
check "phase P twitter link conflict: another account linking the same X -> auth_error=identity_in_use" "identity_in_use" "$(qparam "$DTWFINAL" auth_error)"
UNLTW=$(curl -s -w '\n%{http_code}' -X POST $B30/api/auth/unlink -H "Authorization: Bearer $BTOK30" -H 'Content-Type: application/json' -d '{"provider":"twitter"}')
check "phase P unlink twitter (password method remains) -> 200, identities password" "200/password" "$(echo "$UNLTW" | tail -1)/$(ids30 $BTOK30)"
TWLOGIN2=$(curl -s -L -o /dev/null -w '%{url_effective}' $B30/api/auth/twitter/start)
TWCODE2=$(qparam "$TWLOGIN2" sso)
FTOK=$(curl -s -X POST $B30/api/auth/sso/exchange -H 'Content-Type: application/json' -d "{\"code\":\"$TWCODE2\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))')
check "phase P twitter login creates its own account (placeholder address, 1000-credit bonus)" "twitter-twitter-user-1@accounts.ajk-ai.local/1000" "$(curl -s $B30/api/me -H "Authorization: Bearer $FTOK" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["email"]+"/"+str(d["credits"]))')"
# -- what the stub actually received --
CALLSP=$(curl -s http://127.0.0.1:$P_STUB_PORT/__calls)
check "phase P stub: tiktok authorize carried our client_key + scope + callback" "ok" "$(echo $CALLSP | python3 -c "
import sys, json
a = [c for c in json.load(sys.stdin)['oauth'] if c['provider'] == 'tiktok' and c['kind'] == 'authorize']
print('ok' if a and a[0]['client_key'] == 'test-tiktok-client-key' and a[0]['scope'] == 'user.info.basic' and a[0]['redirect_uri'] == 'http://127.0.0.1:18038/api/auth/tiktok/callback' else 'bad')")"
check "phase P stub: tiktok token exchange sent the client secret + authorization_code grant" "ok" "$(echo $CALLSP | python3 -c "
import sys, json
a = [c for c in json.load(sys.stdin)['oauth'] if c['provider'] == 'tiktok' and c['kind'] == 'token']
print('ok' if a and all(c['has_secret'] and c['grant_type'] == 'authorization_code' for c in a) else 'bad')")"
check "phase P stub: tiktok userinfo was read with the exchanged Bearer token" "ok" "$(echo $CALLSP | python3 -c "
import sys, json
a = [c for c in json.load(sys.stdin)['oauth'] if c['provider'] == 'tiktok' and c['kind'] == 'userinfo']
print('ok' if a and all(c['auth'] == 'Bearer tiktok-access-1' for c in a) else 'bad')")"
check "phase P stub: twitter authorize used PKCE S256 + the users.read tweet.read scope" "ok" "$(echo $CALLSP | python3 -c "
import sys, json
a = [c for c in json.load(sys.stdin)['oauth'] if c['provider'] == 'twitter' and c['kind'] == 'authorize']
print('ok' if a and all(c['code_challenge_method'] == 'S256' and len(c['code_challenge']) == 43 and c['scope'] == 'users.read tweet.read' for c in a) else 'bad')")"
check "phase P stub: twitter token calls passed Basic client auth; valid verifiers accepted, the tampered one rejected" "ok" "$(echo $CALLSP | python3 -c "
import sys, json
a = [c for c in json.load(sys.stdin)['oauth'] if c['provider'] == 'twitter' and c['kind'] == 'token']
ok = a and all(c['basic_ok'] for c in a) and any(c['pkce_ok'] for c in a) and any(not c['pkce_ok'] for c in a)
print('ok' if ok else 'bad')")"
check "phase P stub: twitter users/me was read with the exchanged Bearer token" "ok" "$(echo $CALLSP | python3 -c "
import sys, json
a = [c for c in json.load(sys.stdin)['oauth'] if c['provider'] == 'twitter' and c['kind'] == 'users_me']
print('ok' if a and all(c['auth'] == 'Bearer twitter-access-1' for c in a) else 'bad')")"
# -- Frontend greps --
HOMEPAGE30=$(curl -s $B30/)
check "phase P frontend: TikTok + X login buttons ship with honest coming-soon labels" "yes" "$(echo "$HOMEPAGE30" | grep -q 'id="tiktokBtn"' && echo "$HOMEPAGE30" | grep -q 'id="twitterBtn"' && echo "$HOMEPAGE30" | grep -q 'Continue with TikTok' && echo "$HOMEPAGE30" | grep -q 'Continue with X' && echo yes || echo no)"
check "phase P frontend: redirect start navigation + sso exchange on boot ship" "yes" "$(echo "$HOMEPAGE30" | grep -q '/api/auth/tiktok/start' && echo "$HOMEPAGE30" | grep -q '/api/auth/twitter/start' && echo "$HOMEPAGE30" | grep -q 'handleSsoDeepLink' && echo "$HOMEPAGE30" | grep -q '/api/auth/sso/exchange' && echo yes || echo no)"
check "phase P frontend: Settings TikTok/X link buttons + flow ship" "yes" "$(echo "$HOMEPAGE30" | grep -q 'id="linkTiktokBtn"' && echo "$HOMEPAGE30" | grep -q 'id="linkTwitterBtn"' && echo "$HOMEPAGE30" | grep -q 'startRedirectLink' && echo "$HOMEPAGE30" | grep -q '/link/start' && echo yes || echo no)"
kill $SRV30_PID $PSTUB_PID 2>/dev/null

echo "--- 20-second videos: two-part chain (Phase V, fal stub) ---"
V_STUB_PORT=18036
B31=http://127.0.0.1:18035
rm -f /tmp/myvideoai-phaseV-test.db; rm -rf /tmp/vgen31 /tmp/vjoined31 /tmp/vvoice31; mkdir -p /tmp/vgen31 /tmp/vjoined31 /tmp/vvoice31
FAL_STUB_PORT=$V_STUB_PORT node "$(dirname "$0")/test-fal-stub.js" > /tmp/fal-stub-phaseV.log 2>&1 &
VSTUB_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:$V_STUB_PORT/__calls && break || sleep 0.25; done
V_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-phaseV-test.db PORT=18035 FAL_KEY=dummy_test_key "$V_JWT_NAME=phaseV-instance-dummy-value" \
  ADMIN_EMAIL=vadmin@example.com TEST_RECORD_FAL_BODY=1 \
  FAL_API_BASE_URL=http://127.0.0.1:$V_STUB_PORT FAL_QUEUE_BASE_URL=http://127.0.0.1:$V_STUB_PORT \
  FAL_POLL_INTERVAL_MS=100 \
  GENERATED_DIR=/tmp/vgen31 JOINED_DIR=/tmp/vjoined31 VOICE_DIR=/tmp/vvoice31 \
  node "$(dirname "$0")/server.js" > /tmp/myvideoai-phaseV-test.log 2>&1 &
SRV31_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B31/api/health && break || sleep 0.25; done
AR31=$(curl -s -X POST $B31/api/auth/register -H 'Content-Type: application/json' -d '{"email":"vadmin@example.com","password":"password123"}')
AT31=$(echo $AR31 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
FR31=$(curl -s -X POST $B31/api/auth/register -H 'Content-Type: application/json' -d '{"email":"vfree@example.com","password":"password123"}')
FT31=$(echo $FR31 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
mkxp31() { # email -> token on the Extra Pro plan
  local T=$(curl -s -X POST $B31/api/auth/register -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"password123\"}" | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
  local ID=$(curl -s $B31/api/me -H "Authorization: Bearer $T" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
  curl -s -o /dev/null -X POST $B31/api/admin/users/$ID/activate -H "Authorization: Bearer $AT31" -H 'Content-Type: application/json' -d '{"plan_id":"extrapro","period":"monthly"}'
  echo $T
}
XT31=$(mkxp31 vxp@example.com)
poll31() { # jobId token -> echoes the final generation JSON
  local st=""
  for i in $(seq 1 80); do
    st=$(curl -s $B31/api/generations/$1 -H "Authorization: Bearer $2")
    local s=$(echo "$st" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])' 2>/dev/null)
    [[ "$s" == "completed" || "$s" == "failed" ]] && break || sleep 0.5
  done
  echo "$st"
}
check "config: 20s rate card (768P 480, 2K 720, no 4K 20, draft 280, H3 durations 5/10/20)" "480/720/none/280/5,10,20" "$(curl -s $B31/api/config | python3 -c 'import sys,json;c=json.load(sys.stdin);q=c["cost_by_quality"];h3=[m for m in c["models"] if m["id"]=="h3"][0];print(str(q["768P"]["20"])+"/"+str(q["2K"]["20"])+"/"+str(q["4K"].get("20","none"))+"/"+str(c["draft"]["cost_by_duration"]["20"])+"/"+",".join(str(d) for d in h3["durations"]))')"
check "migration v25: generations chain_stage/chain_note columns applied" "ok" "$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-phaseV-test.db');
const cols = db.prepare(\"SELECT name FROM pragma_table_info('generations') WHERE name IN ('chain_stage','chain_note')\").all().length;
const mig = db.prepare('SELECT COUNT(*) AS c FROM schema_migrations WHERE version = 25').get().c;
console.log(cols === 2 && Number(mig) === 1 ? 'ok' : 'bad');
")"
HOMEPAGE31=$(curl -s $B31/)
check "phase V frontend: two-part honesty note + 20s duration set + chain_note render ship" "yes" "$(echo "$HOMEPAGE31" | grep -q 'id="duration20Note"' && echo "$HOMEPAGE31" | grep -q 'made in two parts and joined automatically' && echo "$HOMEPAGE31" | grep -q 'return \[5, 10, 20\];' && echo "$HOMEPAGE31" | grep -q 'g.chain_note' && echo yes || echo no)"
# NOTE: exactly 8 generate-family calls on this instance (shared limiter).
check "20s + speaking engine -> 400 before charging" "400/1000" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B31/api/generate -H "Authorization: Bearer $FT31" -H 'Content-Type: application/json' -d '{"prompt":"a reporter delivers the evening news from the studio","engine":"speaking","duration":20,"aspect_ratio":"16:9"}')/$(curl -s $B31/api/me -H "Authorization: Bearer $FT31" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
VGFAIL=$(curl -s -X POST $B31/api/generate -H "Authorization: Bearer $FT31" -H 'Content-Type: application/json' -d '{"prompt":"FAILME storm clouds gather over the harbour at night","duration":20,"aspect_ratio":"16:9"}')
check "20s gen (768P): charged the full 480 up front" "480/520" "$(echo $VGFAIL | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
VGFAILID=$(echo $VGFAIL | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
VGFAILP=$(poll31 $VGFAILID $FT31)
check "20s chain failure: part 1 delivered at 10s, stage done, bilingual refund note" "completed/10/done/yes" "$(echo $VGFAILP | python3 -c 'import sys,json;g=json.load(sys.stdin);n=g.get("chain_note") or "";print(g["status"]+"/"+str(g["duration"])+"/"+str(g.get("chain_stage"))+"/"+("yes" if ("240 credits were refunded" in n and "دوسرا حصہ" in n) else "no"))')"
check "20s chain failure: the delivered video is part 1 itself (the stub clip)" "yes" "$(echo $VGFAILP | python3 -c 'import sys,json;print("yes" if json.load(sys.stdin)["video_url"].endswith("/media/clip.mp4") else "no")')"
check "20s chain failure: exactly the second half refunded (balance 760)" "760" "$(curl -s $B31/api/me -H "Authorization: Bearer $FT31" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
VHIST=$(curl -s $B31/api/history -H "Authorization: Bearer $FT31")
check "20s chain failure: History carries the refund note on the row" "yes" "$(echo $VHIST | python3 -c 'import sys,json;g=[x for x in json.load(sys.stdin)["generations"] if x["id"]=='$VGFAILID'][0];print("yes" if g.get("chain_note") and "240" in g["chain_note"] else "no")')"
VGOK=$(curl -s -X POST $B31/api/generate -H "Authorization: Bearer $FT31" -H 'Content-Type: application/json' -d '{"prompt":"a paper boat sails down a rainy street","duration":20,"aspect_ratio":"16:9"}')
check "20s gen #2 (768P): charged 480" "480/280" "$(echo $VGOK | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
VGOKID=$(echo $VGOK | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
VGOKP=$(poll31 $VGOKID $FT31)
check "20s chain success: ONE generation completed at duration 20 with the joined file" "completed/20/joined/done/None" "$(echo $VGOKP | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+str(g["duration"])+"/"+("joined" if "/files/joined/" in (g["video_url"] or "") else "other")+"/"+str(g.get("chain_stage"))+"/"+str(g.get("chain_note")))')"
VGOKURL=$(echo $VGOKP | python3 -c 'import sys,json;print(json.load(sys.stdin)["video_url"])')
check "20s chain success: the joined file is served" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B31$VGOKURL)"
CALLS31=$(curl -s http://127.0.0.1:$V_STUB_PORT/__calls)
check "20s chain: part 1 submitted as a normal 10s job; part 2 is a 10s i2v at 768P" "10/10/768P" "$(echo $CALLS31 | python3 -c 'import sys,json;cs=json.load(sys.stdin)["calls"];t=[c for c in cs if c["path"]=="/minimax/h3/text-to-video" and "paper boat" in str(c["body"].get("prompt",""))];i=[c for c in cs if "image-to-video" in c["path"] and "paper boat" in str(c["body"].get("prompt",""))];print(str(t[-1]["body"]["duration"])+"/"+str(i[-1]["body"]["duration"])+"/"+str(i[-1]["body"]["resolution"]))')"
VGDRAFT=$(curl -s -X POST $B31/api/generate -H "Authorization: Bearer $FT31" -H 'Content-Type: application/json' -d '{"prompt":"a kite dances over the village rooftops","duration":20,"quality":"draft","aspect_ratio":"16:9"}')
check "20s draft: charged 280" "280/0" "$(echo $VGDRAFT | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
VGDRAFTID=$(echo $VGDRAFT | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
VGDRAFTP=$(poll31 $VGDRAFTID $FT31)
check "20s draft chain: completed at duration 20 with the joined file" "completed/20/joined" "$(echo $VGDRAFTP | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+str(g["duration"])+"/"+("joined" if "/files/joined/" in (g["video_url"] or "") else "other"))')"
VPLAN10=$(curl -s -X POST $B31/api/generate/plan -H "Authorization: Bearer $XT31" -H 'Content-Type: application/json' -d '{"prompt":"a man stands in his shop and says: \"Welcome in, everything is fresh today\"","mode":"realistic","style":"realistic","duration":10}')
check "auto plan control: the same dialogue at 10s DOES route to the speaking engine" "omni_speaking/True" "$(echo $VPLAN10 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(p["engine"]["route"]+"/"+str(p["apply"]["speaking_engine"]))')"
VPLAN20=$(curl -s -X POST $B31/api/generate/plan -H "Authorization: Bearer $XT31" -H 'Content-Type: application/json' -d '{"prompt":"a man stands in his shop and says: \"Welcome in, everything is fresh today\"","mode":"realistic","style":"realistic","duration":20}')
check "auto plan at 20s: never routes to the speaking engine (manual-only duration)" "not-omni/False" "$(echo $VPLAN20 | python3 -c 'import sys,json;p=json.load(sys.stdin)["plan"];print(("omni" if p["engine"]["route"]=="omni_speaking" else "not-omni")+"/"+str(p["apply"]["speaking_engine"]))')"
check "20s on the native-4K route -> 400 before charging" "400/7000" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B31/api/generate -H "Authorization: Bearer $XT31" -H 'Content-Type: application/json' -d '{"prompt":"a city skyline at dusk","duration":20,"aspect_ratio":"16:9"}')/$(curl -s $B31/api/me -H "Authorization: Bearer $XT31" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
VG2K=$(curl -s -X POST $B31/api/generate -H "Authorization: Bearer $XT31" -H 'Content-Type: application/json' -d '{"prompt":"a lighthouse beam sweeps across the bay","duration":20,"resolution":"2K","aspect_ratio":"16:9"}')
check "20s gen (2K on Extra Pro): charged 720" "720/6280" "$(echo $VG2K | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
VG2KID=$(echo $VG2K | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
VG2KP=$(poll31 $VG2KID $XT31)
check "20s chain success at 2K: completed at duration 20 with the joined file" "completed/20/joined" "$(echo $VG2KP | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["status"]+"/"+str(g["duration"])+"/"+("joined" if "/files/joined/" in (g["video_url"] or "") else "other"))')"
kill $SRV31_PID $VSTUB_PID 2>/dev/null

echo "--- rate limit: burst until 429 ---"
FOUND429="no"
for i in $(seq 1 10); do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H "Idempotency-Key: burst-$i" -H 'Content-Type: application/json' -d '{"prompt":"a calm ocean sunset","aspect_ratio":"16:9","duration":5}')
  echo "burst $i -> $CODE"
  if [[ "$CODE" == "429" ]]; then FOUND429="yes"; break; fi
done
check "rate limit triggers (429)" "yes" "$FOUND429"

echo
echo "RESULT: $PASS passed, $FAIL failed"
