#!/usr/bin/env bash
set -euo pipefail

gone_bytes=5
bad_request_bytes=12
temporary_root=""
artifact_parent=""
operation_owner="runtime-response-verifier-$$"
curl_command="curl"
head_fixture_pid=""

cleanup() {
  if [[ -n "${head_fixture_pid}" ]] && kill -0 "${head_fixture_pid}" 2>/dev/null; then
    kill "${head_fixture_pid}" 2>/dev/null || true
    wait "${head_fixture_pid}" 2>/dev/null || true
  fi
  if [[ -n "${temporary_root}" && -d "${temporary_root}" ]]; then
    [[ ! -L "${temporary_root}" && ! -L "${artifact_parent}" &&
       "$(dirname -- "${temporary_root}")" == "${artifact_parent}" &&
       -f "${temporary_root}/.operation-owner" &&
       "$(cat -- "${temporary_root}/.operation-owner")" == "${operation_owner}" ]] || {
      echo "ERROR: verifier output cleanup lost its owned artifact identity" >&2
      return 1
    }
    rm -rf -- "${temporary_root}"
  fi
}

http_status() {
  local header_file="$1"
  awk '
    {
      line=$0
      sub(/\r$/, "", line)
      if (toupper(line) ~ /^HTTP\//) {
        split(line, fields, /[[:space:]]+/)
        code=fields[2]
      }
    }
    END { if (code != "") print code }
  ' "${header_file}"
}

header_values() {
  local header_file="$1"
  local wanted="${2,,}"
  awk -v wanted="${wanted}" '
    function reset_values( i) {
      for (i in values) delete values[i]
      count=0
    }
    BEGIN { reset_values(); in_headers=0 }
    {
      line=$0
      sub(/\r$/, "", line)
      if (toupper(line) ~ /^HTTP\//) {
        reset_values()
        in_headers=1
        next
      }
      if (in_headers && line == "") {
        in_headers=0
        next
      }
      if (in_headers) {
        colon=index(line, ":")
        if (colon > 0 && tolower(substr(line, 1, colon - 1)) == wanted) {
          value=substr(line, colon + 1)
          sub(/^[[:space:]]+/, "", value)
          sub(/[[:space:]]+$/, "", value)
          values[++count]=value
        }
      }
    }
    END { for (i=1; i<=count; i++) print values[i] }
  ' "${header_file}"
}

# Check a captured redirect against its required destination without following it.
verify_redirect_headers() {
  local header_file="$1"
  local expected="$2"
  local status
  status="$(http_status "${header_file}")"
  if [[ "${status}" != "301" ]]; then
    echo "ERROR: redirect returned HTTP ${status:-unknown}; expected 301" >&2
    return 1
  fi
  # Inspect raw Location bytes before shell parsing can discard NUL or trim controls.
  # Windows awk must read binary input so CRLF translation cannot hide an extra CR.
  # HTTP field whitespace is permitted; URL normalization and folded values are not.
  if ! LC_ALL=C awk -v BINMODE=1 -v expected="${expected}" '
    BEGIN { in_headers=0; count=0; invalid=0; location_active=0 }
    {
      line=$0
      sub(/\r$/, "", line)
      if (toupper(line) ~ /^HTTP\//) {
        in_headers=1
        count=0
        invalid=0
        location_active=0
        next
      }
      if (in_headers && line == "") {
        in_headers=0
        next
      }
      if (in_headers) {
        if (line ~ /^[ \t]/) {
          if (location_active) invalid=1
          next
        }
        location_active=0
        colon=index(line, ":")
        if (colon > 0 && tolower(substr(line, 1, colon - 1)) == "location") {
          count++
          location_active=1
          value=substr(line, colon + 1)
          sub(/^[ \t]+/, "", value)
          sub(/[ \t]+$/, "", value)
          if (value ~ /[[:cntrl:]]/ || value != expected) invalid=1
        }
      }
    }
    END { if (count != 1 || invalid) exit 1 }
  ' "${header_file}"; then
    echo "ERROR: redirect returned an unexpected Location header" >&2
    return 1
  fi
}

assert_exact_header() {
  local header_file="$1"
  local name="$2"
  local expected="$3"
  local -a values=()
  mapfile -t values < <(header_values "${header_file}" "${name}")
  if [[ "${#values[@]}" -ne 1 || "${values[0]}" != "${expected}" ]]; then
    echo "ERROR: ${name} must contain exactly '${expected}'" >&2
    return 1
  fi
}

