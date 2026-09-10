<!-- Banner -->
<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:0F0E0D,35:8C4A32,70:D97757,100:F5E6D3&height=240&section=header&text=claude-account-manager&fontSize=52&fontColor=F5E6D3&animation=fadeIn&fontAlignY=38&desc=Switch%20Claude%20Code%20accounts%20on%20macOS%20%E2%80%94%20one%20command%2C%20no%20re-login&descAlignY=60&descSize=16" />
</div>

<!-- Typing -->
<div align="center">
  <img src="https://readme-typing-svg.demolab.com?font=JetBrains+Mono&weight=600&size=21&duration=2800&pause=900&color=D97757&center=true&vCenter=true&width=840&lines=Switch+between+Claude+Code+accounts+with+one+command;Keychain-only+secrets+%E2%80%94+no+tokens+in+dotfiles;Every+auth+layer+swapped+atomically%2C+nothing+shadows+you;doctor+%C2%B7+status+%C2%B7+probe+%E2%80%94+never+print+a+secret" />
</div>

<!-- Status -->
<div align="center">
  <img src="https://img.shields.io/badge/Platform-macOS-0F0E0D?style=for-the-badge&logo=apple&logoColor=F5E6D3" />
  <img src="https://img.shields.io/badge/Secrets-Keychain%20only-D97757?style=for-the-badge&logo=apple&logoColor=white" />
  <img src="https://img.shields.io/badge/For-Claude%20Code-D97757?style=for-the-badge&logo=anthropic&logoColor=white" />
  <img src="https://img.shields.io/badge/Runtime-Bash%20%2B%20jq-8C4A32?style=for-the-badge&logo=gnubash&logoColor=F5E6D3" />
  <img src="https://img.shields.io/badge/License-MIT-25a162?style=for-the-badge" />
</div>

> **claude-account-manager** turns each of your Claude Code accounts into a named profile and switches all of them with a single command: no re-login, no reboot, no token pasted into a dotfile, no silent fallback to the wrong account. Secrets live exclusively in the macOS Keychain.

> Not affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are Anthropic trademarks.

[Leia em português](README.pt-BR.md)

<br>

## What it is

```yaml
product:     multi-account switcher for Claude Code on macOS
accounts:    named profiles — OAuth setup-token or native /login
vault:       macOS Keychain only (no secret in dotfiles, JSON or logs)
switch:      claude-account use <name> — atomic across every auth layer
layers:      Keychain slots · native slot (agents) · launchctl · ~/.claude.json · daemon · shells
safety:      every displaced credential archived first, fingerprint-verified
diagnostics: doctor · status · probe (SHA-256 fingerprints, never secrets)
extras:      optional Orca integration · CLAUDE_NATIVE_BIN override
```

## The problem

Claude Code resolves authentication through several layers at once: the `CLAUDE_CODE_OAUTH_TOKEN`
environment variable, a native credential in the Keychain (`Claude Code-credentials`), account
metadata in `~/.claude.json`, your login shells, and a background daemon. Switching just one of
those layers lets another silently win.

The classic trap: you start from a setup-token, run `/login` into a second account, and then
cannot get back to the token without rebooting, because the native credential `/login` wrote into
the Keychain shadows it.

The second trap is `claude agents`. The daemon behind it does not pass `CLAUDE_CODE_OAUTH_TOKEN` on
to the background sessions it spawns, so they authenticate from the native Keychain slot alone.
With the token only in your shell, the terminal runs on one account and every background agent on
whatever the slot holds, or on nothing. `use` therefore projects the active setup-token into that
slot too.

## Architecture

```
              ~/.config/claude-account/active          (profile name, no secret)
                              │
      claude (wrapper) ──▶ exec under active profile ──▶ real claude binary
                              │
        ┌──────────────────┬──┴──────────────────┬──────────────────┐
        ▼                  ▼                     ▼                  ▼
  macOS Keychain     native slot           launchctl env      ~/.claude.json
  profile slots   (daemon, claude agents) CLAUDE_CODE_OAUTH_TOKEN account metadata
        └──────────────────┴─────────────────────┴──────────────────┘
                              │
        claude-account use <name>  = swaps ALL of them atomically,
        archiving any login it displaces (switching never destroys a login)
```

