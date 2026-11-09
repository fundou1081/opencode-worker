#!/bin/bash
# Regression for the standalone-worker profile (no chatroom, no cell roles).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
T=${T:-${TMPDIR:-/tmp}/opencode-worker-e2e-simple}
S=${OW_MANAGER:-$HERE/../scripts/opencode-worker}
FAKE=$HERE/fake-opencode
export OPENCODE_BIN=$FAKE
export FAKE_OPENCODE_HOME="$T/fakehome"
R="$T/root"

pass=0
fail=0
check() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$label"
  else
    fail=$((fail+1)); printf 'FAIL %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
  fi
}
rc() { "$@" >/dev/null 2>&1; echo $?; }
jqp() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null || echo "ERR"; }
ow() { "$S" --profile simple --root "$R" "$@"; }
start_chat() { ow chat start --worker "$1" --approved-by user --max-turns "$2" | sed -n 's/^chat: //p' | head -1; }

rm -rf "$T"; mkdir -p "$R" "$T/src"
cd "$T/src" && git init -q && echo "# demo" > README.md && git add -A \
  && git -c user.email=a@b -c user.name=t commit -qm init

echo "== A. worker lifecycle =="
ow new w1 --source "$T/src" --mode copy --task "simple task" --quiet
check "A1 worker created" "yes" "$([ -d "$R/w1" ] && echo yes || echo no)"
check "A2 simple AGENTS.md" "yes" "$(grep -q 'self-contained worker' "$R/w1/AGENTS.md" && echo yes || echo no)"
check "A3 no cell language in brief" "no" "$(grep -qE 'base station|user equipment|broadcast' "$R/w1/AGENTS.md" && echo yes || echo no)"
check "A4 managed block in workspace" "yes" "$(grep -q 'dsh-opencode-worker:start' "$R/w1/workspace/AGENTS.md" && echo yes || echo no)"
check "A5 no chatroom directory" "no" "$([ -d "$R/.chatroom" ] && echo yes || echo no)"
check "A6 list without role column" "no" "$(ow list | head -2 | grep -q 'ROLE' && echo yes || echo no)"
check "A7 status without role line" "no" "$(ow status w1 | grep -q '^role:' && echo yes || echo no)"
check "A8 status shows task" "yes" "$(ow status w1 | grep -q 'simple task' && echo yes || echo no)"

echo "== B. one-off run =="
check "B1 run works" "0" "$(rc ow run w1 'one-off task')"
check "B2 result stored" "yes" "$([ -s "$R/w1/result.md" ] && echo yes || echo no)"
check "B3 run count" "1" "$(ow status w1 --json | jqp "d['run_count']")"
check "B4 session recorded" "yes" "$(ow status w1 --json | jqp "'yes' if d.get('session_id') else 'no'")"
check "B5 diff works" "0" "$(rc ow diff w1 --stat)"
check "B6 commit works" "0" "$(rc ow commit w1 -m 'simple commit')"

echo "== C. local chat budget =="
CHAT=$(start_chat w1 3)
check "C1 chat created" "open" "$(ow chat status --chat "$CHAT" --json | jqp "d['status']")"
check "C2 approval recorded" "user" "$(ow chat status --chat "$CHAT" --json | jqp "d['approved_by']")"
check "C3 chat send works" "0" "$(rc ow chat send --chat "$CHAT" --expect reply --expect-within 60 --prompt hello)"
check "C4 turn consumed" "1" "$(ow chat status --chat "$CHAT" --json | jqp "d['turns_used']")"
check "C5 session linked after turn" "yes" "$(ow chat status --chat "$CHAT" --json | jqp "'yes' if d.get('session_id') else 'no'")"
check "C6 chat list shows chat" "$CHAT" "$(ow chat list --json | jqp "d[0]['chat_id']")"
check "C7 is_new_session on later turn" "2" "$(rc ow chat send --chat "$CHAT" --is-new-session true --expect x --expect-within 60 --prompt again)"
check "C8 turn not consumed by rejection" "1" "$(ow chat status --chat "$CHAT" --json | jqp "d['turns_used']")"
check "C9 close chat" "0" "$(rc ow chat close --chat "$CHAT")"
check "C10 closed status" "closed" "$(ow chat status --chat "$CHAT" --json | jqp "d['status']")"

echo "== D. exhaustion and session continuation =="
CHAT2=$(start_chat w1 1)
ow chat send --chat "$CHAT2" --expect x --expect-within 60 --prompt one >/dev/null 2>&1
check "D1 exhausted chat rejected" "4" "$(rc ow chat send --chat "$CHAT2" --expect x --expect-within 60 --prompt two)"
check "D2 exhausted status" "exhausted" "$(ow chat status --chat "$CHAT2" --json | jqp "d['status']")"
SES=$(ow chat status --chat "$CHAT2" --json | jqp "d['session_id']")
CHAT3=$(ow chat start --worker w1 --approved-by user --max-turns 2 --session "$SES" | sed -n 's/^chat: //p' | head -1)
check "D3 linked chat created" "yes" "$([ -n "$CHAT3" ] && echo yes || echo no)"
check "D4 session reused" "$SES" "$(ow chat status --chat "$CHAT3" --json | jqp "d['session_id']")"
check "D5 continuation turn" "0" "$(rc ow chat send --chat "$CHAT3" --expect x --expect-within 60 --prompt resume)"
check "D6 chat start needs approval" "2" "$(rc ow chat start --worker w1)"

