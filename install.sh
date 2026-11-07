#!/bin/bash

REPO="mrtome101/pterodactyl-helper"
PANEL="/var/www/pterodactyl"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
BOLD='\033[1m'
RESET='\033[0m'

banner() {
  clear
  echo -e "${CYAN}"
  cat << 'EOF'
  ████████╗ ██████╗ ███╗   ███╗███╗   ███╗██╗   ██╗
  ╚══██╔══╝██╔═══██╗████╗ ████║████╗ ████║╚██╗ ██╔╝
     ██║   ██║   ██║██╔████╔██║██╔████╔██║ ╚████╔╝ 
     ██║   ██║   ██║██║╚██╔╝██║██║╚██╔╝██║  ╚██╔╝  
     ██║   ╚██████╔╝██║ ╚═╝ ██║██║ ╚═╝ ██║   ██║   
     ╚═╝    ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚═╝   ╚═╝   
EOF
  echo -e "${RESET}"
  echo -e "${MAGENTA}        Pterodactyl Blueprint Extension Installer${RESET}"
  echo -e "${CYAN}  ------------------------------------------------------${RESET}"
  echo ""
}

pause() {
  echo ""
  read -r -p "Press Enter to continue..." _ < /dev/tty
}

install_one() {
  local URL="$1"
  local NAME
  NAME="$(basename "$URL" .blueprint)"

  echo -e "${YELLOW}Downloading ${NAME}...${RESET}"
  if ! curl -fL -o "${NAME}.blueprint" "$URL"; then
    echo -e "${RED}Download failed for ${NAME}.${RESET}"
    return 1
  fi

  echo -e "${YELLOW}Installing ${NAME}...${RESET}"
  if blueprint -install "$NAME"; then
    echo -e "${GREEN}${NAME} was installed successfully.${RESET}"
  else
    echo -e "${RED}Installation of ${NAME} failed.${RESET}"
  fi
  rm -f "${NAME}.blueprint"
}

# ---------- Checks ----------
banner

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Please run this script as root.${RESET}"
  exit 1
fi

if ! command -v blueprint >/dev/null 2>&1; then
  echo -e "${RED}Blueprint was not installed. Install Blueprint first, then run this again.${RESET}"
  exit 1
fi

if [ ! -d "$PANEL" ]; then
  echo -e "${RED}Panel folder not found: ${PANEL}${RESET}"
  exit 1
fi

cd "$PANEL" || exit 1

# ---------- Fetch extension list ----------
echo -e "${YELLOW}Fetching extension list...${RESET}"
mapfile -t URLS < <(curl -s "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.blueprint"' \
  | sed 's/.*"\(https[^"]*\)"$/\1/')

if [ "${#URLS[@]}" -eq 0 ]; then
  echo -e "${RED}No .blueprint files found in the latest release.${RESET}"
  exit 1
fi

# ---------- Main loop ----------
while true; do
  banner
  echo -e "${BOLD}  Available extensions:${RESET}"
  echo ""
  i=1
  for u in "${URLS[@]}"; do
    printf "   ${GREEN}%2d)${RESET} %s\n" "$i" "$(basename "$u" .blueprint)"
    i=$((i+1))
  done
  echo ""
  echo -e "   ${YELLOW} I)${RESET} Install ALL extensions"
  echo -e "   ${RED} 0)${RESET} Exit"
  echo ""
  echo -e "${CYAN}  ------------------------------------------------------${RESET}"
  read -r -p "  Select an option: " CHOICE < /dev/tty

  case "$CHOICE" in
    0|"")
      echo -e "${GREEN}Goodbye!${RESET}"
      exit 0
      ;;
    I|i)
      echo ""
      echo -e "${YELLOW}This will install ALL ${#URLS[@]} extensions, one after another.${RESET}"
      read -r -p "  Are you sure? (y/N): " CONFIRM < /dev/tty
      if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
        for u in "${URLS[@]}"; do
          echo ""
          install_one "$u"
        done
        echo ""
        echo -e "${GREEN}All done.${RESET}"
      else
        echo -e "${RED}Cancelled.${RESET}"
      fi
      pause
      ;;
    *)
      if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "${#URLS[@]}" ]; then
        echo -e "${RED}Invalid option.${RESET}"
        pause
        continue
      fi
      URL="${URLS[$((CHOICE-1))]}"
      NAME="$(basename "$URL" .blueprint)"
      echo ""
      read -r -p "  Install ${NAME}? (y/N): " CONFIRM < /dev/tty
      if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
        install_one "$URL"
      else
        echo -e "${RED}Cancelled.${RESET}"
      fi
      pause
      ;;
  esac
done
