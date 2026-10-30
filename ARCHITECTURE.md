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
   token), because that is the account background agents would run on. The exception is an OAuth
   profile with a full login of its own (`secureStorageDir`, ADR-006): it never touches the slot,
   and `launchctl` carries `CLAUDE_SECURESTORAGE_CONFIG_DIR` instead of the token.
3. An active native profile implies absence of `CLAUDE_CODE_OAUTH_TOKEN` and of
   `CLAUDE_SECURESTORAGE_CONFIG_DIR` in `launchctl`.
4. A default switch moves background sessions to the new account (ADR-007) and restarts Orca
   when applicable. `--keep-agents` leaves them on their account. `--no-restart` stops nothing;
   the headless switcher passes `--no-restart --move-agents`, which moves them only once none is
   busy, and only when the policy opts in with `"move_agents": true`. `regime` measures the
   account of the session that asks.
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

## ADR-006: a full login per OAuth profile, in its own Keychain item

**Status:** accepted (2026-10-07).

A setup-token has inference scope only. Claude Code runs on it, but the claude.ai connectors
(Drive, Gmail, Granola and the rest) never load under it: `claude mcp list` shows the local MCP
servers and none of the `claude.ai ...` ones, while the native `/login` of another account on the
same machine lists them all. The account has the connectors; the credential cannot reach them.

Claude Code derives the name of its credential item from `CLAUDE_SECURESTORAGE_CONFIG_DIR`
(`Claude Code-credentials-<sha256(dir)[0:8]>`) without moving the configuration directory, so
settings, hooks and MCP configuration stay shared. `login <name>` runs `claude auth login` once
with that variable pointing to `~/.config/claude-account/logins/<name>`, checks the e-mail against
the profile's `account`, and records `secureStorageDir` in the profile. From then on that profile
exports the variable instead of the token, Claude Code keeps refreshing the login in its own
item, and switching never asks for a browser again. The setup-token stays in the profile for
`measure`.

Claude Code forwards this variable to the daemon's background sessions (it shows up in the
`providerEnv` of `~/.claude/jobs/<id>/state.json`) while it drops the OAuth token, which is why
such a profile needs nothing projected into the native slot (ADR-005 still applies to plain
setup-token profiles). Measured on 2.1.287: after `login`, `mcp list` under the profile shows the
nine `claude.ai` connectors, a background session resumed under it answers a Granola call with
that account's workspace, and the native slot's modification date does not move.

Side effects: `claude auth login` rewrites `oauthAccount` in `~/.claude.json`, so the account
shown by `auth status` follows the last login (display only). Going back to a native profile
after a full-login one archives the live `/login` instead of restoring the older archive over it:
the slot was never displaced, its refresh token kept rotating, and the archive is the stale copy.
`use` and `doctor` validate the full login itself (signed in, recorded e-mail) before anything
moves. Rejected: two `native_archive` profiles sharing the native slot, because a session of one
account refreshing its token overwrites the other account's login.

## ADR-007: background sessions are moved, not killed

**Status:** accepted (2026-10-07; amends ADR-003 for background sessions).

The daemon behind `claude agents` keeps the environment of whoever started it, so a switch
reached background sessions only through a daemon stop, which ended them. `bg-restart` moves them
instead:

1. Snapshot the live background sessions (`claude agents --json`); a failure there is an error
   that keeps the move pending, never "zero sessions".
2. If one is `busy` or `shell` (alive with a background shell), defer: write
   `bg-restart.pending`; with `"move_agents": true` in the policy the autoswitch cycle finishes
   the move once all are idle. Nothing headless ever forces a busy session (ADR-003);
   a manual `use` or `login` forces the move (a busy session is cut and resumed with the wake
   prompt, by decision of the operator, 2026-10-09), as does `bg-restart --force`.
3. A detached worker (double fork plus `setsid`, because the caller is often one of the sessions
   about to stop) holds a lock, stops the daemon from the new profile's environment and resumes
   each session with `claude --bg --resume <sessionId> "<wake prompt>"`. A prompt alone keeps the
   session id; any extra flag (`-n`, `--model`) makes Claude Code open a copy under a new id.
4. The daemon resumes a conversation into the job whose short id is the session id prefix; a
   session that had lived under another job comes back with no saved flags, without its name and
   in the default permission mode. The worker compares each session with the snapshot and, when
   the name differs or bypass is missing while the global default is `bypassPermissions`, writes
   `respawnFlags` in `state.json` and runs `claude respawn <id>`, which restarts that one session
   with those flags and keeps its id.

The wake prompt tells each session that its monitors and background shells died in the restart.
A session whose identity had to be restored is respawned a few seconds after its resume, which
cuts the wake turn short; the prompt stays in its transcript. The live slot's owner is recorded
in `native-owner` (set when a native profile becomes active, cleared when a setup-token is
projected), so the /login there is always archived into the profile it belongs to. `lib/
restart-orca.sh` skips the daemon, background sessions and in-flight `--bg` clients.
`claude-sessions` exposes the same mechanics one session at a time (create, resume, rename,
colour, mode, stop), always on the active profile, so nothing needs to start the daemon with a
bare `claude --bg` from an environment that may hold another account.

## ADR-008: updating Claude Code goes through the daemon's own handover

`update --apply` runs the native installer (`claude install <version>`, which works with
`DISABLE_AUTOUPDATER` set), checks that the `claude` link points at the new version, and then
replaces `claude-stable`, the signed copy at a fixed path that keeps the macOS permission grants
across versions. The copy is signed in a temp file and renamed over the old one: rewriting the
file in place gets the daemon and its workers killed (Code Signature Invalid) on the next page-in.
The daemon runs from `claude-stable`, notices the new file, restarts itself and adopts the
running sessions; the 2.1.299 to 2.1.301 update on 2026-10-16 logged `adopted=19 respawned=0
dead=0`, and the adopted workers stay on the old version until they go idle. The command reads
that `bg adopt:` line from `daemon.log` and fails when a session died. A failed install changes
nothing, `claude-stable` included.

Adopted sessions keep running the binary they started with, so after the adoption the update
restarts them the way a switch of account does (`bg-restart --force`: same ids, a busy one comes
back with the wake prompt) and restarts Orca, and everything runs the new version at once.
`--no-restart` leaves them on the old version until they go idle. When a session died in the
handover, nothing is restarted on top of it.

**Rejected.** Turning the auto-updater back on: it would restart the daemon at an hour nobody
chose, under the sessions running at that moment.
