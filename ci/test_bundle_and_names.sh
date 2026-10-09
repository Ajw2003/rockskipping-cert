#!/usr/bin/env bash
# Tests for pick_name.sh, bundle_cert.sh and unbundle_cert.sh. Offline: builds
# throwaway certificate authorities with openssl in a temp dir.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
failures=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
expect() { # expect <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# --- pick_name.sh -----------------------------------------------------------
P="$HERE/pick_name.sh"
expect "revoked moves to the next name"        pad2.skiprocking.ca "$("$P" pad.skiprocking.ca revoked)"
expect "revoked on the last name wraps around"  pad.skiprocking.ca  "$("$P" pad3.skiprocking.ca revoked)"
expect "expiring keeps the name"               pad2.skiprocking.ca "$("$P" pad2.skiprocking.ca expiring)"
expect "invalid keeps the name"                pad3.skiprocking.ca "$("$P" pad3.skiprocking.ca invalid)"
expect "missing with no name starts at first"  pad.skiprocking.ca  "$("$P" "" missing)"
expect "unknown current name starts at first"  pad.skiprocking.ca  "$("$P" old.skiprocking.ca expiring)"
expect "revoked unknown name starts at first"  pad.skiprocking.ca  "$("$P" old.skiprocking.ca revoked)"
"$P" pad.skiprocking.ca bogus > /dev/null 2>&1
expect "unknown reason exits 2" 2 "$?"

# --- certificates -----------------------------------------------------------
# make_ca <dir> <common name>
make_ca() {
  mkdir -p "$1"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
    -subj "/CN=$2" -keyout "$1/ca.key" -out "$1/ca.pem" 2> /dev/null
}
# make_leaf <ca dir> <out prefix> <dns name>
make_leaf() {
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$3" \
    -keyout "$2.key" -out "$2.csr" 2> /dev/null
  printf 'subjectAltName=DNS:%s\n' "$3" > "$2.ext"
  openssl x509 -req -in "$2.csr" -CA "$1/ca.pem" -CAkey "$1/ca.key" -CAcreateserial \
    -days 10 -extfile "$2.ext" -out "$2.pem" 2> /dev/null
  cat "$2.pem" "$1/ca.pem" > "$2.chain.pem"
}

make_ca "$T/prod" "Test Production CA"
make_ca "$T/stage" "(STAGING) Test Pretend CA"
make_leaf "$T/prod" "$T/good" pad.skiprocking.ca
make_leaf "$T/prod" "$T/other" pad.skiprocking.ca
make_leaf "$T/stage" "$T/stg" pad.skiprocking.ca

B="$HERE/bundle_cert.sh"
U="$HERE/unbundle_cert.sh"

"$B" "$T/good.chain.pem" "$T/good.key" pad.skiprocking.ca production "$T/good.json" > "$T/out.txt" 2>&1
expect "good production certificate bundles" 0 "$?"

"$U" "$T/good.json" "$T/round" > /dev/null 2>&1
rc=$?
if [ "$rc" = 0 ] && cmp -s "$T/round/chain.pem" "$T/good.chain.pem" && cmp -s "$T/round/key.pem" "$T/good.key" \
   && [ "$(cat "$T/round/name")" = pad.skiprocking.ca ]; then
  pass "bundle round-trips through unbundle unchanged"
else
  fail "bundle round-trips through unbundle unchanged (rc=$rc)"
fi

serial_json=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["serial"])' "$T/good.json")
serial_cert=$(openssl x509 -in "$T/good.pem" -noout -serial | cut -d= -f2)
expect "bundle records the certificate's serial" "$serial_cert" "$serial_json"

"$B" "$T/good.chain.pem" "$T/other.key" pad.skiprocking.ca production "$T/x.json" > /dev/null 2>&1
expect "mismatched key is refused" 1 "$?"

"$B" "$T/good.pem" "$T/good.key" pad.skiprocking.ca production "$T/x.json" > /dev/null 2>&1
expect "bare leaf is refused" 1 "$?"

"$B" "$T/good.chain.pem" "$T/good.key" pad2.skiprocking.ca production "$T/x.json" > /dev/null 2>&1
expect "wrong name is refused" 1 "$?"

"$B" "$T/stg.chain.pem" "$T/stg.key" pad.skiprocking.ca production "$T/x.json" > /dev/null 2>&1
expect "staging certificate refused on a production run" 1 "$?"

"$B" "$T/good.chain.pem" "$T/good.key" pad.skiprocking.ca staging "$T/x.json" > /dev/null 2>&1
expect "trusted certificate refused on a staging run" 1 "$?"

"$B" "$T/stg.chain.pem" "$T/stg.key" pad.skiprocking.ca staging "$T/stg.json" > /dev/null 2>&1
expect "staging certificate bundles on a staging run" 0 "$?"

echo '{"name": "pad.skiprocking.ca"}' > "$T/broken.json"
"$U" "$T/broken.json" "$T/broken" > /dev/null 2>&1
expect "bundle missing its key is refused" 1 "$?"

echo 'not json' > "$T/garbage.json"
"$U" "$T/garbage.json" "$T/garbage" > /dev/null 2>&1
expect "garbage bundle is refused" 1 "$?"

echo "----"
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILED"; exit 1; fi
