#!/usr/bin/env bash
# Detects whether sites use HTTP/3, HTTP/2, or HTTP/1.1 using curl (with QUIC support).
# Writes a CSV report with fallback info and whether HTTP/3 is advertised but not used.

set -u

INPUT_FILE="${1:-}"
OUTPUT_CSV="${2:-http_protocol_report.csv}"
TIMEOUT="${TIMEOUT:-10}"           # seconds per attempt
USERAGENT="${USERAGENT:-curl-probe/1.0}"
CURL_BIN="${CURL_BIN:-curl}"

if [[ -z "${INPUT_FILE}" ]]; then
  echo "Usage: $0 <urls.txt> [output.csv]" >&2
  exit 1
fi

if ! command -v "${CURL_BIN}" >/dev/null 2>&1; then
  echo "Error: curl not found. Set CURL_BIN or install curl." >&2
  exit 1
fi

# CSV header
echo "url,effective_url,final_protocol,http3_attempt,http2_attempt,http1_attempt,fallback_chain,http3_advertised,response_code,error" > "${OUTPUT_CSV}"

trim() { sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//'; }

normalize_url() {
  local raw="$1"
  raw="$(echo "$raw" | trim)"
  # If no scheme, assume https
  if [[ "$raw" =~ ^https?:// ]]; then
    echo "$raw"
  else
    echo "https://$raw"
  fi
}

# Run a curl probe and capture:
#  - exit code
#  - http_version
#  - response_code
#  - effective_url
#  - headers (to a tempfile)
probe() {
  local url="$1"
  local mode="$2"  # one of: h3only, h2, h1, auto
  local hdr_file
  hdr_file="$(mktemp)"
  local httpv rc eff err

  # Common options
  # -I = HEAD only, -s silent, -S show errors, -L follow redirects
  # -m timeout, -D dump headers, -o discard body
  # -w write metrics at the end
  # Note: we keep -L so we see Alt-Svc across redirects as well.
  local base=( -I -s -S -L -m "${TIMEOUT}" -D "${hdr_file}" -o /dev/null
               -A "${USERAGENT}"
               -w 'HTTPV=%{http_version}\nRC=%{response_code}\nEFF=%{url_effective}\n' )

  case "$mode" in
    h3only) opts=( --http3-only );;
    h2)     opts=( --http2 );;
    h1)     opts=( --http1.1 );;
    auto)   opts=( );;
    *)      echo "invalid mode" >&2; return 99;;
  esac

  # Execute
  local out
  if ! out="$("${CURL_BIN}" "${base[@]}" "${opts[@]}" "$url" 2>&1)"; then
    # Curl failed. Still parse what we can.
    err="$(echo "$out" | tr '\n' ' ' | sed 's/,/;/g')"
    httpv=""
    rc=""
    eff=""
    echo "$mode|1|$httpv|$rc|$eff|$hdr_file|$err"
    return 0
  fi

  httpv="$(echo "$out" | awk -F= '/^HTTPV=/{print $2}')"
  rc="$(echo "$out" | awk -F= '/^RC=/{print $2}')"
  eff="$(echo "$out" | awk -F= '/^EFF=/{print $2}')"
  err=""
  echo "$mode|0|$httpv|$rc|$eff|$hdr_file|$err"
}

# Determine if a header file advertises HTTP/3 via Alt-Svc
has_h3_altsvc() {
  local hdr_file="$1"
  # Look for h3 tokens, e.g., h3, h3-29, h3-50, etc.
  # Case-insensitive, ignore folded headers by joining lines.
  tr -d '\r' < "$hdr_file" \
    | awk 'BEGIN{IGNORECASE=1} /^alt-svc:/ {print $0}' \
    | grep -E '(^|[ ,;])h3(-[0-9]+)?=' >/dev/null 2>&1
}

# CSV-safe quoting (wrap field in quotes, escape inner quotes)
csvq() {
  local s="${1:-}"
  s="${s//\"/\"\"}"
  echo "\"$s\""
}

