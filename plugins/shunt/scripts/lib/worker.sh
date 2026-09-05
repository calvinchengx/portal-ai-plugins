#!/bin/bash
# Shared worker plumbing for shunt's delegation scripts.
#
# Delegation runs against a cheap worker model over one of two transports.
# Upstream shunt routes through the Portal CLI's aika:invoke-chat action, which
# needs a Portal instance with AiKA enabled; neither transport here does.
#
#   cli (default) — shells out to `claude -p`, reusing the Claude Code login.
#                   No API key. Costs ~12K cached tokens of harness overhead per
#                   delegation, written once per cache TTL and read cheaply
#                   after, and it spends from the same quota Claude Code itself
#                   uses.
#   api           — POSTs to the Messages API. Needs ANTHROPIC_API_KEY or an
#                   `ant auth login` profile. Minimal overhead and explicit
#                   cache_control on the corpus, but bills separately.
#
# Each delegation is one shot: no conversation state is kept anywhere. Re-ask
# with the same corpus rather than trying to carry context across calls — the
# corpus is cached (see below), so repeating it is close to free.

SHUNT_TRANSPORT="${SHUNT_TRANSPORT:-cli}"
SHUNT_MODEL="${SHUNT_MODEL:-claude-haiku-4-5}"
SHUNT_CLAUDE_BIN="${SHUNT_CLAUDE_BIN:-claude}"
SHUNT_MAX_TOKENS="${SHUNT_MAX_TOKENS:-16000}"
SHUNT_API_URL="${SHUNT_API_URL:-https://api.anthropic.com/v1/messages}"
SHUNT_CURL_BIN="${SHUNT_CURL_BIN:-curl}"

# Ceiling for one request. The Portal transport capped this at ARG_MAX because
# invoke-chat took its input on the command line; a POST body has no such
# limit, so the real constraint is the worker's context window. Haiku 4.5 holds
# 200K tokens — this leaves room for the system prompt and the reply.
SHUNT_MAX_PAYLOAD_BYTES="${SHUNT_MAX_PAYLOAD_BYTES:-500000}"

# Ceiling for one call; large generations can take a while.
SHUNT_TIMEOUT_SECONDS="${SHUNT_TIMEOUT_SECONDS:-180}"

# Mode instructions, carried over verbatim from the AiKA modes upstream shunt
# documents, so output shape matches what the skills expect.
shunt_system_prompt() {
  case "$1" in
    bulk-reader)
      printf '%s' "You are a precise code analyst. Read the provided files and answer the question concisely. Output structured bullets only. No greetings, no prose, no preambles, no summaries. Lead every bullet with the exact name, type, or line number. Use nested bullets for details. Skip anything the caller did not ask for."
      ;;
    code-writer)
      printf '%s' "You generate code files based on a spec and reference files. Match the existing patterns, conventions, naming, and style exactly. Output only the code — no explanations, no markdown fences unless asked. If the spec is ambiguous, make reasonable choices that match the patterns in the reference code."
      ;;
    *)
      return 1
      ;;
  esac
}

# mktemp with cleanup on script exit. Usage: shunt_tmpfile <varname>
SHUNT_TMPFILES=()
shunt_tmpfile() {
  local f
  f=$(mktemp) || return 1
  SHUNT_TMPFILES+=("$f")
  trap 'rm -f "${SHUNT_TMPFILES[@]}"' EXIT
  printf -v "$1" '%s' "$f"
}

shunt_preflight() {
  local missing=""
  command -v jq >/dev/null 2>&1 || missing=" jq"

  case "$SHUNT_TRANSPORT" in
    cli)
      command -v "$SHUNT_CLAUDE_BIN" >/dev/null 2>&1 || missing="$missing $SHUNT_CLAUDE_BIN"
      ;;
    api)
      command -v "$SHUNT_CURL_BIN" >/dev/null 2>&1 || missing="$missing $SHUNT_CURL_BIN"
      ;;
    *)
      echo "Error: unknown SHUNT_TRANSPORT \"$SHUNT_TRANSPORT\" (expected cli or api)." >&2
      return 1
      ;;
  esac

  if [ -n "$missing" ]; then
    echo "Error: missing required command(s):$missing" >&2
    echo "  jq — brew install jq" >&2
    return 1
  fi

  # Only the api transport needs a credential; cli reuses the Claude Code login.
  if [ "$SHUNT_TRANSPORT" = "api" ] && ! shunt_auth_header >/dev/null; then
    return 1
  fi
  return 0
}

