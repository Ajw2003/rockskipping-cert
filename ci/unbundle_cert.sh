#!/usr/bin/env bash
# Unpacks pad-cert.json into <dir>/chain.pem, <dir>/key.pem and <dir>/name, so
# check_cert.sh can read the chain. Exits 1 if the file isn't a usable bundle.
#
#   unbundle_cert.sh <pad-cert.json> <dir>
set -euo pipefail

bundle="${1:?usage: unbundle_cert.sh <pad-cert.json> <dir>}"
dir="${2:?}"
mkdir -p "$dir"

python3 - "$bundle" "$dir" <<'PY'
import json, os, sys
bundle_path, out = sys.argv[1:]
try:
    with open(bundle_path) as f:
        b = json.load(f)
    for field in ("name", "chain", "key"):
        if not isinstance(b.get(field), str) or not b[field]:
            raise ValueError("missing field %r" % field)
except Exception as exc:
    print("unbundle_cert.sh: not a usable bundle: %s" % exc, file=sys.stderr)
    sys.exit(1)
with open(os.path.join(out, "chain.pem"), "w") as f: f.write(b["chain"])
with open(os.path.join(out, "key.pem"), "w") as f: f.write(b["key"])
with open(os.path.join(out, "name"), "w") as f: f.write(b["name"] + "\n")
PY
