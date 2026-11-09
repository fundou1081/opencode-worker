#!/bin/bash
# Real-model suite for the standalone-worker profile (simple profile).
# Exercises the local chat budget, session resume and the no-chatroom rules
# with the real OpenCode CLI and a real model.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib-quota.sh"
T=${T:-${TMPDIR:-/tmp}/opencode-worker-e2e-real-simple}
S=${OW_MANAGER:-$HERE/../scripts/opencode-worker}
R="$T/root"
export OPENCODE_BIN=${OPENCODE_BIN:-$(command -v opencode)}
MODEL=${MODEL:-opencode/deepseek-v4.1-flash-free}

pass=0

if [ "${OW_SKIP_PROBE:-0}" != "1" ] && ! MODEL="$MODEL" T="$T/probe" "$HERE/probe-model.sh" >/dev/null 2>&1; then
  echo "SKIPPED: model $MODEL is unavailable (quota exhausted or provider down)"
  echo "Re-run later, or pick another model: MODEL=minimax-cn-coding-plan/MiniMax-M3.1-Flash $0"
  exit 77
fi
fail=0
check() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    pass=$((pass+1)); printf 'ok   %s\n' "$label"
  else
    fail=$((fail+1)); printf 'FAIL %s (expected %s, got %s)\n' "$label" "$expected" "$actual"
  fi
}
jqp() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null || echo "ERR"; }
ow() { "$S" --profile simple --root "$R" "$@"; }

rm -rf "$T"; mkdir -p "$R" "$T/src"
cd "$T/src" && git init -q && printf '# demo\n' > README.md && git add -A \
  && git -c user.email=a@b -c user.name=t commit -qm init

echo "== setup =="
ow new w1 --source "$T/src" --mode copy --task "produce the artifacts" --model "$MODEL" --quiet
check "worker created" "yes" "$([ -d "$R/w1" ] && echo yes || echo no)"
check "simple brief written" "yes" "$(grep -q 'self-contained worker' "$R/w1/AGENTS.md" && echo yes || echo no)"
check "no chatroom directory" "no" "$([ -d "$R/.chatroom" ] && echo yes || echo no)"

echo "== real one-off run =="
ow run w1 "Create a file named simple.txt in the current workspace whose only line is: simple ok
Then run 'cat simple.txt' and report the output." > "$T/run1.out" 2>&1
check "run exit" "0" "$?"
check "artifact created" "yes" "$([ -f "$R/w1/workspace/simple.txt" ] && echo yes || echo no)"
check "artifact content" "simple ok" "$(cat "$R/w1/workspace/simple.txt" 2>/dev/null | head -1)"
check "no chatroom created by run" "no" "$([ -d "$R/.chatroom" ] && echo yes || echo no)"

echo "== real local chat turn =="
CHAT=$(ow chat start --worker w1 --approved-by user --max-turns 2 | sed -n 's/^chat: //p' | head -1)
ow chat send --chat "$CHAT" --expect "chat ok" --expect-within 300 --timeout 300 \
  --prompt "Create a file named chat.txt in the current workspace whose only line is: chat ok
Then run 'cat chat.txt' and report the output." > "$T/chat1.out" 2>&1
check "chat turn exit" "0" "$?"
check "chat artifact created" "yes" "$([ -f "$R/w1/workspace/chat.txt" ] && echo yes || echo no)"
check "chat artifact content" "chat ok" "$(cat "$R/w1/workspace/chat.txt" 2>/dev/null | head -1)"
check "ledger turn counted" "1" "$(ow chat status --chat "$CHAT" --json | jqp "d['turns_used']")"
check "ledger session stored" "yes" "$(ow chat status --chat "$CHAT" --json | jqp "'yes' if d.get('session_id') else 'no'")"
check "ledger keeps expectation" "chat ok" "$(ow chat status --chat "$CHAT" --json | jqp "d['turns'][0].get('expected')")"
check "ledger keeps deadline" "yes" "$(ow chat status --chat "$CHAT" --json | jqp "'yes' if d['turns'][0].get('deadline') else 'no'")"
SES=$(ow chat status --chat "$CHAT" --json | jqp "d['session_id']")

echo "== session continuation with a real turn =="
CHAT2=$(ow chat start --worker w1 --approved-by user --max-turns 2 --session "$SES" | sed -n 's/^chat: //p' | head -1)
ow chat send --chat "$CHAT2" --expect "chat.txt" --expect-within 300 --timeout 300 \
  --prompt "Which file did you create in the previous turn of this session? Answer with only the file name." > "$T/chat2.out" 2>&1
check "continuation exit" "0" "$?"
check "continuation reused session" "$SES" "$(ow chat status --chat "$CHAT2" --json | jqp "d['session_id']")"
check "model remembered earlier work" "yes" "$(grep -q 'chat.txt' "$T/chat2.out" && echo yes || echo no)"

echo "== standalone rules =="
set +e
ow room status >/dev/null 2>&1; RC=$?
set -e
check "room command refused" "2" "$RC"
check "still no chatroom directory" "no" "$([ -d "$R/.chatroom" ] && echo yes || echo no)"
check "chat list shows the ledger" "yes" "$(ow chat list --json | jqp "'yes' if len(d)>=2 else 'no'")"


# A provider-side quota refusal is not a product failure.
if [ "$fail" -ne 0 ] && quota_failure_detected "$T"; then
  printf '\nSKIPPED: the model provider refused the run (quota or rate limit)\n'
  exit 77
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