# Resolves a credential without ever prompting for one. An unset
# ANTHROPIC_API_KEY does not mean there is no credential: the `ant` CLI keeps
# OAuth profiles on disk that work just as well.
#
# Prints the auth header(s), one per line, for curl to consume.
shunt_auth_header() {
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    printf 'x-api-key: %s\n' "$ANTHROPIC_API_KEY"
    return 0
  fi

  if command -v ant >/dev/null 2>&1; then
    local token
    token=$(ant auth print-credentials --access-token 2>/dev/null)
    if [ -n "$token" ]; then
      # OAuth tokens go on Authorization: Bearer and need the beta opt-in;
      # this is a header change from the API-key form, not a key swap.
      printf 'Authorization: Bearer %s\n' "$token"
      printf 'anthropic-beta: oauth-2025-04-20\n'
      return 0
    fi
  fi

  echo "Error: no Anthropic credential found." >&2
  echo "  Run 'ant auth login' (stores a profile the SDKs and this script read)," >&2
  echo "  or export ANTHROPIC_API_KEY." >&2
  return 1
}

# One HTTP POST. Split out so the eval suite can stub the transport without a
# network or a credential.
#   $1 body file
#   $2 header file (one header per line)
shunt_http() {
  local body_file="$1" header_file="$2"
  local args=(-sS --max-time "$SHUNT_TIMEOUT_SECONDS"
              -H "content-type: application/json"
              -H "anthropic-version: 2023-06-01")
  local h
  while IFS= read -r h; do
    [ -n "$h" ] && args+=(-H "$h")
  done < "$header_file"
  "$SHUNT_CURL_BIN" "${args[@]}" --data-binary "@$body_file" "$SHUNT_API_URL"
}

# One `claude -p` run. Split out so the eval suite can stub it.
#   $1 system prompt
#   $2 prompt file
#
# The worker is stripped down deliberately: no tools, no MCP servers, no skills.
# Claude Code otherwise loads its full harness into the worker's context — 28K
# tokens before the corpus even arrives, which would defeat the point.
shunt_cli() {
  local system="$1" prompt_file="$2"
  "$SHUNT_CLAUDE_BIN" -p \
    --model "$SHUNT_MODEL" \
    --output-format json \
    --system-prompt "$system" \
    --disallowedTools "Bash Read Write Edit MultiEdit NotebookEdit Glob Grep WebFetch WebSearch Task Agent TodoWrite" \
    --strict-mcp-config \
    --disable-slash-commands \
    < "$prompt_file"
}

