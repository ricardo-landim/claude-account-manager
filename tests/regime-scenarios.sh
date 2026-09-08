#!/usr/bin/env bash
# Scenario tests for claude-account-regime. Each case builds a measure.json in
# a scratch CLAUDE_ACCOUNT_HOME and checks the regime word. Pure: no network.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
REGIME="$here/../bin/claude-account-regime"
now=$(date -u +%s)
fails=0; runs=0
# The runner's own session token must not leak into the cases (11e sets it on purpose).
unset CLAUDE_CODE_OAUTH_TOKEN
homes=()
trap 'rm -rf "${homes[@]}"' EXIT

setup() {  # fresh home with policy and active account
  H="$(mktemp -d)"; export CLAUDE_ACCOUNT_HOME="$H"; homes+=("$H")
  printf '{"preferred":"work","fallback":"personal","regime":{"hyst":2,"hold_min":15}}' > "$H/policy.json"
  printf 'work' > "$H/active"
}
# measure <u5> <left5_s> <u7> <left7_s> <status> <overage_in_use> <o5> <o7> <ostatus> [hist "u1 u2 u3"] [age_s]
measure() {
  local age="${11:-60}" hist="${10:-}"
  local at; at=$(date -u -r $(( now - age )) +%Y-%m-%dT%H:%M:%SZ)
  local h='[]'
  if [ -n "$hist" ]; then
    # samples 5 min apart, the last one at now-300: [[ts, util], ...]
    h=$(printf '%s' "$hist" | jq -R -c --argjson n "$now" 'split(" ") | map(select(length > 0) | tonumber) | length as $k | to_entries | map([$n - 300 * ($k - .key), .value])')
  fi
  jq -n --arg at "$at" --argjson n "$now" --argjson u5 "$1" --argjson l5 "$2" --argjson u7 "$3" --argjson l7 "$4" --arg st "$5" --argjson ov "$6" \
        --argjson o5 "$7" --argjson o7 "$8" --arg ost "$9" --argjson h "$h" '
    {measured_at: $at,
     profiles: {work: {status: $st, overage_in_use: $ov, util_5h: $u5, reset_5h: ($n + $l5), util_7d: $u7, reset_7d: ($n + $l7)},
                "personal": {status: $ost, overage_in_use: false, util_5h: $o5, reset_5h: ($n + 18000), util_7d: $o7, reset_7d: ($n + 604800 - 86400)}},
     history: {work: $h}}' > "$H/measure.json"
}
expect() {  # <name> <expected regime>
  runs=$((runs + 1))
  local got; got=$("$REGIME" --json | jq -r .regime)
  if [ "$got" = "$2" ]; then printf 'ok   %-58s %s\n' "$1" "$got"
  else printf 'FAIL %-58s expected %s, got %s\n' "$1" "$2" "$got"; "$REGIME"; fails=$((fails + 1)); fi
}
tick() { "$REGIME" --json >/dev/null; }   # one read = one measurement consumed

