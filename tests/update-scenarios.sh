#!/usr/bin/env bash
# Scenario tests for `claude-account update`. The native installer, codesign, the
# registry and the daemon are stubbed under a scratch HOME, so nothing here touches the
# real Claude Code install, its daemon or the background sessions.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
CA="$here/../bin/claude-account"
fails=0; runs=0

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
R="$W/home/.local"; S="$W/stub"
mkdir -p "$R/bin" "$R/share/claude/versions" "$S" "$W/home/.claude" "$W/cfg/profiles"
export STUB_ROOT="$R" STUB_LOG="$W/install.log" STUB_AGENTS="$W/agents.json"
: > "$STUB_LOG"
echo '[{"kind":"background","id":"a1","sessionId":"s1","status":"idle"},{"kind":"background","id":"a2","sessionId":"s2","status":"busy"},{"kind":"interactive","id":"t1"}]' > "$STUB_AGENTS"

# One stub plays every version: `install <v>` lays down versions/<v> and points claude at it.
cat > "$W/claude-stub" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  install)
    echo "install $2" >> "$STUB_LOG"
    [ -z "${STUB_INSTALL_FAIL:-}" ] || exit 1
    cp "$0" "$STUB_ROOT/share/claude/versions/$2"
    ln -sfn "$STUB_ROOT/share/claude/versions/$2" "$STUB_ROOT/bin/claude" ;;
  --version) echo "$(basename "$(readlink "$STUB_ROOT/bin/claude")") (Claude Code)" ;;
  agents) cat "$STUB_AGENTS" ;;
esac
EOF
chmod +x "$W/claude-stub"
printf '#!/bin/sh\nexit 0\n' > "$S/codesign"; chmod +x "$S/codesign"
# The restart after an update must never reach the real Keychain or launchd.
printf '#!/bin/sh\nexit 44\n' > "$S/security"; printf '#!/bin/sh\nexit 0\n' > "$S/launchctl"; chmod +x "$S/security" "$S/launchctl"
jq -n '{version:2,name:"nat",type:"native_archive",keychainService:"x-archive",label:"nat"}' > "$W/cfg/profiles/nat.json"
echo nat > "$W/cfg/active"
cp "$W/claude-stub" "$R/share/claude/versions/2.1.301"
ln -sfn "$R/share/claude/versions/2.1.301" "$R/bin/claude"
cp "$W/claude-stub" "$R/bin/claude-stable"
printf '%s' "$R/share/claude/versions/2.1.301" > "$R/share/claude/.stable-src"
echo '{"version":"2.1.310"}' > "$W/latest.json"
DLOG="$W/home/.claude/daemon.log"; : > "$DLOG"

envs=(HOME="$W/home" PATH="$S:$PATH" CLAUDE_ACCOUNT_HOME="$W/cfg" CLAUDE_NATIVE_BIN="$R/bin/claude-stable"
      CLAUDE_INSTALL_ROOT="$R" CLAUDE_ACCOUNT_UPDATE_REGISTRY="file://$W/latest.json"
      CLAUDE_ACCOUNT_DAEMON_LOG="$DLOG" CLAUDE_ACCOUNT_UPDATE_WAIT=5)