# Reads the `claude -p --output-format json` envelope.
shunt_invoke_cli() {
  local system="$1" prefix_file="$2" suffix_file="$3"
  local prompt_file response text

  shunt_tmpfile prompt_file || return 1
  cat "$prefix_file" > "$prompt_file"
  [ -n "$suffix_file" ] && cat "$suffix_file" >> "$prompt_file"

  response=$(shunt_cli "$system" "$prompt_file")
  if [ -z "$response" ]; then
    echo "Error: \`$SHUNT_CLAUDE_BIN -p\` returned nothing." >&2
    return 1
  fi

  if ! printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
    echo "Error: \`$SHUNT_CLAUDE_BIN -p\` returned unparseable output." >&2
    printf '%s\n' "$response" >&2
    return 1
  fi

  if [ "$(printf '%s' "$response" | jq -r '.is_error // false')" = "true" ]; then
    echo "Error: the worker run failed: $(printf '%s' "$response" | jq -r '.result // .subtype // "no detail"')" >&2
    return 1
  fi

  text=$(printf '%s' "$response" | jq -r '.result // empty')
  if [ -z "$text" ]; then
    echo "Error: the worker returned no text." >&2
    printf '%s\n' "$response" >&2
    return 1
  fi

  SHUNT_LAST_USAGE=$(printf '%s' "$response" | jq -r '
    "in \(.usage.input_tokens // 0) | cache write \(.usage.cache_creation_input_tokens // 0) | cache read \(.usage.cache_read_input_tokens // 0) | out \(.usage.output_tokens // 0) | $\(.total_cost_usd // 0)"')

  printf '%s\n' "$text"
}

# Runs one worker turn and prints the answer.
#   $1 mode name (bulk-reader | code-writer)
#   $2 file holding the stable prefix (the file corpus, or the reference file)
#   $3 file holding the volatile suffix (the question, or the spec) — optional
#
# The prefix is sent as its own content block marked cache_control, so asking a
# second question over the same corpus reads the cache instead of paying full
# input price for it again. That is what makes the skills' "re-ask with the
# same --paths" advice actually cheap rather than merely convenient.
shunt_invoke() {
  local mode_name="$1" prefix_file="$2" suffix_file="${3:-}"
  local system bytes response text stop usage payload_file header_file

  if ! system=$(shunt_system_prompt "$mode_name"); then
    echo "Error: unknown worker mode \"$mode_name\"." >&2
    return 1
  fi

  if [ "$SHUNT_TRANSPORT" = "cli" ]; then
    shunt_invoke_cli "$system" "$prefix_file" "$suffix_file"
    return $?
  fi

  shunt_tmpfile payload_file || return 1
  shunt_tmpfile header_file || return 1

  if [ -n "$suffix_file" ]; then
    jq -n \
      --arg model "$SHUNT_MODEL" \
      --argjson max_tokens "$SHUNT_MAX_TOKENS" \
      --arg system "$system" \
      --rawfile prefix "$prefix_file" \
      --rawfile suffix "$suffix_file" \
      '{model: $model, max_tokens: $max_tokens, system: $system,
        messages: [{role: "user", content: [
          {type: "text", text: $prefix, cache_control: {type: "ephemeral"}},
          {type: "text", text: $suffix}
        ]}]}' > "$payload_file"
  else
    jq -n \
      --arg model "$SHUNT_MODEL" \
      --argjson max_tokens "$SHUNT_MAX_TOKENS" \
      --arg system "$system" \
      --rawfile prefix "$prefix_file" \
      '{model: $model, max_tokens: $max_tokens, system: $system,
        messages: [{role: "user", content: [
          {type: "text", text: $prefix, cache_control: {type: "ephemeral"}}
        ]}]}' > "$payload_file"
  fi

  bytes=$(wc -c < "$payload_file" | tr -d ' ')
  if [ "$bytes" -gt "$SHUNT_MAX_PAYLOAD_BYTES" ]; then
    echo "Error: request is $bytes bytes, over the $SHUNT_MAX_PAYLOAD_BYTES byte limit." >&2
    echo "The worker's context window is the real ceiling here. Send fewer or" >&2
    echo "smaller files, or raise SHUNT_MAX_PAYLOAD_BYTES if the model has room." >&2
    return 1
  fi

  shunt_auth_header > "$header_file" || return 1

  response=$(shunt_http "$payload_file" "$header_file")
  if [ $? -ne 0 ] || [ -z "$response" ]; then
    echo "Error: the request to $SHUNT_API_URL failed." >&2
    [ -n "$response" ] && printf '%s\n' "$response" >&2
    return 1
  fi

  if ! printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
    echo "Error: the API returned unparseable output." >&2
    printf '%s\n' "$response" >&2
    return 1
  fi

  # API errors arrive as HTTP 4xx/5xx with a JSON body, not as a curl failure.
  if printf '%s' "$response" | jq -e '.type == "error"' >/dev/null 2>&1; then
    local etype emsg
    etype=$(printf '%s' "$response" | jq -r '.error.type // "error"')
    emsg=$(printf '%s' "$response" | jq -r '.error.message // "no message"')
    echo "Error: $etype: $emsg" >&2
    case "$etype" in
      authentication_error) echo "  Check ANTHROPIC_API_KEY, or re-run 'ant auth login'." >&2 ;;
      rate_limit_error)     echo "  Rate limited — retry shortly." >&2 ;;
      overloaded_error)     echo "  The API is overloaded — retry shortly." >&2 ;;
    esac
    return 1
  fi

  # A refusal returns HTTP 200 with no usable content, so check before reading.
  stop=$(printf '%s' "$response" | jq -r '.stop_reason // empty')
  if [ "$stop" = "refusal" ]; then
    echo "Error: the worker declined this request (stop_reason: refusal)." >&2
    return 1
  fi

  text=$(printf '%s' "$response" | jq -r '[.content[]? | select(.type == "text") | .text] | join("")')
  if [ -z "$text" ]; then
    echo "Error: the worker returned no text." >&2
    printf '%s\n' "$response" >&2
    return 1
  fi

  if [ "$stop" = "max_tokens" ]; then
    echo "Warning: output hit max_tokens ($SHUNT_MAX_TOKENS) and is truncated." >&2
    echo "  Raise SHUNT_MAX_TOKENS or split the request." >&2
  fi

  usage=$(printf '%s' "$response" | jq -r '
    .usage // {} |
    "in \(.input_tokens // 0) | cache write \(.cache_creation_input_tokens // 0) | cache read \(.cache_read_input_tokens // 0) | out \(.output_tokens // 0)"')
  SHUNT_LAST_USAGE="$usage"

  printf '%s\n' "$text"
}
