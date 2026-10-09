#!/usr/bin/env bash
# Checks a freshly issued certificate and packs it into the one file launchers
# download.
#
#   bundle_cert.sh <fullchain.pem> <key.pem> <expected-name> <production|staging> <out.json>
#
# One file rather than separate certificate and key files, so a launcher that
# downloads mid-publish can never pair a new certificate with an old key.
# Refuses (exit 1, ::error:: lines) when the chain is a bare leaf, the name
# isn't covered, the key doesn't match, or the issuer doesn't match the
# endpoint that was asked for: the last keeps a staging certificate off the
# live tag and a real one off the staging tag.
set -euo pipefail

chain="${1:?usage: bundle_cert.sh <fullchain.pem> <key.pem> <name> <production|staging> <out.json>}"
key="${2:?}"
name="${3:?}"
mode="${4:?}"
out="${5:?}"

fail=0
err() { echo "::error::$*"; fail=1; }

count=$(grep -c 'BEGIN CERTIFICATE' "$chain" || true)
[ "$count" -ge 2 ] || err "bare leaf ($count certificate), not a full chain; phones would reject it"

san=$(openssl x509 -in "$chain" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ')
echo "$san" | tr ',' '\n' | grep -qx "DNS:$name" || err "certificate does not cover $name (SAN: $san)"

cert_pub=$(openssl x509 -in "$chain" -noout -pubkey)
key_pub=$(openssl pkey -in "$key" -pubout)
[ "$cert_pub" = "$key_pub" ] || err "key does not match the certificate"

issuer=$(openssl x509 -in "$chain" -noout -issuer)
if echo "$issuer" | grep -qi 'staging\|pretend\|bogus\|fake'; then
  [ "$mode" = "staging" ] || err "production run produced a staging certificate ($issuer)"
else
  [ "$mode" = "production" ] || err "staging run produced a trusted certificate ($issuer)"
fi

[ "$fail" -eq 0 ] || exit 1

serial=$(openssl x509 -in "$chain" -noout -serial | cut -d= -f2)
not_after=$(openssl x509 -in "$chain" -noout -enddate | cut -d= -f2)

# python3 for the JSON so PEM newlines are escaped correctly.
python3 - "$name" "$serial" "$not_after" "$chain" "$key" "$out" <<'PY'
import json, sys, datetime
name, serial, not_after, chain_path, key_path, out = sys.argv[1:]
with open(chain_path) as f: chain = f.read()
with open(key_path) as f: key = f.read()
bundle = {
    "name": name,
    "serial": serial,
    "not_after": not_after,
    "issued_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "chain": chain,
    "key": key,
}
with open(out, "w") as f: json.dump(bundle, f, indent=2)
PY
echo "bundled $name serial=$serial notAfter=$not_after -> $out"
