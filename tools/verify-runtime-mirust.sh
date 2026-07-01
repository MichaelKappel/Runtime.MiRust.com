#!/usr/bin/env bash
set -euo pipefail
BASE="${1:-https://runtime.mirust.com}"
BASE="${BASE%/}"
check() {
  local path="$1"
  echo "==> ${BASE}${path}"
  curl -fsSIL "${BASE}${path}" | sed -n '1,8p'
}
body() {
  local path="$1"
  echo "==> body ${BASE}${path}"
  curl -fsS "${BASE}${path}" | sed -n '1,12p'
}
check "/"
body "/healthz"
body "/version.json"
body "/llms.txt"
body "/docs/index.md"
body "/.uai/index.uai"
echo "==> Markdown negotiation"
curl -fsS -H "Accept: text/markdown" "${BASE}/source-facts/" | sed -n '1,24p'
echo "Verification completed for ${BASE}"
