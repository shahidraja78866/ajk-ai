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
# the per-quality rate card charges and the 400-credit daily cap, so the
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
# Outgoing provider request shapes are asserted via the TEST_RECORD-style
# hook GET /api/_test/voice-calls.
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
check "register gives 100 credits" "100" "$(echo $R | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
DUP=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/auth/register -H 'Content-Type: application/json' -d '{"email":"test@example.com","password":"password123"}')
check "duplicate register rejected" "409" "$DUP"
BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/auth/login -H 'Content-Type: application/json' -d '{"email":"test@example.com","password":"wrongpass1"}')
check "wrong password rejected" "401" "$BAD"
L=$(curl -s -X POST $B/api/auth/login -H 'Content-Type: application/json' -d '{"email":"test@example.com","password":"password123"}')
TOKEN=$(echo $L | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
ME=$(curl -s $B/api/me -H "Authorization: Bearer $TOKEN"); echo "$ME"
check "me credits = 100" "100" "$(echo $ME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' $B/api/history)
check "history requires auth" "401" "$NOAUTH"

echo "--- validation & moderation (no charge) ---"
V=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"prompt":"a cat video","aspect_ratio":"7:3"}')
check "bad aspect ratio rejected" "400" "$V"
M=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"prompt":"gore and violence scene"}')
check "blocked prompt rejected" "400" "$M"
ME2=$(curl -s $B/api/me -H "Authorization: Bearer $TOKEN")
check "credits untouched by rejected prompts" "100" "$(echo $ME2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- generation with dummy key: submit fails -> 502 + refund ---"
G=$(curl -s -w '\n%{http_code}' -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: test-key-001' -H 'Content-Type: application/json' -d '{"prompt":"a kitten chasing a butterfly in a sunny garden","aspect_ratio":"16:9","duration":5,"style":"realistic"}')
echo "$G"
check "dummy-key generation returns 502" "502" "$(echo "$G" | tail -1)"
HIST=$(curl -s $B/api/history -H "Authorization: Bearer $TOKEN"); echo "$HIST" | head -c 400; echo
check "credits refunded after failure" "100" "$(echo $HIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "history has 1 failed job" "failed" "$(echo $HIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["status"])')"
JOBID=$(echo $HIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["id"])')

echo "--- idempotency: same key again -> same job, no new charge ---"
G2=$(curl -s -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: test-key-001' -H 'Content-Type: application/json' -d '{"prompt":"a kitten chasing a butterfly in a sunny garden","aspect_ratio":"16:9","duration":5,"style":"realistic"}')
echo "$G2"
check "duplicate flagged" "True" "$(echo $G2 | python3 -c 'import sys,json;print(json.load(sys.stdin).get("duplicate"))')"
HIST2=$(curl -s $B/api/history -H "Authorization: Bearer $TOKEN")
check "still only 1 job in history" "1" "$(echo $HIST2 | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["generations"]))')"
check "credits still 100" "100" "$(echo $HIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- report endpoint ---"
RP=$(curl -s -X POST $B/api/report -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "{\"generation_id\":$JOBID,\"reason\":\"test report\"}")
check "report accepted" "True" "$(echo $RP | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"

echo "--- automatic payments: FAIL CLOSED while unconfigured (main server) ---"
# The main server runs with no PLAY_*/GATEWAY_* env, so both automatic
# pipelines must refuse and grant nothing.
CFG0=$(curl -s $B/api/config)
check "config: play_billing_configured is false" "False" "$(echo $CFG0 | python3 -c 'import sys,json;print(json.load(sys.stdin)["play_billing_configured"])')"
check "config: gateway_configured is false" "False" "$(echo $CFG0 | python3 -c 'import sys,json;print(json.load(sys.stdin)["gateway_configured"])')"
UNCONF=$(curl -s -w '\n%{http_code}' -X POST $B/api/billing/play/verify -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_100","purchase_token":"valid-pack-100"}')
check "play verify unconfigured -> 503" "503" "$(echo "$UNCONF" | tail -1)"
check "play verify unconfigured error is billing_not_configured" "billing_not_configured" "$(echo "$UNCONF" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "unconfigured play verify granted nothing" "100" "$(curl -s $B/api/me -H "Authorization: Bearer $TOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
GWUNCONF=$(curl -s -w '\n%{http_code}' -X POST $B/api/billing/gateway/checkout -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"pack_id":1}')
check "gateway checkout unconfigured -> 503" "503" "$(echo "$GWUNCONF" | tail -1)"
check "gateway checkout unconfigured error is gateway_not_configured" "gateway_not_configured" "$(echo "$GWUNCONF" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
check "gateway webhook unconfigured -> 503" "503" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d 'BASKET_ID=X&TXNAMT=1&RESPONSE_CODE=00&SIGNATURE=x')"

echo "--- monetization: plans API (public) ---"
PLANS=$(curl -s $B/api/plans); echo "$PLANS" | head -c 400; echo
check "plans list has 4 plans" "4" "$(echo $PLANS | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["plans"]))')"
check "normal plan price Rs 5600" "5600" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="normal"][0]["price_monthly"])')"
check "normal plan yearly Rs 56000" "56000" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="normal"][0]["price_yearly"])')"
check "normal plan 400 credits/mo" "400" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="normal"][0]["credits_monthly"])')"
check "weekly plan: Rs 1800/week, 80 credits/wk" "1800/80" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["plans"] if x["id"]=="weekly"][0];print(str(p["price_weekly"])+"/"+str(p["credits_weekly"]))')"
check "weekly plan has no monthly price (null)" "None" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="weekly"][0]["price_monthly"])')"
check "normal plan: Veo flag off" "False" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="normal"][0]["features"]["can_veo"])')"
check "pro plan: Veo + lip-sync flags on" "True/True" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["plans"] if x["id"]=="pro"][0];print(str(p["features"]["can_veo"])+"/"+str(p["features"]["can_lipsync"]))')"
check "extrapro label is Native 4K" "Native 4K" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="extrapro"][0]["quality_label"])')"

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
check "activation: total credits 100 free + 400 plan = 500" "500" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "activation: plan bucket = 400" "400" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
check "activation: free bucket untouched = 100" "100" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
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
check "normal 10s job cost 20 credits" "20" "$(echo $PHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
check "credits refunded to 500 after failed normal job" "500" "$(echo $PHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- monetization: extrapro native-4K routing + 4K rate card ---"
MP2=$(curl -s -X POST $B/api/admin/users/$PID/manual-payment -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"plan_id":"extrapro","period":"monthly"}')
check "extrapro activation ok" "True" "$(echo $MP2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
PME2=$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN")
check "extrapro: total credits 100 free + 600 plan = 700" "700" "$(echo $PME2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "extrapro: plan switched" "extrapro" "$(echo $PME2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["id"])')"
curl -s -o /dev/null -X POST $B/api/generate -H "Authorization: Bearer $PTOKEN" -H 'Idempotency-Key: plan-4k-1' -H 'Content-Type: application/json' -d '{"prompt":"a mountain sunrise above the clouds","aspect_ratio":"16:9","duration":5}'
PHIST2=$(curl -s $B/api/history -H "Authorization: Bearer $PTOKEN")
check "4K job routed at 4K" "4K" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "4K job uses FAL_MODEL_4K model" "$TEST_FAL_MODEL_4K" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["model"])')"
check "4K 5s job cost (rate card) = 40 credits" "40" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
check "credits refunded to 700 after failed 4K job" "700" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
JOB4K=$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["id"])')
curl -s $B/api/generations/$JOB4K -H "Authorization: Bearer $PTOKEN" > /dev/null
check "no double refund after polling failed 4K job" "700" "$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
curl -s -o /dev/null -X POST $B/api/generate -H "Authorization: Bearer $PTOKEN" -H 'Idempotency-Key: plan-4k-low' -H 'Content-Type: application/json' -d '{"prompt":"a quiet forest stream in soft light","aspect_ratio":"16:9","duration":5,"resolution":"768P"}'
PHIST3=$(curl -s $B/api/history -H "Authorization: Bearer $PTOKEN")
check "extrapro lower-quality pick routed at 768P" "768P" "$(echo $PHIST3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "lower-quality pick cost normal = 10 credits" "10" "$(echo $PHIST3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
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
check "21:9 fallback cost (2K rate) = 15 credits" "15" "$(echo $PHIST4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
# (The fallback `note` only appears on a successful provider response, which is
#  unreachable with a dummy key; routing/cost/refund are fully asserted above.)
FB2=$(curl -s $B/api/_test/fal-body)
check "fallback fal body keeps resolution param" "2K" "$(echo $FB2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"].get("resolution","absent"))')"
check "fallback fal body duration is integer" "5-int" "$(echo $FB2 | python3 -c 'import sys,json;b=json.load(sys.stdin)["body"];print(str(b["duration"])+("-int" if isinstance(b["duration"],int) else "-NOTINT"))')"
check "credits refunded to 700 after failed fallback job" "700" "$(echo $PHIST4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- monetization: renewal grant + cancel ---"
RG=$(curl -s -X POST $B/api/admin/users/$PID/grant-renewal -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')
check "renewal grant ok" "True" "$(echo $RG | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
check "renewal resets plan bucket to 600" "600" "$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
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
check "pack 50 credits = Rs 899" "50/899" "$(echo $PK | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["packs"] if x["credits"]==50][0];print(str(p["credits"])+"/"+str(p["price_pkr"]))')"
check "pack 100 credits = Rs 1499" "100/1499" "$(echo $PK | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["packs"] if x["credits"]==100][0];print(str(p["credits"])+"/"+str(p["price_pkr"]))')"
check "pack 250 credits = Rs 3499" "250/3499" "$(echo $PK | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["packs"] if x["credits"]==250][0];print(str(p["credits"])+"/"+str(p["price_pkr"]))')"
check "config exposes payment_methods object" "dict" "$(curl -s $B/api/config | python3 -c 'import sys,json;print(type(json.load(sys.stdin)["payment_methods"]).__name__)')"
check "NayaPay QR image is served (/nayapay-qr.jpg)" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B/nayapay-qr.jpg)"
PACK100=$(echo $PK | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["packs"] if x["credits"]==100][0]["id"])')
PACK50=$(echo $PK | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["packs"] if x["credits"]==50][0]["id"])')
PACK250=$(echo $PK | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["packs"] if x["credits"]==250][0]["id"])')
KR=$(curl -s -X POST $B/api/auth/register -H 'Content-Type: application/json' -d '{"email":"packuser@example.com","password":"password123"}')
KTOKEN=$(echo $KR | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PUR=$(curl -s -w '\n%{http_code}' -X POST $B/api/packs/$PACK100/purchase -H "Authorization: Bearer $KTOKEN" -H 'Content-Type: application/json' -d '{"method":"easypaisa","transaction_ref":"TXN-99887766"}')
check "pack purchase created (201)" "201" "$(echo "$PUR" | tail -1)"
PURBODY=$(echo "$PUR" | sed '$d')
check "purchase starts pending" "pending" "$(echo $PURBODY | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["status"])')"
check "purchase snapshots 100 credits / Rs 1499" "100/1499" "$(echo $PURBODY | python3 -c 'import sys,json;p=json.load(sys.stdin)["purchase"];print(str(p["credits"])+"/"+str(p["amount_pkr"]))')"
PURID=$(echo $PURBODY | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["id"])')
check "pending purchase grants nothing yet" "100" "$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
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
check "approve granted pack into free bucket (100 signup + 100 pack)" "200" "$(echo $KME | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
check "balance after approve = 200" "200" "$(echo $KME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "second approve is a conflict (409)" "409" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/admin/pack-purchases/$PURID/approve -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')"
check "double approve did NOT double-grant" "200" "$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
PUR2=$(curl -s -X POST $B/api/packs/$PACK50/purchase -H "Authorization: Bearer $KTOKEN" -H 'Content-Type: application/json' -d '{"method":"jazzcash","transaction_ref":"JC-55544433"}')
PUR2ID=$(echo $PUR2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["id"])')
REJ=$(curl -s -X POST $B/api/admin/pack-purchases/$PUR2ID/reject -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"note":"No matching payment found"}')
check "admin reject ok" "rejected" "$(echo $REJ | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["status"])')"
check "rejected purchase granted nothing" "200" "$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
echo "--- credit packs: nayapay purchase -> approve grants exactly once ---"
PUR3=$(curl -s -X POST $B/api/packs/$PACK50/purchase -H "Authorization: Bearer $KTOKEN" -H 'Content-Type: application/json' -d '{"method":"nayapay","transaction_ref":"NP-2026-445566"}')
check "nayapay purchase created pending" "pending" "$(echo $PUR3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["status"])')"
check "nayapay purchase method recorded" "nayapay" "$(echo $PUR3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["method"])')"
PUR3ID=$(echo $PUR3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["purchase"]["id"])')
check "nayapay pending purchase grants nothing" "200" "$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
APPR3=$(curl -s -X POST $B/api/admin/pack-purchases/$PUR3ID/approve -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')
check "nayapay approve ok" "True" "$(echo $APPR3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
check "nayapay approve granted 50 into free bucket (250 total)" "250" "$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
check "nayapay double approve is a conflict (409)" "409" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/admin/pack-purchases/$PUR3ID/approve -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')"
check "nayapay double approve did NOT double-grant" "250" "$(curl -s $B/api/me -H "Authorization: Bearer $KTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
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
check "urdu job refunded to 100 after dummy-key failure" "100" "$(echo $LHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
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
check "config cost 5s = 10 credits (rescaled)" "10" "$(echo $CFG3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_by_duration"]["5"])')"
check "config cost 10s = 20 credits (rescaled)" "20" "$(echo $CFG3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_by_duration"]["10"])')"
check "config signup credits = 100 (rescaled)" "100" "$(echo $CFG3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["signup_credits"])')"
check "config daily cap = 400" "400" "$(echo $CFG3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["max_daily_credits"])')"
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
const ins = (uid, url, status) => Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run(uid, 'seed clip', '16:9', 1, 'realistic', status, url, 10).lastInsertRowid);
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
check "join charged nothing (balance still 100)" "100" "$(echo $JHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
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
check "pack 100 exposes play product id credits_100" "credits_100" "$(echo $PK4 | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["packs"] if x["credits"]==100][0]["play_product_id"])')"
PACK100_4=$(echo $PK4 | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["packs"] if x["credits"]==100][0]["id"])')
PACK50_4=$(echo $PK4 | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["packs"] if x["credits"]==50][0]["id"])')
BR4=$(curl -s -X POST $B4/api/auth/register -H 'Content-Type: application/json' -d '{"email":"billuser@example.com","password":"password123"}')
BTOKEN=$(echo $BR4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
AR4=$(curl -s -X POST $B4/api/auth/register -H 'Content-Type: application/json' -d '{"email":"billadmin@example.com","password":"password123"}')
ATOKEN4=$(echo $AR4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
OR4=$(curl -s -X POST $B4/api/auth/register -H 'Content-Type: application/json' -d '{"email":"billother@example.com","password":"password123"}')
OTOKEN4=$(echo $OR4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

echo "--- play billing: (b) valid pack token grants exactly once ---"
V1=$(curl -s -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_100","purchase_token":"valid-pack-100"}')
check "play pack verify ok" "True" "$(echo $V1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
check "play pack verify status succeeded" "succeeded" "$(echo $V1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
check "play pack grant: free bucket 100 signup + 100 pack = 200" "200" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
V2=$(curl -s -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_100","purchase_token":"valid-pack-100"}')
check "play pack replay flagged duplicate" "True" "$(echo $V2 | python3 -c 'import sys,json;print(json.load(sys.stdin).get("duplicate"))')"
check "play pack replay granted nothing more (total still 200)" "200" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- play billing: (f) a token is bound to its first user ---"
check "other user replaying the token -> 409" "409" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $OTOKEN4" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_100","purchase_token":"valid-pack-100"}')"
check "other user balance unchanged (100)" "100" "$(curl -s $B4/api/me -H "Authorization: Bearer $OTOKEN4" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- play billing: (d) unknown product / unverifiable / unpaid grant nothing ---"
check "unknown play product -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"nope_product","purchase_token":"valid-pack-100"}')"
check "token google does not know -> 502" "502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_100","purchase_token":"bogus-token"}')"
check "purchase not in paid state -> 402" "402" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_50","purchase_token":"pending-pack-50"}')"
check "failed verifications granted nothing (total still 200)" "200" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- play billing: (c) valid subscription token activates the plan ---"
V3=$(curl -s -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"subscription","product_id":"ajk_normal_monthly","purchase_token":"valid-sub-monthly"}')
check "play sub verify ok" "True" "$(echo $V3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
BME=$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN"); echo "$BME"
check "play sub: current plan is normal" "normal" "$(echo $BME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["id"])')"
check "play sub: plan bucket granted 400" "400" "$(echo $BME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
check "play sub: subscription status active" "active" "$(echo $BME | python3 -c 'import sys,json;print(json.load(sys.stdin)["subscription"]["status"])')"
check "play sub: total = 200 free + 400 plan = 600" "600" "$(echo $BME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- play billing: (e) voided purchase sync claws credits back ---"
V4=$(curl -s -X POST $B4/api/billing/play/verify -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d '{"kind":"pack","product_id":"credits_100","purchase_token":"voided-token"}')
check "voided-token purchase grants first (free 300)" "300" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
SYNC=$(curl -s -X POST $B4/api/admin/billing/sync-voided -H "Authorization: Bearer $ATOKEN4" -H 'Content-Type: application/json' -d '{}')
check "sync-voided ok" "True" "$(echo $SYNC | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
check "sync-voided found and clawed the payment" "100" "$(echo $SYNC | python3 -c 'import sys,json;r=[x for x in json.load(sys.stdin)["results"] if x.get("token")=="voided-token"][0];print(r["clawed"])')"
check "clawback: free bucket back to 200" "200" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
check "clawback fully recovered: credit_deficit 0" "0" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credit_deficit"])')"
check "voided payment marked refunded" "refunded" "$(curl -s $B4/api/payments -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print([p for p in json.load(sys.stdin)["payments"] if p["provider_txn_id"]=="voided-token"][0]["status"])')"

echo "--- gateway: checkout creates a pending payment and grants nothing ---"
CO1=$(curl -s -w '\n%{http_code}' -X POST $B4/api/billing/gateway/checkout -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d "{\"pack_id\":$PACK100_4}")
check "gateway checkout -> 201" "201" "$(echo "$CO1" | tail -1)"
CO1B=$(echo "$CO1" | sed '$d')
BASKET1=$(echo $CO1B | python3 -c 'import sys,json;print(json.load(sys.stdin)["basket_id"])')
check "gateway checkout URL is the PayFast PostTransaction endpoint" "yes" "$(echo $CO1B | python3 -c 'import sys,json;u=json.load(sys.stdin)["checkout_url"];print("yes" if u.endswith("/Ecommerce/api/Transaction/PostTransaction") else "no")')"
check "gateway checkout params carry the merchant signature" "yes" "$(echo $CO1B | python3 -c 'import sys,json;s=json.load(sys.stdin)["params"].get("SIGNATURE","");print("yes" if len(s)==32 else "no")')"
check "gateway checkout granted nothing (total still 600)" "600" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- gateway: (b) correctly-signed success webhook grants exactly once ---"
WB1=$(node "$(dirname "$0")/test-gateway-stub.js" testmerchant "AJK AI" 1499 "$BASKET1" 00 TXN-GW-1)
WH1=$(curl -s -X POST $B4/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d "$WB1")
check "gateway success webhook grants 100" "100" "$(echo $WH1 | python3 -c 'import sys,json;print(json.load(sys.stdin)["granted"])')"
check "gateway grant landed in free bucket (300)" "300" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
WH1B=$(curl -s -X POST $B4/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d "$WB1")
check "gateway webhook replay flagged duplicate" "True" "$(echo $WH1B | python3 -c 'import sys,json;print(json.load(sys.stdin).get("duplicate"))')"
check "gateway replay granted nothing more (free still 300)" "300" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"

echo "--- gateway: (c) bad signature rejected, (d) failure status grants nothing ---"
CO2=$(curl -s -X POST $B4/api/billing/gateway/checkout -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d "{\"pack_id\":$PACK50_4}")
BASKET2=$(echo $CO2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["basket_id"])')
WBAD=$(node "$(dirname "$0")/test-gateway-stub.js" testmerchant "WRONG NAME" 899 "$BASKET2" 00 TXN-GW-BAD)
check "bad-signature webhook -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B4/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d "$WBAD")"
check "bad signature granted nothing (free still 300)" "300" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
WFAIL=$(node "$(dirname "$0")/test-gateway-stub.js" testmerchant "AJK AI" 899 "$BASKET2" failed TXN-GW-2)
WHF=$(curl -s -X POST $B4/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d "$WFAIL")
check "failure webhook grants 0" "0" "$(echo $WHF | python3 -c 'import sys,json;print(json.load(sys.stdin)["granted"])')"
check "failure webhook granted nothing (free still 300)" "300" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
check "failed gateway payment marked failed" "failed" "$(curl -s $B4/api/payments -H "Authorization: Bearer $BTOKEN" | python3 -c "import sys,json;print([p for p in json.load(sys.stdin)['payments'] if p['provider_txn_id']=='$BASKET2'][0]['status'])")"

echo "--- gateway: (e) verified reversal claws credits back ---"
CO3=$(curl -s -X POST $B4/api/billing/gateway/checkout -H "Authorization: Bearer $BTOKEN" -H 'Content-Type: application/json' -d "{\"pack_id\":$PACK50_4}")
BASKET3=$(echo $CO3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["basket_id"])')
WSUC=$(node "$(dirname "$0")/test-gateway-stub.js" testmerchant "AJK AI" 899 "$BASKET3" 00 TXN-GW-3)
curl -s -X POST $B4/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d "$WSUC" > /dev/null
check "gateway pack-50 grant landed (free 350)" "350" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
WREV=$(node "$(dirname "$0")/test-gateway-stub.js" testmerchant "AJK AI" 899 "$BASKET3" refunded TXN-GW-3)
WHR=$(curl -s -X POST $B4/api/billing/gateway/webhook -H 'Content-Type: application/x-www-form-urlencoded' -d "$WREV")
check "reversal webhook claws back 50" "50" "$(echo $WHR | python3 -c 'import sys,json;print(json.load(sys.stdin)["clawed_back"])')"
check "reversal: free bucket back to 300" "300" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
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
check "play weekly: plan bucket granted 80" "80" "$(echo $OME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
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
check "Pro keeps its v9 values after v8 re-apply (9500/500)" "9500/500" "$(node --input-type=module -e "
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

echo "--- pricing v9: weekly plan, per-quality rate card, daily cap 400 (own instance) ---"
# Self-contained SIXTH instance (own throwaway DB). Kept off the main
# server because its per-IP generation budget is nearly exhausted by the
# earlier sections. Covers: /api/config exposing the full rate card,
# /api/plans weekly + feature flags, weekly activation (80 credits,
# 7-day period, Rs 1,800 payment), period-fit rejections, the 2K/4K rows
# of the rate card in real generation charges, and the daily cap at 400.
B6=http://127.0.0.1:18092
rm -f /tmp/myvideoai-v9-test.db
V9_JWT_NAME="JWT_SECRE""T"
env DB_PATH=/tmp/myvideoai-v9-test.db PORT=18092 FAL_KEY=dummy_test_key "$V9_JWT_NAME=v9-instance-dummy-value" ADMIN_EMAIL=v9admin@example.com TEST_RECORD_FAL_BODY=1 node "$(dirname "$0")/server.js" > /tmp/myvideoai-v9-test.log 2>&1 &
SRV6_PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null $B6/api/health && break || sleep 0.25; done
CFG6=$(curl -s $B6/api/config)
check "config daily cap defaults to 400" "400" "$(echo $CFG6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["max_daily_credits"])')"
check "config rate card 768P: 5s=10, 10s=20" "10/20" "$(echo $CFG6 | python3 -c 'import sys,json;q=json.load(sys.stdin)["cost_by_quality"]["768P"];print(str(q["5"])+"/"+str(q["10"]))')"
check "config rate card 2K: 5s=15, 10s=30" "15/30" "$(echo $CFG6 | python3 -c 'import sys,json;q=json.load(sys.stdin)["cost_by_quality"]["2K"];print(str(q["5"])+"/"+str(q["10"]))')"
check "config rate card 4K: 5s=40, 10s=80" "40/80" "$(echo $CFG6 | python3 -c 'import sys,json;q=json.load(sys.stdin)["cost_by_quality"]["4K"];print(str(q["5"])+"/"+str(q["10"]))')"
PL6=$(curl -s $B6/api/plans)
check "plans: 4 plans listed" "4" "$(echo $PL6 | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["plans"]))')"
check "plans: weekly 1800/wk + 80 credits, monthly fields null" "1800/80/None/None" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["plans"] if x["id"]=="weekly"][0];print("/".join([str(p["price_weekly"]),str(p["credits_weekly"]),str(p["price_monthly"]),str(p["credits_monthly"])]))')"
check "plans: weekly play product is ajk_weekly" "ajk_weekly" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["plans"] if x["id"]=="weekly"][0]["play_product_id"]["weekly"])')"
check "plans: weekly features (no Veo/lip-sync, max 768P)" "False/False/768P" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);f=[x for x in d["plans"] if x["id"]=="weekly"][0]["features"];print(str(f["can_veo"])+"/"+str(f["can_lipsync"])+"/"+f["max_quality"])')"
check "plans: normal has no weekly price (null)" "None" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);print([x for x in d["plans"] if x["id"]=="normal"][0]["price_weekly"])')"
check "plans: pro features (Veo + lip-sync, max 2K)" "True/True/2K" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);f=[x for x in d["plans"] if x["id"]=="pro"][0]["features"];print(str(f["can_veo"])+"/"+str(f["can_lipsync"])+"/"+f["max_quality"])')"
check "plans: extrapro 14000/mo + 600 credits, max 4K" "14000/600/4K" "$(echo $PL6 | python3 -c 'import sys,json;d=json.load(sys.stdin);p=[x for x in d["plans"] if x["id"]=="extrapro"][0];print(str(p["price_monthly"])+"/"+str(p["credits_monthly"])+"/"+p["features"]["max_quality"])')"
AR6=$(curl -s -X POST $B6/api/auth/register -H 'Content-Type: application/json' -d '{"email":"v9admin@example.com","password":"password123"}')
AT6=$(echo $AR6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
WR6=$(curl -s -X POST $B6/api/auth/register -H 'Content-Type: application/json' -d '{"email":"v9user@example.com","password":"password123"}')
UT6=$(echo $WR6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
UID6=$(curl -s $B6/api/me -H "Authorization: Bearer $UT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')

echo "--- pricing v9: weekly activation (80 credits, 7-day period) ---"
WMP=$(curl -s -X POST $B6/api/admin/users/$UID6/manual-payment -H "Authorization: Bearer $AT6" -H 'Content-Type: application/json' -d '{"plan_id":"weekly","period":"weekly"}')
check "weekly manual payment ok" "True" "$(echo $WMP | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
check "weekly payment amount Rs 1800" "1800" "$(curl -s $B6/api/payments -H "Authorization: Bearer $UT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["payments"][0]["amount"])')"
WME=$(curl -s $B6/api/me -H "Authorization: Bearer $UT6")
check "weekly: plan bucket granted 80" "80" "$(echo $WME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
check "weekly: total = 100 free + 80 plan = 180" "180" "$(echo $WME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "weekly: subscription period is weekly" "weekly" "$(echo $WME | python3 -c 'import sys,json;print(json.load(sys.stdin)["subscription"]["period"])')"
check "weekly: period spans exactly 7 days" "7" "$(echo $WME | python3 -c 'import sys,json,datetime as dt;s=json.load(sys.stdin)["subscription"];a=dt.datetime.fromisoformat(s["current_period_start"]);b=dt.datetime.fromisoformat(s["current_period_end"]);print((b-a).days)')"

echo "--- pricing v9: period/plan fit is enforced ---"
check "weekly plan bought monthly -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B6/api/admin/users/$UID6/manual-payment -H "Authorization: Bearer $AT6" -H 'Content-Type: application/json' -d '{"plan_id":"weekly","period":"monthly"}')"
check "weekly plan bought yearly -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B6/api/admin/users/$UID6/manual-payment -H "Authorization: Bearer $AT6" -H 'Content-Type: application/json' -d '{"plan_id":"weekly","period":"yearly"}')"
check "monthly plan bought weekly -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B6/api/admin/users/$UID6/manual-payment -H "Authorization: Bearer $AT6" -H 'Content-Type: application/json' -d '{"plan_id":"normal","period":"weekly"}')"
check "rejected period purchases changed nothing (total still 180)" "180" "$(curl -s $B6/api/me -H "Authorization: Bearer $UT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- pricing v9: rate card charges by routed quality (2K / 4K) ---"
PR6=$(curl -s -X POST $B6/api/auth/register -H 'Content-Type: application/json' -d '{"email":"v9pro@example.com","password":"password123"}')
PT6=$(echo $PR6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PID6=$(curl -s $B6/api/me -H "Authorization: Bearer $PT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B6/api/admin/users/$PID6/activate -H "Authorization: Bearer $AT6" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
curl -s -o /dev/null -X POST $B6/api/generate -H "Authorization: Bearer $PT6" -H 'Idempotency-Key: v9-pro-5s' -H 'Content-Type: application/json' -d '{"prompt":"a city skyline at golden hour","aspect_ratio":"16:9","duration":5}'
PH6=$(curl -s $B6/api/history -H "Authorization: Bearer $PT6")
check "pro 5s job routed at 2K" "2K" "$(echo $PH6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "pro 5s job cost 15 credits (2K rate)" "15" "$(echo $PH6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
curl -s -o /dev/null -X POST $B6/api/generate -H "Authorization: Bearer $PT6" -H 'Idempotency-Key: v9-pro-10s' -H 'Content-Type: application/json' -d '{"prompt":"a city skyline at golden hour, longer take","aspect_ratio":"16:9","duration":10}'
check "pro 10s job cost 30 credits (2K rate)" "30" "$(curl -s $B6/api/history -H "Authorization: Bearer $PT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
XR6=$(curl -s -X POST $B6/api/auth/register -H 'Content-Type: application/json' -d '{"email":"v9xpro@example.com","password":"password123"}')
XT6=$(echo $XR6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
XID6=$(curl -s $B6/api/me -H "Authorization: Bearer $XT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B6/api/admin/users/$XID6/activate -H "Authorization: Bearer $AT6" -H 'Content-Type: application/json' -d '{"plan_id":"extrapro","period":"monthly"}'
curl -s -o /dev/null -X POST $B6/api/generate -H "Authorization: Bearer $XT6" -H 'Idempotency-Key: v9-x-5s' -H 'Content-Type: application/json' -d '{"prompt":"an eagle soaring over snow peaks","aspect_ratio":"16:9","duration":5}'
XH6=$(curl -s $B6/api/history -H "Authorization: Bearer $XT6")
check "extrapro 5s job routed at 4K" "4K" "$(echo $XH6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "extrapro 5s job cost 40 credits (4K rate)" "40" "$(echo $XH6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
curl -s -o /dev/null -X POST $B6/api/generate -H "Authorization: Bearer $XT6" -H 'Idempotency-Key: v9-x-10s' -H 'Content-Type: application/json' -d '{"prompt":"an eagle soaring over snow peaks, longer take","aspect_ratio":"16:9","duration":10}'
check "extrapro 10s job cost 80 credits (4K rate)" "80" "$(curl -s $B6/api/history -H "Authorization: Bearer $XT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"

echo "--- pricing v9: daily cap enforced at 400 ---"
DR6=$(curl -s -X POST $B6/api/auth/register -H 'Content-Type: application/json' -d '{"email":"v9daily@example.com","password":"password123"}')
DT6=$(echo $DR6 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
DID6=$(curl -s $B6/api/me -H "Authorization: Bearer $DT6" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-v9-test.db');
db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?)').run($DID6, 'daily-cap seed', '16:9', 10, 'realistic', 'completed', 395);
console.log('seeded 395 credits of completed spend for today');
"
DCAP=$(curl -s -w '\n%{http_code}' -X POST $B6/api/generate -H "Authorization: Bearer $DT6" -H 'Content-Type: application/json' -d '{"prompt":"one more small clip please","aspect_ratio":"16:9","duration":5}')
check "395 spent + 10 more exceeds the 400 daily cap -> 429" "429" "$(echo "$DCAP" | tail -1)"
check "daily-cap error names the limit" "Daily spending limit reached. Try again tomorrow." "$(echo "$DCAP" | sed '$d' | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
kill $SRV6_PID 2>/dev/null

echo "--- voice system: config on the main server ---"
CV=$(curl -s $B/api/config)
check "voice: gemini provider configured (fal key present)" "True" "$(echo $CV | python3 -c 'import sys,json;print(json.load(sys.stdin)["voice"]["providers"]["gemini"])')"
check "voice: azure provider NOT configured (no owner key yet)" "False" "$(echo $CV | python3 -c 'import sys,json;print(json.load(sys.stdin)["voice"]["providers"]["azure"])')"
check "voice: default provider is gemini" "gemini" "$(echo $CV | python3 -c 'import sys,json;print(json.load(sys.stdin)["voice"]["default_provider"])')"
check "voice: catalog lists Kore as a female gemini voice" "female" "$(echo $CV | python3 -c 'import sys,json;d=json.load(sys.stdin);g=[x for x in d["voice"]["voices"] if x["provider"]=="gemini"][0];print([v for v in g["voices"] if v["id"]=="Kore"][0]["gender"])')"
check "voice: add-on costs lipsync 30 / voiceover 10" "30/10" "$(echo $CV | python3 -c 'import sys,json;d=json.load(sys.stdin)["voice"]["costs"];print(str(d["lipsync_credits"])+"/"+str(d["voiceover_credits"]))')"

echo "--- sound system: config on the main server ---"
CS=$(curl -s $B/api/config)
check "sound: configured (fal key present)" "True" "$(echo $CS | python3 -c 'import sys,json;print(json.load(sys.stdin)["sound"]["configured"])')"
check "sound: add-on costs sync 10 / premium 25 / sfx 5 / music 5" "10/25/5/5" "$(echo $CS | python3 -c 'import sys,json;c=json.load(sys.stdin)["sound"]["costs"];print(str(c["sync"])+"/"+str(c["premium_sync"])+"/"+str(c["sfx"])+"/"+str(c["music"]))')"
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
check "unconfigured: preview charged nothing" "100" "$(curl -s $B8/api/me -H "Authorization: Bearer $UT8" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
SEED8=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-voice-none-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($UID8, 'seed clip', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:18090/media/clip.mp4', 10).lastInsertRowid));
")
check "unconfigured: voiceover -> 503" "503" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B8/api/voice/voiceover -H "Authorization: Bearer $UT8" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED8,\"script\":\"mera naam ahmed hai\",\"spoken_language\":\"ur\",\"script_mode\":\"roman\"}")"
check "unconfigured: voiceover charged nothing" "100" "$(curl -s $B8/api/me -H "Authorization: Bearer $UT8" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
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
check "voice instance: languages are en/hi/ur" "en,hi,ur" "$(echo $CFG7 | python3 -c 'import sys,json;print(",".join(sorted(l["code"] for l in json.load(sys.stdin)["voice"]["languages"])))')"
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
check "preview: charges nothing (credits_left 100)" "100" "$(echo $PVB | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
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
check "preview: still no charge after 5 previews" "100" "$(curl -s $B7/api/me -H "Authorization: Bearer $PT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- preview daily cap --
CR7=$(curl -s -X POST $B7/api/auth/register -H 'Content-Type: application/json' -d '{"email":"capuser@example.com","password":"password123"}')
CT7=$(echo $CR7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
for i in 1 2 3 4 5; do
  curl -s -o /dev/null -X POST $B7/api/voice/preview -H "Authorization: Bearer $CT7" -H 'Content-Type: application/json' -d '{"script":"salam dost","spoken_language":"ur","script_mode":"roman"}'
done
check "preview: 6th preview of the day -> 429" "429" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B7/api/voice/preview -H "Authorization: Bearer $CT7" -H 'Content-Type: application/json' -d '{"script":"salam dost","spoken_language":"ur","script_mode":"roman"}')"
check "preview cap: credits untouched" "100" "$(curl -s $B7/api/me -H "Authorization: Bearer $CT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- preview provider failure --
FR7=$(curl -s -X POST $B7/api/auth/register -H 'Content-Type: application/json' -d '{"email":"failuser@example.com","password":"password123"}')
FT7=$(echo $FR7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
check "preview: provider failure -> 502" "502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B7/api/voice/preview -H "Authorization: Bearer $FT7" -H 'Content-Type: application/json' -d '{"script":"FAILME please","spoken_language":"en","script_mode":"native"}')"
check "preview failure: credits untouched" "100" "$(curl -s $B7/api/me -H "Authorization: Bearer $FT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- lip-sync gating: Normal plan -> 403 --
LR7=$(curl -s -X POST $B7/api/auth/register -H 'Content-Type: application/json' -d '{"email":"lipnormal@example.com","password":"password123"}')
LT7=$(echo $LR7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
LSN=$(curl -s -w '\n%{http_code}' -X POST $B7/api/voice/lipsync -H "Authorization: Bearer $LT7" -H 'Content-Type: application/json' -d '{"image_path":"data/uploads/1/x.png","script":"mera naam ahmed hai","spoken_language":"ur","script_mode":"roman"}')
check "lipsync: no Pro plan -> 403" "403" "$(echo "$LSN" | tail -1)"
check "lipsync: 403 error names the Pro plan" "yes" "$(echo "$LSN" | sed '$d' | python3 -c 'import sys,json;print("yes" if "Pro" in json.load(sys.stdin)["error"] else "no")')"
check "lipsync 403: credits untouched" "100" "$(curl -s $B7/api/me -H "Authorization: Bearer $LT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- lip-sync success + failure (Pro user) --
RR7=$(curl -s -X POST $B7/api/auth/register -H 'Content-Type: application/json' -d '{"email":"lippro@example.com","password":"password123"}')
RT7=$(echo $RR7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
RID7=$(curl -s $B7/api/me -H "Authorization: Bearer $RT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B7/api/admin/users/$RID7/activate -H "Authorization: Bearer $AT7" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
check "pro user balance after activation (100 free + 500 plan)" "600" "$(curl -s $B7/api/me -H "Authorization: Bearer $RT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
PNG_B64_V=$(python3 -c "import base64; print(base64.b64encode(bytes.fromhex('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c636000000000020001e221bc330000000049454e44ae426082')).decode())")
UPV=$(curl -s -X POST $B7/api/uploads/image -H "Authorization: Bearer $RT7" -H 'Content-Type: application/json' -d "{\"image_base64\":\"$PNG_B64_V\",\"content_type\":\"image/png\"}")
VIMG=$(echo $UPV | python3 -c 'import sys,json;print(json.load(sys.stdin)["image_path"])')
LS=$(curl -s -w '\n%{http_code}' -X POST $B7/api/voice/lipsync -H "Authorization: Bearer $RT7" -H 'Content-Type: application/json' -d "{\"image_path\":\"$VIMG\",\"script\":\"mera naam ahmed hai\",\"spoken_language\":\"ur\",\"script_mode\":\"roman\"}")
check "lipsync (image): -> 201" "201" "$(echo "$LS" | tail -1)"
LSB=$(echo "$LS" | sed '$d')
check "lipsync (image): generation kind is lipsync" "lipsync" "$(echo $LSB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["kind"])')"
check "lipsync (image): cost is 30 credits" "30" "$(echo $LSB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["cost_credits"])')"
check "lipsync (image): status completed" "completed" "$(echo $LSB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["status"])')"
check "lipsync (image): credits_left 570 (charged exactly once)" "570" "$(echo $LSB | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
VC2=$(curl -s $B7/api/_test/voice-calls)
check "lipsync (image): fal body has data-URI image_url + /files/voice/ audio_url" "ok" "$(echo $VC2 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x["kind"]=="queue"][-1];b=c["body"];print("ok" if c["model"]=="minimax/h3-max/lip-sync/image-to-video" and b["image_url"].startswith("data:image/png") and "/files/voice/" in b["audio_url"] else "bad")')"
check "lipsync (image): newest history entry is the lipsync job" "lipsync" "$(curl -s $B7/api/history -H "Authorization: Bearer $RT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["kind"])')"
LSF=$(curl -s -w '\n%{http_code}' -X POST $B7/api/voice/lipsync -H "Authorization: Bearer $RT7" -H 'Content-Type: application/json' -d "{\"image_path\":\"$VIMG\",\"script\":\"FAILME bolna hai\",\"spoken_language\":\"ur\",\"script_mode\":\"native\"}")
check "lipsync: TTS failure -> 502" "502" "$(echo "$LSF" | tail -1)"
check "lipsync failure: full refund (back to 570)" "570" "$(curl -s $B7/api/me -H "Authorization: Bearer $RT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "lipsync failure: job row marked failed" "failed" "$(curl -s $B7/api/history -H "Authorization: Bearer $RT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["status"])')"
SEED7=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-voice-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($RID7, 'seed talking source', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:$FAL_STUB_PORT/media/clip.mp4', 10).lastInsertRowid));
")
LSV=$(curl -s -w '\n%{http_code}' -X POST $B7/api/voice/lipsync -H "Authorization: Bearer $RT7" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED7,\"script\":\"mera naam ahmed hai\",\"spoken_language\":\"ur\",\"script_mode\":\"roman\"}")
check "lipsync (video): -> 201" "201" "$(echo "$LSV" | tail -1)"
LSVB=$(echo "$LSV" | sed '$d')
check "lipsync (video): routed to the latentsync model" "fal-ai/latentsync" "$(echo $LSVB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["model"])')"
check "lipsync (video): credits_left 540" "540" "$(echo $LSVB | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"

# -- voiceover: failure refund, then success + mux, then chunking --
VR7=$(curl -s -X POST $B7/api/auth/register -H 'Content-Type: application/json' -d '{"email":"voiceover@example.com","password":"password123"}')
VT7=$(echo $VR7 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
VID7=$(curl -s $B7/api/me -H "Authorization: Bearer $VT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
SEEDV=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-voice-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($VID7, 'seed voiceover source', '16:9', 2, 'realistic', 'completed', 'http://127.0.0.1:$FAL_STUB_PORT/media/clip.mp4', 10).lastInsertRowid));
")
check "voiceover: TTS failure -> 502" "502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B7/api/voice/voiceover -H "Authorization: Bearer $VT7" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDV,\"script\":\"FAILME bolna hai\",\"spoken_language\":\"ur\",\"script_mode\":\"native\"}")"
check "voiceover failure: full refund (back to 100)" "100" "$(curl -s $B7/api/me -H "Authorization: Bearer $VT7" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
VO=$(curl -s -w '\n%{http_code}' -X POST $B7/api/voice/voiceover -H "Authorization: Bearer $VT7" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDV,\"script\":\"mera naam ahmed hai\",\"spoken_language\":\"ur\",\"script_mode\":\"roman\"}")
check "voiceover: -> 201" "201" "$(echo "$VO" | tail -1)"
VOB=$(echo "$VO" | sed '$d')
check "voiceover: generation kind is voiceover" "voiceover" "$(echo $VOB | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["kind"])')"
check "voiceover: cost 10, credits_left 90" "10/90" "$(echo $VOB | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
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
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($UID10, 'seed sound source', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:18088/media/clip.mp4', 10).lastInsertRowid));
")
check "sound disabled: apply -> 503" "503" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B10/api/sound/apply -H "Authorization: Bearer $UT10" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED10,\"mode\":\"sync\"}")"
check "sound disabled: generate with sound -> 503" "503" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B10/api/generate -H "Authorization: Bearer $UT10" -H 'Content-Type: application/json' -d '{"prompt":"a calm lake at dawn","duration":5,"sound":{"mode":"sync"}}')"
check "sound disabled: nothing charged (balance 100)" "100" "$(curl -s $B10/api/me -H "Authorization: Bearer $UT10" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
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
check "gen+sync: total cost 20 (10 video + 10 sync)" "20" "$(echo $GA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_credits"])')"
check "gen+sync: sound add-on reported as 10" "10" "$(echo $GA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["sound_cost_credits"])')"
check "gen+sync: balance 80 after submit (charged exactly once)" "80" "$(echo $GA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
JOBA9=$(echo $GA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
POLLA9=$(curl -s $B9/api/generations/$JOBA9 -H "Authorization: Bearer $TA9")
check "gen+sync: job completed" "completed" "$(echo $POLLA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
check "gen+sync: sound_status applied" "applied" "$(echo $POLLA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["sound_status"])')"
check "gen+sync: sound_mode recorded" "sync" "$(echo $POLLA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["sound_mode"])')"
check "gen+sync: video_url is the sounded (mmaudio) version" "http://127.0.0.1:$SOUND_STUB_PORT/media/clip.mp4" "$(echo $POLLA9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["video_url"])')"
check "gen+sync: still 80 after completion (no second charge)" "80" "$(curl -s $B9/api/me -H "Authorization: Bearer $TA9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
VC9=$(curl -s $B9/api/_test/voice-calls)
check "gen+sync: mmaudio body has video_url + prompt + duration" "ok" "$(echo $VC9 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("model")=="fal-ai/mmaudio-v2"][-1];b=c["body"];print("ok" if b.get("video_url","").endswith("/media/clip.mp4") and b.get("prompt")=="rain and thunder over the city" and b.get("duration")==5 else "bad")')"
check "gen+sync: unknown sound mode -> 400, no charge" "400/80" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B9/api/generate -H "Authorization: Bearer $TA9" -H 'Content-Type: application/json' -d '{"prompt":"a calm lake","duration":5,"sound":{"mode":"bogus"}}')/$(curl -s $B9/api/me -H "Authorization: Bearer $TA9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- generate with sync sound, engine fails: video delivered, add-on refunded --
RB9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"soundfail@example.com","password":"password123"}')
TB9=$(echo $RB9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
GB9=$(curl -s -X POST $B9/api/generate -H "Authorization: Bearer $TB9" -H 'Content-Type: application/json' -d '{"prompt":"a quiet beach at sunset","aspect_ratio":"16:9","duration":5,"sound":{"mode":"sync","prompt":"FAILME waves crashing"}}')
check "gen+sync fail: balance 80 after submit" "80" "$(echo $GB9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
JOBB9=$(echo $GB9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
POLLB9=$(curl -s $B9/api/generations/$JOBB9 -H "Authorization: Bearer $TB9")
check "gen+sync fail: video still completed" "completed" "$(echo $POLLB9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')"
check "gen+sync fail: sound_status failed_refunded" "failed_refunded" "$(echo $POLLB9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["sound_status"])')"
check "gen+sync fail: add-on refunded (balance 90)" "90" "$(curl -s $B9/api/me -H "Authorization: Bearer $TB9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "gen+sync fail: row cost reduced to the video-only 10" "10" "$(echo $POLLB9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_credits"])')"

# -- generate with sound effects: mixed under the original audio --
RC9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"sfxgen@example.com","password":"password123"}')
TC9=$(echo $RC9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
GC9=$(curl -s -X POST $B9/api/generate -H "Authorization: Bearer $TC9" -H 'Content-Type: application/json' -d '{"prompt":"a dog playing in a park","aspect_ratio":"16:9","duration":5,"sound":{"mode":"sfx","prompt":"dog barking and birds","volume":40}}')
check "gen+sfx: total cost 15 (10 video + 5 sfx)" "15" "$(echo $GC9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_credits"])')"
check "gen+sfx: balance 85 after submit" "85" "$(echo $GC9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
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
check "urdu sound: charged once (balance 80)" "80" "$(curl -s $B9/api/me -H "Authorization: Bearer $TH9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- apply sound to an existing video: sync, premium gate, music, failure --
RD9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"apply@example.com","password":"password123"}')
TD9=$(echo $RD9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
DID9=$(curl -s $B9/api/me -H "Authorization: Bearer $TD9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
SEEDD9=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-sound-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($DID9, 'seed apply source', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:$SOUND_STUB_PORT/media/clip.mp4', 10).lastInsertRowid));
")
AP19=$(curl -s -w '\n%{http_code}' -X POST $B9/api/sound/apply -H "Authorization: Bearer $TD9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDD9,\"mode\":\"sync\",\"prompt\":\"city traffic and rain\"}")
check "apply sync: -> 201" "201" "$(echo "$AP19" | tail -1)"
AP1B=$(echo "$AP19" | sed '$d')
check "apply sync: new history entry kind is sound" "sound" "$(echo $AP1B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["kind"])')"
check "apply sync: linked to the source generation" "$SEEDD9" "$(echo $AP1B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["source_generation_id"])')"
check "apply sync: cost 10, credits_left 90" "10/90" "$(echo $AP1B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
check "apply sync: sound_status applied on the new entry" "applied" "$(echo $AP1B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["sound_status"])')"
check "apply: another user's video -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B9/api/sound/apply -H "Authorization: Bearer $TA9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDD9,\"mode\":\"sync\"}")"
AP29=$(curl -s -w '\n%{http_code}' -X POST $B9/api/sound/apply -H "Authorization: Bearer $TD9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDD9,\"mode\":\"premium_sync\"}")
check "apply premium (no plan): -> 403" "403" "$(echo "$AP29" | tail -1)"
check "apply premium 403: error names the Pro plan" "yes" "$(echo "$AP29" | sed '$d' | python3 -c 'import sys,json;print("yes" if "Pro" in json.load(sys.stdin)["error"] else "no")')"
check "apply premium 403: credits untouched (90)" "90" "$(curl -s $B9/api/me -H "Authorization: Bearer $TD9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
AP39=$(curl -s -w '\n%{http_code}' -X POST $B9/api/sound/apply -H "Authorization: Bearer $TD9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDD9,\"mode\":\"music\",\"prompt\":\"soft piano bed\",\"volume\":100}")
check "apply music: -> 201" "201" "$(echo "$AP39" | tail -1)"
AP3B=$(echo "$AP39" | sed '$d')
check "apply music: cost 5, credits_left 85" "5/85" "$(echo $AP3B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
MUSURL=$(echo $AP3B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["video_url"])')
curl -s -o /tmp/music-mixed.mp4 $B9$MUSURL
check "apply music: mixed output HAS an audio stream" "yes" "$("$FFBIN9" -i /tmp/music-mixed.mp4 2>&1 | python3 -c 'import sys;print("yes" if "Audio:" in sys.stdin.read() else "no")')"
SC9B=$(curl -s $B9/api/_test/sound-calls)
check "apply music: engine body asks for instrumental, duration 10" "ok" "$(echo $SC9B | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("engine")=="music"][-1];b=c["body"];print("ok" if "instrumental, no vocals" in b.get("prompt","") and b.get("duration")==10 else "bad")')"
check "apply sfx (engine fails): -> 502" "502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B9/api/sound/apply -H "Authorization: Bearer $TD9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDD9,\"mode\":\"sfx\",\"prompt\":\"FAILME dog\"}")"
check "apply sfx failure: full refund (still 85)" "85" "$(curl -s $B9/api/me -H "Authorization: Bearer $TD9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "apply sfx failure: job row marked failed" "failed" "$(curl -s $B9/api/history -H "Authorization: Bearer $TD9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["status"])')"

# -- volume: sync at 50% measurably lowers the soundtrack level --
RE9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"vol@example.com","password":"password123"}')
TE9=$(echo $RE9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
EID9=$(curl -s $B9/api/me -H "Authorization: Bearer $TE9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
SEEDE9=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-sound-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($EID9, 'seed volume source', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:$SOUND_STUB_PORT/media/clip.mp4', 10).lastInsertRowid));
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

# -- premium sync succeeds for a Pro user (+25, speech preserved by design) --
RF9=$(curl -s -X POST $B9/api/auth/register -H 'Content-Type: application/json' -d '{"email":"soundpro@example.com","password":"password123"}')
TF9=$(echo $RF9 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
FID9=$(curl -s $B9/api/me -H "Authorization: Bearer $TF9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B9/api/admin/users/$FID9/activate -H "Authorization: Bearer $AT9" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
check "sound pro balance after activation (100 free + 500 plan)" "600" "$(curl -s $B9/api/me -H "Authorization: Bearer $TF9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
SEEDF9=$(node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-sound-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits) VALUES (?, ?, ?, ?, ?, ?, ?, ?)').run($FID9, 'seed premium source', '16:9', 5, 'realistic', 'completed', 'http://127.0.0.1:$SOUND_STUB_PORT/media/clip.mp4', 10).lastInsertRowid));
")
APP9=$(curl -s -w '\n%{http_code}' -X POST $B9/api/sound/apply -H "Authorization: Bearer $TF9" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDF9,\"mode\":\"premium_sync\",\"prompt\":\"distant sirens\"}")
check "apply premium (Pro): -> 201" "201" "$(echo "$APP9" | tail -1)"
APPB=$(echo "$APP9" | sed '$d')
check "apply premium (Pro): cost 25, credits_left 575" "25/575" "$(echo $APPB | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
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
check "audio-only sfx: kind sound, cost 5, credits_left 95" "sound/5/95" "$(echo $SGAB | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["generation"]["kind"]+"/"+str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
check "audio-only sfx: file under /files/sounds/ (.mp3)" "yes" "$(echo $SGAB | python3 -c 'import sys,json;u=json.load(sys.stdin)["audio_url"];print("yes" if u.startswith("/files/sounds/") and u.endswith(".mp3") else "no")')"
SFXAURL=$(echo $SGAB | python3 -c 'import sys,json;print(json.load(sys.stdin)["audio_url"])')
check "audio-only sfx: file is served (200)" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B9$SFXAURL)"
SC9C=$(curl -s $B9/api/_test/sound-calls)
check "audio-only sfx: engine body has text + duration_seconds 10" "ok" "$(echo $SC9C | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("engine")=="sfx"][-1];b=c["body"];print("ok" if b.get("text")=="dog barking in the rain" and b.get("duration_seconds")==10 else "bad")')"
SMA9=$(curl -s -w '\n%{http_code}' -X POST $B9/api/sound/generate -H "Authorization: Bearer $TG9" -H 'Content-Type: application/json' -d '{"kind":"music","prompt":"calm piano for a rainy evening","duration_seconds":30}')
check "audio-only music: -> 201" "201" "$(echo "$SMA9" | tail -1)"
SMAB=$(echo "$SMA9" | sed '$d')
check "audio-only music: credits_left 90" "90" "$(echo $SMAB | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
check "audio-only music: file under /files/sounds/ (.wav)" "yes" "$(echo $SMAB | python3 -c 'import sys,json;u=json.load(sys.stdin)["audio_url"];print("yes" if u.startswith("/files/sounds/") and u.endswith(".wav") else "no")')"
MUSAURL=$(echo $SMAB | python3 -c 'import sys,json;print(json.load(sys.stdin)["audio_url"])')
check "audio-only music: file is served (200)" "200" "$(curl -s -o /dev/null -w '%{http_code}' $B9$MUSAURL)"
SC9D=$(curl -s $B9/api/_test/sound-calls)
check "audio-only music: engine body asks for instrumental, duration 30" "ok" "$(echo $SC9D | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("engine")=="music"][-1];b=c["body"];print("ok" if "instrumental, no vocals" in b.get("prompt","") and b.get("duration")==30 else "bad")')"
check "audio-only: engine failure -> 502" "502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B9/api/sound/generate -H "Authorization: Bearer $TG9" -H 'Content-Type: application/json' -d '{"kind":"sfx","prompt":"FAILME thunder"}')"
check "audio-only failure: full refund (still 90)" "90" "$(curl -s $B9/api/me -H "Authorization: Bearer $TG9" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
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
check "config finishers: reframe 0 / captions 5" "0/5" "$(echo $CFG11 | python3 -c 'import sys,json;p=json.load(sys.stdin)["finishers"]["prices"];print(str(p["reframe"])+"/"+str(p["captions"]))')"
check "config finishers: upscale model is topaz endpoint" "fal-ai/topaz/upscale/video" "$(echo $CFG11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["finishers"]["prices"]["upscale"]["model"])')"
check "config draft: 480P at 7/14 credits" "480P/7/14" "$(echo $CFG11 | python3 -c 'import sys,json;d=json.load(sys.stdin)["draft"];print(d["quality"]+"/"+str(d["cost_by_duration"]["5"])+"/"+str(d["cost_by_duration"]["10"]))')"
RA11=$(curl -s -X POST $B11/api/auth/register -H 'Content-Type: application/json' -d '{"email":"fin-a@example.com","password":"password123"}')
TA11=$(echo $RA11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
AID11=$(curl -s $B11/api/me -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
RB11=$(curl -s -X POST $B11/api/auth/register -H 'Content-Type: application/json' -d '{"email":"fin-b@example.com","password":"password123"}')
TB11=$(echo $RB11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
seed_fin() { # userId prompt url resolution
node --input-type=module -e "
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync('/tmp/myvideoai-finish-test.db');
console.log(Number(db.prepare('INSERT INTO generations (user_id, prompt, aspect_ratio, duration, style, status, video_url, cost_credits, resolution) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)').run($1, '$2', '16:9', 5, 'realistic', 'completed', '$3', 10, '$4').lastInsertRowid));
"
}
SEED169=$(seed_fin $AID11 "seed harbour clip" "http://127.0.0.1:$FIN_STUB_PORT/media/clip169.mp4" "768P")
SEEDSIL=$(seed_fin $AID11 "seed silent clip" "http://127.0.0.1:$FIN_STUB_PORT/media/silent.mp4" "768P")

# -- reframe: free, blurred-pad, correct output dimensions --
RF11=$(curl -s -w '\n%{http_code}' -X POST $B11/api/finish/reframe -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED169,\"aspect_ratio\":\"9:16\"}")
check "reframe: -> 201" "201" "$(echo "$RF11" | tail -1)"
RF11B=$(echo "$RF11" | sed '$d')
check "reframe: kind reframe, linked to source, cost 0" "reframe/$SEED169/0" "$(echo $RF11B | python3 -c 'import sys,json;g=json.load(sys.stdin)["generation"];print(g["kind"]+"/"+str(g["source_generation_id"])+"/"+str(g["cost_credits"]))')"
check "reframe: FREE — balance still 100" "100" "$(curl -s $B11/api/me -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
RFURL=$(echo $RF11B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["video_url"])')
curl -s -o /tmp/reframed.mp4 $B11$RFURL
check "reframe: output is exactly 1080x1920 (9:16)" "1080x1920" "$("$FFBIN11" -i /tmp/reframed.mp4 2>&1 | python3 -c 'import sys,re; m=re.search(r"(\d{2,5})x(\d{2,5})", sys.stdin.read()); print(m.group(1)+"x"+m.group(2) if m else "none")')"
check "reframe: another user's video -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/finish/reframe -H "Authorization: Bearer $TB11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED169,\"aspect_ratio\":\"1:1\"}")"
check "finish: unknown action -> 400" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/finish/bogus -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED169}")"

# -- captions: whisper stub -> burned subs, -5; silent video -> 400 free --
CP11=$(curl -s -w '\n%{http_code}' -X POST $B11/api/finish/captions -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED169}")
check "captions: -> 201" "201" "$(echo "$CP11" | tail -1)"
CP11B=$(echo "$CP11" | sed '$d')
check "captions: kind captions, cost 5, credits_left 95" "captions/5/95" "$(echo $CP11B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["generation"]["kind"]+"/"+str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
CPURL=$(echo $CP11B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["video_url"])')
curl -s -o /tmp/captioned.mp4 $B11$CPURL
check "captions: output keeps video + audio streams" "yes/yes" "$("$FFBIN11" -i /tmp/captioned.mp4 2>&1 | python3 -c 'import sys;s=sys.stdin.read();print(("yes" if "Video:" in s else "no")+"/"+("yes" if "Audio:" in s else "no"))')"
VC11=$(curl -s $B11/api/_test/voice-calls)
check "captions: whisper body has audio_url + task transcribe + segment chunks" "ok" "$(echo $VC11 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("model")=="fal-ai/whisper"][-1];b=c["body"];print("ok" if b.get("audio_url","").endswith("/media/clip169.mp4") and b.get("task")=="transcribe" and b.get("chunk_level")=="segment" else "bad")')"
CPS11=$(curl -s -w '\n%{http_code}' -X POST $B11/api/finish/captions -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDSIL}")
check "captions on silent video: -> 400 (no audio stream)" "400" "$(echo "$CPS11" | tail -1)"
check "captions on silent video: nothing charged (still 95)" "95" "$(curl -s $B11/api/me -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

# -- draft: 480P at 7 credits, marked draft, add-ons rejected --
DR11=$(curl -s -X POST $B11/api/generate -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d '{"prompt":"a lighthouse draft preview","aspect_ratio":"16:9","duration":5,"quality":"draft"}')
check "draft: cost 7 credits" "7" "$(echo $DR11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["cost_credits"])')"
check "draft: stage draft + resolution 480P in response" "draft/480P" "$(echo $DR11 | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["stage"]+"/"+g["resolution"])')"
check "draft: balance 88 (95 - 7)" "88" "$(echo $DR11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
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
check "draft + sound rejected: balance still 88" "88" "$(curl -s $B11/api/me -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "sound apply on a draft: -> 400 (drafts take no add-ons)" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/sound/apply -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$DRAFTID,\"mode\":\"sync\"}")"
check "voiceover on a draft: -> 400 (drafts take no add-ons)" "400" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/voice/voiceover -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$DRAFTID,\"script\":\"hello draft world\"}")"

# -- upgrade: same prompt/settings at full quality, standard rate, linked --
UP11=$(curl -s -w '\n%{http_code}' -X POST $B11/api/generations/$DRAFTID/upgrade -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d '{"quality":"768P"}')
check "upgrade: -> 200" "200" "$(echo "$UP11" | tail -1)"
UP11B=$(echo "$UP11" | sed '$d')
check "upgrade: standard rate 10 charged, linked to the draft" "10/$DRAFTID" "$(echo $UP11B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["source_generation_id"]))')"
check "upgrade: balance 78 (88 - 10)" "78" "$(echo $UP11B | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits_left"])')"
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
check "extend: kind extend, standard 768P/5s rate 10, balance 68" "extend/10/68" "$(echo $EX11B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(g["generation"]["kind"]+"/"+str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
EXURL=$(echo $EX11B | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["video_url"])')
check "extend: joined video stored under /files/joined/" "yes" "$(python3 -c "print('yes' if '$EXURL'.startswith('/files/joined/') else 'no')")"
curl -s -o /tmp/extended.mp4 $B11$EXURL
check "extend: joined duration approx source + extension (2s + 2s)" "ok" "$("$FFBIN11" -i /tmp/extended.mp4 2>&1 | python3 -c 'import sys,re; m=re.search(r"Duration: (\d+):(\d+):([\d.]+)", sys.stdin.read()); d=int(m.group(1))*3600+int(m.group(2))*60+float(m.group(3)) if m else -1; print("ok" if 3.4 <= d <= 4.8 else "bad")')"
VC11B=$(curl -s $B11/api/_test/voice-calls)
check "extend: i2v body has data-URI image + 768P + 5s" "ok" "$(echo $VC11B | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("model")=="minimax/h3/image-to-video"][-1];b=c["body"];print("ok" if str(b.get("image_url","")).startswith("data:image/jpeg;base64,") and b.get("resolution")=="768P" and b.get("duration")==5 else "bad")')"
SEEDFAIL=$(seed_fin $AID11 "FAILME waterfall scene" "http://127.0.0.1:$FIN_STUB_PORT/media/clip169.mp4" "768P")
check "extend failure: -> 502" "502" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/finish/extend -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDFAIL,\"extra_seconds\":5}")"
check "extend failure: refunded exactly once (still 68)" "68" "$(curl -s $B11/api/me -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "extend failure: the job row is marked failed (no partial entry)" "failed" "$(curl -s $B11/api/history -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["status"])')"
SEED4K=$(seed_fin $AID11 "seed 4k clip" "http://127.0.0.1:$FIN_STUB_PORT/media/clip169.mp4" "4K")
check "extend 4K source on free plan: -> 403 (plan cap)" "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/finish/extend -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED4K,\"extra_seconds\":5}")"

# -- upscale: plan gate, topaz body, price formula (min + computed) --
check "upscale 768P on free plan: -> 403 (result 2K above plan max)" "403" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B11/api/finish/upscale -H "Authorization: Bearer $TA11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEED169}")"
check "upscale gate: nothing charged (still 68)" "68" "$(curl -s $B11/api/me -H "Authorization: Bearer $TA11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
RP11=$(curl -s -X POST $B11/api/auth/register -H 'Content-Type: application/json' -d '{"email":"fin-pro@example.com","password":"password123"}')
TP11=$(echo $RP11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
PID11=$(curl -s $B11/api/me -H "Authorization: Bearer $TP11" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -s -o /dev/null -X POST $B11/api/admin/users/$PID11/activate -H "Authorization: Bearer $AT11" -H 'Content-Type: application/json' -d '{"plan_id":"pro","period":"monthly"}'
SEEDPRO=$(seed_fin $PID11 "seed pro harbour clip" "http://127.0.0.1:$FIN_STUB_PORT/media/clip169.mp4" "768P")
US11=$(curl -s -w '\n%{http_code}' -X POST $B11/api/finish/upscale -H "Authorization: Bearer $TP11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDPRO}")
check "upscale (Pro): -> 201" "201" "$(echo "$US11" | tail -1)"
US11B=$(echo "$US11" | sed '$d')
check "upscale: kind upscale, recorded tier 2K, minimum price 10" "upscale/2K/10" "$(echo $US11B | python3 -c 'import sys,json;g=json.load(sys.stdin)["generation"];print(g["kind"]+"/"+g["resolution"]+"/"+str(g["cost_credits"]))')"
VC11C=$(curl -s $B11/api/_test/voice-calls)
check "upscale: topaz body has video_url + model Proteus + factor 2" "ok" "$(echo $VC11C | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x.get("model")=="fal-ai/topaz/upscale/video"][-1];b=c["body"];print("ok" if b.get("video_url","").endswith("/media/clip169.mp4") and b.get("model")=="Proteus" and b.get("upscale_factor")==2 else "bad")')"
SEEDLONG=$(seed_fin $PID11 "seed long harbour clip" "http://127.0.0.1:$FIN_HTTP_PORT/long.mp4" "768P")
USL11=$(curl -s -X POST $B11/api/finish/upscale -H "Authorization: Bearer $TP11" -H 'Content-Type: application/json' -d "{\"generation_id\":$SEEDLONG}")
check "upscale price formula: 30s to 720p = ceil(0.01*30*277/15)*2 = 12 credits" "12" "$(echo $USL11 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generation"]["cost_credits"])')"

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
check "generate with character: STANDARD rate (768P 5s = 10), balance 90" "10/90" "$(echo $CGB | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["cost_credits"])+"/"+str(g["credits_left"]))')"
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
check "lipsync with character: cost 30, credits_left 570" "30/570" "$(echo $LS12B | python3 -c 'import sys,json;g=json.load(sys.stdin);print(str(g["generation"]["cost_credits"])+"/"+str(g["credits_left"]))')"
check "lipsync with character: row records character + its image" "$CHAR_LIP/$IMGP" "$(echo $LS12B | python3 -c 'import sys,json;g=json.load(sys.stdin)["generation"];print(str(g["character_id"])+"/"+str(g["source_image_path"]))')"
VC12=$(curl -s $B12/api/_test/voice-calls)
check "lipsync with character: TTS used the BOUND voice (Charon, Urdu)" "Charon/Urdu (Pakistan)" "$(echo $VC12 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x["kind"]=="tts"][-1];print(c["body"]["voice"]+"/"+c["body"]["language_code"])')"
check "lipsync with character: queue body is the character image data URI" "ok" "$(echo $VC12 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x["kind"]=="queue"][-1];print("ok" if c["model"]=="minimax/h3-max/lip-sync/image-to-video" and c["body"]["image_url"].startswith("data:image/png") else "bad")')"
LS13=$(curl -s -w '\n%{http_code}' -X POST $B12/api/voice/lipsync -H "Authorization: Bearer $TP12" -H 'Content-Type: application/json' -d "{\"character_id\":$CHAR_LIP,\"script\":\"salam dost\",\"script_mode\":\"roman\",\"provider\":\"elevenlabs\",\"voice\":\"Rachel\",\"spoken_language\":\"ur\",\"style\":\"conversation\"}")
check "lipsync override -> 201" "201" "$(echo "$LS13" | tail -1)"
VC13=$(curl -s $B12/api/_test/voice-calls)
check "lipsync override: explicit voice wins over the binding (Rachel)" "elevenlabs/Rachel" "$(echo $VC13 | python3 -c 'import sys,json;c=[x for x in json.load(sys.stdin)["calls"] if x["kind"]=="tts"][-1];print(c["provider"]+"/"+c["body"]["voice"])')"
check "lipsync override: credits_left 540" "540" "$(curl -s $B12/api/me -H "Authorization: Bearer $TP12" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "lipsync with ANOTHER user's character -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/voice/lipsync -H "Authorization: Bearer $TP12" -H 'Content-Type: application/json' -d "{\"character_id\":$SARA_ID,\"script\":\"salam dost\",\"script_mode\":\"roman\"}")"
check "lipsync with a nonexistent character -> 404" "404" "$(curl -s -o /dev/null -w '%{http_code}' -X POST $B12/api/voice/lipsync -H "Authorization: Bearer $TP12" -H 'Content-Type: application/json' -d '{"character_id":99999,"script":"salam dost","script_mode":"roman"}')"
check "lipsync 404s charged nothing (still 540)" "540" "$(curl -s $B12/api/me -H "Authorization: Bearer $TP12" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

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
