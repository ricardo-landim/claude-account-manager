#!/usr/bin/env bash
# Scenario tests for `claude-account use`, `import-native`, `status` and `doctor`.
# The Keychain (`security`), `launchctl` and the Claude binary are stubbed and HOME
# is a scratch directory, so nothing here touches the real Keychain, daemon or Orca.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
CA="$here/../bin/claude-account"
unset CLAUDE_CODE_OAUTH_TOKEN
fails=0; runs=0

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
S="$W/stub"; mkdir -p "$S" "$W/kc" "$W/lc" "$W/home/bin"
export STUB_KC="$W/kc" STUB_LC="$W/lc" STUB_LOG="$W/daemon.log"
: > "$STUB_LOG"

cat > "$S/security" <<'EOF'
#!/usr/bin/env bash
op="$1"; shift; svc=""; val=""; want=false
while [ $# -gt 0 ]; do
  case "$1" in
    -s) svc="$2"; shift ;;
    -a) shift ;;
    -w) if [ "$op" = add-generic-password ]; then val="$2"; shift; else want=true; fi ;;
  esac
  shift
done
f="$STUB_KC/$(printf %s "$svc" | shasum | cut -c1-16)"
case "$op" in
  find-generic-password)
    [ -f "$f" ] || exit 44
    if $want; then cat "$f"; else printf '    "mdat"<timedate>=0x00  "%sZ\\000"\n' "$(cat "$f.mdat")"; fi ;;
  add-generic-password) printf %s "$val" > "$f"; date -u +%Y%m%d%H%M%S > "$f.mdat" ;;
  delete-generic-password) [ -f "$f" ] || exit 44; rm -f "$f" "$f.mdat" ;;
esac
EOF
cat > "$S/launchctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  setenv) printf %s "$3" > "$STUB_LC/$2" ;;
  unsetenv) rm -f "$STUB_LC/$2" ;;
  getenv) [ -f "$STUB_LC/$2" ] && cat "$STUB_LC/$2" || exit 1 ;;
esac
EOF
cat > "$S/claude" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  auth) if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then echo '{"loggedIn":true}'; else echo '{"loggedIn":false}'; fi ;;
  daemon) echo "$*" >> "$STUB_LOG" ;;
esac
EOF
chmod +x "$S/security" "$S/launchctl" "$S/claude"
printf '#!/bin/sh\n' > "$W/home/bin/claude"; chmod +x "$W/home/bin/claude"
printf 'source claude-account\n' > "$W/home/.zprofile"

ca() { HOME="$W/home" CLAUDE_ACCOUNT_HOME="$W/cfg" CLAUDE_NATIVE_BIN="$S/claude" PATH="$S:$PATH" "$CA" "$@"; }
kc_get() { PATH="$S:$PATH" security find-generic-password -a x -s "$1" -w; }
kc_put() { PATH="$S:$PATH" security add-generic-password -U -a x -s "$1" -w "$2"; }
live() { kc_get "Claude Code-credentials" | jq -r "$1"; }
fp() { printf '%s' "$1" | shasum -a 256 | cut -c1-12; }
check() {  # <name> <expected> <got>
  runs=$((runs + 1))
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}

# Two setup-token profiles, one native profile, and a stray /login in the live slot.
mkdir -p "$W/cfg/profiles"
kc_put "Claude Code OAuth Token - work" "sk-ant-oat01-WORK"
kc_put "Claude Code OAuth Token - home" "sk-ant-oat01-HOME"
kc_put "Claude Code-credentials-personal-archive" '{"claudeAiOauth":{"accessToken":"A1","refreshToken":"R1"}}'
kc_put "Claude Code-credentials-empty-archive" '{"mcpOAuth":{}}'
for p in work home; do
  printf '{"version":2,"name":"%s","type":"oauth_token","keychainService":"Claude Code OAuth Token - %s","label":"%s"}' "$p" "$p" "$p" > "$W/cfg/profiles/$p.json"
done
for p in personal empty; do
  printf '{"version":2,"name":"%s","type":"native_archive","keychainService":"Claude Code-credentials-%s-archive","label":"%s"}' "$p" "$p" "$p" > "$W/cfg/profiles/$p.json"
done
printf 'work\n' > "$W/cfg/active"
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"L1","refreshToken":"R9"},"mcpOAuth":{"srv":1}}'

set +e
out="$(ca doctor)"; rc=$?
set -e
check "doctor fails while a /login sits in the slot" 1 "$rc"
check "doctor names the /login" 1 "$(printf '%s' "$out" | grep -c 'a /login sits in the native slot')"