echo "== D2. provider limit is explained =="
CHAT4=$(start_chat w1 2)
OUT=$(ow chat send --chat "$CHAT4" --expect x --expect-within 60 --prompt "PROVIDERLIMIT nope" 2>&1)
check "D7 provider limit explained" "yes" "$(printf '%s' "$OUT" | grep -q '\[provider limit\]' && echo yes || echo no)"
check "D8 provider limit names the fix" "yes" "$(printf '%s' "$OUT" | grep -q 'PROVIDER/MODEL' && echo yes || echo no)"

echo "== D3. task-aware working loop =="
ow new loopbug --mode empty --task "fix the failing auth tests" --quiet >/dev/null
check "D9 bug task picks the bugfix loop" "bugfix" "$(ow status loopbug | sed -n 's/^loop: //p')"
check "D10 bugfix loop asks for a reproduction" "yes" "$(grep -q 'Reproduce the failure first' "$R/loopbug/AGENTS.md" && echo yes || echo no)"
check "D11 bugfix loop defines done" "yes" "$(grep -q '## Definition of done' "$R/loopbug/AGENTS.md" && echo yes || echo no)"
ow new looptest --mode empty --task "add regression test for the expired token path" --quiet >/dev/null
check "D12 test task picks the test loop" "test" "$(ow status looptest | sed -n 's/^loop: //p')"
ow new loopfeat --mode empty --task "implement a new endpoint for report export" --quiet >/dev/null
check "D13 feature task picks the feature loop" "feature" "$(ow status loopfeat | sed -n 's/^loop: //p')"
ow new looppin --mode empty --task "fix the failing auth tests" --loop research --quiet >/dev/null
check "D14 --loop pins the profile" "research" "$(ow status looppin | sed -n 's/^loop: //p')"
ow agents looppin --task "investigate the memory leak" --write >/dev/null
check "D15 pinned profile survives a task change" "research" "$(ow status looppin | sed -n 's/^loop: //p')"
check "D16 workspace block carries the loop" "yes" "$(grep -q 'Working method (investigation)' "$R/looppin/workspace/AGENTS.md" && echo yes || echo no)"
ow new loopauto --mode empty --task "clean up the repo" --quiet >/dev/null
check "D17 unknown task falls back to generic" "generic" "$(ow status loopauto | sed -n 's/^loop: //p')"

echo "== E. cell features are unavailable =="
check "E1 room rejected" "2" "$(rc ow room status)"
check "E2 server rejected" "2" "$(rc ow server status)"
check "E3 watch rejected" "2" "$(rc ow watch --once)"
check "E4 no chatroom dir created" "no" "$([ -d "$R/.chatroom" ] && echo yes || echo no)"

echo "== F. semaphore and doctor =="
check "F1 semaphore status" "0" "$(rc ow semaphore status)"
check "F2 doctor works" "0" "$(rc ow doctor)"
check "F3 doctor reports simple profile" "yes" "$(ow doctor | grep -q 'profile: simple' && echo yes || echo no)"
check "F4 doctor created no chatroom" "no" "$([ -d "$R/.chatroom" ] && echo yes || echo no)"
check "F5 destroy worker" "0" "$(rc ow destroy w1 --force)"
check "F6 destroyed worker gone" "no" "$([ -d "$R/w1" ] && echo yes || echo no)"

echo "== G. remaining command surface =="
ow new w2 --source "$T/src" --mode worktree --branch "opencode/test-w2" --quiet
check "G1 worktree mode" "yes" "$([ -d "$R/w2/workspace/.git" ] || [ -f "$R/w2/workspace/.git" ] && echo yes || echo no)"
check "G2 worktree branch recorded" "opencode/test-w2" "$(ow status w2 --json | jqp "d.get('branch')")"
printf 'custom instruction line\n' > "$T/custom.md"
ow new w3 --source "$T/src" --mode copy --agents-file "$T/custom.md" --quiet
check "G3 AGENTS.custom.md stored" "yes" "$([ -f "$R/w3/AGENTS.custom.md" ] && echo yes || echo no)"
check "G4 custom instructions in brief" "yes" "$(grep -q 'custom instruction line' "$R/w3/AGENTS.md" && echo yes || echo no)"
ow agents w3 --task "changed task" --write >/dev/null
check "G5 agents --write updates task" "yes" "$(grep -q 'changed task' "$R/w3/AGENTS.md" && echo yes || echo no)"
ow run w2 "first task for w2" >/dev/null 2>&1
check "G6 result command works" "0" "$(rc ow result w2)"
check "G7 logs command works" "0" "$(rc ow logs w2)"
check "G8 session command works" "0" "$(rc ow session w2)"
ow close w2
check "G9 closed worker hidden from list" "no" "$(ow list | grep -q '^w2' && echo yes || echo no)"
check "G10 closed worker shown with --all" "yes" "$(ow list --all | grep -q '^w2' && echo yes || echo no)"
check "G11 semaphore set works" "0" "$(rc ow semaphore set --max-concurrent 2)"
check "G12 semaphore max applied" "2" "$(ow semaphore status --json | jqp "d['max_concurrent']")"
ow semaphore set --max-concurrent 3 >/dev/null
check "G13 run --new-session works" "0" "$(rc ow run w2 --new-session 'new session task')"
check "G14 destroy --delete-session accepted" "0" "$(rc ow destroy w3 --force --delete-session)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
