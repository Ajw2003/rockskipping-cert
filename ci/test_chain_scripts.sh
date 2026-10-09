#!/usr/bin/env bash
# Adapted from Ajw2003/CannaScraper ci/test_chain_scripts.sh at c4148a8 (names changed only).
# Behavioural tests for chain_lib.sh / watchdog.sh / chain_next.sh
# against a stub `gh` on PATH, so the dispatch logic can be checked without
# hitting the real GitHub API. Scenario JSON lives in a temp dir; the stub
# reads it and logs every `gh workflow run` call so tests can assert on it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FAIL=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# ---- stub gh -------------------------------------------------------------
STUBDIR="$(mktemp -d)"
trap 'rm -rf "$STUBDIR"' EXIT

cat > "$STUBDIR/gh" <<'STUB'
#!/usr/bin/env bash
# Fake `gh`: serves scenario JSON from $GH_STUB_DIR and logs dispatches.
set -euo pipefail
LOG="$GH_STUB_DIR/calls.log"
if [ "$1" = "api" ]; then
  path="$2"
  if [[ "$path" == *"/actions/workflows/"*"/runs"* ]]; then
    wf="$(echo "$path" | sed -E 's#.*/workflows/([^/]+)/runs.*#\1#')"
    cat "$GH_STUB_DIR/runs_${wf}.json"
  elif [[ "$path" == *"/actions/runs/"* ]]; then
    cat "$GH_STUB_DIR/run_lookup.json"
  else
    echo "stub gh: unhandled api path: $path" >&2
    exit 1
  fi
elif [ "$1" = "workflow" ] && [ "$2" = "run" ]; then
  echo "$*" >> "$LOG"
  if [ -f "$GH_STUB_DIR/dispatch_fail" ]; then
    echo "stub gh: forced dispatch failure" >&2
    exit 1
  fi
  exit 0
else
  echo "stub gh: unhandled command: $*" >&2
  exit 1
fi
STUB
chmod +x "$STUBDIR/gh"

export PATH="$STUBDIR:$PATH"
export GH_TOKEN=fake
export GITHUB_REPOSITORY=Ajw2003/rockskipping-cert

# ---- scenario helpers -----------------------------------------------------
new_scenario_dir() {
  local d
  d="$(mktemp -d)"
  echo '{"workflow_runs":[]}' > "$d/runs_pad-cert-watch.yml.json"
  echo '{"workflow_runs":[]}' > "$d/runs_pad-cert-watchdog.yml.json"
  echo '{"run_started_at":"2026-09-28T00:00:00Z"}' > "$d/run_lookup.json"
  : > "$d/calls.log"
  echo "$d"
}

run_of() { # run_of ID STATUS CREATED_AT_ISO
  printf '{"id":%s,"status":"%s","created_at":"%s"}' "$1" "$2" "$3"
}

runs_array() { # runs_array run_json...
  local IFS=,
  echo "{\"workflow_runs\":[$*]}"
}

