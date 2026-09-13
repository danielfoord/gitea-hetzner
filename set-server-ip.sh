#!/usr/bin/env bash
# set-server-ip.sh — replace <SERVER_IP> placeholders in gitea-values.yaml
# Usage: ./set-server-ip.sh <IP_ADDRESS>

set -euo pipefail

FILE="$(dirname "$0")/gitea-values.yaml"
IP="${1:-}"

usage() {
  echo "Usage: $0 <IP_ADDRESS>" >&2
  exit 1
}

[[ -z "$IP" ]] && usage

# Basic IPv4 sanity check (four octets 0-255)
if [[ ! "$IP" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
  echo "Error: '$IP' doesn't look like an IPv4 address." >&2
  exit 1
fi
for octet in "${BASH_REMATCH[@]:1}"; do
  if (( octet > 255 )); then
    echo "Error: '$IP' has an octet > 255." >&2
    exit 1
  fi
done

[[ -f "$FILE" ]] || { echo "Error: $FILE not found." >&2; exit 1; }

if ! grep -q '<SERVER_IP>' "$FILE"; then
  echo "No <SERVER_IP> placeholders found in $FILE — nothing to do."
  exit 0
fi

BEFORE_COUNT=$(grep -o '<SERVER_IP>' "$FILE" | wc -l | tr -d ' ')

cp "$FILE" "$FILE.bak"
sed -i '' "s/<SERVER_IP>/$IP/g" "$FILE"

echo "Replaced $BEFORE_COUNT instance(s) of <SERVER_IP> with $IP in $FILE"
echo "Backup saved: $FILE.bak"
echo
echo "Changed lines:"
diff -u "$FILE.bak" "$FILE" | grep -E '^[+-]' | grep -v -E '^(\+\+\+|---)'
