#!/bin/bash

REPO="mrtome101/pterodactyl-helper"
PANEL="/var/www/pterodactyl"

# Names listed here show up under Themes. Everything else is an extension.
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

# ---------- Fetch list ----------
echo -e "${YELLOW}Fetching extension list...${RESET}"
mapfile -t ALL_URLS < <(curl -s "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.blueprint"' \
  | sed 's/.*"\(https[^"]*\)"$/\1/')

if [ "${#ALL_URLS[@]}" -eq 0 ]; then
  echo -e "${RED}No .blueprint files found in the latest release.${RESET}"
  exit 1
fi

# ---------- Split into extensions and themes ----------
EXT_URLS=()
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
    EXT_URLS+=("$u")
  fi
done

# ---------- Selection menu ----------
# Usage: select_menu "Title" LIST_ARRAY_NAME SINGLE(0/1)
select_menu() {
  local TITLE="$1"
  local -n LIST="$2"
  local SINGLE="$3"
  local TOTAL="${#LIST[@]}"
  local MODE="install"
  local -A SEL=()
  local n u k count CHOICE CONFIRM MARK was

  if [ "$TOTAL" -eq 0 ]; then
    echo ""
    echo -e "${RED}No ${TITLE} found in the latest release.${RESET}"
    pause
    return 0
  fi

  while true; do
    banner
    echo -e "  ${BOLD}${TITLE}${RESET}"
    if [ "$MODE" = "install" ]; then
      echo -e "  Current mode: ${GREEN}${BOLD}INSTALL${RESET}"
    else
      echo -e "  Current mode: ${RED}${BOLD}REMOVE${RESET}"
    fi
    echo ""

    for ((n=1; n<=TOTAL; n++)); do
      u="${LIST[$((n-1))]}"
      if [ "${SEL[$n]}" = "1" ]; then
        MARK="${GREEN}[x]${RESET}"
      else
        MARK="[ ]"
      fi
      printf "   ${GREEN}%2d)${RESET} %b %s\n" "$n" "$MARK" "$(basename "$u" .blueprint)"
    done

    count=0
    for k in "${!SEL[@]}"; do
      [ "${SEL[$k]}" = "1" ] && count=$((count+1))
    done

    echo ""
    echo -e "   ${YELLOW} I)${RESET} Install mode"
    echo -e "   ${YELLOW} R)${RESET} Remove mode"
    if [ "$SINGLE" -eq 0 ]; then
      echo -e "   ${YELLOW} A)${RESET} Select all"
    fi
    echo -e "   ${YELLOW} C)${RESET} Clear selection"
    echo -e "   ${YELLOW} B)${RESET} Back to main menu"
    echo -e "   ${YELLOW} Q)${RESET} Quit"
    echo -e "   ${CYAN}Enter)${RESET} Continue with selected (${count} selected)"
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
        if [ "$SINGLE" -eq 0 ]; then
          for ((n=1; n<=TOTAL; n++)); do SEL[$n]=1; done
        else
          echo -e "${RED}Only one can be selected here.${RESET}"
          pause
        fi
        ;;
      C|c)
        SEL=()
        ;;
      B|b)
        return 0
        ;;
      Q|q|0)
        echo -e "${GREEN}Goodbye!${RESET}"
        exit 0
        ;;
      "")
        if [ "$count" -eq 0 ]; then
          echo -e "${RED}Nothing selected. Select at least one first.${RESET}"
          pause
          continue
        fi

        echo ""
        echo -e "${BOLD}  You selected these to ${MODE}:${RESET}"
        echo ""
        for ((n=1; n<=TOTAL; n++)); do
          if [ "${SEL[$n]}" = "1" ]; then
            echo -e "   ${GREEN}-${RESET} $(basename "${LIST[$((n-1))]}" .blueprint)"
          fi
        done
        echo ""
        read -r -p "  Are you sure you want to ${MODE} them? (y/N): " CONFIRM < /dev/tty

        if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
          for ((n=1; n<=TOTAL; n++)); do
            if [ "${SEL[$n]}" = "1" ]; then
              u="${LIST[$((n-1))]}"
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
          was="${SEL[$CHOICE]}"
          SEL=()
          if [ "$was" != "1" ]; then
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

# ---------- Main menu ----------
while true; do
  banner
  echo -e "${BOLD}  Main menu:${RESET}"
  echo ""
  echo -e "   ${GREEN} 1)${RESET} Blueprint Extensions (${#EXT_URLS[@]})"
  echo -e "   ${GREEN} 2)${RESET} Themes (${#THEME_URLS[@]})"
  echo ""
  echo -e "   ${RED} 0)${RESET} Exit"
  echo ""
  echo -e "${CYAN}  ------------------------------------------------------${RESET}"
  read -r -p "  Select an option: " TOP < /dev/tty

  case "$TOP" in
    1)
      select_menu "Blueprint Extensions" EXT_URLS 0
      ;;
    2)
      select_menu "Themes" THEME_URLS 1
      ;;
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
