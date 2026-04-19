#!/usr/bin/env bash
# Curl demos for 404 and 501 against the GKE LoadBalancer.
# Set BASE to http://EXTERNAL_IP:8080 (no trailing slash).
#
# Browser demos (paste into the address bar; some statuses need DevTools):
#   200:  http://EXTERNAL_IP:8080/pages/page_00001.json
#   404:  http://EXTERNAL_IP:8080/pages/does_not_exist_99999.json
#   501:  Browsers issue GET for normal navigation — use curl for POST/HEAD,
#         or open DevTools → Network → right-click a request → "Copy as cURL"
#         and change method. For a quick 501 in browser context, use an
#         HTML form with method=POST to the same URL, or rely on curl below.
#   400:  curl cannot set X-country in the address bar; use:
#         curl -s -o /dev/null -w '%{http_code}\n' -H 'X-country: Iran' \\
#           "${BASE}/pages/page_00001.json"

set -euo pipefail
BASE="${BASE:?Set BASE=http://EXTERNAL_IP:8080}"

echo "=== 404: missing object ==="
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "${BASE}/pages/no_such_file_hw9.json"

echo "=== 501: POST ==="
curl -sS -o /dev/null -w "HTTP %{http_code}\n" -X POST "${BASE}/pages/page_00001.json"

echo "=== 501: HEAD ==="
curl -sS -o /dev/null -w "HTTP %{http_code}\n" -I "${BASE}/pages/page_00001.json"

echo "=== 200: GET (optional sanity) ==="
curl -sS -o /dev/null -w "HTTP %{http_code}\n" "${BASE}/pages/page_00001.json"

echo "=== 400: forbidden country (subscriber should log) ==="
curl -sS -o /dev/null -w "HTTP %{http_code}\n" -H "X-country: North Korea" "${BASE}/pages/page_00001.json"
