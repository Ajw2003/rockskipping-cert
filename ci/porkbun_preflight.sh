#!/usr/bin/env bash
# Checks Porkbun accepts the API key and has API Access on for the domain.
#   porkbun_preflight.sh <domain>
# Keys come from PORKBUN_API_KEY / PORKBUN_SECRET_API_KEY. PORKBUN_API_BASE
# overrides the base URL (tests).
set -euo pipefail

domain="${1:?usage: porkbun_preflight.sh <domain>}"
base="${PORKBUN_API_BASE:-https://api.porkbun.com/api/json/v3}"
body="$(python3 -c 'import json,os;print(json.dumps({"apikey":os.environ.get("PORKBUN_API_KEY",""),"secretapikey":os.environ.get("PORKBUN_SECRET_API_KEY","")}))')"

# Prints "<status>|<message>" for a POST; message is Porkbun's own text.
call() {
  curl -sS --max-time 30 -X POST -H 'Content-Type: application/json' -d "$body" "$base/$1" 2>&1 \
    | python3 -c 'import json,sys
raw=sys.stdin.read()
try:
    j=json.loads(raw)
    print(j.get("status","?")+"|"+str(j.get("message","")))
except Exception:
    print("ERROR|no JSON reply: "+raw[:200])' || true   # curl failure still reaches the ::error:: below
}

r="$(call ping)"
if [ "${r%%|*}" != SUCCESS ]; then
  echo "::error::Porkbun did not accept the API key (${r#*|}). Check the API key and secret key in DNS_CREDENTIALS (or the PORKBUN_* secrets)."
  exit 1
fi
r="$(call "dns/retrieve/$domain")"
if [ "${r%%|*}" != SUCCESS ]; then
  echo "::error::Porkbun refused access to $domain (${r#*|}). Turn on API Access for this domain in Porkbun's domain list (Domain Management > Details > API Access)."
  exit 1
fi
echo "Porkbun accepted the key and API access is on for $domain."
