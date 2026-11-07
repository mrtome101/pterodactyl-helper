#!/bin/bash
set -e

REPO="mrtome101/pterodactyl-helper"
PANEL="/var/www/pterodactyl"

if [ "$(id -u)" -ne 0 ]; then
  echo "Isse root user se chalao."
  exit 1
fi

if ! command -v blueprint >/dev/null 2>&1; then
  echo "Blueprint installed nahi hai. Pehle Blueprint install karo."
  exit 1
fi

if [ ! -d "$PANEL" ]; then
  echo "Panel folder nahi mila: $PANEL"
  exit 1
fi

cd "$PANEL"

echo "Extensions ki list la raha hu..."
mapfile -t URLS < <(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.blueprint"' \
  | sed 's/.*"\(https[^"]*\)"$/\1/')

if [ "${#URLS[@]}" -eq 0 ]; then
  echo "Koi .blueprint file nahi mili."
  exit 1
fi

echo ""
echo "=== Available Extensions ==="
i=1
for u in "${URLS[@]}"; do
  echo "$i) $(basename "$u" .blueprint)"
  i=$((i+1))
done
echo "0) Exit"
echo ""

read -p "Number chuno: " CHOICE

if [ "$CHOICE" = "0" ] || [ -z "$CHOICE" ]; then
  echo "Bye!"
  exit 0
fi

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -gt "${#URLS[@]}" ]; then
  echo "Galat number."
  exit 1
fi

URL="${URLS[$((CHOICE-1))]}"
NAME="$(basename "$URL" .blueprint)"

echo "Download ho raha hai: $NAME"
curl -L -o "$NAME.blueprint" "$URL"

echo "Install ho raha hai..."
blueprint -install "$NAME"

rm -f "$NAME.blueprint"
echo "Ho gaya! $NAME install ho gaya."
