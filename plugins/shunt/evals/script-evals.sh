#!/bin/bash
# Script evals for scripts/bulk-read and scripts/code-write.
#
# Drives the real scripts end to end against a stubbed `claude` binary installed
# via SHUNT_CLAUDE_BIN — the default transport — so these need no network, no
# credential and no spend.
#
# Prints one PASS/FAIL line per check plus a machine-readable "## <pass> <fail>"
# trailer for run.sh.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

PASSED=0
FAILED=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf "  \033[32mPASS\033[0m  %-32s %s\n" "$name" "$4"
    PASSED=$((PASSED + 1))
  else
    printf "  \033[31mFAIL\033[0m  %-32s expected=[%s] got=[%s]\n" "$name" "$expected" "$actual"
    FAILED=$((FAILED + 1))
  fi
}

# A fake `claude` that answers with whatever STUB_ANSWER_FILE holds, in the
# shape `claude -p --output-format json` returns. STUB_ERROR forces a failure.
STUB="$WORKDIR/claude"
cat > "$STUB" <<'STUBEOF'
#!/bin/bash
cat >/dev/null   # drain the prompt on stdin
if [ -n "${STUB_ERROR:-}" ]; then
  echo '{"is_error":true,"subtype":"error_during_execution","result":"stub failure"}'
  exit 0
fi
jq -n --rawfile text "$STUB_ANSWER_FILE" \
  '{is_error: false, subtype: "success", result: $text, total_cost_usd: 0.003,
    usage: {input_tokens: 9, cache_creation_input_tokens: 0, cache_read_input_tokens: 11337, output_tokens: 5}}'
STUBEOF
chmod +x "$STUB"
export SHUNT_CLAUDE_BIN="$STUB"

ANSWER="$WORKDIR/answer.txt"
export STUB_ANSWER_FILE="$ANSWER"

REFERENCE="$WORKDIR/reference.ts"
printf 'export const a = 1;\n' > "$REFERENCE"

# ── Fence handling ──

printf '```typescript\nexport const x = 1;\n```\n' > "$ANSWER"
out=$("$PLUGIN_DIR/scripts/code-write" --spec s --reference "$REFERENCE" 2>/dev/null)
check "outer-fence-stripped" "export const x = 1;" "$out" \
  "a wrapped answer loses its fence"

# A fenced example inside a docstring is content, not a wrapper.
printf '/** Example:\n```ts\nfoo()\n```\n*/\nexport const x = 1;\n' > "$ANSWER"
out=$("$PLUGIN_DIR/scripts/code-write" --spec s --reference "$REFERENCE" 2>/dev/null)
check "inner-fences-preserved" "$(printf '/** Example:\n```ts\nfoo()\n```\n*/\nexport const x = 1;')" "$out" \
  "fences inside the code survive"

# ── Verbatim output ──

printf -- '-n\nexport const x = 1;\n' > "$ANSWER"
out=$("$PLUGIN_DIR/scripts/code-write" --spec s --reference "$REFERENCE" 2>/dev/null)
check "leading-dash-n-preserved" "$(printf -- '-n\nexport const x = 1;')" "$out" \
  "content starting with -n is not eaten as a flag"

printf 'const re = "a\\tb";\n' > "$ANSWER"
out=$("$PLUGIN_DIR/scripts/code-write" --spec s --reference "$REFERENCE" 2>/dev/null)
check "backslash-preserved" 'const re = "a\tb";' "$out" \
  "backslashes survive verbatim"

# ── Target safety ──

printf 'export const x = 1;\n' > "$ANSWER"

existing="$WORKDIR/existing.ts"
printf 'DO NOT LOSE ME\n' > "$existing"
"$PLUGIN_DIR/scripts/code-write" --spec s --reference "$REFERENCE" --target "$existing" >/dev/null 2>&1
check "existing-target-refused" "1" "$?" "an occupied target is not overwritten"
check "existing-target-intact" "DO NOT LOSE ME" "$(cat "$existing")" \
  "the refusal leaves the file byte-identical"

"$PLUGIN_DIR/scripts/code-write" --spec s --reference "$REFERENCE" --target "$existing" --force >/dev/null 2>&1
check "force-overwrites" "export const x = 1;" "$(cat "$existing")" \
  "--force is the explicit opt-in"

fresh="$WORKDIR/fresh.ts"
"$PLUGIN_DIR/scripts/code-write" --spec s --reference "$REFERENCE" --target "$fresh" >/dev/null 2>&1
check "new-target-written" "export const x = 1;" "$(cat "$fresh" 2>/dev/null)" \
  "a free path is written normally"

missing_dir="$WORKDIR/nope/out.ts"
"$PLUGIN_DIR/scripts/code-write" --spec s --reference "$REFERENCE" --target "$missing_dir" >/dev/null 2>&1
check "missing-target-dir-refused" "1" "$?" "a target directory that does not exist fails loudly"

# A failed invocation must not leave a truncated or empty target behind.
untouched="$WORKDIR/untouched.ts"
( export STUB_ERROR=1
  "$PLUGIN_DIR/scripts/code-write" --spec s --reference "$REFERENCE" --target "$untouched" >/dev/null 2>&1 )
check "no-target-on-failure" "false" "$([ -e "$untouched" ] && echo true || echo false)" \
  "a failed call writes nothing"

# ── Argument guards ──

"$PLUGIN_DIR/scripts/code-write" --spec s >/dev/null 2>&1
check "missing-reference-fails" "1" "$?" "--reference is required"

"$PLUGIN_DIR/scripts/code-write" --spec s --reference "$WORKDIR/no-such-file" >/dev/null 2>&1
check "absent-reference-fails" "1" "$?" "a reference that is not there fails loudly"

# ── bulk-read guards ──

"$PLUGIN_DIR/scripts/bulk-read" --paths "$REFERENCE" >/dev/null 2>&1
check "bulk-read-needs-question" "1" "$?" "--question is required"

"$PLUGIN_DIR/scripts/bulk-read" --question q >/dev/null 2>&1
check "bulk-read-needs-paths" "1" "$?" "--paths is required"

"$PLUGIN_DIR/scripts/bulk-read" --question q --paths "$WORKDIR/no-such-file" >/dev/null 2>&1
check "bulk-read-typo-path-fails" "1" "$?" "a typo'd path must not answer about nothing"

echo "## $PASSED $FAILED"
[ "$FAILED" -gt 0 ] && exit 1
exit 0
