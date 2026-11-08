#!/bin/bash

REPO="mrtome101/pterodactyl-helper"
PANEL="/var/www/pterodactyl"

# Names listed here show up under Themes. Everything else is a Blueprint.
THEME_NAMES=("nebula")

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
  ████████╗ ██████╗ ███╗   ███╗███████╗
  ╚══██╔══╝██╔═══██╗████╗ ████║██╔════╝
     ██║   ██║   ██║██╔████╔██║█████╗  
     ██║   ██║   ██║██║╚██╔╝██║██╔══╝  
     ██║   ╚██████╔╝██║ ╚═╝ ██║███████╗
     ╚═╝    ╚═════╝ ╚═╝     ╚═╝╚══════╝
EOF
  echo -e "${RESET}"
  echo -e "${MAGENTA}        Pterodactyl Blueprint Installer${RESET}"
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
    echo -e "${GREEN}${NAME} installed successfully.${RESET}"
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
  echo -e "${RED}Blueprint is not installed. Install Blueprint first, then run this again.${RESET}"
  exit 1
fi

if [ ! -d "$PANEL" ]; then
  echo -e "${RED}Panel folder not found: ${PANEL}${RESET}"
  exit 1
fi

cd "$PANEL" || exit 1

# ---------- Fetch list ----------
echo -e "${YELLOW}Fetching list from GitHub...${RESET}"
mapfile -t ALL_URLS < <(curl -s "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.blueprint"' \
  | sed 's/.*"\(https[^"]*\)"$/\1/')

if [ "${#ALL_URLS[@]}" -eq 0 ]; then
  echo -e "${RED}No .blueprint files found in the latest release.${RESET}"
  exit 1
fi

# ---------- Split: Blueprints / Themes ----------
BP_URLS=()
THEME_URLS=()
for u in "${ALL_URLS[@]}"; do
  n="$(basename "$u" .blueprint)"
  is_theme=0
  for t in "${THEME_NAMES[@]}"; do
    [ "$n" = "$t" ] && is_theme=1
  done
  if [ "$is_theme" -eq 1 ]; then
    THEME_URLS+=("$u")
  else
    BP_URLS+=("$u")
  fi
done

# ---------- Section menu ----------
# Usage: section_menu "Title" LIST_ARRAY_NAME SINGLE(0=multi, 1=only one)
section_menu() {
  local TITLE="$1"
  local -n LIST="$2"
  local SINGLE="$3"
  local TOTAL="${#LIST[@]}"
  local -A SEL=()
  local n count k CHOICE CONFIRM MARK

  if [ "$TOTAL" -eq 0 ]; then
    echo -e "${RED}No ${TITLE} found in the latest release.${RESET}"
    pause
    return 0
  fi

  while true; do
    banner
    echo -e "  ${BOLD}${TITLE}${RESET}"
    echo ""

    for ((n=1; n<=TOTAL; n++)); do
      if [ "${SEL[$n]}" = "1" ]; then
        MARK="${GREEN}[x]${RESET}"
      else
        MARK="[ ]"
      fi
      printf "   ${GREEN}%2d)${RESET} %b %s\n" "$n" "$MARK" "$(basename "${LIST[$((n-1))]}" .blueprint)"
    done

    count=0
    for k in "${!SEL[@]}"; do
      [ "${SEL[$k]}" = "1" ] && count=$((count+1))
    done

    echo ""
    echo -e "   ${YELLOW} B)${RESET} Back"
    echo -e "   ${CYAN}Enter)${RESET} Install selected (${count} selected)"
    echo ""
    echo -e "${CYAN}  ------------------------------------------------------${RESET}"
    read -r -p "  Enter a number to select/unselect: " CHOICE < /dev/tty

    case "$CHOICE" in
      B|b)
        return 0
        ;;
      "")
        if [ "$count" -eq 0 ]; then
          echo -e "${RED}Nothing selected. Select at least one first.${RESET}"
          pause
          continue
        fi

        echo ""
        echo -e "${BOLD}  These will be installed:${RESET}"
        for ((n=1; n<=TOTAL; n++)); do
          [ "${SEL[$n]}" = "1" ] && echo -e "   ${GREEN}-${RESET} $(basename "${LIST[$((n-1))]}" .blueprint)"
        done
        echo ""
        read -r -p "  Install them? (y/N): " CONFIRM < /dev/tty

        if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
          for ((n=1; n<=TOTAL; n++)); do
            if [ "${SEL[$n]}" = "1" ]; then
              echo ""
              install_one "${LIST[$((n-1))]}"
            fi
          done
          echo ""
          echo -e "${GREEN}All done.${RESET}"
          SEL=()
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
        if [ "$SINGLE" -eq 1 ]; then
          # Themes: only one can be selected at a time
          if [ "${SEL[$CHOICE]}" = "1" ]; then
            SEL=()
          else
            SEL=()
            SEL[$CHOICE]=1
          fi
        else
          if [ "${SEL[$CHOICE]}" = "1" ]; then
            SEL[$CHOICE]=0
          else
            SEL[$CHOICE]=1
          fi
        fi
        ;;
    esac
  done
}

# ---------- Main menu (left: Blueprints | right: Themes) ----------
while true; do
  banner
  LEFT="Blueprints (${#BP_URLS[@]})"
  RIGHT="Themes (${#THEME_URLS[@]})"
  echo -e "   ${CYAN}┌──────────────────────────┬──────────────────────────┐${RESET}"
  printf "   ${CYAN}│${RESET} ${GREEN}1)${RESET} %-22s ${CYAN}│${RESET} ${GREEN}2)${RESET} %-22s ${CYAN}│${RESET}\n" "$LEFT" "$RIGHT"
  echo -e "   ${CYAN}└──────────────────────────┴──────────────────────────┘${RESET}"
  echo ""
  echo -e "   ${RED} 0)${RESET} Exit"
  echo ""
  echo -e "${CYAN}  ------------------------------------------------------${RESET}"
  read -r -p "  Select an option: " TOP < /dev/tty

  case "$TOP" in
    1) section_menu "Blueprints" BP_URLS 0 ;;
    2) section_menu "Themes" THEME_URLS 1 ;;
    0|Q|q)
      echo -e "${GREEN}Goodbye!${RESET}"
      exit 0
      ;;
    *)
      echo -e "${RED}Invalid option.${RESET}"
      pause
      ;;
  esac
done