assert_content_type() {
  local header_file="$1"
  local -a values=()
  mapfile -t values < <(header_values "${header_file}" "content-type")
  if [[ "${#values[@]}" -ne 1 ]]; then
    echo "ERROR: Content-Type must occur exactly once" >&2
    return 1
  fi
  local compact="${values[0],,}"
  compact="${compact//[[:space:]]/}"
  if [[ "${compact}" != "text/plain;charset=utf-8" ]]; then
    echo "ERROR: Content-Type must be text/plain with charset=utf-8" >&2
    return 1
  fi
}

assert_no_location() {
  local header_file="$1"
  local -a values=()
  mapfile -t values < <(header_values "${header_file}" "location")
  if [[ "${#values[@]}" -ne 0 ]]; then
    echo "ERROR: retired route returned a forbidden Location header" >&2
    return 1
  fi
}

verify_terminal_files() {
  local method="$1"
  local header_file="$2"
  local body_file="$3"
  local expected_status="$4"
  local expected_length="$5"
  local expected_file="$6"
  local label="$7"
  local status
  status="$(http_status "${header_file}")"
  if [[ "${status}" != "${expected_status}" ]]; then
    echo "ERROR: ${label} returned HTTP ${status:-unknown}; expected ${expected_status}" >&2
    return 1
  fi
  assert_no_location "${header_file}" || return 1
  assert_exact_header "${header_file}" "cache-control" "no-store" || return 1
  assert_exact_header "${header_file}" "x-robots-tag" "noindex, nofollow" || return 1
  assert_exact_header "${header_file}" "x-content-type-options" "nosniff" || return 1
  assert_exact_header "${header_file}" "content-length" "${expected_length}" || return 1
  assert_content_type "${header_file}" || return 1
  if [[ "${method}" == "GET" ]]; then
    if ! cmp --silent -- "${body_file}" "${expected_file}"; then
      echo "ERROR: ${label} returned unexpected GET bytes" >&2
      return 1
    fi
  elif [[ "${method}" == "HEAD" ]]; then
    if [[ -s "${body_file}" ]]; then
      echo "ERROR: ${label} HEAD must not contain response-body bytes" >&2
      return 1
    fi
  else
    echo "ERROR: retired verifier method must be GET or HEAD" >&2
    return 1
  fi
}

verify_retired_files() {
  local expected_file="${temporary_root}/expected-gone"
  printf 'Gone\n' > "${expected_file}"
  verify_terminal_files "$1" "$2" "$3" 410 "${gone_bytes}" "${expected_file}" "retired route"
}

verify_bad_request_files() {
  local expected_file="${temporary_root}/expected-bad-request"
  printf 'Bad Request\n' > "${expected_file}"
  verify_terminal_files "$1" "$2" "$3" 400 "${bad_request_bytes}" "${expected_file}" "hostile route"
}

verify_server_boundary_files() {
  local method="$1"
  local header_file="$2"
  local body_file="$3"
  local status
  status="$(http_status "${header_file}")"
  if [[ "${status}" != "400" && "${status}" != "404" ]]; then
    echo "ERROR: server-boundary route returned HTTP ${status:-unknown}; expected 400 or 404" >&2
    return 1
  fi
  assert_no_location "${header_file}" || return 1
  local body_bytes
  body_bytes="$(wc -c < "${body_file}" | tr -d '[:space:]')"
  if [[ ! "${body_bytes}" =~ ^[0-9]+$ || "${body_bytes}" -gt 65536 ]]; then
    echo "ERROR: server-boundary rejection body exceeds 65536 bytes" >&2
    return 1
  fi
  if [[ "${method}" == "HEAD" && "${body_bytes}" -ne 0 ]]; then
    echo "ERROR: server-boundary HEAD returned response-body bytes" >&2
    return 1
  fi
}

fetch_terminal_response() {
  local method="$1"
  local source_url="$2"
  local header_file="$3"
  local body_file="$4"
  if [[ "${method}" == "HEAD" ]]; then
    # Deliberately use a custom HEAD method instead of curl --head. The latter
    # suppresses body bytes by client semantics and cannot expose a broken
    # HTTP/1.1 server that sends bytes after a HEAD header block.
    "${curl_command}" --http1.1 --request HEAD --ignore-content-length --raw \
      --header "Connection: close" --path-as-is --silent --show-error \
      --dump-header "${header_file}" --output "${body_file}" --max-redirs 0 \
      "${source_url}"
  else
    "${curl_command}" --path-as-is --silent --show-error --dump-header "${header_file}" \
      --output "${body_file}" --max-redirs 0 "${source_url}"
  fi
}