ca use work >/dev/null
check "use work: slot carries the work token" "sk-ant-oat01-WORK" "$(live .claudeAiOauth.accessToken)"
check "use work: projected token has no refresh token" "null" "$(live .claudeAiOauth.refreshToken)"
check "use work: MCP OAuth kept" "1" "$(live .mcpOAuth.srv)"
check "use work: stray /login archived" "L1" "$(kc_get 'Claude Code-credentials-last-login-archive' | jq -r .claudeAiOauth.accessToken)"
check "use work: launchctl carries the work token" "sk-ant-oat01-WORK" "$(cat "$STUB_LC/CLAUDE_CODE_OAUTH_TOKEN")"
# Run from inside a background agent, `use` keeps the workers so it does not end itself.
expected_stop="daemon stop --any"
pid=$$
while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
  case "$(ps -o command= -p "$pid" 2>/dev/null || true)" in
    *"daemon run"*|*bg-pty-host*) expected_stop="daemon stop --any --keep-workers"; break ;;
  esac
  pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
done
check "use work: daemon restarted ($expected_stop)" "$expected_stop" "$(tail -1 "$STUB_LOG")"
check "doctor passes after use" 1 "$(ca doctor | grep -c '\[ok\] native slot carries the active profile token')"
check "status reports the projected slot" "native_slot=token" "$(ca status | grep '^native_slot=')"
check "status fingerprint matches the profile" "native_fingerprint=$(fp sk-ant-oat01-WORK)" "$(ca status | grep '^native_fingerprint=')"

lines="$(wc -l < "$STUB_LOG")"
ca use home --no-restart >/dev/null
check "use --no-restart: slot carries the home token" "sk-ant-oat01-HOME" "$(live .claudeAiOauth.accessToken)"
check "use --no-restart: daemon untouched" "$lines" "$(wc -l < "$STUB_LOG")"
check "use --no-restart: last-login archive not overwritten by a projection" "L1" "$(kc_get 'Claude Code-credentials-last-login-archive' | jq -r .claudeAiOauth.accessToken)"

ca use personal --keep-agents >/dev/null
check "use native: slot carries the archived login" "A1" "$(live .claudeAiOauth.accessToken)"
check "use native: MCP OAuth kept" "1" "$(live .mcpOAuth.srv)"
check "use native: launchctl token removed" "absent" "$([ -f "$STUB_LC/CLAUDE_CODE_OAUTH_TOKEN" ] && echo present || echo absent)"
check "use --keep-agents: workers kept" "daemon stop --any --keep-workers" "$(tail -1 "$STUB_LOG")"

# The native login rotates its tokens while active; leaving it refreshes its archive.
kc_put "Claude Code-credentials" '{"claudeAiOauth":{"accessToken":"A2","refreshToken":"R2"},"mcpOAuth":{"srv":1}}'
ca use work >/dev/null
check "leaving a native profile refreshes its archive" "A2" "$(kc_get 'Claude Code-credentials-personal-archive' | jq -r .claudeAiOauth.accessToken)"

set +e
ca use empty >/dev/null 2>&1; rc=$?
set -e
check "use refuses an archive without a /login" 1 "$rc"
check "refused use leaves the slot untouched" "sk-ant-oat01-WORK" "$(live .claudeAiOauth.accessToken)"

set +e
ca import-native bogus >/dev/null 2>&1; rc=$?
set -e
check "import-native refuses a projected setup-token" 1 "$rc"
ca import-native saved --last-login >/dev/null
check "import-native --last-login creates the profile" "native_archive" "$(jq -r .type "$W/cfg/profiles/saved.json")"
check "import-native --last-login copies the stray /login" "L1" "$(kc_get 'Claude Code-credentials-saved-archive' | jq -r .claudeAiOauth.accessToken)"

# A setup-token lives one year from when it was written: the projection carries that expiry, so the
# daemon never refreshes (and drops) a credential that still works, and doctor warns 30 days ahead.
kc_set_written() { printf '%s\n' "$2" > "$STUB_KC/$(printf %s "$1" | shasum | cut -c1-16).mdat"; }
ca use work --no-restart >/dev/null
written="$(date -j -u -f '%Y%m%d%H%M%S' "$(cat "$STUB_KC/$(printf %s 'Claude Code OAuth Token - work' | shasum | cut -c1-16).mdat")" +%s)"
check "projection expires one year after the token was written" "$(( (written + 364 * 86400) * 1000 ))" "$(live .claudeAiOauth.expiresAt)"
check "doctor reports a fresh token as valid" 1 "$(ca doctor | grep -c "\[ok\] setup-token of 'work' valid until about")"
kc_set_written "Claude Code OAuth Token - home" "$(date -u -v-340d +%Y%m%d%H%M%S)"
check "doctor warns 30 days before the token dies" 1 "$(ca doctor | grep -c "\[warn\] setup-token of 'home' expires around")"
kc_set_written "Claude Code OAuth Token - home" "$(date -u -v-400d +%Y%m%d%H%M%S)"
set +e
out="$(ca doctor)"; rc=$?
set -e
check "doctor fails on an expired token" 1 "$(printf '%s' "$out" | grep -c "\[FAIL\] setup-token of 'home' expired around")"
check "an expired token fails the doctor" 1 "$rc"

printf '%d/%d passed\n' "$((runs - fails))" "$runs"
[ "$fails" -eq 0 ]
