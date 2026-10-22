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
# e.g.  ADMIN_EMAIL=admin@example.com FAL_MODEL_4K=test-4k-model TEST_RECORD_FAL_BODY=1 npm start
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
check "register gives 10 credits" "10" "$(echo $R | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
DUP=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/auth/register -H 'Content-Type: application/json' -d '{"email":"test@example.com","password":"password123"}')
check "duplicate register rejected" "409" "$DUP"
BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/auth/login -H 'Content-Type: application/json' -d '{"email":"test@example.com","password":"wrongpass1"}')
check "wrong password rejected" "401" "$BAD"
L=$(curl -s -X POST $B/api/auth/login -H 'Content-Type: application/json' -d '{"email":"test@example.com","password":"password123"}')
TOKEN=$(echo $L | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
ME=$(curl -s $B/api/me -H "Authorization: Bearer $TOKEN"); echo "$ME"
check "me credits = 10" "10" "$(echo $ME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' $B/api/history)
check "history requires auth" "401" "$NOAUTH"

echo "--- validation & moderation (no charge) ---"
V=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"prompt":"a cat video","aspect_ratio":"7:3"}')
check "bad aspect ratio rejected" "400" "$V"
M=$(curl -s -o /dev/null -w '%{http_code}' -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"prompt":"gore and violence scene"}')
check "blocked prompt rejected" "400" "$M"
ME2=$(curl -s $B/api/me -H "Authorization: Bearer $TOKEN")
check "credits untouched by rejected prompts" "10" "$(echo $ME2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- generation with dummy key: submit fails -> 502 + refund ---"
G=$(curl -s -w '\n%{http_code}' -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: test-key-001' -H 'Content-Type: application/json' -d '{"prompt":"a kitten chasing a butterfly in a sunny garden","aspect_ratio":"16:9","duration":5,"style":"realistic"}')
echo "$G"
check "dummy-key generation returns 502" "502" "$(echo "$G" | tail -1)"
HIST=$(curl -s $B/api/history -H "Authorization: Bearer $TOKEN"); echo "$HIST" | head -c 400; echo
check "credits refunded after failure" "10" "$(echo $HIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "history has 1 failed job" "failed" "$(echo $HIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["status"])')"
JOBID=$(echo $HIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["id"])')

echo "--- idempotency: same key again -> same job, no new charge ---"
G2=$(curl -s -X POST $B/api/generate -H "Authorization: Bearer $TOKEN" -H 'Idempotency-Key: test-key-001' -H 'Content-Type: application/json' -d '{"prompt":"a kitten chasing a butterfly in a sunny garden","aspect_ratio":"16:9","duration":5,"style":"realistic"}')
echo "$G2"
check "duplicate flagged" "True" "$(echo $G2 | python3 -c 'import sys,json;print(json.load(sys.stdin).get("duplicate"))')"
HIST2=$(curl -s $B/api/history -H "Authorization: Bearer $TOKEN")
check "still only 1 job in history" "1" "$(echo $HIST2 | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["generations"]))')"
check "credits still 10" "10" "$(echo $HIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- report endpoint ---"
RP=$(curl -s -X POST $B/api/report -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "{\"generation_id\":$JOBID,\"reason\":\"test report\"}")
check "report accepted" "True" "$(echo $RP | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"

echo "--- monetization: plans API (public) ---"
PLANS=$(curl -s $B/api/plans); echo "$PLANS" | head -c 400; echo
check "plans list has 3 plans" "3" "$(echo $PLANS | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["plans"]))')"
check "normal plan price Rs 1500" "1500" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="normal"][0]["price_monthly"])')"
check "normal plan 5 credits/mo" "5" "$(echo $PLANS | python3 -c 'import sys,json;d=json.load(sys.stdin);print([p for p in d["plans"] if p["id"]=="normal"][0]["credits_monthly"])')"
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
check "activation: total credits 10 free + 5 plan = 15" "15" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "activation: plan bucket = 5" "5" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
check "activation: free bucket untouched = 10" "10" "$(echo $PME | python3 -c 'import sys,json;print(json.load(sys.stdin)["free_credits"])')"
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