# Process each URL
while IFS= read -r line || [[ -n "$line" ]]; do
  # Skip empty lines and comments
  if [[ -z "$(echo "$line" | trim)" ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
    continue
  fi

  url="$(normalize_url "$line")"

  # Attempt order: h3only -> h2 -> h1
  # Also collect an "auto" attempt to capture Alt-Svc even when h3-only fails.
  h3res="$(probe "$url" h3only)"
  IFS="|" read -r _h3 mode_fail_h3 httpv_h3 rc_h3 eff_h3 hdr_h3 err_h3 <<< "$h3res"

  # Initialize tracking
  final_protocol=""
  response_code=""
  effective_url=""
  fallback_chain=""

  # If HTTP/3 succeeded and reported version "3" we’re done
  if [[ "$mode_fail_h3" == "0" && "$httpv_h3" == "3" ]]; then
    final_protocol="h3"
    response_code="$rc_h3"
    effective_url="$eff_h3"
    fallback_chain="h3"
    # Check Alt-Svc presence anyway (from h3 response)
    h3_adv="false"
    if has_h3_altsvc "$hdr_h3"; then h3_adv="true"; fi

    echo "$(csvq "$url"),$(csvq "$effective_url"),$(csvq "$final_protocol"),$(csvq "success"),$(csvq "n/a"),$(csvq "n/a"),$(csvq "$fallback_chain"),$(csvq "$h3_adv"),$(csvq "$response_code"),$(csvq "$err_h3")" >> "${OUTPUT_CSV}"
    rm -f "$hdr_h3"
    continue
  fi

  # If h3 failed, try HTTP/2
  h2res="$(probe "$url" h2)"
  IFS="|" read -r _h2 mode_fail_h2 httpv_h2 rc_h2 eff_h2 hdr_h2 err_h2 <<< "$h2res"

  if [[ "$mode_fail_h2" == "0" && "$httpv_h2" == "2" ]]; then
    final_protocol="h2"
    response_code="$rc_h2"
    effective_url="$eff_h2"
    fallback_chain="h3->h2"
    # Check Alt-Svc to see if h3 is advertised but not used
    h3_adv="false"
    if has_h3_altsvc "$hdr_h2"; then h3_adv="true"; fi

    echo "$(csvq "$url"),$(csvq "$effective_url"),$(csvq "$final_protocol"),$(csvq "fail"),$(csvq "success"),$(csvq "n/a"),$(csvq "$fallback_chain"),$(csvq "$h3_adv"),$(csvq "$response_code"),$(csvq "$err_h2")" >> "${OUTPUT_CSV}"
    rm -f "$hdr_h3" "$hdr_h2"
    continue
  fi

  # If h2 failed, try HTTP/1.1
  h1res="$(probe "$url" h1)"
  IFS="|" read -r _h1 mode_fail_h1 httpv_h1 rc_h1 eff_h1 hdr_h1 err_h1 <<< "$h1res"

  if [[ "$mode_fail_h1" == "0" && "$httpv_h1" == "1.1" ]]; then
    final_protocol="http/1.1"
    response_code="$rc_h1"
    effective_url="$eff_h1"
    fallback_chain="h3->h2->h1.1"
    # Check Alt-Svc (advertises h3 even though not used)
    h3_adv="false"
    if has_h3_altsvc "$hdr_h1"; then h3_adv="true"; fi

    echo "$(csvq "$url"),$(csvq "$effective_url"),$(csvq "$final_protocol"),$(csvq "fail"),$(csvq "fail"),$(csvq "success"),$(csvq "$fallback_chain"),$(csvq "$h3_adv"),$(csvq "$response_code"),$(csvq "$err_h1")" >> "${OUTPUT_CSV}"
    rm -f "$hdr_h3" "$hdr_h2" "$hdr_h1"
    continue
  fi

  # All explicit attempts failed. Do one "auto" attempt to try to grab headers/Alt-Svc for diagnostics.
  autores="$(probe "$url" auto)"
  IFS="|" read -r _a mode_fail_a httpv_a rc_a eff_a hdr_a err_a <<< "$autores"
  h3_adv="false"
  if [[ -f "$hdr_a" ]] && has_h3_altsvc "$hdr_a"; then h3_adv="true"; fi

  final_protocol="fail"
  response_code="${rc_a:-}"
  effective_url="${eff_a:-}"
  fallback_chain="h3->h2->h1.1->fail"

  echo "$(csvq "$url"),$(csvq "$effective_url"),$(csvq "$final_protocol"),$(csvq "fail"),$(csvq "fail"),$(csvq "fail"),$(csvq "$fallback_chain"),$(csvq "$h3_adv"),$(csvq "$response_code"),$(csvq "${err_h3:-}${err_h2:+ ; $err_h2}${err_h1:+ ; $err_h1}${err_a:+ ; $err_a}")" >> "${OUTPUT_CSV}"

  rm -f "$hdr_h3" "$hdr_h2" "$hdr_h1" "$hdr_a" 2>/dev/null || true

done < "${INPUT_FILE}"
