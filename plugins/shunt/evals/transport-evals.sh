#!/bin/bash
# Transport evals for scripts/lib/worker.sh.
#
# Runs against a stubbed HTTP layer, so these need no network, no credential
# and no tokens — nothing here spends money.
#
# Prints one PASS/FAIL line per check plus a machine-readable "## <pass> <fail>"
# trailer for run.sh. Runs as its own process so the stub cannot leak.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
CAPTURED_PAYLOAD="$WORKDIR/captured-payload.json"
CAPTURED_HEADERS="$WORKDIR/captured-headers.txt"

export ANTHROPIC_API_KEY="test-key-not-real"

# shellcheck source=../scripts/lib/worker.sh
. "$PLUGIN_DIR/scripts/lib/worker.sh"

# Stub the transport: record what it was handed, return a canned Messages
# response in the shape POST /v1/messages actually returns.
shunt_http() {
  cp "$1" "$CAPTURED_PAYLOAD"
  cp "$2" "$CAPTURED_HEADERS"
  cat <<'JSON'
{"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-4-5",
 "content":[{"type":"text","text":"- first line\n- second line"}],
 "stop_reason":"end_turn",
 "usage":{"input_tokens":120,"cache_creation_input_tokens":80,"cache_read_input_tokens":0,"output_tokens":12}}
JSON
}

PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-34s %s\n" "$name" "$4"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-34s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

payload_field() { jq -r "$1" "$CAPTURED_PAYLOAD" 2>/dev/null; }

prefix_file="$WORKDIR/prefix.txt"
suffix_file="$WORKDIR/suffix.txt"
printf '<file path="a.ts">\nline one\nline two\n</file>\n' > "$prefix_file"
printf 'Question: what does this do?\n' > "$suffix_file"

# ── Invocation ──

check "answer-text-extracted" "- first line
- second line" "$(shunt_invoke bulk-reader "$prefix_file" "$suffix_file")" \
  "reads .content[].text, not raw stdout"
check "model-sent" "claude-haiku-4-5" "$(payload_field '.model')" \
  "the worker model is the cheap one by default"
check "prefix-sent-verbatim" "$(cat "$prefix_file")" "$(payload_field '.messages[0].content[0].text')" \
  "the corpus survives the round trip byte for byte"
check "suffix-sent-verbatim" "$(cat "$suffix_file")" "$(payload_field '.messages[0].content[1].text')" \
  "the question travels as its own block"
check "system-prompt-sent" "true" "$(payload_field '.system | startswith("You are a precise code analyst")')" \
  "the mode instructions become the system prompt"
check "no-history-sent" "1" "$(payload_field '.messages | length')" \
  "every delegation is one shot"
check "max-tokens-sent" "16000" "$(payload_field '.max_tokens')" \
  "output is not lowballed into truncation"

# ── Caching ──

check "prefix-marked-cacheable" "ephemeral" "$(payload_field '.messages[0].content[0].cache_control.type')" \
  "the corpus is the cached prefix"
check "suffix-not-cached" "false" "$(payload_field '.messages[0].content[1] | has("cache_control")')" \
  "the volatile block must sit after the breakpoint"
# The checks above ran in command substitutions, so re-invoke in this shell to
# observe SHUNT_LAST_USAGE.
shunt_invoke bulk-reader "$prefix_file" "$suffix_file" >/dev/null
check "usage-reports-cache" "in 120 | cache write 80 | cache read 0 | out 12" "$SHUNT_LAST_USAGE" \
  "cache hits are visible to the caller"

# A corpus with no question still forms one cacheable block.
shunt_invoke bulk-reader "$prefix_file" >/dev/null
check "suffix-optional" "1" "$(payload_field '.messages[0].content | length')" \
  "a prefix-only call sends a single block"

# ── Auth ──

check "api-key-header" "x-api-key: test-key-not-real" "$(grep '^x-api-key' "$CAPTURED_HEADERS")" \
  "ANTHROPIC_API_KEY goes on x-api-key"
check "no-bearer-with-api-key" "" "$(grep '^Authorization' "$CAPTURED_HEADERS")" \
  "an API key is not sent as a bearer token"

