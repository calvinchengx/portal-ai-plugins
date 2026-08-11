---
name: doctor
description: Diagnose Spotify Portal plugin, CLI, authentication, and action access without changing state. Use when setup is failing, commands are missing, authentication is unclear, a plugin update looks stale, or the user asks whether Portal is ready.
---

# Diagnose Spotify Portal

Run a read-only health check for the current coding-agent host. Do not install,
authenticate, select an instance, or invoke a mutating Portal action.

## Diagnostic workflow

### 1. Inspect the host plugin

Use only the command for the current host:

```bash
claude plugin list --json
codex plugin list --available --json
```

In Cursor, inspect the installed plugin through **Cursor Settings → Plugins**.
Do not assume a Cursor plugin-list CLI command exists.

Confirm whether `portal` is installed and enabled, and record its
reported version. If the installed version is current but the visible commands
have older descriptions, recommend `/reload-plugins` in Claude Code or a new
session in the current host.

Run the corresponding plugin command with `--help` first if its JSON syntax is
not supported by the installed host version.

### 2. Verify the CLI runtime and command surface

```bash
node --version
npm --version
npx @spotify/portal-cli --help
npx @spotify/portal-cli auth --help
```

The CLI should expose `auth`, `actions`, `owner`, `search`, and `service`.
Report missing commands as a CLI-version blocker.

### 3. Inspect authentication without changing selection

```bash
npx @spotify/portal-cli auth list
npx @spotify/portal-cli auth show
```

When the user supplied an instance name, inspect it with the documented
`auth show` instance flag. When multiple instances exist and no target was
provided, report the ambiguity instead of selecting one.

Never request or print credentials, tokens, or authorization codes.

### 4. Verify read-only Portal access

```bash
npx @spotify/portal-cli actions list --json
```

Treat success as evidence that the CLI can authenticate, reach the selected
instance, and enumerate the user's available actions. Do not invoke an action.

## Report

Return a compact table with these checks:

| Check | Status | Evidence or next action |
| --- | --- | --- |
| Plugin | Ready, warning, or blocked | Installed version and reload guidance |
| CLI | Ready or blocked | Runtime and required command surface |
| Authentication | Ready, ambiguous, or blocked | Instance name and backend URL |
| Actions | Ready or blocked | Result of `actions list --json` |

Do not report overall readiness when a required check is blocked or unverified.
