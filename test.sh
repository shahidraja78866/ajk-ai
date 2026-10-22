#!/usr/bin/env bash
# My Video AI backend test battery — uses a DUMMY fal key, so no paid API calls.
# A "successful" fal submission is impossible with a dummy key by design:
# the generate call must fail with 502 and the credit must be refunded.
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