write_fixture_headers() {
  local target="$1"
  local status="$2"
  local location="$3"
  local cache_control="$4"
  local robots="$5"
  local nosniff="$6"
  local content_type="$7"
  local content_length="$8"
  printf 'HTTP/1.1 200 Connection established\r\n\r\n' > "${target}"
  printf 'HTTP/2 %s\r\n' "${status}" >> "${target}"
  [[ -z "${location}" ]] || printf 'Location: %s\r\n' "${location}" >> "${target}"
  [[ -z "${cache_control}" ]] || printf 'Cache-Control: %s\r\n' "${cache_control}" >> "${target}"
  [[ -z "${robots}" ]] || printf 'X-Robots-Tag: %s\r\n' "${robots}" >> "${target}"
  [[ -z "${nosniff}" ]] || printf 'X-Content-Type-Options: %s\r\n' "${nosniff}" >> "${target}"
  [[ -z "${content_type}" ]] || printf 'Content-Type: %s\r\n' "${content_type}" >> "${target}"
  [[ -z "${content_length}" ]] || printf 'Content-Length: %s\r\n' "${content_length}" >> "${target}"
  printf '\r\n' >> "${target}"
}

run_fixture() {
  local name="$1"
  local expected_verdict="$2"
  local method="$3"
  local status="$4"
  local location="$5"
  local cache_control="$6"
  local robots="$7"
  local nosniff="$8"
  local content_type="$9"
  local content_length="${10}"
  local body_kind="${11}"
  local header_file="${temporary_root}/${name}.headers"
  local body_file="${temporary_root}/${name}.body"
  write_fixture_headers "${header_file}" "${status}" "${location}" \
    "${cache_control}" "${robots}" "${nosniff}" "${content_type}" "${content_length}"
  case "${body_kind}" in
    gone) printf 'Gone\n' > "${body_file}" ;;
    no-newline) printf 'Gone' > "${body_file}" ;;
    empty) : > "${body_file}" ;;
    *) echo "ERROR: unknown self-test body kind" >&2; return 1 ;;
  esac
  local actual_verdict="fail"
  if [[ "${expected_verdict}" == "pass" ]]; then
    if verify_retired_files "${method}" "${header_file}" "${body_file}"; then
      actual_verdict="pass"
    fi
  elif verify_retired_files "${method}" "${header_file}" "${body_file}" >/dev/null 2>&1; then
    actual_verdict="pass"
  fi
  if [[ "${actual_verdict}" != "${expected_verdict}" ]]; then
    echo "ERROR: shell retired verifier fixture produced the wrong verdict: ${name}" >&2
    return 1
  fi
}

# Supply bounded raw response headers to the same validator used by live checks.
run_redirect_fixture() {
  local name="$1"
  local expected_verdict="$2"
  local status="$3"
  local location_kind="$4"
  local expected="https://tinyrustlm.mirust.com/developer-portal/"
  local header_file="${temporary_root}/redirect-${name}.headers"
  printf 'HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 %s\r\n' "${status}" > "${header_file}"
  case "${location_kind}" in
    exact) printf 'Location: %s\r\n' "${expected}" >> "${header_file}" ;;
    field-case) printf 'lOcAtIoN: %s\r\n' "${expected}" >> "${header_file}" ;;
    field-whitespace) printf 'Location:\t %s \t\r\n' "${expected}" >> "${header_file}" ;;
    folded) printf 'Location: %s\r\n\tignored\r\n' "${expected}" >> "${header_file}" ;;
    missing) ;;
    empty) printf 'Location:\r\n' >> "${header_file}" ;;
    wrong) printf 'Location: https://example.invalid/\r\n' >> "${header_file}" ;;
    normalized) printf 'Location: HTTPS://TINYRUSTLM.MIRUST.COM/developer-portal/\r\n' >> "${header_file}" ;;
    relative) printf 'Location: /developer-portal/\r\n' >> "${header_file}" ;;
    duplicate) printf 'Location: %s\r\nLocation: %s\r\n' "${expected}" "${expected}" >> "${header_file}" ;;
    carriage-return) printf 'Location: %s\r\r\n' "${expected}" >> "${header_file}" ;;
    vertical-tab) printf 'Location: %s\v\r\n' "${expected}" >> "${header_file}" ;;
    delete) printf 'Location: %s\177\r\n' "${expected}" >> "${header_file}" ;;
    null) printf 'Location: %s\000\r\n' "${expected}" >> "${header_file}" ;;
    *) echo "ERROR: unknown redirect fixture kind" >&2; return 1 ;;
  esac
  printf '\r\n' >> "${header_file}"
  local actual_verdict="fail"
  if verify_redirect_headers "${header_file}" "${expected}" >/dev/null 2>&1; then
    actual_verdict="pass"
  fi
  if [[ "${actual_verdict}" != "${expected_verdict}" ]]; then
    echo "ERROR: shell redirect verifier fixture produced the wrong verdict: ${name}" >&2
    return 1
  fi
}

