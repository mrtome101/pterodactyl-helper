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

MODE="install"
declare -A SELECTED

banner() {
  clear
  echo -e "${CYAN}"
  cat << 'EOF'
  ████████╗ ██████╗ ███╗   ███╗███████╗
  ╚══██╔══╝██╔═══██╗████╗ ████║██╔════╝
     ██║   ██║   ██║██╔████╔██║█████╗  
     ██║   ██║   ██║██║╚██╔╝██║██╔══╝  
     ██║   ╚██████╔╝██║ ╚═╝ ██║███████╗
     ╚═╝    ╚═════╝ ╚═╝     ╚═╝╚══════╝
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

remove_one() {
  local NAME="$1"

  echo -e "${YELLOW}Removing ${NAME}...${RESET}"
  if blueprint -remove "$NAME"; then
    echo -e "${GREEN}${NAME} was removed successfully.${RESET}"
  else
    echo -e "${RED}Removal of ${NAME} failed.${RESET}"
  fi
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

TOTAL="${#URLS[@]}"

count_selected() {
  local c=0 k
  for k in "${!SELECTED[@]}"; do
    [ "${SELECTED[$k]}" = "1" ] && c=$((c+1))
  done
  echo "$c"
}

# ---------- Main loop ----------
while true; do
  banner

  if [ "$MODE" = "install" ]; then
    echo -e "  Current mode: ${GREEN}${BOLD}INSTALL${RESET}"
  else
    echo -e "  Current mode: ${RED}${BOLD}REMOVE${RESET}"
  fi
  echo ""
  echo -e "${BOLD}  Available extensions:${RESET}"
  echo ""

  for ((n=1; n<=TOTAL; n++)); do
    u="${URLS[$((n-1))]}"
    if [ "${SELECTED[$n]}" = "1" ]; then
      MARK="${GREEN}[x]${RESET}"
    else
      MARK="[ ]"
    fi
    printf "   ${GREEN}%2d)${RESET} %b %s\n" "$n" "$MARK" "$(basename "$u" .blueprint)"
  done

  echo ""
  echo -e "   ${YELLOW} I)${RESET} Install mode"
  echo -e "   ${YELLOW} R)${RESET} Remove mode"
  echo -e "   ${YELLOW} A)${RESET} Select all"
  echo -e "   ${YELLOW} C)${RESET} Clear selection"
  echo -e "   ${YELLOW} Q)${RESET} Quit"
  echo -e "   ${CYAN}Enter)${RESET} Continue with selected ($(count_selected) selected)"
  echo ""
  echo -e "${CYAN}  ------------------------------------------------------${RESET}"
  read -r -p "  Number to select/unselect, or an option: " CHOICE < /dev/tty

  case "$CHOICE" in
    I|i)
      MODE="install"
      ;;
    R|r)
      MODE="remove"
      ;;
    A|a)
      for ((n=1; n<=TOTAL; n++)); do SELECTED[$n]=1; done
      ;;
    C|c)
      SELECTED=()
      ;;
    Q|q|0)
      echo -e "${GREEN}Goodbye!${RESET}"
      exit 0
      ;;
    "")
      if [ "$(count_selected)" -eq 0 ]; then
        echo -e "${RED}Nothing selected. Select at least one extension first.${RESET}"
        pause
        continue
      fi

      echo ""
      echo -e "${BOLD}  You selected these extensions to ${MODE}:${RESET}"
      echo ""
      for ((n=1; n<=TOTAL; n++)); do
        if [ "${SELECTED[$n]}" = "1" ]; then
          echo -e "   ${GREEN}-${RESET} $(basename "${URLS[$((n-1))]}" .blueprint)"
        fi
      done
      echo ""
      read -r -p "  Are you sure you want to ${MODE} them? (y/N): " CONFIRM < /dev/tty

      if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
        for ((n=1; n<=TOTAL; n++)); do
          if [ "${SELECTED[$n]}" = "1" ]; then
            u="${URLS[$((n-1))]}"
            echo ""
            if [ "$MODE" = "install" ]; then
              install_one "$u"
            else
              remove_one "$(basename "$u" .blueprint)"
            fi
          fi
        done
        echo ""
        echo -e "${GREEN}All done.${RESET}"
        SELECTED=()
      else
        echo -e "${RED}Cancelled.${RESET}"
      fi
      pause
      ;;
    *)
      if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$TOTAL" ]; then
        echo -e "${RED}Invalid option.${RESET}"
        pause
        continue
      fi
      if [ "${SELECTED[$CHOICE]}" = "1" ]; then
        SELECTED[$CHOICE]=0
      else
        SELECTED[$CHOICE]=1
      fi
      ;;
  esac
done
