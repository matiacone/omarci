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

# A single huge line must not exceed the byte cap even with --tail.
huge_id=$("$CLI" start --name huge)
log=$("$CLI" show "$huge_id" | jq -r .log)
python3 -c 'import sys; sys.stdout.write("H"*200000 + "\nTINY\n")' >"$log"
"$CLI" pass "$huge_id" -m ok --no-notify
n=$("$CLI" logs --tail 200 "$huge_id" | wc -c)
(( n <= 65536 )) || fail "logs --tail leaked $n bytes (cap 65536)"
"$CLI" logs --tail 200 --bytes 100 "$huge_id" | wc -c | awk '{exit !($1<=100)}' \
  || fail "logs --bytes 100 did not cap"

# --- GitHub Actions: a fake gh answers from files under $FAKE_GH ----------
FAKE_GH=$(mktemp -d)
mkdir -p "$FAKE_GH/bin"
cat >"$FAKE_GH/bin/gh" <<'GH'
#!/usr/bin/env bash
# api user | api repos/O/R | api repos/O/R/actions/runs?... ; run rerun|cancel ID -R O/R [--failed]
printf '%s\n' "$*" >>"$FAKE_GH/calls"
jq_filter=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ ${args[i]} == --jq ]] && jq_filter=${args[i+1]}
done
case "$1 $2" in
  "api user") body='{"login":"me"}' ;;
  "api repos/acme/missing") echo "HTTP 404: Not Found" >&2; exit 1 ;;
  "api repos/acme/app") body='{"full_name":"Acme/App"}' ;;
  "api repos/Acme/App/actions/runs?per_page=10") body=$(cat "$FAKE_GH/runs.json") ;;
  "run rerun"|"run cancel") exit 0 ;;
  *) echo "fake gh: unexpected $*" >&2; exit 2 ;;
esac
if [[ -n $jq_filter ]]; then jq -r "$jq_filter" <<<"$body"; else printf '%s\n' "$body"; fi
GH
chmod +x "$FAKE_GH/bin/gh"
export FAKE_GH
export PATH="$FAKE_GH/bin:$PATH"
trap 'rm -rf "$OMARCI_DIR" "$FAKE_GH"' EXIT

run_json() { # $1 status, $2 conclusion, $3 actor
  jq -n --arg st "$1" --arg c "$2" --arg a "$3" '{workflow_runs: [{
    id: 42, name: "ci", display_title: "Fix the thing", head_branch: "main", head_sha: "abcdef1234",
    event: "push", status: $st, conclusion: (if $c == "" then null else $c end),
    actor: {login: $a}, triggering_actor: {login: $a}, run_attempt: 1,
    html_url: "https://github.com/Acme/App/actions/runs/42",
    created_at: "2026-10-05T10:00:00Z", run_started_at: "2026-10-05T10:00:05Z", updated_at: "2026-10-05T10:01:00Z"
  }]}' >"$FAKE_GH/runs.json"
}

printf '%s\n' '{"notify":false}' >"$OMARCI_DIR/settings.json"
"$CLI" repos add acme/missing >/dev/null 2>&1 && fail "adding an unreadable repo should fail" || true
[[ $("$CLI" repos add acme/app) == Acme/App ]] || fail "repos add should store GitHub's canonical name"
"$CLI" repos add acme/app >/dev/null
[[ $("$CLI" repos list) == Acme/App ]] || fail "a repo added twice should be listed once"
jq -e '.notify == false' "$OMARCI_DIR/settings.json" >/dev/null || fail "repos add dropped the notify setting"

run_json in_progress "" me
"$CLI" gh sync
jq -e '.me == "me" and (.repos | length) == 1 and .repos[0].repo == "Acme/App"
  and .repos[0].runs[0].id == 42 and .repos[0].runs[0].status == "in_progress"
  and .repos[0].runs[0].sha == "abcdef1" and .repos[0].runs[0].startedAt > 0' \
  "$OMARCI_DIR/github.json" >/dev/null || fail "gh sync wrote unexpected runs"

(
  # A run of yours that finishes between two syncs notifies once; a later
  # sync of the same finished run does not notify again.
  unset OMARCI_NOTIFY
  cat >"$FAKE_GH/bin/notify-send" <<'NS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH/toasts"
NS
  chmod +x "$FAKE_GH/bin/notify-send"
  jq '.notify = true' "$OMARCI_DIR/settings.json" >"$OMARCI_DIR/s.tmp" && mv "$OMARCI_DIR/s.tmp" "$OMARCI_DIR/settings.json"
  run_json completed failure me
  "$CLI" gh sync
  "$CLI" gh sync
  [[ $(grep -c "ci failure" "$FAKE_GH/toasts") == 1 ]] || fail "a finished run of yours should notify exactly once"
  jq '.notify = false' "$OMARCI_DIR/settings.json" >"$OMARCI_DIR/s.tmp" && mv "$OMARCI_DIR/s.tmp" "$OMARCI_DIR/settings.json"
)

"$CLI" gh rerun Acme/App 42 --failed
grep -q '^run rerun 42 -R Acme/App --failed$' "$FAKE_GH/calls" || fail "gh rerun --failed did not reach gh"
"$CLI" gh cancel Acme/App 42
grep -q '^run cancel 42 -R Acme/App$' "$FAKE_GH/calls" || fail "gh cancel did not reach gh"
"$CLI" gh rerun Acme/App 'x; rm -rf /' >/dev/null 2>&1 && fail "a non-numeric run id must be refused" || true
"$CLI" gh rerun '../etc' 42 >/dev/null 2>&1 && fail "a malformed repo must be refused" || true

"$CLI" repos remove acme/APP
[[ -z $("$CLI" repos list) ]] || fail "repos remove should match case-insensitively"
jq -e '(.repos | length) == 0' "$OMARCI_DIR/github.json" >/dev/null || fail "repos remove left the repo's runs"
jq -e '.notify == false' "$OMARCI_DIR/settings.json" >/dev/null || fail "repos remove dropped the notify setting"

printf 'ok\n'