# Exercise exact redirect status, single-destination identity, and unsafe bytes.
redirect_self_test() {
  local failed=0
  run_redirect_fixture exact-301 pass 301 exact || failed=1
  run_redirect_fixture field-case pass 301 field-case || failed=1
  run_redirect_fixture field-whitespace pass 301 field-whitespace || failed=1
  run_redirect_fixture temporary-302 fail 302 exact || failed=1
  run_redirect_fixture temporary-307 fail 307 exact || failed=1
  run_redirect_fixture different-permanent-308 fail 308 exact || failed=1
  run_redirect_fixture successful-200 fail 200 exact || failed=1
  run_redirect_fixture missing-location fail 301 missing || failed=1
  run_redirect_fixture empty-location fail 301 empty || failed=1
  run_redirect_fixture wrong-location fail 301 wrong || failed=1
  run_redirect_fixture normalized-location fail 301 normalized || failed=1
  run_redirect_fixture relative-location fail 301 relative || failed=1
  run_redirect_fixture duplicate-location fail 301 duplicate || failed=1
  run_redirect_fixture folded-location fail 301 folded || failed=1
  run_redirect_fixture carriage-return-location fail 301 carriage-return || failed=1
  run_redirect_fixture vertical-tab-location fail 301 vertical-tab || failed=1
  run_redirect_fixture delete-location fail 301 delete || failed=1
  run_redirect_fixture null-location fail 301 null || failed=1
  [[ "${failed}" -eq 0 ]] || return 1
  echo "PASS shell redirect verifier fixtures (18)"
}

self_test() {
  run_fixture valid-get pass GET 410 "" no-store "noindex, nofollow" nosniff "text/plain; charset=UTF-8" 5 gone
  run_fixture valid-head pass HEAD 410 "" no-store "noindex, nofollow" nosniff "text/plain; charset=utf-8" 5 empty
  run_fixture wrong-status fail GET 200 "" no-store "noindex, nofollow" nosniff "text/plain; charset=UTF-8" 5 gone
  run_fixture location-present fail GET 410 "https://example.invalid/" no-store "noindex, nofollow" nosniff "text/plain; charset=UTF-8" 5 gone
  run_fixture cache-extra fail GET 410 "" "private, no-store" "noindex, nofollow" nosniff "text/plain; charset=UTF-8" 5 gone
  run_fixture robots-spacing fail GET 410 "" no-store "noindex,nofollow" nosniff "text/plain; charset=UTF-8" 5 gone
  run_fixture nosniff-missing fail GET 410 "" no-store "noindex, nofollow" "" "text/plain; charset=UTF-8" 5 gone
  run_fixture wrong-media fail GET 410 "" no-store "noindex, nofollow" nosniff "text/html; charset=UTF-8" 5 gone
  run_fixture missing-charset fail GET 410 "" no-store "noindex, nofollow" nosniff text/plain 5 gone
  run_fixture wrong-length fail GET 410 "" no-store "noindex, nofollow" nosniff "text/plain; charset=UTF-8" 4 gone
  run_fixture missing-newline fail GET 410 "" no-store "noindex, nofollow" nosniff "text/plain; charset=UTF-8" 5 no-newline
  run_fixture head-has-body fail HEAD 410 "" no-store "noindex, nofollow" nosniff "text/plain; charset=UTF-8" 5 gone
  echo "PASS shell retired-route verifier fixtures (12)"
  redirect_self_test
}

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
artifact_parent="${repository_root}/artifacts"
[[ ! -L "${artifact_parent}" ]] || { echo "ERROR: artifacts must not be a link" >&2; exit 1; }
mkdir -p -- "${artifact_parent}"
temporary_root="$(mktemp -d "${artifact_parent}/response-verifier.XXXXXXXX")"
printf '%s\n' "${operation_owner}" > "${temporary_root}/.operation-owner"
trap cleanup EXIT

