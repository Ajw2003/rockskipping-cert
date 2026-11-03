#!/usr/bin/env bash
# Tests for load_dns_credentials.sh and porkbun_preflight.sh (local fake Porkbun).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
T="$(mktemp -d)"; PID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null' EXIT   # temp dir is tiny; left for the OS

# --- load_dns_credentials.sh
unset GITHUB_ENV
CREDS=$'# comment\n\nFOO_1=abc\nBAR=x=y\nEMPTY=\n'
out="$(DNS_CREDENTIALS="$CREDS" "$HERE/load_dns_credentials.sh" 2>&1)"; rc=$?
[ $rc = 0 ] && grep -q '^export FOO_1=abc$' <<<"$out" && grep -q '^export BAR=x=y$' <<<"$out" \
  && ! grep -q 'EMPTY\|comment' <<<"$out" && pass "good lines exported, comments/blank/empty skipped" || fail "good lines: $out"
out="$(DNS_CREDENTIALS=$'A=1\n\nbad key=secretvalue\n' "$HERE/load_dns_credentials.sh" 2>&1)"; rc=$?
[ $rc != 0 ] && grep -q '^::error::.*line 3' <<<"$out" && ! grep -q secretvalue <<<"$out" \
  && pass "bad key fails naming line 3, value not printed" || fail "bad key: $out"
out="$(DNS_CREDENTIALS=$'NOEQUALS' "$HERE/load_dns_credentials.sh" 2>&1)"; rc=$?
[ $rc != 0 ] && grep -q 'line 1' <<<"$out" && pass "line without = fails" || fail "no equals: $out"
out="$(DNS_CREDENTIALS=$'CF_Token=t1\nCF_Zone_ID=z1' "$HERE/load_dns_credentials.sh" 2>&1)"
grep -q 'export CF_Token=t1' <<<"$out" && grep -q 'export CF_Zone_ID=z1' <<<"$out" && pass "mixed-case Cloudflare names load" || fail "cloudflare: $out"
out="$(PORKBUN_API_KEY=k1 PORKBUN_SECRET_API_KEY=s1 "$HERE/load_dns_credentials.sh" 2>&1)"
grep -q 'export PORKBUN_API_KEY=k1' <<<"$out" && pass "porkbun fallback" || fail "fallback: $out"
out="$(env -u DNS_CREDENTIALS -u PORKBUN_API_KEY -u PORKBUN_SECRET_API_KEY "$HERE/load_dns_credentials.sh" 2>&1)"; rc=$?
[ $rc != 0 ] && grep -q 'DNS_CREDENTIALS' <<<"$out" && pass "neither set fails naming secret" || fail "neither: $out"
GITHUB_ENV="$T/env" DNS_CREDENTIALS=$'TOKEN=topsecret' "$HERE/load_dns_credentials.sh" > "$T/stdout"
grep -q 'topsecret' "$T/env" && ! grep -v '^::add-mask::' "$T/stdout" | grep -q topsecret && pass "GITHUB_ENV written, stdout has only the mask line" || fail "GITHUB_ENV"

# --- porkbun_preflight.sh against a fake server
cat > "$T/fake.py" <<'PY'
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if b.get("apikey") != "good":
            r = {"status": "ERROR", "message": "Invalid API key. (001)"}
        elif self.path.endswith("/dns/retrieve/refused.test"):
            r = {"status": "ERROR", "message": "Domain is not opted in to API access."}
        else:
            r = {"status": "SUCCESS"}
        d = json.dumps(r).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
PY
python3 "$T/fake.py" > "$T/port" & PID=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
export PORKBUN_API_BASE="http://127.0.0.1:$(cat "$T/port")/api/json/v3"
export PORKBUN_SECRET_API_KEY=s
out="$(PORKBUN_API_KEY=good "$HERE/porkbun_preflight.sh" ok.test 2>&1)"; rc=$?
[ $rc = 0 ] && pass "preflight success" || fail "success: $out"
out="$(PORKBUN_API_KEY=bad "$HERE/porkbun_preflight.sh" ok.test 2>&1)"; rc=$?
[ $rc != 0 ] && grep -q '::error::Porkbun did not accept the API key.*Invalid API key' <<<"$out" && pass "preflight bad key" || fail "bad key: $out"
out="$(PORKBUN_API_KEY=good "$HERE/porkbun_preflight.sh" refused.test 2>&1)"; rc=$?
[ $rc != 0 ] && grep -q '::error::Porkbun refused access to refused.test.*not opted in.*API Access' <<<"$out" && pass "preflight domain refused" || fail "refused: $out"

exit $FAIL
