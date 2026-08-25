#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLI=$ROOT/bin/omarci
export OMARCI_DIR
OMARCI_DIR=$(mktemp -d)
export OMARCI_NOTIFY=0
trap 'rm -rf "$OMARCI_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

id=$("$CLI" start --name demo --cwd "$ROOT")
[[ -n $id ]] || fail "start printed no id"
"$CLI" show "$id" | jq -e '.status == "running" and .name == "demo"' >/dev/null

"$CLI" pass "$id" -m "ok" --no-notify
"$CLI" show "$id" | jq -e '.status == "pass" and .message == "ok" and .dismissed == false' >/dev/null

"$CLI" pass "$id" --no-notify >/dev/null 2>&1 && fail "pass on a finished job should fail" || true

fid=$("$CLI" start --name broken)
"$CLI" fail "$fid" -m "nope" --no-notify
"$CLI" show "$fid" | jq -e '.status == "fail" and .message == "nope"' >/dev/null

"$CLI" run --name echo --no-notify -- echo hello-from-omarci >/dev/null
"$CLI" list --json | jq -e '[.[] | select(.name == "echo" and .status == "pass")] | length == 1' >/dev/null
echo_id=$("$CLI" list --json | jq -r '.[] | select(.name == "echo") | .id' | head -1)
"$CLI" logs "$echo_id" | grep -q hello-from-omarci || fail "log missing command output"

set +e
"$CLI" run --name false --no-notify -- false >/dev/null
rc=$?
set -e
[[ $rc -eq 1 ]] || fail "run should return the command's exit status, got $rc"

bg_id=$("$CLI" run --bg --name sleep --no-notify -- sleep 0.2)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  st=$("$CLI" show "$bg_id" | jq -r .status)
  [[ $st != running ]] && break
  sleep 0.1
done
[[ $st == pass ]] || fail "bg job should pass, got $st"

"$CLI" dismiss "$fid"
"$CLI" show "$fid" | jq -e '.dismissed == true' >/dev/null
"$CLI" list --json | jq -e --arg id "$fid" '[.[] | select(.id == $id)] | length == 1' >/dev/null

"$CLI" clear --prune
"$CLI" list --json | jq -e --arg id "$fid" '[.[] | select(.id == $id)] | length == 0' >/dev/null

(
  unset OMARCI_NOTIFY
  printf '%s\n' '{"notify":false}' >"$OMARCI_DIR/settings.json"
  qid=$("$CLI" start --name quiet)
  "$CLI" pass "$qid" -m ok
  "$CLI" show "$qid" | jq -e '.status == "pass"' >/dev/null
)

printf 'ok\n'
