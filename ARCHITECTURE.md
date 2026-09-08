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
| shell-init | login shells |
| launchctl | new GUI processes |
| measure.json (written by autoswitch) | regime, status lines, hooks |

## Invariants

1. No token in `.zshrc`, `.zprofile`, profile JSON, logs or persistent arguments.
2. An active OAuth profile is carried by `CLAUDE_CODE_OAUTH_TOKEN` in `launchctl`; a native login
   in the live slot is left in place because the environment variable wins over it.
3. An active native profile implies absence of `CLAUDE_CODE_OAUTH_TOKEN` in `launchctl`.
4. A switch never kills a process. New processes pick the active profile; running ones keep the
   account they started with, and `regime` measures the account of the session that asks.
5. Before anything displaces the native credential, the archive of the profile that owns it is
   refreshed, verified by fingerprint.
6. `doctor`, `status` and `measure` never print a secret; they use truncated SHA-256 fingerprints.
7. An unknown measurement (dead probe, stale file) never locks anything; only a measured fact
   (`rejected`, overage in use) can set `trava`.

## ADR-001: Keychain as the single vault

**Status:** accepted.

OAuth tokens live in services named `Claude Code OAuth Token - <profile>`. Archived native
credentials live in `Claude Code-credentials-<profile>-archive`. The file
`~/.config/claude-account/active` contains only the profile name.

Consequence: profile selection works for the CLI without spreading secrets; a switch reaches new
processes only, by design.

## ADR-002: detect the native binary, allow override

**Status:** accepted.

The real Claude Code binary is discovered by probing common install locations and then `PATH`
(always excluding the `~/bin/claude` wrapper itself), with `CLAUDE_NATIVE_BIN` as the explicit
override. Hardcoding a single path broke on installs done via other methods.

## ADR-003: switching never kills a process

**Status:** accepted (2026-09).

The first release restarted Orca and stopped the daemon so that persistent processes picked the
new account. On machines running background jobs and workers under `claude`, the SIGTERM broadcast
of the restart helper killed real work. The switch now touches only `launchctl` and the Keychain;
a running session keeps its account and `regime` reasons about the account of the caller, found
by fingerprinting the token in its environment. `--stop-daemon` remains available as an explicit
opt-in.

## ADR-004: measure from response headers, project from pace

**Status:** accepted (2026-09).

A setup-token has inference scope only, so the usage endpoint is not available to it. `measure`
sends a one-token request and reads the `anthropic-ratelimit-unified-*` headers instead. The
regime projects where each window lands at reset from its average pace, with a floor on the
elapsed time so a young window does not explode the estimate; the recent pace is used only for
the landing check in the last 30 minutes, because blending it into the projection made the
reserve swing wildly within half an hour.