if [[ "${1:-}" == "--self-test" ]]; then
  [[ "$#" -eq 1 ]] || { echo "ERROR: --self-test accepts no other arguments" >&2; exit 2; }
  self_test
  exit 0
fi

if [[ "${1:-}" == "--self-test-head-transfer" ]]; then
  [[ "$#" -eq 1 ]] || {
    echo "ERROR: --self-test-head-transfer accepts no other arguments" >&2
    exit 2
  }
  python_command="${RUNTIME_PYTHON:-python3}"
  command -v "${python_command}" >/dev/null 2>&1 || {
    echo "ERROR: Python 3 is required for the shell HEAD transfer self-test (RUNTIME_PYTHON)" >&2
    exit 2
  }
  port_file="${temporary_root}/head-transfer.port"
  "${python_command}" - "${port_file}" <<'PY' &
import socketserver
import sys


class RetiredRouteHandler(socketserver.BaseRequestHandler):
    responses = 0

    def handle(self):
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            request += chunk
        if not request.startswith(b"HEAD "):
            return
        RetiredRouteHandler.responses += 1
        body = b"" if RetiredRouteHandler.responses == 1 else b"Gone\n"
        headers = (
            b"HTTP/1.1 410 Gone\r\n"
            b"Cache-Control: no-store\r\n"
            b"X-Robots-Tag: noindex, nofollow\r\n"
            b"X-Content-Type-Options: nosniff\r\n"
            b"Content-Type: text/plain; charset=UTF-8\r\n"
            b"Content-Length: 5\r\n"
            b"Connection: close\r\n\r\n"
        )
        self.request.sendall(headers + body)


server = socketserver.TCPServer(("127.0.0.1", 0), RetiredRouteHandler)
with open(sys.argv[1], "w", encoding="ascii", newline="\n") as port_stream:
    port_stream.write(f"{server.server_address[1]}\n")
    port_stream.flush()
server.handle_request()
server.handle_request()
server.server_close()
PY
  head_fixture_pid="$!"
  for _ in $(seq 1 100); do
    [[ -s "${port_file}" ]] && break
    kill -0 "${head_fixture_pid}" 2>/dev/null || break
    sleep 0.05
  done
  [[ -s "${port_file}" ]] || {
    echo "ERROR: shell HEAD transfer fixture did not start" >&2
    exit 1
  }
  port="$(tr -d '\r\n' < "${port_file}")"
  [[ "${port}" =~ ^[0-9]+$ ]] || {
    echo "ERROR: shell HEAD transfer fixture emitted an invalid port" >&2
    exit 1
  }
  header_file="${temporary_root}/head-transfer.headers"
  body_file="${temporary_root}/head-transfer.body"
  fetch_terminal_response HEAD "http://127.0.0.1:${port}/docs/workspace.uai" \
    "${header_file}" "${body_file}"
  verify_retired_files HEAD "${header_file}" "${body_file}"
  bad_header_file="${temporary_root}/head-transfer-bad.headers"
  bad_body_file="${temporary_root}/head-transfer-bad.body"
  fetch_terminal_response HEAD "http://127.0.0.1:${port}/docs/workspace.uai" \
    "${bad_header_file}" "${bad_body_file}"
  wait "${head_fixture_pid}"
  head_fixture_pid=""
  if verify_retired_files HEAD "${bad_header_file}" "${bad_body_file}" >/dev/null 2>&1; then
    echo "ERROR: shell HEAD transfer verifier ignored forbidden wire bytes" >&2
    exit 1
  fi
  [[ "$(wc -c < "${bad_body_file}" | tr -d '[:space:]')" == "5" ]] || {
    echo "ERROR: shell HEAD transfer probe did not preserve forbidden wire bytes" >&2
    exit 1
  }
  echo "PASS shell HEAD transfer verifier (good and forbidden-body fixtures)"
  exit 0
fi

base="${1:-https://runtime.mirust.com}"
base="${base%/}"
if [[ "${base}" != "https://runtime.mirust.com" ]]; then
  echo "ERROR: base URL must be the canonical Runtime.MiRust.com HTTPS origin" >&2
  exit 2
fi

paths=(
  "/"
  "/healthz"
  "/version.json"
  "/llms.txt"
  "/docs/index.md"
  "/.uai/index.uai"
  "/.uai/taboo.uai"
  "/source-facts/"
  "/workspace.uai"
  "/assets/js/site.js"
  "/assets/css/site.css"
  "/data/pages.json"
  "/inc/site.php"
  "/tools/build-runtime-manifests.js"
  "/tools/verify-runtime-mirust.sh"
)

