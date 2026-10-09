#!/usr/bin/env bash
# Checks a published certificate chain for revocation and near expiry.
# Usage: check_cert.sh <chain.pem> [--min-days N]   (default N=30)
# Prints exactly one status line. Exit: ok 0, revoked 10, expiring 11, unreadable 12.
# Revoked beats expiring. Deps: openssl, curl.
set -euo pipefail

chain="${1:-}"
min_days=30
if [ "${2:-}" = "--min-days" ]; then
  min_days="${3:-}"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

unreadable() { echo "unreadable: $1"; exit 12; }

[ -n "$chain" ] && [ -r "$chain" ] || unreadable "cannot read chain file '$chain'"
case "$min_days" in
  ''|*[!0-9]*) unreadable "--min-days must be a whole number, got '$min_days'" ;;
esac

# Split the chain: cert1.pem = leaf, cert2.pem = issuer.
awk -v dir="$tmp" '
  /-----BEGIN CERTIFICATE-----/ { n++; out = dir "/cert" n ".pem" }
  n > 0 { print > out }
  /-----END CERTIFICATE-----/ { out = "/dev/null" }
' "$chain"
[ -s "$tmp/cert1.pem" ] && [ -s "$tmp/cert2.pem" ] \
  || unreadable "chain has fewer than 2 certificates"
leaf="$tmp/cert1.pem"
issuer="$tmp/cert2.pem"

subject="$(openssl x509 -in "$leaf" -noout -subject 2>/dev/null)" \
  || unreadable "leaf certificate is not parseable"
serial="$(openssl x509 -in "$leaf" -noout -serial | sed 's/^serial=//')"
not_after="$(openssl x509 -in "$leaf" -noout -enddate | sed 's/^notAfter=//')"
name="${subject#subject=}"
info="name=$name serial=$serial notAfter=$not_after"

crl_url="$(openssl x509 -in "$leaf" -noout -ext crlDistributionPoints 2>/dev/null \
  | grep -o 'URI:[^ ,]*' | head -n 1 | sed 's/^URI://' || true)"
[ -n "$crl_url" ] || unreadable "no CRL URL in leaf ($info)"

curl -fsS --max-time 30 -o "$tmp/crl.raw" "$crl_url" 2>"$tmp/curl.err" \
  || unreadable "CRL download from $crl_url failed: $(cat "$tmp/curl.err") ($info)"

# Accept DER or PEM; normalise to PEM.
if grep -q -- '-----BEGIN X509 CRL-----' "$tmp/crl.raw"; then
  cp "$tmp/crl.raw" "$tmp/crl.pem"
else
  openssl crl -inform DER -in "$tmp/crl.raw" -outform PEM -out "$tmp/crl.pem" 2>"$tmp/crl.err" \
    || unreadable "CRL from $crl_url is not valid DER or PEM: $(cat "$tmp/crl.err") ($info)"
fi

cat "$issuer" "$tmp/crl.pem" > "$tmp/ca.pem"
verify_rc=0
verify_out="$(openssl verify -partial_chain -crl_check -CAfile "$tmp/ca.pem" "$leaf" 2>&1)" || verify_rc=$?

if printf '%s' "$verify_out" | grep -q 'certificate revoked'; then
  echo "revoked: $info"
  exit 10
fi
if [ "$verify_rc" -ne 0 ]; then
  unreadable "openssl verify failed: $(printf '%s' "$verify_out" | tr '\n' ' ') ($info)"
fi

if ! openssl x509 -in "$leaf" -noout -checkend $((min_days * 86400)) >/dev/null; then
  echo "expiring: expires within $min_days days; $info"
  exit 11
fi

echo "ok: not revoked, valid more than $min_days days; $info"
exit 0
