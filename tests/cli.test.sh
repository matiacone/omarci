#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLI=$ROOT/bin/omarci
export OMARCI_DIR
OMARCI_DIR=$(mktemp -d)
export OMARCI_NOTIFY=0
export OMARCI_PREFETCH=0
trap 'rm -rf "$OMARCI_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

"$CLI" --help | grep -q "omarci gh sync" || fail "--help should list the gh commands"
"$CLI" run -- true >/dev/null 2>&1 && fail "local-job commands are gone" || true

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
  "run view")
    if [[ " $* " == *" --json "* ]]; then body=$(cat "$FAKE_GH/jobs.json")
    elif [[ " $* " == *" --log-failed "* ]]; then printf 'ci\tTest\t2026-10-05T10:00:59Z boom\n'; exit 0
    else printf 'ci\tTest\t2026-10-05T10:00:59Z all good\nci\tUNKNOWN STEP\t2026-10-05T10:01:00Z Post job cleanup.\nci\tUNKNOWN STEP\t2026-10-05T10:01:01Z cleanup noise\n'; exit 0
    fi ;;
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
    id: 42, name: "ci", display_title: "Fix <img src=x> the thing", head_branch: "main", head_sha: "abcdef1234",
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
  grep -qF 'Fix &lt;img src=x&gt; the thing' "$FAKE_GH/toasts" || fail "a run title reaches the notification body unescaped"
  jq '.notify = false' "$OMARCI_DIR/settings.json" >"$OMARCI_DIR/s.tmp" && mv "$OMARCI_DIR/s.tmp" "$OMARCI_DIR/settings.json"
)

"$CLI" gh rerun Acme/App 42 --failed
grep -q '^run rerun 42 -R Acme/App --failed$' "$FAKE_GH/calls" || fail "gh rerun --failed did not reach gh"
"$CLI" gh cancel Acme/App 42
grep -q '^run cancel 42 -R Acme/App$' "$FAKE_GH/calls" || fail "gh cancel did not reach gh"
"$CLI" gh rerun Acme/App 'x; rm -rf /' >/dev/null 2>&1 && fail "a non-numeric run id must be refused" || true
"$CLI" gh rerun '../etc' 42 >/dev/null 2>&1 && fail "a malformed repo must be refused" || true

jobs_json() { # $1 conclusion of the one job
  jq -n --arg c "$1" '{jobs: [{name: "ci", status: "completed", conclusion: $c,
    startedAt: "2026-10-05T10:00:05Z", completedAt: "2026-10-05T10:01:00Z", url: "u",
    steps: [{number: 1, name: "Test", status: "completed", conclusion: $c}]}]}' >"$FAKE_GH/jobs.json"
}
jobs_json failure
"$CLI" gh view Acme/App 42 | jq -e '.logKind == "failed" and (.log | contains("boom"))
  and .jobs[0].steps[0].name == "Test" and .jobs[0].completedAt > .jobs[0].startedAt' >/dev/null \
  || fail "gh view of a failed run should carry the failed jobs' log"
[[ -f $OMARCI_DIR/runs/Acme__App/42-1.json ]] || fail "a finished run's view should be cached"
"$CLI" gh cached | jq -e '.["Acme/App#42#1"].logKind == "failed"' >/dev/null \
  || fail "gh cached should return every cached view keyed repo#id#attempt"
calls_before=$(grep -c '^run view' "$FAKE_GH/calls")
"$CLI" gh view Acme/App 42 | jq -e '.logKind == "failed"' >/dev/null || fail "the cached view changed"
[[ $(grep -c '^run view' "$FAKE_GH/calls") == "$calls_before" ]] || fail "a cached view should not call gh"

rm -rf "$OMARCI_DIR/runs"
jobs_json success
"$CLI" gh view Acme/App 42 | jq -e '.logKind == "all" and (.log | contains("all good")) and (.log | contains("cleanup") | not)' >/dev/null \
  || fail "gh view of a passed run should carry the run's own log, without post-job cleanup"

"$CLI" repos remove acme/APP
[[ -z $("$CLI" repos list) ]] || fail "repos remove should match case-insensitively"
jq -e '(.repos | length) == 0' "$OMARCI_DIR/github.json" >/dev/null || fail "repos remove left the repo's runs"
jq -e '.notify == false' "$OMARCI_DIR/settings.json" >/dev/null || fail "repos remove dropped the notify setting"

printf 'ok\n'