targets=(
  "https://tinyrustlm.mirust.com/developer-portal/"
  "https://tinyrustlm.mirust.com/developer-portal/"
  "https://tinyrustlm.mirust.com/developer-portal/"
  "https://tinyrustlm.mirust.com/llms.txt"
  "https://tinyrustlm.mirust.com/docs/"
  "https://tinyrustlm.mirust.com/docs/long-term-memory.md"
  "https://tinyrustlm.mirust.com/docs/long-term-memory.md"
  "https://tinyrustlm.mirust.com/developer-portal/"
  "https://tinyrustlm.mirust.com/developer-portal/"
  "https://tinyrustlm.mirust.com/developer-portal/"
  "https://tinyrustlm.mirust.com/developer-portal/"
  "https://tinyrustlm.mirust.com/developer-portal/"
  "https://tinyrustlm.mirust.com/developer-portal/"
  "https://tinyrustlm.mirust.com/developer-portal/"
  "https://tinyrustlm.mirust.com/developer-portal/"
)

retired_paths=(
  "/docs/workspace.uai"
  "/DOCS/WORKSPACE.UAI"
  "/docs/workspace.uai/"
  "/docs/workspace.uai?retired=1"
  "/docs/%77orkspace.uai"
  "/docs/workspace%2Euai"
)

hostile_paths=(
  "//docs/workspace.uai"
  "/docs//workspace.uai"
  "/docs/workspace.uai//"
)

server_boundary_paths=(
  "/docs/workspace.uai%2F%2F"
  "/%2Fdocs/workspace.uai"
  "/docs/%2577orkspace.uai"
  "/docs/%2e%2e/workspace.uai"
  "/docs/../workspace.uai"
  "/docs/foo%5C..%5Cworkspace.uai"
  "/docs/workspace.uai%3Fignored"
  "/docs/%ZZworkspace.uai"
  "/docs/%00workspace.uai"
  "/docs/%FFworkspace.uai"
)

for index in "${!paths[@]}"; do
  source_url="${base}${paths[$index]}"
  expected="${targets[$index]}"
  header_file="${temporary_root}/redirect-${index}.headers"
  body_file="${temporary_root}/redirect-${index}.body"
  "${curl_command}" --fail --path-as-is --silent --show-error --dump-header "${header_file}" \
    --output "${body_file}" --max-redirs 0 "${source_url}"
  verify_redirect_headers "${header_file}" "${expected}"
  echo "PASS redirect ${paths[$index]} -> ${expected}"
done

observation_index=0
for retired_path in "${retired_paths[@]}"; do
  for method in GET HEAD; do
    source_url="${base}${retired_path}"
    header_file="${temporary_root}/retired-${observation_index}.headers"
    body_file="${temporary_root}/retired-${observation_index}.body"
    fetch_terminal_response "${method}" "${source_url}" "${header_file}" "${body_file}"
    verify_retired_files "${method}" "${header_file}" "${body_file}"
    echo "PASS retired ${method} ${retired_path} -> 410"
    observation_index=$((observation_index + 1))
  done
done

for hostile_path in "${hostile_paths[@]}"; do
  for method in GET HEAD; do
    source_url="${base}${hostile_path}"
    header_file="${temporary_root}/hostile-${observation_index}.headers"
    body_file="${temporary_root}/hostile-${observation_index}.body"
    fetch_terminal_response "${method}" "${source_url}" "${header_file}" "${body_file}"
    verify_bad_request_files "${method}" "${header_file}" "${body_file}"
    echo "PASS hostile ${method} ${hostile_path} -> 400"
    observation_index=$((observation_index + 1))
  done
done

for boundary_path in "${server_boundary_paths[@]}"; do
  for method in GET HEAD; do
    source_url="${base}${boundary_path}"
    header_file="${temporary_root}/boundary-${observation_index}.headers"
    body_file="${temporary_root}/boundary-${observation_index}.body"
    fetch_terminal_response "${method}" "${source_url}" "${header_file}" "${body_file}"
    verify_server_boundary_files "${method}" "${header_file}" "${body_file}"
    status="$(http_status "${header_file}")"
    echo "PASS server-boundary ${method} ${boundary_path} -> ${status}"
    observation_index=$((observation_index + 1))
  done
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