## Quick start

```bash
git clone https://github.com/ricardo-landim/claude-account-manager.git
cd claude-account-manager
bash install.sh
```

Add the line the installer prints to your `~/.zprofile`:

```bash
[ -r "$HOME/.local/lib/claude-account-manager/shell-init.zsh" ] && \
  source "$HOME/.local/lib/claude-account-manager/shell-init.zsh"
```

Register your current `/login` as a profile, add a second account by setup-token
(run `claude setup-token` while logged into it), then switch freely:

```bash
claude-account import-native personal
claude-account add-oauth work
claude-account use work
claude-account use personal
```

> [!NOTE]
> `use` restarts the Claude daemon and [Orca](https://orca.dev) (if installed) so live processes
> switch too. `--keep-agents` keeps running background agents alive on their account (this is
> automatic when `use` runs inside an agent, which a full stop would end); `--no-restart` stops
> nothing. New shells and new agents always pick up the active profile; already-open sessions
> keep the previous account until restarted. The headless switcher (`claude-account-autoswitch`)
> always passes `--no-restart`.

## Commands

| | Command | What it does |
|:---:|---|---|
| ➕ | `add-oauth <name>` | register a profile from a setup-token (validated before storing) |
| 📥 | `import-native [name] [--last-login]` | import the current `/login` (or the last one `use` displaced) as a profile |
| 🔁 | `use <name>` | switch every auth layer to that profile, atomically, the native slot included |
| 📋 | `list` | profiles, the active one marked with `*` |
| 🩺 | `doctor` | check every auth layer for divergence |
| 📊 | `status` | active profile + fingerprints (never the secrets) |
| 🧪 | `probe` | authenticate and run a minimal inference |
| 📈 | `measure [name...]` | 5h and 7d rate-limit state per profile, read from response headers |
| 🚦 | `regime [--json]` | one word saying what the quota allows right now |
| ▶️ | `exec [args...]` | run the native binary under the active profile (what the wrapper does) |

## Rate limits, automatic switching and the quota regime

Three pieces on top of profile switching, all shell + `jq`, no new dependency.

### `measure`

Sends a one-token request to the API with each profile's token and reads the
`anthropic-ratelimit-unified-*` response headers: utilization and reset time of the 5-hour and
7-day windows, plus whether the account is paying overage. Prints fingerprints only, never a token.
A native (`/login`) profile has no setup-token to measure with; give it one from the same account:

```bash
claude-account add-oauth personal-measure --measure-for personal
```

### `claude-account-autoswitch`

A job for launchd or cron, every 5 minutes. It measures the two profiles named in
`~/.config/claude-account/policy.json`, moves the active profile to `fallback` when `preferred`
reaches the exhaustion thresholds, and returns when `preferred` has room again (hysteresis, a
minimum interval between switches and a daily cap). It also writes `measure.json` with the last
24 samples per profile, so a status line or any other reader consumes a file instead of calling
the API.

```json
{
  "preferred": "work",
  "fallback": "personal",
  "exhausted_at": {"five_hour": 0.95, "seven_day": 0.97},
  "return_below": {"five_hour": 0.70, "seven_day": 0.90},
  "min_switch_interval_min": 10,
  "max_switches_per_day": 12
}
```

Kill switch: `touch ~/.config/claude-account/autoswitch.off`. Log: `autoswitch.log`. A profile
outside the policy that you activated by hand is never overridden. Try it with `--dry-run` first.
A LaunchAgent that runs it every 5 minutes:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.claude-account.autoswitch</string>
  <key>ProgramArguments</key><array><string>/Users/YOU/bin/claude-account-autoswitch</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
```

Save it as `~/Library/LaunchAgents/local.claude-account.autoswitch.plist` and load it with
`launchctl bootstrap gui/$(id -u) <path>`.

### `regime`

One word that says what the quota allows right now, projected from the average pace of each
window of the account **this session** actually uses (a switch never moves a running session):

| Regime | Meaning |
|---|---|
| `livre` | reserve at reset is comfortable, nothing to do |
| `atencao` | on pace to land close to the limit, heads up only |
| `economia` | at this pace a window empties before it resets; heavy work is downgraded |
| `pouso` | would be `economia`, but the 5h reset is close and the recent pace fits under 100% |
| `trava` | both accounts are out (rejected or paying overage), measured as such |

A change needs two consecutive measurements, `economia` holds 15 minutes, `trava` is immediate both
ways because it is a measured fact, and a measurement older than 15 minutes (or a dead probe) never
locks anything. Override with an expiry: `regime livre --por 30m`, `regime economia --por 1h`,
`regime auto`. Under `economia` or `trava`, `exec` (and therefore the `claude` wrapper) opens the
new session with `--effort medium` unless you pass `--effort` yourself. Hooks and status lines read
`regime --json` (about 30 ms, no network). Tunables live in `policy.json` under `"regime"`.

Why a pace projection instead of a plain "usage above N%" rule: a threshold reacts late. On the
two mornings in a week of real transcripts where a 5h window went past 100%, an 80% threshold
warned 20 and 75 minutes before the crossing; the projection warned about 3 hours before, with 35
minutes of unnecessary braking in the whole week. Offline scenario tests: `tests/regime-scenarios.sh`.

## Troubleshooting

> [!WARNING]
> Once you adopt this tool, switch accounts **only** through `claude-account use`, never through
> `/login` inside Claude Code. A direct `/login` writes a native credential that shadows the
> active setup-token profile, and the state diverges silently.

If it happens anyway, `doctor` catches it, because background agents would run on that login:

```
[FAIL] a /login sits in the native slot: background agents run on that account, not on 'work' (fix: claude-account use work)
[warn] 1 of 3 open session(s) run on another account (pid 51821): restart them to use 'work'
```

The fix is one command, no reboot: `claude-account use <active-profile>`. The `/login` found in the
slot is never deleted: it is kept as `Claude Code-credentials-last-login-archive`, and
`claude-account import-native <name> --last-login` turns it into a profile. Offline scenario tests
for switching: `tests/switch-scenarios.sh`.

## Requirements

- macOS (the Keychain `security` CLI is the vault)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- `jq` (`brew install jq`)
- zsh login shells (the macOS default)

`~/bin` must come **before** your Claude Code install directory in `PATH` (the installer warns if
it does not). Unusual install location? Point at it with `CLAUDE_NATIVE_BIN=/path/to/claude`.

## Security notes

- Tokens are validated against `claude auth status` before being stored.
- `status` and `doctor` print SHA-256 fingerprints, never secrets.
- Every removal from the active Keychain slot is preceded by an archive copy, verified by
  fingerprint.
- `~/.claude.json` account metadata is backed up before being stripped.
- On machines without Orca, the restart helper is skipped entirely and nothing is killed; the
  headless switcher never restarts Orca.
- `measure` spends one output token per profile per run and prints fingerprints only.

## Docs

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — invariants and ADRs
- [`install.sh`](install.sh) — what lands where (`~/bin`, `~/.local/lib`, `~/.config`)

---

## Made by Six Quasar

**Six Quasar** builds AI agents that actually work: WhatsApp as the interface, a deterministic
core, AI at the edge. This tool was born from operating multiple Claude Code accounts across that
fleet, every day.

<a href="https://github.com/ricardo-landim"><img src="https://img.shields.io/badge/GitHub%20profile-181717?style=for-the-badge&logo=github&logoColor=white" /></a>
<a href="https://sixquasar.shop"><img src="https://img.shields.io/badge/sixquasar.shop-D97757?style=for-the-badge&logo=safari&logoColor=F5E6D3" /></a>

<!-- Footer -->
<div align="center">
  <img src="https://capsule-render.vercel.app/api?type=waving&color=0:D97757,40:8C4A32,100:0F0E0D&height=120&section=footer" />
</div>
