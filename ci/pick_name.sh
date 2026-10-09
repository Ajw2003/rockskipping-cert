#!/usr/bin/env bash
# Prints the name the next certificate should be issued for.
#
#   pick_name.sh <current-name|""> <reason>
#
# reason is revoked, expiring, invalid or missing. A revoked certificate moves
# to the next name in PAD_NAMES, because Let's Encrypt allows only 5
# certificates per exact name per 7 days and someone revoking every new
# certificate would otherwise lock us out of that one name. Every other reason
# keeps the current name, so routine renewals never change the address phones
# open.
set -euo pipefail

PAD_NAMES="${PAD_NAMES:-pad.skiprocking.ca pad2.skiprocking.ca pad3.skiprocking.ca}"
current="${1:-}"
reason="${2:?usage: pick_name.sh <current-name> <revoked|expiring|invalid|missing>}"

read -r -a names <<< "$PAD_NAMES"
first="${names[0]}"

index=-1
for i in "${!names[@]}"; do
  if [ "${names[$i]}" = "$current" ]; then index=$i; fi
done

case "$reason" in
  revoked)
    if [ "$index" -lt 0 ]; then echo "$first"; else echo "${names[$(( (index + 1) % ${#names[@]} ))]}"; fi
    ;;
  expiring|invalid|missing)
    # An unknown current name (renamed list, first run) starts over at the first.
    if [ "$index" -lt 0 ]; then echo "$first"; else echo "$current"; fi
    ;;
  *)
    echo "pick_name.sh: unknown reason '$reason'" >&2
    exit 2
    ;;
esac