echo "--- monetization: plan routing (normal = 768P on H3; 10s costs 2) ---"
curl -s -o /dev/null -X POST $B/api/generate -H "Authorization: Bearer $PTOKEN" -H 'Idempotency-Key: plan-norm-1' -H 'Content-Type: application/json' -d '{"prompt":"a river flowing through green hills","aspect_ratio":"16:9","duration":10}'
PHIST=$(curl -s $B/api/history -H "Authorization: Bearer $PTOKEN")
check "normal job routed at 768P" "768P" "$(echo $PHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "normal job model is H3" "minimax/h3/text-to-video" "$(echo $PHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["model"])')"
check "normal 10s job cost 2 credits" "2" "$(echo $PHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
check "credits refunded to 15 after failed normal job" "15" "$(echo $PHIST | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- monetization: extrapro native-4K routing + double credit cost ---"
MP2=$(curl -s -X POST $B/api/admin/users/$PID/manual-payment -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{"plan_id":"extrapro","period":"monthly"}')
check "extrapro activation ok" "True" "$(echo $MP2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
PME2=$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN")
check "extrapro: total credits 10 free + 10 plan = 20" "20" "$(echo $PME2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
check "extrapro: plan switched" "extrapro" "$(echo $PME2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan"]["id"])')"
curl -s -o /dev/null -X POST $B/api/generate -H "Authorization: Bearer $PTOKEN" -H 'Idempotency-Key: plan-4k-1' -H 'Content-Type: application/json' -d '{"prompt":"a mountain sunrise above the clouds","aspect_ratio":"16:9","duration":5}'
PHIST2=$(curl -s $B/api/history -H "Authorization: Bearer $PTOKEN")
check "4K job routed at 4K" "4K" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "4K job uses FAL_MODEL_4K model" "$TEST_FAL_MODEL_4K" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["model"])')"
check "4K 5s job cost doubled = 2 credits" "2" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
check "credits refunded to 20 after failed 4K job" "20" "$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
JOB4K=$(echo $PHIST2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["id"])')
curl -s $B/api/generations/$JOB4K -H "Authorization: Bearer $PTOKEN" > /dev/null
check "no double refund after polling failed 4K job" "20" "$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"
curl -s -o /dev/null -X POST $B/api/generate -H "Authorization: Bearer $PTOKEN" -H 'Idempotency-Key: plan-4k-low' -H 'Content-Type: application/json' -d '{"prompt":"a quiet forest stream in soft light","aspect_ratio":"16:9","duration":5,"resolution":"768P"}'
PHIST3=$(curl -s $B/api/history -H "Authorization: Bearer $PTOKEN")
check "extrapro lower-quality pick routed at 768P" "768P" "$(echo $PHIST3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["resolution"])')"
check "lower-quality pick cost normal = 1 credit" "1" "$(echo $PHIST3 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
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
check "21:9 fallback cost normal = 1 credit" "1" "$(echo $PHIST4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["generations"][0]["cost_credits"])')"
# (The fallback `note` only appears on a successful provider response, which is
#  unreachable with a dummy key; routing/cost/refund are fully asserted above.)
FB2=$(curl -s $B/api/_test/fal-body)
check "fallback fal body keeps resolution param" "2K" "$(echo $FB2 | python3 -c 'import sys,json;print(json.load(sys.stdin)["body"].get("resolution","absent"))')"
check "fallback fal body duration is integer" "5-int" "$(echo $FB2 | python3 -c 'import sys,json;b=json.load(sys.stdin)["body"];print(str(b["duration"])+("-int" if isinstance(b["duration"],int) else "-NOTINT"))')"
check "credits refunded to 20 after failed fallback job" "20" "$(echo $PHIST4 | python3 -c 'import sys,json;print(json.load(sys.stdin)["credits"])')"

echo "--- monetization: renewal grant + cancel ---"
RG=$(curl -s -X POST $B/api/admin/users/$PID/grant-renewal -H "Authorization: Bearer $ATOKEN" -H 'Content-Type: application/json' -d '{}')
check "renewal grant ok" "True" "$(echo $RG | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')"
check "renewal resets plan bucket to 10" "10" "$(curl -s $B/api/me -H "Authorization: Bearer $PTOKEN" | python3 -c 'import sys,json;print(json.load(sys.stdin)["plan_credits"])')"
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
