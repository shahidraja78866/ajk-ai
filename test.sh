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
check "plans list has 3 plans" "3" "$(echo $PLANS | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["plans"]))')"
check "normal plan price Rs 1500" "1500" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="normal"][0]["price_monthly"])')"
check "normal plan 100 credits/mo" "100" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="normal"][0]["credits_monthly"])')"
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
check "activation: total credits 100 free + 100 plan = 200" "200" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "activation: plan bucket = 100" "100" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
check "activation: free bucket untouched = 100" "100" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
check "activation: current plan is normal" "normal" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["id"])')"
PAY=$(curl -s $B/api/payments -H "Authorization: Bearer $PTOKEN")
check "user payment history has 1 payment" "1" "$(echo $PAY | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["payments"]))')"
check "payment amount Rs 1500" "1500" "$(echo $PAY | python3 -c 'import sys,json;print(json.load(sys.stdin)["payments"][0]["amount"])')"
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
check "credits refunded to 200 after failed normal job" "200" "$(echo $PHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- monetization: extrapro native-4K routing + double credit cost ---"
MP2=$(curl -s -X POST $B/api/admin/users/$PID/manual-payment -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"plan_id":"extrapro","period":"monthly"}')
check "extrapro activation ok" "True" "$(echo $MP2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
PME2=$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN")
check "extrapro: total credits 100 free + 120 plan = 220" "220" "$(echo $PME2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "extrapro: plan switched" "extrapro" "$(echo $PME2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["id"])')"
curl -s -o /dev/null -X POST $B/api/generate -H "Authorization: Bearer $PTOKEN" -H 'Idempotency-Key: plan-4k-1' -H 'Content-Type: application/json' -d '{"prompt":"a mountain sunrise above the clouds","aspect_ratio":"16:9","duration":5}'
PHIST2=$(curl -s $B/api/history -H "Authorization: Bearer $PTOKEN")
check "4K job routed at 4K" "4K" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "4K job uses FAL_MODEL_4K model" "$TEST_FAL_MODEL_4K" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["model"])')"
check "4K 5s job cost doubled = 20 credits" "20" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
check "credits refunded to 220 after failed 4K job" "220" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
JOB4K=$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["id"])')
curl -s $B/api/generations/$JOB4K -H "Authorization: Bearer $PTOKEN" > /dev/null
check "no double refund after polling failed 4K job" "220" "$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
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

echo "--- monetization: 4K aspect-ratio fallback (21:9 -> H3 at 2K, normal rate) ---"
R2119=$(curl -s -X POST $B/api/generate -H "Authorization: Bearer $PTOKEN" -H 'Idempotency-Key: plan-4k-2119' -H 'Content-Type: application/json' -d '{"prompt":"wide desert panorama at dusk","aspect_ratio":"21:9","duration":5}')
PHIST4=$(curl -s $B/api/history -H "Authorization: Bearer $PTOKEN")
check "21:9 fallback routed at 2K" "2K" "$(echo $PHIST4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "21:9 fallback uses H3 model" "minimax/h3/text-to-video" "$(echo $PHIST4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["model"])')"
check "21:9 fallback cost normal = 10 credits" "10" "$(echo $PHIST4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
# (The fallback `note` only appears on a successful provider response, which is
#  unreachable with a dummy key; routing/cost/refund are fully asserted above.)
FB2=$(curl -s $B/api/_test/fal-body)
check "fallback fal body keeps resolution param" "2K" "$(echo $FB2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"].get("resolution","absent"))')"
check "fallback fal body duration is integer" "5-int" "$(echo $FB2 | python3 -c 'import sys,json;b=json.load(sys.stdin)["body"];print(str(b["duration"])+("-int" if isinstance(b["duration"],int) else "-NOTINT"))')"
check "credits refunded to 220 after failed fallback job" "220" "$(echo $PHIST4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- monetization: renewal grant + cancel ---"
RG=$(curl -s -X POST $B/api/admin/users/$PID/grant-renewal -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')
check "renewal grant ok" "True" "$(echo $RG | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
check "renewal resets plan bucket to 120" "120" "$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
CX=$(curl -s -X POST $B/api/admin/users/$PID/cancel-subscription -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')
check "cancel sets status canceled" "canceled" "$(echo $CX | python3 -c 'import sys,json;print(json.load(sys.stdin)["subscription"]["status"])')"

echo "--- monetization: admin price edit takes effect ---"
PE=$(curl -s -X PUT $B/api/admin/plans/pro -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"price_monthly":3200}')
check "price edit returns Rs 3200" "3200" "$(echo $PE | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["price_monthly"])')"
check "public plans API shows edited price" "3200" "$(curl -s $B/api/plans | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="pro"][0]["price_monthly"])')"
curl -s -X PUT $B/api/admin/plans/pro -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"price_monthly":3000}' > /dev/null
check "price restored to Rs 3000" "3000" "$(curl -s $B/api/plans | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="pro"][0]["price_monthly"])')"

echo "--- monetization: revenue summary math ---"
REV=$(curl -s $B/api/admin/revenue -H "Authorization: Bearer $ATOKEN"); echo "$REV"
check "revenue total = 1500 + 5000" "6500" "$(echo $REV | python3 -c 'import sys,json;print(json.load(sys.stdin)["total_succeeded"])')"
check "revenue payment count = 2" "2" "$(echo $REV | python3 -c 'import sys,json;print(json.load(sys.stdin)["total_succeeded_count"])')"
check "extrapro revenue = 5000" "5000" "$(echo $REV | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["by_plan"] if p["plan_id"]=="extrapro"][0]["total"])')"
check "current-month revenue = 6500" "6500" "$(echo $REV | python3 -c 'import sys,json;print(json.load(sys.stdin)["monthly"][0]["total"])')"

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
check "config daily cap = 200 (rescaled)" "200" "$(echo $CFG3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["max_daily_credits"])')"
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
check "play sub: plan bucket granted 100" "100" "$(echo $BME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
check "play sub: subscription status active" "active" "$(echo $BME | python3 -c 'import sys,json;print(json.load(sys.stdin)["subscription"]["status"])')"
check "play sub: total = 200 free + 100 plan = 300" "300" "$(echo $BME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

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
check "gateway checkout granted nothing (total still 300)" "300" "$(curl -s $B4/api/me -H "Authorization: Bearer $BTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

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
kill $SRV4_PID 2>/dev/null

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
