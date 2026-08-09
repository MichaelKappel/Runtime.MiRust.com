#!/usr/bin/env bash
set -euo pipefail

base="${1:-https://runtime.mirust.com}"
base="${base%/}"

paths=(
  "/"
  "/healthz"
  "/version.json"
  "/llms.txt"
  "/docs/index.md"
  "/.uai/index.uai"
  "/source-facts/"
)

targets=(
  "https://tinyrustlm.mirust.com/developer-portal/"
  "https://tinyrustlm.mirust.com/docs/runtime-portal/package/healthz"
  "https://tinyrustlm.mirust.com/docs/runtime-portal/package/version.json"
  "https://tinyrustlm.mirust.com/llms.txt"
  "https://tinyrustlm.mirust.com/docs/runtime-portal/runtime-docs/index.md"
  "https://tinyrustlm.mirust.com/docs/runtime-portal/runtime-docs/long-term-memory.uai"
  "https://tinyrustlm.mirust.com/developer-portal/"
)

for index in "${!paths[@]}"; do
  source_url="${base}${paths[$index]}"
  expected="${targets[$index]}"
  headers="$(curl --fail --silent --show-error --dump-header - --output /dev/null --max-redirs 0 "${source_url}")"
  status="$(printf '%s\n' "${headers}" | awk 'toupper($1) ~ /^HTTP\// { code=$2 } END { print code }')"
  location="$(printf '%s\n' "${headers}" | awk 'BEGIN { IGNORECASE=1 } /^location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }')"

  case "${status}" in
    301|302|307|308) ;;
    *) echo "ERROR: ${source_url} returned HTTP ${status:-unknown}; expected a redirect" >&2; exit 1 ;;
  esac

  if [[ "${location}" != "${expected}" ]]; then
    echo "ERROR: ${source_url} redirected to ${location:-missing}; expected ${expected}" >&2
    exit 1
  fi
  echo "PASS redirect ${paths[$index]} -> ${location}"
done

printf '%s\n' "${targets[@]}" | awk '!seen[$0]++' | while IFS= read -r target_url; do
  status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-redirs 0 "${target_url}")"
  if [[ "${status}" != "200" ]]; then
    echo "ERROR: ${target_url} returned HTTP ${status}; expected 200" >&2
    exit 1
  fi
  echo "PASS readback ${target_url}"
done

echo "Verification completed for ${base}"
