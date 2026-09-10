# Architecture: claude-account-manager

## Problem

Claude Code on macOS resolves authentication through more than one layer: the OAuth environment
variable, the native Keychain credential, account metadata in `~/.claude.json`, persistent login
shells and the Claude daemon. Switching only one of them allows a silent fallback to the previous
account. The daemon behind `claude agents` does not pass `CLAUDE_CODE_OAUTH_TOKEN` on to the
background sessions it spawns (measured on Claude Code 2.1.267: the variable is present in the
session that started the daemon and absent from the daemon and from every background session), so
those sessions authenticate from the native Keychain slot alone. Since the 2026-09 revision the
tool also measures the rate-limit state of each account and can switch on its own.

## Features

- Named profiles for multiple Claude subscriptions.
- Setup-tokens stored exclusively in the Keychain.
- The active account declared in a file that holds no secret.
- Integration with login shells, `launchctl` and the Claude daemon.
- Rate-limit measurement per profile (`measure`), a headless switcher (`claude-account-autoswitch`)
  and a quota regime (`regime`) that hooks and status lines read.
- The active OAuth profile projected into the native Keychain slot, so background agents run on
  the same account as the terminal.
- A recoverable archive of any native credential that gets displaced.
- `status`, `doctor` and `probe` that never print tokens.

## Dependencies

| Foundation | Consumers |
|---|---|
| Keychain | OAuth profiles and native archives |
| active-profile marker | wrapper, shell-init, doctor |
| shell-init | Orca and login shells |
| launchctl | new GUI processes |
| native Keychain slot (projected) | daemon, background agents, any session without the env var |
| controlled restart | making the switch effective in persistent processes |
| measure.json (written by autoswitch) | regime, status lines, hooks |

## Invariants

1. No token in `.zshrc`, `.zprofile`, profile JSON, logs or persistent arguments.
2. An active OAuth profile implies that the native slot `Claude Code-credentials` carries that
   profile's token as a projected credential (no refresh token), with every other key of the blob
   kept. `doctor` fails on anything else in the slot (a stray `/login`, an empty slot, another
   token), because that is the account background agents would run on.
3. An active native profile implies absence of `CLAUDE_CODE_OAUTH_TOKEN` in `launchctl`.
4. A default switch restarts the daemon and (when applicable) Orca. Running agents are kept on
   their account with `--keep-agents`, and always when `use` runs inside an agent (a full stop
   would end the caller). `--no-restart` stops nothing, and the headless switcher always passes
   it; `regime` measures the account of the session that asks.
5. Every real login removed from the active slot has a recoverable archive in the Keychain,
   verified by fingerprint: the archive of the active native profile, or
   `Claude Code-credentials-last-login-archive` for a `/login` done inside Claude Code. The
   restart helper never kills processes on a machine without Orca.
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

## ADR-005: the native slot is a projection of the active profile

**Status:** accepted (2026-09-10; supersedes "an OAuth profile removes the native slot").

Removing the native slot was meant to stop a stale `/login` from shadowing the setup-token. It
did that for the terminal, where the environment variable wins anyway, and it left the daemon
behind `claude agents` with no credential at all, because the daemon does not pass the variable
on. The usual reaction, a `/login` inside Claude Code, then put a third account in the slot:
terminal, profile and agents each on a different account.

`use` now writes the OAuth profile into the slot in the shape of a native login: the setup-token
as access token, no refresh token and the token's own expiry, one year from when the Keychain item
was written. The expiry matters only to the daemon: a plain session with no refresh token never
tries to refresh, even past the expiry, but the daemon refreshes when the expiry is near, fails
without a refresh token and drops the credential ("proactive refresh failed, signalling re-auth
required" in its log). An expiry earlier than the token's would break the agents while the token
still works; `doctor` warns 30 days before a setup-token turns one year old. Measured before adopting it: a session with no environment variable and only that
credential reports `authMethod: claude.ai`, completes an inference and leaves the credential
untouched. Other keys of the blob (MCP server OAuth) are kept on every write. A real `/login`
found in the slot is archived, never overwritten. The price is an undocumented credential shape;
if a future CLI rejects it, `doctor` shows the agents failing and the old removal is one revert
away.

## ADR-004: measure from response headers, project from pace

**Status:** accepted (2026-09).

A setup-token has inference scope only, so the usage endpoint is not available to it. `measure`
sends a one-token request and reads the `anthropic-ratelimit-unified-*` headers instead. The
regime projects where each window lands at reset from its average pace, with a floor on the
elapsed time so a young window does not explode the estimate; the recent pace is used only for
the landing check in the last 30 minutes, because blending it into the projection made the
reserve swing wildly within half an hour.