ca() { env "${envs[@]}" "$CA" "$@"; }
check() {
  runs=$((runs + 1))
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$2], got [$3]"; fails=$((fails + 1)); fi
}
inode() { stat -f %i "$R/bin/claude-stable"; }
# The daemon restarts once claude-stable becomes a new file, as the real one does.
fake_daemon() { # dead count
  local before n=0; before="$(inode)"
  ( while [ "$(inode)" = "$before" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
    [ "$(inode)" = "$before" ] && exit 0
    printf '[t] [supervisor] shutting down (cause=upgrade)\n[t] [bg] bg adopt: adopted=2 respawned=0 dead=%s\n' "$1" >> "$DLOG" ) &
}

out="$(ca update)"; rc=$?
check "check: exit 0" 0 "$rc"
check "check: installed, stable and latest" "2.1.301 2.1.301 2.1.310" \
  "$(printf '%s\n' "$out" | awk -F': ' '/^installed:/{a=$2} /^stable:/{b=$2} /^latest:/{c=$2} END{print a, b, c}')"
check "check: counts background sessions only" 2 "$(printf '%s\n' "$out" | awk -F': ' '/^background_sessions:/{print $2}')"
check "check: points at --apply" 1 "$(printf '%s\n' "$out" | grep -c 'help: claude-account update --apply')"
check "check: installs nothing" 0 "$(wc -l < "$STUB_LOG" | tr -d ' ')"

old_inode="$(inode)"
fake_daemon 0
set +e; out="$(ca update --no-restart --apply)"; rc=$?; set -e; wait
check "apply: exit 0" 0 "$rc"
check "apply: the installer ran for the latest" "install 2.1.310" "$(tail -1 "$STUB_LOG")"
check "apply: claude points at the new version" "$R/share/claude/versions/2.1.310" "$(readlink "$R/bin/claude")"
check "apply: claude-stable runs the new version" "2.1.310 (Claude Code)" "$("$R/bin/claude-stable" --version)"
check "apply: claude-stable is a new file, not rewritten in place" 1 "$([ "$(inode)" != "$old_inode" ] && echo 1 || echo 0)"
check "apply: the stable marker follows" "$R/share/claude/versions/2.1.310" "$(cat "$R/share/claude/.stable-src")"
check "apply: no temp copy left" 0 "$(find "$R/bin" -name '.claude-stable.tmp.*' | wc -l | tr -d ' ')"
check "apply: reports the adoption" 1 "$(printf '%s\n' "$out" | grep -c 'daemon: restarted, adopted=2 respawned=0 dead=0')"

set +e; out="$(ca update --no-restart --apply)"; rc=$?; set -e
check "apply when current: no-op, exit 0" "0 1" "$rc $(printf '%s\n' "$out" | grep -c 'unchanged')"
check "apply when current: the installer does not run" 1 "$(wc -l < "$STUB_LOG" | tr -d ' ')"

fake_daemon 0
set +e; ca update --no-restart --apply 2.1.301 >/dev/null 2>&1; rc=$?; set -e; wait
check "apply of a named version (rollback)" "0 $R/share/claude/versions/2.1.301" "$rc $(readlink "$R/bin/claude")"

stable_before="$(inode)"
set +e; out="$(env STUB_INSTALL_FAIL=1 "${envs[@]}" "$CA" update --no-restart --apply 2.1.310 2>&1)"; rc=$?; set -e
check "installer fails: exit 1 and says so" "1 1" "$rc $(printf '%s\n' "$out" | grep -c "'claude install 2.1.310' failed")"
check "installer fails: claude and claude-stable untouched" "$R/share/claude/versions/2.1.301 $stable_before" "$(readlink "$R/bin/claude") $(inode)"

fake_daemon 1
set +e; out="$(ca update --no-restart --apply 2.1.310)"; rc=$?; set -e; wait
check "a session died in the handover: exit 1 and points at claude-sessions" "1 1" "$rc $(printf '%s\n' "$out" | grep -c 'help: claude-sessions')"

set +e; out="$(env "${envs[@]}" CLAUDE_ACCOUNT_UPDATE_WAIT=1 "$CA" update --no-restart --apply 2.1.301)"; rc=$?; set -e
check "sessions running and no adoption reported: exit 1" "1 1" "$rc $(printf '%s\n' "$out" | grep -c 'no adoption of the sessions reported')"

# The log was rotated after the offset was taken: the adoption line is still found.
: > "$DLOG"; printf '%0500d\n' 0 > "$DLOG"
before="$(inode)"
( while [ "$(inode)" = "$before" ]; do sleep 0.1; done
  : > "$DLOG"; printf '[t] [bg] bg adopt: adopted=2 respawned=0 dead=0\n' >> "$DLOG" ) &
set +e; out="$(ca update --no-restart --apply 2.1.310)"; rc=$?; set -e; wait
check "daemon log rotated mid-update: the adoption is still read" "0 1" "$rc $(printf '%s\n' "$out" | grep -c 'adopted=2')"

# Re-signing fails: the unsigned copy never replaces claude-stable.
printf '#!/bin/sh\ncase "$1" in --remove-signature) exit 0 ;; esac\nexit 1\n' > "$S/codesign"
stable_before="$(inode)"
set +e; out="$(ca update --no-restart --apply 2.1.301 2>&1)"; rc=$?; set -e
check "re-signing fails: exit 1, claude-stable untouched" "1 $stable_before" "$rc $(inode)"
check "re-signing fails: no temp copy left" 0 "$(find "$R/bin" -name '.claude-stable.tmp.*' | wc -l | tr -d ' ')"
check "re-signing fails: the check says claude-stable is behind" 1 "$(ca update | grep -c 'claude-stable is behind')"
printf '#!/bin/sh\nexit 0\n' > "$S/codesign"
fake_daemon 0
set +e; ca update --no-restart --apply 2.1.301 >/dev/null 2>&1; rc=$?; set -e; wait
check "then --apply with the version installed refreshes claude-stable" "0 2.1.301" "$rc $(basename "$(cat "$R/share/claude/.stable-src")")"

# Default --apply: after the adoption, every session restarts on the new version, as a switch does.
fake_daemon 0
set +e; out="$(ca update --apply 2.1.310)"; rc=$?; set -e; wait
check "apply restarts the sessions after the adoption" "0 1" "$rc $(printf '%s\n' "$out" | grep -c 'bg-restart: moving 2 background session')"
check "apply restart: snapshot of the sessions taken" 2 "$(jq length "$W/cfg/bg-restart.json" 2>/dev/null || echo 0)"
check "apply restart: says how to restart the terminals when Orca is absent" 1 "$(printf '%s\n' "$out" | grep -c 'restart your terminal sessions')"
rm -f "$W/cfg/bg-restart.json"
fake_daemon 1
set +e; out="$(ca update --apply 2.1.301)"; rc=$?; set -e; wait
check "a session died: no restart on top of it" "1 0" "$rc $(printf '%s\n' "$out" | grep -c 'bg-restart: moving')"
set +e; ca update --no-restart >/dev/null 2>&1; rc=$?; set -e
check "--no-restart without --apply: usage error" 2 "$rc"
check "--no-restart leaves them running" 1 "$(ca update --no-restart --apply 2.1.301 | grep -c 'unchanged')"

echo '{}' > "$W/latest.json"
set +e; out="$(ca update --no-restart --apply 2>&1)"; rc=$?; set -e
check "registry without an answer: --apply asks for the version" "1 1" "$rc $(printf '%s\n' "$out" | grep -c 'name the version')"
check "registry without an answer: the check still works" "0 1" "$(ca update >/dev/null 2>&1; echo $?) $(ca update | grep -c 'latest: unknown')"

set +e; ca update 2.1.310 >/dev/null 2>&1; rc1=$?; ca update --no-restart --apply x.y >/dev/null 2>&1; rc2=$?; ca update --now >/dev/null 2>&1; rc3=$?; set -e
check "usage errors exit 2" "2 2 2" "$rc1 $rc2 $rc3"

rm "$R/bin/claude"; cp "$W/claude-stub" "$R/bin/claude"
set +e; out="$(ca update 2>&1)"; rc=$?; set -e
check "not the native installer's link: refused" "1 1" "$rc $(printf '%s\n' "$out" | grep -c "not the native installer's link")"

echo "$runs cases, $fails failures"
[ "$fails" -eq 0 ]