( unset ANTHROPIC_API_KEY
  PATH="$WORKDIR/empty-path" shunt_auth_header >/dev/null 2>&1 ) && rc=0 || rc=$?
check "missing-credential-fails" "1" "$rc" "no credential is an error, never a prompt"

# ── Mode guard ──

( shunt_invoke no-such-mode "$prefix_file" >/dev/null 2>&1 ) && rc=0 || rc=$?
check "unknown-mode-fails" "1" "$rc" "an unknown mode is rejected before any spend"

# ── Failure modes ──

( shunt_http() { echo '{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}'; }
  guard=$(shunt_invoke bulk-reader "$prefix_file" "$suffix_file" 2>&1 >/dev/null) && exit 1
  case "$guard" in *"authentication_error"*"invalid x-api-key"*) exit 0 ;; *) exit 1 ;; esac ) && rc=0 || rc=$?
check "api-error-surfaced" "0" "$rc" "a JSON error body is unwrapped, not dumped"

( shunt_http() { echo '{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}'; }
  guard=$(shunt_invoke bulk-reader "$prefix_file" "$suffix_file" 2>&1 >/dev/null) && exit 1
  case "$guard" in *"retry shortly"*) exit 0 ;; *) exit 1 ;; esac ) && rc=0 || rc=$?
check "rate-limit-explained" "0" "$rc" "the error carries a remediation"

( shunt_http() { echo 'not json at all'; }
  guard=$(shunt_invoke bulk-reader "$prefix_file" "$suffix_file" 2>&1 >/dev/null) && exit 1
  case "$guard" in *"unparseable"*) exit 0 ;; *) exit 1 ;; esac ) && rc=0 || rc=$?
check "garbled-response-fails" "0" "$rc" "unparseable output is a transport error"

( shunt_http() { printf ''; }
  shunt_invoke bulk-reader "$prefix_file" "$suffix_file" >/dev/null 2>&1 ) && rc=0 || rc=$?
check "empty-response-fails" "1" "$rc" "an empty body is a failure, not an answer"

# A refusal is HTTP 200 with no usable content — it must not pass as an answer.
( shunt_http() { echo '{"type":"message","content":[],"stop_reason":"refusal"}'; }
  guard=$(shunt_invoke bulk-reader "$prefix_file" "$suffix_file" 2>&1 >/dev/null) && exit 1
  case "$guard" in *"refusal"*) exit 0 ;; *) exit 1 ;; esac ) && rc=0 || rc=$?
check "refusal-fails" "0" "$rc" "a refusal is checked before reading content"

( shunt_http() { echo '{"type":"message","content":[],"stop_reason":"end_turn"}'; }
  shunt_invoke bulk-reader "$prefix_file" "$suffix_file" >/dev/null 2>&1 ) && rc=0 || rc=$?
check "empty-content-fails" "1" "$rc" "an answer with no text is an error"

# Truncation must warn rather than silently hand back half a file.
warn=$( shunt_http() { echo '{"type":"message","content":[{"type":"text","text":"half"}],"stop_reason":"max_tokens"}'; }
  shunt_invoke bulk-reader "$prefix_file" "$suffix_file" 2>&1 >/dev/null )
case "$warn" in
  *"truncated"*) check "truncation-warned" "y" "y" "max_tokens is surfaced, not swallowed" ;;
  *)             check "truncation-warned" "y" "n" "max_tokens is surfaced, not swallowed" ;;
esac

# ── Payload ceiling ──

saved="$SHUNT_MAX_PAYLOAD_BYTES"
SHUNT_MAX_PAYLOAD_BYTES=10
guard=$(shunt_invoke bulk-reader "$prefix_file" "$suffix_file" 2>&1 >/dev/null) && rc=0 || rc=$?
check "oversized-payload-fails" "1" "$rc" "the context window is the real ceiling"
case "$guard" in
  *"over the 10 byte limit"*) check "oversized-payload-explained" "y" "y" "the error names the limit" ;;
  *)                          check "oversized-payload-explained" "y" "n" "the error names the limit" ;;
esac
SHUNT_MAX_PAYLOAD_BYTES="$saved"

echo "## $PASSED $FAILED"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