dispatch_count() { # dispatch_count SCENARIO_DIR WORKFLOW_FILE
  grep -c "^workflow run $2 " "$1/calls.log" 2>/dev/null || true
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
hours_ago_iso() { date -u -d "-$1 hours" +%Y-%m-%dT%H:%M:%SZ; }

# =========================================================================
# a. watchdog, one in_progress pad-cert-watch -> no pad-cert-watch dispatch;
#    successor watchdog dispatched at end with successor_of = run id.
# =========================================================================
d="$(new_scenario_dir)"
runs_array "$(run_of 900 in_progress "$(now_iso)")" > "$d/runs_pad-cert-watch.yml.json"
GH_STUB_DIR="$d" GITHUB_RUN_ID=500 WATCH_MINUTES=0 POLL_SECONDS=0 "$HERE/watchdog.sh" > "$d/out.log" 2>&1 || true
if [ "$(dispatch_count "$d" pad-cert-watch.yml)" = "0" ] && grep -q "successor_of=500" "$d/calls.log" 2>/dev/null; then
  pass "a: chain alive -> no pad-cert-watch dispatch, successor watchdog dispatched"
else
  fail "a: chain alive -> no pad-cert-watch dispatch, successor watchdog dispatched"; cat "$d/out.log" "$d/calls.log" 2>/dev/null
fi

# =========================================================================
# b. watchdog, no active pad-cert-watch, newest created 3h ago -> dispatched once
# =========================================================================
d="$(new_scenario_dir)"
runs_array "$(run_of 901 completed "$(hours_ago_iso 3)")" > "$d/runs_pad-cert-watch.yml.json"
GH_STUB_DIR="$d" GITHUB_RUN_ID=501 WATCH_MINUTES=0 POLL_SECONDS=0 "$HERE/watchdog.sh" > "$d/out.log" 2>&1 || true
if [ "$(dispatch_count "$d" pad-cert-watch.yml)" = "1" ]; then
  pass "b: stale chain -> pad-cert-watch dispatched once"
else
  fail "b: stale chain -> pad-cert-watch dispatched once (got $(dispatch_count "$d" pad-cert-watch.yml))"; cat "$d/out.log"
fi

# =========================================================================
# c. watchdog, no pad-cert-watch runs at all -> dispatched
# =========================================================================
d="$(new_scenario_dir)"
GH_STUB_DIR="$d" GITHUB_RUN_ID=502 WATCH_MINUTES=0 POLL_SECONDS=0 "$HERE/watchdog.sh" > "$d/out.log" 2>&1 || true
if [ "$(dispatch_count "$d" pad-cert-watch.yml)" = "1" ]; then
  pass "c: no runs at all -> pad-cert-watch dispatched"
else
  fail "c: no runs at all -> pad-cert-watch dispatched (got $(dispatch_count "$d" pad-cert-watch.yml))"; cat "$d/out.log"
fi

# =========================================================================
# d. watchdog started while an OLDER watchdog is in_progress -> exits 0
#    immediately, no dispatches.
# =========================================================================
d="$(new_scenario_dir)"
runs_array "$(run_of 400 in_progress "$(now_iso)")" > "$d/runs_pad-cert-watchdog.yml.json"
rc=0
GH_STUB_DIR="$d" GITHUB_RUN_ID=500 WATCH_MINUTES=0 POLL_SECONDS=0 SUCCESSOR_OF='' "$HERE/watchdog.sh" > "$d/out.log" 2>&1 || rc=$?
total_calls=$(wc -l < "$d/calls.log" 2>/dev/null || echo 0)
if [ "$rc" = "0" ] && [ "$total_calls" = "0" ]; then
  pass "d: older watchdog active -> exits 0, no dispatches"
else
  fail "d: older watchdog active -> exits 0, no dispatches (rc=$rc calls=$total_calls)"; cat "$d/out.log"
fi

# =========================================================================
# e. watchdog with successor_of equal to the older in_progress run's id ->
#    does NOT exit early.
# =========================================================================
d="$(new_scenario_dir)"
runs_array "$(run_of 400 in_progress "$(now_iso)")" > "$d/runs_pad-cert-watchdog.yml.json"
GH_STUB_DIR="$d" GITHUB_RUN_ID=500 WATCH_MINUTES=0 POLL_SECONDS=0 SUCCESSOR_OF='400' "$HERE/watchdog.sh" > "$d/out.log" 2>&1 || true
if grep -q "successor_of=500" "$d/calls.log" 2>/dev/null; then
  pass "e: successor_of matches older run -> does not exit early"
else
  fail "e: successor_of matches older run -> does not exit early"; cat "$d/out.log" "$d/calls.log" 2>/dev/null
fi

# =========================================================================
# f. chain-next: another pad-cert-watch queued -> no pad-cert-watch dispatch;
#    watchdog dispatched if none active, not dispatched if one active.
# =========================================================================
d="$(new_scenario_dir)"
runs_array "$(run_of 700 queued "$(now_iso)")" > "$d/runs_pad-cert-watch.yml.json"
GH_STUB_DIR="$d" GITHUB_RUN_ID=600 MIN_GAP_MINUTES=0 "$HERE/chain_next.sh" > "$d/out.log" 2>&1 || true
if [ "$(dispatch_count "$d" pad-cert-watch.yml)" = "0" ] && [ "$(dispatch_count "$d" pad-cert-watchdog.yml)" = "1" ]; then
  pass "f1: pad-cert-watch already queued -> no pad-cert-watch dispatch, watchdog dispatched (none active)"
else
  fail "f1: pad-cert-watch already queued -> no pad-cert-watch dispatch, watchdog dispatched"; cat "$d/out.log"
fi

d="$(new_scenario_dir)"
runs_array "$(run_of 700 queued "$(now_iso)")" > "$d/runs_pad-cert-watch.yml.json"
runs_array "$(run_of 800 in_progress "$(now_iso)")" > "$d/runs_pad-cert-watchdog.yml.json"
GH_STUB_DIR="$d" GITHUB_RUN_ID=600 MIN_GAP_MINUTES=0 "$HERE/chain_next.sh" > "$d/out.log" 2>&1 || true
if [ "$(dispatch_count "$d" pad-cert-watch.yml)" = "0" ] && [ "$(dispatch_count "$d" pad-cert-watchdog.yml)" = "0" ]; then
  pass "f2: pad-cert-watch queued and watchdog active -> nothing dispatched"
else
  fail "f2: pad-cert-watch queued and watchdog active -> nothing dispatched"; cat "$d/out.log"
fi

# =========================================================================
# g. chain-next: nothing else active -> pad-cert-watch dispatched
# =========================================================================
d="$(new_scenario_dir)"
GH_STUB_DIR="$d" GITHUB_RUN_ID=600 MIN_GAP_MINUTES=0 "$HERE/chain_next.sh" > "$d/out.log" 2>&1 || true
if [ "$(dispatch_count "$d" pad-cert-watch.yml)" = "1" ]; then
  pass "g: nothing active -> pad-cert-watch dispatched"
else
  fail "g: nothing active -> pad-cert-watch dispatched (got $(dispatch_count "$d" pad-cert-watch.yml))"; cat "$d/out.log"
fi

# =========================================================================
# h. dispatch failing all retries -> script exits non-zero, prints ::error::
# =========================================================================
d="$(new_scenario_dir)"
touch "$d/dispatch_fail"
rc=0
GH_STUB_DIR="$d" GITHUB_RUN_ID=600 MIN_GAP_MINUTES=0 RETRY_BASE_SECONDS=0 "$HERE/chain_next.sh" > "$d/out.log" 2>&1 || rc=$?
if [ "$rc" != "0" ] && grep -q "::error::" "$d/out.log"; then
  pass "h: dispatch failing all retries -> non-zero exit, ::error:: printed"
else
  fail "h: dispatch failing all retries -> non-zero exit, ::error:: printed (rc=$rc)"; cat "$d/out.log"
fi

echo "----"
if [ "$FAIL" = "0" ]; then
  echo "ALL PASS"
else
  echo "SOME FAILED"
fi
exit "$FAIL"
