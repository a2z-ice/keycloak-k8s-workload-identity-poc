#!/usr/bin/env bash
# End-to-end smoke test (curl) of the token-exchange flow.
# Mirrors spec §7.1.
set -euo pipefail

POD_A=${POD_A:-http://127.0.0.1:30810}
POD_B=${POD_B:-http://127.0.0.1:30820}

echo "=== Token-exchange smoke test ==="

echo ""
echo "[1] pod-a /api/health"
curl -sf "${POD_A}/api/health" | python3 -m json.tool || { echo "FAILED"; exit 1; }

echo ""
echo "[2] pod-b /api/health"
curl -sf "${POD_B}/api/health" | python3 -m json.tool || { echo "FAILED"; exit 1; }

echo ""
echo "[3] pod-b /api/public/info (unauth)"
curl -sf "${POD_B}/api/public/info" | python3 -m json.tool || { echo "FAILED"; exit 1; }

echo ""
echo "[4] pod-b /api/protected/data without token (expect 401)"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "${POD_B}/api/protected/data")
echo "    HTTP ${CODE}"
[[ "${CODE}" == "401" ]] || { echo "expected 401"; exit 1; }

echo ""
echo "[5] pod-a /api/exchange (request token)"
TOKEN_BODY=$(curl -sf -X POST "${POD_A}/api/exchange")
echo "${TOKEN_BODY}" | python3 -m json.tool
ACCESS_TOKEN=$(echo "${TOKEN_BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['accessToken'])")
echo "    Token length: ${#ACCESS_TOKEN}"

echo ""
echo "[6] inspect token claims"
echo "${ACCESS_TOKEN}" | cut -d. -f2 \
  | python3 -c "import sys,base64,json; tok=sys.stdin.read().strip(); tok+='='*(-len(tok)%4); print(json.dumps(json.loads(base64.urlsafe_b64decode(tok)), indent=2))"

echo ""
echo "[7] pod-b /api/protected/data with token (expect 200)"
curl -sf -H "Authorization: Bearer ${ACCESS_TOKEN}" "${POD_B}/api/protected/data" | python3 -m json.tool

echo ""
echo "[8] pod-a /api/call-pod-b (S2S using cached token)"
curl -sf "${POD_A}/api/call-pod-b" | python3 -m json.tool

echo ""
echo "✅ End-to-end test completed successfully!"