# 1. livre: 20% with 2h left (60% elapsed), weekly calm
setup; measure 20 7200 12 400000 allowed false 0 9 allowed; expect "livre: 20% with 2h left" livre
# 2. atencao: on pace (50% at half window) -> reserve 0..25
setup; measure 50 9000 30 300000 allowed false 0 9 allowed; tick; measure 51 8900 30 300000 allowed false 0 9 allowed "" 30; expect "atencao: 50% at half window" atencao
# 3. economia needs two measurements (hysteresis): 60% with 30% elapsed, fallback exhausted
setup; measure 60 12600 40 200000 allowed false 96 9 rejected; expect "economia: first measurement still holds livre" livre
measure 61 12500 40 200000 allowed false 96 9 rejected "" 30; expect "economia: second measurement confirms" economia
# 4. same but fallback fresh: pool softens to atencao
setup; measure 60 12600 40 200000 allowed false 0 9 allowed; tick; measure 61 12500 40 200000 allowed false 0 9 allowed "" 30; expect "pool with room softens to atencao" atencao
# 5. pouso: 95% with 25 min left projects 104% on average pace, but recent pace is flat: fits
setup; measure 95 1800 40 200000 allowed false 96 9 rejected "95 95 95 95 95 95"; tick; measure 95 1500 40 200000 allowed false 96 9 rejected "95 95 95 95 95 95" 30; expect "pouso: 95% with 25 min left, recent pace flat" pouso
# 6. no pouso when it does not fit: 95% with 25 min left and +4 pts per 5 min
setup; measure 91 2100 40 200000 allowed false 96 9 rejected "71 75 79 83 87 91"; tick; measure 95 1500 40 200000 allowed false 96 9 rejected "75 79 83 87 91 95" 30; expect "no pouso: 95% with 25 min left and +4 pts per 5 min" economia
# 5b. no pouso when the weekly window also projects exhaustion
setup; measure 95 1800 92 200000 allowed false 96 9 rejected "95 95 95 95 95 95"; tick; measure 95 1500 92 199700 allowed false 96 9 rejected "95 95 95 95 95 95" 30; expect "no pouso: the weekly window exhausts too" economia
# 6b. 90% with 5 min left and heavy use: projection lands at 90, no brake at all
setup; measure 88 600 40 200000 allowed false 96 9 rejected "80 82 84 86 88 88"; tick; measure 90 300 40 200000 allowed false 96 9 rejected "82 84 86 88 90 90" 30; expect "90% with 5 min left: atencao, no brake" atencao
# 7. trava: active paying overage, other rejected (immediate, no hysteresis)
setup; measure 100 3000 50 200000 allowed true 98 30 rejected; expect "trava: active paying overage, fallback rejected" trava
# 7a. leaving trava is immediate once both accounts measure allowed again
setup; measure 100 3000 50 200000 allowed true 98 30 rejected; tick; measure 20 7200 12 400000 allowed false 0 9 allowed "" 30; expect "leaves trava on the first good measurement" livre
# 7b. dead probe on both (unknown, null usage) is never trava
setup; jq -n --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{measured_at:$at, profiles:{work:{status:"unknown"}, "personal":{status:"unknown"}}, history:{}}' > "$H/measure.json"; expect "dead probe on both: livre, never trava" livre
# 8. weekly rules: 5h calm, 7d 88% with 2d21h left
setup; measure 12 12000 88 250000 allowed false 96 9 rejected; tick; measure 12 11900 88 249900 allowed false 96 9 rejected "" 30; expect "economia driven by the weekly window" economia
[ "$("$REGIME" --json | jq -r .causa)" = 7d ] && printf 'ok   %-58s 7d\n' "weekly cause" || { printf 'FAIL expected cause 7d\n'; fails=$((fails+1)); }
# 9. stale measurement: economia numbers but 40 min old -> livre with warning
setup; measure 60 12600 40 200000 allowed false 96 9 rejected "" 2400; expect "stale measurement becomes livre" livre
"$REGIME" | grep -q 'aviso: medida com' && printf 'ok   %-58s\n' "stale warning printed" || { printf 'FAIL no stale warning\n'; fails=$((fails+1)); }
# 10. override wins
setup; measure 20 7200 12 400000 allowed false 0 9 allowed; "$REGIME" economia --por 10m >/dev/null; expect "override economia" economia
"$REGIME" auto >/dev/null; expect "override dropped" livre
# 11. hold: economia settled must hold 15 min even if the next two measurements say livre
setup; measure 60 12600 40 200000 allowed false 96 9 rejected; tick; measure 61 12500 40 200000 allowed false 96 9 rejected "" 30; tick
measure 5 12400 10 200000 allowed false 96 9 rejected "" 20; tick; measure 5 12300 10 200000 allowed false 96 9 rejected "" 10; expect "economia holds 15 min" economia
# 11b. junk state file never breaks a read
setup; measure 20 7200 12 400000 allowed false 0 9 allowed; : > "$H/regime.state.json"; expect "empty state file: still answers" livre
# 11c. an extra economia measurement keeps the original hold deadline
setup; measure 60 12600 40 200000 allowed false 96 9 rejected; tick; measure 61 12500 40 200000 allowed false 96 9 rejected "" 30; tick
h1=$(jq -r .hold_until "$H/regime.state.json"); measure 62 12400 40 200000 allowed false 96 9 rejected "" 20; tick; h2=$(jq -r .hold_until "$H/regime.state.json")
runs=$((runs+1)); if [ "$h1" = "$h2" ] && [ "$h1" != 0 ] && [ "$h1" != null ]; then printf 'ok   %-58s\n' "hold_until kept across repeated economia measurements"; else printf 'FAIL hold_until changed: %s -> %s\n' "$h1" "$h2"; fails=$((fails+1)); fi
# 11d. a plain read never rewrites the state file
setup; measure 20 7200 12 400000 allowed false 0 9 allowed; tick; m1=$(stat -f %m "$H/regime.state.json"); sleep 1.1; tick; m2=$(stat -f %m "$H/regime.state.json")
runs=$((runs+1)); if [ "$m1" = "$m2" ]; then printf 'ok   %-58s\n' "a read without a new measurement does not rewrite the state"; else printf 'FAIL state rewritten without change\n'; fails=$((fails+1)); fi
# 11e. the running session's own token decides which account is measured, not the
# active file: a switch never moves a session that is already running.
setup; measure 60 12600 12 400000 allowed false 0 9 allowed
printf 'personal' > "$H/active"
printf '%s work\n' "$(printf 'tok-of-preferred' | shasum -a 256 | cut -c1-12)" > "$H/fp-cache"
runs=$((runs + 1))
with=$(CLAUDE_CODE_OAUTH_TOKEN='tok-of-preferred' "$REGIME" --json)
if [ "$(printf '%s' "$with" | jq -r .conta)" = work ] && [ "$(printf '%s' "$with" | jq -r .reserva_5h)" -lt 0 ]; then
  printf 'ok   %-58s %s\n' "session token picks its own account and numbers" "work"
else printf 'FAIL %-58s got %s\n' "session token picks its own account and numbers" "$(printf '%s' "$with" | jq -c '{conta,reserva_5h}')"; fails=$((fails + 1)); fi
runs=$((runs + 1))
without=$("$REGIME" --json)
if [ "$(printf '%s' "$without" | jq -r .conta)" = personal ]; then
  printf 'ok   %-58s %s\n' "no token in the environment falls back to the active file" "personal"
else printf 'FAIL %-58s got %s\n' "no token in the environment falls back to the active file" "$(printf '%s' "$without" | jq -r .conta)"; fails=$((fails + 1)); fi
# 12. young window (10 min elapsed) and calm week: livre
setup; measure 3 17400 12 400000 allowed false 0 9 allowed; expect "young window, no pace yet" livre

printf '\n%d cases, %d failures\n' "$runs" "$fails"
[ "$fails" -eq 0 ]
