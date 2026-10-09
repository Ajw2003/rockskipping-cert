#!/usr/bin/env bash
# Offline tests for check_cert.sh: throwaway CAs, CRLs served from a local
# python http.server (started and killed inside this script).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="$HERE/check_cert.sh"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

T="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
  rm -rf "$T"
}
trap cleanup EXIT

WEB="$T/web"
mkdir -p "$WEB"

# Ask the OS for a free port.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"

# make_ca NAME -> $T/NAME/{ca.pem,key.pem,openssl.cnf,...}
make_ca() {
  local d="$T/$1"
  mkdir -p "$d"
  : > "$d/index.txt"
  echo 1000 > "$d/serial"
  echo 01 > "$d/crlnumber"
  echo "unique_subject = no" > "$d/index.txt.attr"
  cat > "$d/openssl.cnf" <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir = $d
database = \$dir/index.txt
serial = \$dir/serial
crlnumber = \$dir/crlnumber
new_certs_dir = \$dir
certificate = \$dir/ca.pem
private_key = \$dir/key.pem
default_md = sha256
policy = policy_any
unique_subject = no
copy_extensions = none
[ policy_any ]
commonName = supplied
[ req ]
distinguished_name = dn
prompt = no
[ dn ]
CN = $1
EOF
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 30 \
    -keyout "$d/key.pem" -out "$d/ca.pem" -config "$d/openssl.cnf" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
}

# issue_leaf CA NAME DAYS CRL_PATH_OR_EMPTY -> $T/NAME.pem (leaf) and $T/NAME.chain.pem
issue_leaf() {
  local ca="$1" name="$2" days="$3" crlpath="$4" d="$T/$1"
  local ext="$T/$name.ext"
  : > "$ext"
  if [ -n "$crlpath" ]; then
    echo "crlDistributionPoints = URI:http://127.0.0.1:$PORT/$crlpath" > "$ext"
  fi
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$T/$name.key" -out "$T/$name.csr" -subj "/CN=$name.test" 2>/dev/null
  openssl ca -batch -config "$d/openssl.cnf" -days "$days" -extfile "$ext" \
    -in "$T/$name.csr" -out "$T/$name.pem" -notext 2>/dev/null
  cat "$T/$name.pem" "$d/ca.pem" > "$T/$name.chain.pem"
}

# gen_crl CA OUTFILE [der]
gen_crl() {
  if [ "${3:-}" = "der" ]; then
    openssl ca -config "$T/$1/openssl.cnf" -gencrl -crldays 7 -out "$T/$1/crl.pem" 2>/dev/null
    openssl crl -in "$T/$1/crl.pem" -outform DER -out "$2"
  else
    openssl ca -config "$T/$1/openssl.cnf" -gencrl -crldays 7 -out "$2" 2>/dev/null
  fi
}

# expect NAME CHAIN WANT_RC WANT_PREFIX [extra args]
expect() {
  local label="$1" chain="$2" want_rc="$3" prefix="$4" out rc=0
  shift 4
  out="$("$CHECK" "$chain" "$@")" || rc=$?
  if [ "$rc" = "$want_rc" ] && [[ "$out" == "$prefix"* ]] && [ "$(printf '%s\n' "$out" | wc -l)" = "1" ]; then
    pass "$label (rc=$rc)"
  else
    fail "$label (rc=$rc want $want_rc; output: $out)"
  fi
}

# ---- fixtures --------------------------------------------------------------
make_ca ca1
make_ca ca2

issue_leaf ca1 good 90 ca.crl
issue_leaf ca1 tobe_revoked 90 ca.crl
issue_leaf ca1 short 1 ca.crl
issue_leaf ca1 nocrl 90 ""
issue_leaf ca1 wrongcrl 90 other.crl
issue_leaf ca1 rev_short 1 ca.crl

gen_crl ca1 "$WEB/ca.crl"          # PEM, nothing revoked yet
gen_crl ca2 "$WEB/other.crl" der   # signed by the wrong CA, DER

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WEB" >/dev/null 2>&1 &
SERVER_PID=$!
up=0
for _ in $(seq 1 50); do
  if curl -fs --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/ca.crl"; then up=1; break; fi
  sleep 0.1
done
if [ "$up" != 1 ]; then echo "FAIL: test web server never answered"; exit 1; fi

# ---- cases -----------------------------------------------------------------
expect "a: good cert valid 90 days -> ok" "$T/good.chain.pem" 0 "ok:"

echo "garbage" > "$T/garbage.pem"
expect "d: garbage file -> unreadable" "$T/garbage.pem" 12 "unreadable:"
expect "e: no CRL DP -> unreadable" "$T/nocrl.chain.pem" 12 "unreadable:"
expect "f: CRL signed by a different CA -> unreadable" "$T/wrongcrl.chain.pem" 12 "unreadable:"
expect "c: leaf valid 1 day, --min-days 30 -> expiring" "$T/short.chain.pem" 11 "expiring:" --min-days 30

openssl ca -config "$T/ca1/openssl.cnf" -revoke "$T/tobe_revoked.pem" 2>/dev/null
openssl ca -config "$T/ca1/openssl.cnf" -revoke "$T/rev_short.pem" 2>/dev/null
gen_crl ca1 "$WEB/ca.crl" der      # regenerated, DER this time
expect "b: revoked leaf after CRL regenerated -> revoked" "$T/tobe_revoked.chain.pem" 10 "revoked:"
expect "g: revoked and expiring -> revoked wins" "$T/rev_short.chain.pem" 10 "revoked:" --min-days 30
expect "a2: good cert still ok with DER CRL" "$T/good.chain.pem" 0 "ok:"

echo "----"
if [ "$FAIL" = "0" ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit "$FAIL"
