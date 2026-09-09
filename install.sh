#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LIB="$HOME/.local/lib/claude-account-manager"
BIN="$HOME/bin"
CONFIG="$HOME/.config/claude-account"

command -v security >/dev/null 2>&1 || {
  echo "ERROR: 'security' CLI not found. This tool is macOS-only (it stores secrets in the Keychain)." >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is required. Install it with: brew install jq" >&2
  exit 1
}

mkdir -p "$LIB" "$BIN" "$CONFIG/profiles"
chmod 700 "$LIB" "$CONFIG" "$CONFIG/profiles"

install -m 700 "$ROOT/bin/claude-account" "$BIN/claude-account"
install -m 700 "$ROOT/bin/claude-account-autoswitch" "$BIN/claude-account-autoswitch"
install -m 700 "$ROOT/bin/claude-account-regime" "$BIN/claude-account-regime"
install -m 700 "$ROOT/bin/claude" "$BIN/claude"
install -m 600 "$ROOT/lib/shell-init.zsh" "$LIB/shell-init.zsh"

if [ -d "/Applications/Orca.app" ] || [ -d "$HOME/Applications/Orca.app" ]; then
  install -m 700 "$ROOT/lib/restart-orca.sh" "$LIB/restart-orca.sh"
  echo "Orca detected: restart helper installed."
else
  rm -f "$LIB/restart-orca.sh"
  echo "Orca not detected: restart helper skipped. After switching accounts, restart your terminal sessions."
fi

echo "Installed: $BIN/claude-account, $BIN/claude-account-regime, $BIN/claude-account-autoswitch, $BIN/claude (wrapper)."
echo
echo "Shell integration: if your shell already defines a claude() function (claude-stable"
echo "setups), route it through the profile: CLAUDE_NATIVE_BIN=\"\$bin\" \"\$HOME/bin/claude-account\" exec ..."
echo "Otherwise add to ~/.zprofile:"
# shellcheck disable=SC2016
printf '  [ -r "$HOME/.local/lib/claude-account-manager/shell-init.zsh" ] && source "$HOME/.local/lib/claude-account-manager/shell-init.zsh"\n'
echo
echo "Automatic switching is opt-in: write $CONFIG/policy.json and schedule"
echo "$BIN/claude-account-autoswitch every 5 minutes (launchd or cron); see README."

resolved="$(command -v claude 2>/dev/null || true)"
if [ "$resolved" != "$BIN/claude" ]; then
  echo
  echo "WARNING: 'claude' currently resolves to: ${resolved:-nothing}"
  echo "Make sure $BIN comes BEFORE it in your PATH, otherwise the profile wrapper never runs."
fi
