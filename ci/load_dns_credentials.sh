#!/usr/bin/env bash
# Exports the KEY=value lines of $DNS_CREDENTIALS (blank and # lines skipped)
# to $GITHUB_ENV, or prints `export` lines when GITHUB_ENV is unset (tests).
# Falls back to PORKBUN_API_KEY / PORKBUN_SECRET_API_KEY. Never prints values.
set -euo pipefail

out() { # name value
  echo "::add-mask::$2"
  if [ -n "${GITHUB_ENV:-}" ]; then
    # Random delimiter so a value can never end the block early.
    d="EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    printf '%s<<%s\n%s\n%s\n' "$1" "$d" "$2" "$d" >> "$GITHUB_ENV"
  else
    printf 'export %s=%q\n' "$1" "$2"
  fi
}

if [ -n "${DNS_CREDENTIALS:-}" ]; then
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    if [ "$key" = "$line" ] || ! [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
      echo "::error::DNS_CREDENTIALS line $n is not KEY=value with KEY in capitals, digits and underscores."
      exit 1
    fi
    val="${line#*=}"
    [ -n "$val" ] || continue
    out "$key" "$val"
  done <<< "$DNS_CREDENTIALS"
elif [ -n "${PORKBUN_API_KEY:-}" ] && [ -n "${PORKBUN_SECRET_API_KEY:-}" ]; then
  out PORKBUN_API_KEY "$PORKBUN_API_KEY"
  out PORKBUN_SECRET_API_KEY "$PORKBUN_SECRET_API_KEY"
else
  echo "::error::No DNS keys. Add the repository secret DNS_CREDENTIALS (KEY=value lines), or the secrets PORKBUN_API_KEY and PORKBUN_SECRET_API_KEY."
  exit 1
fi
