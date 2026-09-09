# Architecture: claude-account-manager

## Problem

Claude Code on macOS resolves authentication through more than one layer: the OAuth environment
variable, the native Keychain credential, account metadata in `~/.claude.json`, persistent login
shells and the Claude daemon. Switching only one of them allows a silent fallback to the previous
account. Since the 2026-09 revision the tool also measures the rate-limit state of each account
and can switch on its own.

## Features

- Named profiles for multiple Claude subscriptions.
- Setup-tokens stored exclusively in the Keychain.
- The active account declared in a file that holds no secret.
- Integration with login shells, `launchctl` and the Claude daemon.
- Rate-limit measurement per profile (`measure`), a headless switcher (`claude-account-autoswitch`)
  and a quota regime (`regime`) that hooks and status lines read.
- A recoverable archive of any native credential that gets displaced.
- `status`, `doctor` and `probe` that never print tokens.

## Dependencies

| Foundation | Consumers |
|---|---|
| Keychain | OAuth profiles and native archives |
| active-profile marker | wrapper, shell-init, doctor |
| shell-init | Orca and login shells |
| launchctl | new GUI processes |
| controlled restart | making the switch effective in persistent processes |
| measure.json (written by autoswitch) | regime, status lines, hooks |

## Invariants

1. No token in `.zshrc`, `.zprofile`, profile JSON, logs or persistent arguments.
2. An active OAuth profile implies absence of `Claude Code-credentials` in the native active slot.
3. An active native profile implies absence of `CLAUDE_CODE_OAUTH_TOKEN` in `launchctl`.
4. A switch only completes after the daemon stops and (when applicable) Orca restarts. The
   headless switcher passes `--no-restart` and reaches new processes only; `regime` measures the
   account of the session that asks.
5. Every removal from the active slot has a recoverable archive in the Keychain, verified by
   fingerprint. The restart helper never kills processes on a machine without Orca.
6. `doctor`, `status` and `measure` never print a secret; they use truncated SHA-256 fingerprints.
7. An unknown measurement (dead probe, stale file) never locks anything; only a measured fact
   (`rejected`, overage in use) can set `trava`.

## ADR-001: Keychain as the single vault

**Status:** accepted.

OAuth tokens live in services named `Claude Code OAuth Token - <profile>`. Archived native
credentials live in `Claude Code-credentials-<profile>-archive`. The file
`~/.config/claude-account/active` contains only the profile name.

Consequence: profile selection works for the CLI and for Orca without spreading secrets, but an
account switch requires restarting persistent processes.

## ADR-002: detect the native binary, allow override

**Status:** accepted.

The real Claude Code binary is discovered by probing common install locations and then `PATH`
(always excluding the `~/bin/claude` wrapper itself), with `CLAUDE_NATIVE_BIN` as the explicit
override. Hardcoding a single path broke on installs done via other methods.

## ADR-003: a manual switch restarts; the automatic switch never kills

**Status:** accepted (2026-09-09; supersedes the 2026-09-08 "switching never kills a process").

The first release restarted Orca and stopped the daemon so that persistent processes picked the
new account. The 2026-09-08 revision removed the restart entirely; in practice a manual
`claude-account use` that leaves every open session on the old account is not a switch, so the
restart is back as the default of `use` (`--no-restart` skips it). The exception is the headless
switcher: `claude-account-autoswitch` always passes `--no-restart`, because a SIGTERM broadcast
fired by a scheduler kills background jobs and workers. `regime` still reasons about the account
of the caller, found by fingerprinting the token in its environment.

## ADR-004: measure from response headers, project from pace

**Status:** accepted (2026-09).

A setup-token has inference scope only, so the usage endpoint is not available to it. `measure`
sends a one-token request and reads the `anthropic-ratelimit-unified-*` headers instead. The
regime projects where each window lands at reset from its average pace, with a floor on the
elapsed time so a young window does not explode the estimate; the recent pace is used only for
the landing check in the last 30 minutes, because blending it into the projection made the
reserve swing wildly within half an hour.
