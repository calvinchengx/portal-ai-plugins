# shunt

A Claude Code plugin that shunts I/O-heavy work — bulk file reads and boilerplate generation — to a cheap worker model, so the frontier model's context is spent on thinking rather than on I/O.

This is a fork of [Spotify's shunt](https://github.com/spotify/portal-ai-plugins/tree/main/plugins/shunt) with the transport swapped. Upstream delegates through the Portal CLI's `aika:invoke-chat` action, which requires a Portal instance with AiKA enabled. This version offers two transports, neither of which needs Portal:

| `SHUNT_TRANSPORT` | Reaches the worker via | Credential | Overhead per call |
|---|---|---|---|
| `cli` (default) | `claude -p` | your existing Claude Code login | ~11.3K cached tokens, ~$0.003 once warm |
| `api` | `POST /v1/messages` | `ANTHROPIC_API_KEY` or `ant auth login` | a ~60-token system prompt |

**The `cli` transport spends from the same quota Claude Code itself uses.** If you are on a subscription there is no separate bill, but delegation draws on the same limits as your main session — you are moving spend, not eliminating it. The `api` transport bills separately, so it is the one that actually takes load off your Claude Code quota.

## How it works

Three layers, from hard gate to soft suggestion:

1. **Hooks** block Claude from reading large files and redirect to the bulk-reader skill
2. **Scripts** handle the API call and output cleanup
3. **Skills** tell Claude when and how to call the scripts

Claude never assembles bash pipelines from prose. It calls a script with named arguments.

## Prerequisites

- [`jq`](https://jqlang.org) — `brew install jq`
- For the default `cli` transport: the `claude` CLI, already logged in. Nothing else.
- For the `api` transport: `curl`, plus `ant auth login` or an exported `ANTHROPIC_API_KEY`.

No Portal instance, no Portal CLI, no `portal` plugin.

**Delegation is not free on either transport.** Haiku 4.5 is $1/MTok input and $5/MTok output at the time of writing.

On `cli`, Claude Code loads its harness into the worker's context. Stripped of tools, MCP servers and skills it is ~12K tokens, written once per cache TTL and read at cache rates after — measured at $0.024 for the first call in a window and ~$0.003 for each one after. Left unstripped it is ~28K tokens and $0.058 *per call*, which would defeat the plugin's purpose entirely; `shunt_cli` passes the flags that avoid this.

On `api`, overhead is a ~60-token system prompt, and the corpus is sent as an explicit `cache_control` block so re-asking over the same files reads at cache rates.

## Scripts

### bulk-read

Delegates file reading to the worker. Files are wrapped in XML tags (`<file path="...">`) for clear boundaries.

```bash
bulk-read --question "What does this service do?" --paths src/Service.java src/Handler.java

# Follow-up: ask again with the same paths. The files never enter Claude's
# context either way; on the api transport the corpus is a cached prefix, so
# the second question reads the cache instead of re-paying for the files
bulk-read --question "Which methods call the database?" --paths src/Service.java src/Handler.java
```

### code-write

Delegates boilerplate generation. Strips a wrapping markdown fence from the output, leaving fences inside the code alone. Can write directly to disk via `--target`; an existing target is refused unless you pass `--force`. `--reference` is required — without a file to match patterns against, the worker would generate context-free code that fits nothing in the project.

```bash
code-write --spec "Write tests for UserService" --reference tests/OrderTest.java --target tests/UserTest.java

# On the api transport the reference is a cached prefix, so several specs against it pay once
code-write --spec "Now add edge case tests" --reference tests/OrderTest.java --target tests/UserEdgeCases.java

# Replace a file you already generated
code-write --spec "Regenerate with async setup" --reference tests/OrderTest.java --target tests/UserTest.java --force
```

### One shot per call

No conversation state is kept anywhere. Every call stands alone — re-send the corpus rather than trying to carry context across calls. The corpus never enters Claude's context regardless of transport; on `api` it is additionally sent as a `cache_control` block, so re-sending is close to free there.

## Hooks

### check-file-size (Read hook)

Fires on every `Read`. Blocks full-file reads above `SHUNT_MIN_LINES` (default 350) **or** `SHUNT_MAX_BYTES` (default 50000). The byte ceiling catches minified and single-line JSON files, which a line count cannot see. Allows through:
- Targeted reads (offset or limit set)
- Files under both thresholds
- Nonexistent files (let Read handle the error)
- Unreadable files (let Read report the permission error)

### check-bash-read (Bash hook)

Fires on every `Bash`. Catches `cat`, `less`, `more` on large files, and `head`/`tail` when their count exceeds the threshold. Each `&&`, `||` and `;` segment is judged on its own, so a read buried in a chain (`cd src && cat big.ts`) is still caught, and arguments are split quote-aware so a path containing spaces resolves. Allows through:
- Piped commands (`cat file | grep`) — targeted reads
- Redirections (`cat file > out`) — not reading into context
- Bounded `head`/`tail` reads — `head -100` puts 100 lines in context, not the file, so it follows the same policy as a Read with an explicit offset/limit
- Non-read commands (`git status`, `grep`, etc.)
- Nonexistent or unreadable files (let Bash report the error)

## Configuration

All settings are environment variables — add them to the `env` block in `.claude/settings.json`.

| Variable | Default | Purpose |
|----------|---------|---------|
| `SHUNT_MIN_LINES` | `350` | Line count above which the hooks block and redirect |
| `SHUNT_MAX_BYTES` | `50000` | Byte count above which the hooks block, for minified and single-line files |
| `SHUNT_TRANSPORT` | `cli` | `cli` (via `claude -p`) or `api` (via the Messages API) |
| `SHUNT_MODEL` | `claude-haiku-4-5` | Worker model. `claude-sonnet-5` when the worker needs more judgment |
| `SHUNT_CLAUDE_BIN` | `claude` | Override the Claude Code binary (the evals use this to stub the transport) |
| `SHUNT_MAX_TOKENS` | `16000` | Output ceiling for one delegation |
| `SHUNT_MAX_PAYLOAD_BYTES` | `500000` | Request ceiling, bounded by the worker's context window |
| `SHUNT_TIMEOUT_SECONDS` | `180` | Timeout for one call |
| `SHUNT_API_URL` | Anthropic Messages API | Override the endpoint |
| `SHUNT_CURL_BIN` | `curl` | Override the HTTP client (the evals use this to stub the transport) |

Credentials are resolved without ever prompting: `ANTHROPIC_API_KEY` first, then an `ant auth login` profile. An unset `ANTHROPIC_API_KEY` does not mean there is no credential.

## What doesn't get delegated

- **Debugging** — requires Claude's reasoning, not a summary
- **Editing** — Claude needs exact content in context; use targeted reads (offset/limit)
- **Small files** — delegation overhead exceeds savings under the threshold
- **Architectural decisions** — judgment calls stay on Claude

## Evals

```bash
# Hook routing, transport plumbing and script behavior — no network, no credential, no spend
bash evals/run.sh
```

93 checks across four suites: the two hooks against generated fixtures, `lib/worker.sh` against both a stubbed `claude -p` and a stubbed HTTP layer, and both scripts end to end against a stubbed `claude`. Nothing in the default suite calls a model or costs money.

## On savings claims

Upstream's README publishes an 82–94% savings table measured against a 162K-line Java monorepo. **Those numbers are not reproducible from this repository** — the checked-in benchmark fixtures total 692 lines, and the code-write benchmark hardcodes the with-shunt cost to zero, making its savings 100% by construction. This fork does not carry that table, and does not make a savings claim it cannot demonstrate.

What can be said precisely:

- The delegated portion runs on a model that costs 5× less than Opus 5 on both input and output.
- The corpus never enters Claude's context, so it does not consume the frontier model's context window.
- Total savings are bounded by the fraction of your work that is bulk reading. A 90% cut on a third of your tokens is a 30% cut overall.
- Claude Code's built-in subagents already read files in a separate context and return conclusions, for free. The marginal gain here is the worker's lower price plus the hooks' enforcement — measure against subagents, not against reading whole files into the main context.

If you want a number for your own codebase, measure cost per completed task, not tokens per request.

## Known limitations

- **No enforcement for code-writer** — only bulk-reader has hook enforcement. Code-writer relies on Claude recognizing when to use it via the skill description.
- **Context window** — the worker's window is the real request ceiling. Haiku 4.5 holds 200K tokens; `SHUNT_MAX_PAYLOAD_BYTES` guards against overrunning it with a clear error rather than a truncated read.
- **Latency** — a delegation is a network round trip. Measured at ~9s for a 602-line file on the `cli` transport. `SHUNT_TIMEOUT_SECONDS` caps the `api` transport.
- **Corpus caching is `api`-only** — the `api` transport marks the corpus `cache_control` explicitly. On `cli` the harness prefix caches but the corpus does not, so re-asking over the same files re-pays for them.
- **Line numbers** — worker summaries are not a reliable source of exact line numbers. Verify before using them in edits.
