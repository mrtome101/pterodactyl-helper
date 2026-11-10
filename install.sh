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
  echo -e "${MAGENTA}        Pterodactyl Blueprint & Themes Installer${RESET}"
  echo -e "${CYAN}  ------------------------------------------------------${RESET}"
  echo ""
}

pause() {
  echo ""
  read -r -p "Press Enter to continue..." _ < /dev/tty
}

is_theme_name() {
  local t
  for t in "${THEME_NAMES[@]}"; do
    [ "$1" = "$t" ] && return 0
  done
  return 1
}

# Checks if an extension is already installed in the panel
is_installed() {
  [ -d "$PANEL/.blueprint/extensions/$1" ]
}

# ---------- Blueprint framework installer ----------
install_blueprint_framework() {
  echo -e "${YELLOW}Installing Blueprint framework...${RESET}"

  if ! command -v apt-get >/dev/null 2>&1; then
    echo -e "${RED}Auto-install only supports Debian/Ubuntu (apt). Install Blueprint manually.${RESET}"
    return 1
  fi

  cd "$PANEL" || return 1

  echo -e "${YELLOW}Installing dependencies...${RESET}"
  apt-get update -y
  apt-get install -y curl wget unzip zip git ca-certificates gnupg || return 1

  # Node.js 20
  if ! command -v node >/dev/null 2>&1; then
    echo -e "${YELLOW}Installing Node.js 20...${RESET}"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || return 1
    apt-get install -y nodejs || return 1
  fi

  # Yarn
  if ! command -v yarn >/dev/null 2>&1; then
    npm i -g yarn || return 1
  fi

  echo -e "${YELLOW}Running yarn install in panel...${RESET}"
  yarn install || return 1

  echo -e "${YELLOW}Downloading latest Blueprint release...${RESET}"
  local BP_URL
  BP_URL="$(curl -s https://api.github.com/repos/BlueprintFramework/framework/releases/latest \
    | grep -o '"browser_download_url": *"[^"]*release.zip"' \
    | sed 's/.*"\(https[^"]*\)"$/\1/' | head -n 1)"

  if [ -z "$BP_URL" ]; then
    echo -e "${RED}Could not find Blueprint release.zip (GitHub API limit or network issue).${RESET}"
    return 1
  fi

  wget -O release.zip "$BP_URL" || return 1
  unzip -o release.zip || return 1
  rm -f release.zip

  # Detect web user (www-data on Debian/Ubuntu, nginx on some setups)
  local WEBUSER="www-data"
  if ! id "$WEBUSER" >/dev/null 2>&1 && id nginx >/dev/null 2>&1; then
    WEBUSER="nginx"
  fi

  cat > .blueprintrc << RC
WEBUSER="${WEBUSER}";
OWNERSHIP="${WEBUSER}:${WEBUSER}";
USERSHELL="/bin/bash";
RC

  chmod +x blueprint.sh
  bash blueprint.sh

  # Refresh command lookup
  hash -r
  if command -v blueprint >/dev/null 2>&1; then
    echo -e "${GREEN}Blueprint installed successfully.${RESET}"
    return 0
  else
    echo -e "${RED}Blueprint install finished but the 'blueprint' command was not found.${RESET}"
    return 1
  fi
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

# ---------- Delete / Uninstall ----------
INSTALLED=()

# Reads installed extensions from Blueprint's extensions folder
get_installed() {
  INSTALLED=()
  local dir="$PANEL/.blueprint/extensions"
  local d id
  [ -d "$dir" ] || return 0
  for d in "$dir"/*/; do
    [ -d "$d" ] || continue
    id="$(basename "$d")"
    [ "$id" = "blueprint" ] && continue   # framework's own entry, never list it
    INSTALLED+=("$id")
  done
}

remove_one() {
  local ID="$1"
  cd "$PANEL" || return 1

  echo -e "${YELLOW}Removing ${ID}...${RESET}"
  # blueprint -remove asks for a y/N confirmation, we already confirmed above
  echo "y" | blueprint -remove "$ID"

  if [ ! -d "$PANEL/.blueprint/extensions/$ID" ]; then
    echo -e "${GREEN}${ID} removed successfully.${RESET}"
  else
    echo -e "${RED}Removal of ${ID} failed.${RESET}"
  fi
}

remove_menu() {
  local -A SEL=()
  local n count k CHOICE CONFIRM MARK TAG TOTAL

  while true; do
    get_installed
    TOTAL="${#INSTALLED[@]}"

    banner
    echo -e "  ${BOLD}Delete / Uninstall${RESET}"
    echo ""

    if [ "$TOTAL" -eq 0 ]; then
      echo -e "${RED}Nothing installed to delete.${RESET}"
      pause
      return 0
    fi

    for ((n=1; n<=TOTAL; n++)); do
      if [ "${SEL[$n]}" = "1" ]; then
        MARK="${GREEN}[+]${RESET}"
      else
        MARK="[ ]"
      fi
      TAG=""
      is_theme_name "${INSTALLED[$((n-1))]}" && TAG=" ${MAGENTA}(theme)${RESET}"
      printf "   %b ${GREEN}%2d)${RESET} %s%b\n" "$MARK" "$n" "${INSTALLED[$((n-1))]}" "$TAG"
    done

    count=0
    for k in "${!SEL[@]}"; do
      [ "${SEL[$k]}" = "1" ] && count=$((count+1))
    done

    echo ""
    echo -e "   ${YELLOW} B)${RESET} Back"
    echo -e "   ${CYAN}Enter)${RESET} Delete selected (${count} selected)"
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
        echo -e "${BOLD}  These will be DELETED:${RESET}"
        for ((n=1; n<=TOTAL; n++)); do
          [ "${SEL[$n]}" = "1" ] && echo -e "   ${RED}-${RESET} ${INSTALLED[$((n-1))]}"
        done
        echo ""
        read -r -p "  Are you sure? (y/N): " CONFIRM < /dev/tty

        if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
          for ((n=1; n<=TOTAL; n++)); do
            if [ "${SEL[$n]}" = "1" ]; then
              echo ""
              remove_one "${INSTALLED[$((n-1))]}"
            fi
          done
          echo ""
          echo -e "${GREEN}All done.${RESET}"
          SEL=()   # list changes after deletion, so reset selection
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
        if [ "${SEL[$CHOICE]}" = "1" ]; then
          SEL[$CHOICE]=0
        else
          SEL[$CHOICE]=1
        fi
        ;;
    esac
  done
}

# ---------- Checks ----------
banner

if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}Please run this script as root.${RESET}"
  exit 1
fi

if [ ! -d "$PANEL" ]; then
  echo -e "${RED}Panel folder not found: ${PANEL}${RESET}"
  exit 1
fi

cd "$PANEL" || exit 1

if ! command -v blueprint >/dev/null 2>&1; then
  echo -e "${YELLOW}Blueprint is not installed.${RESET}"
  read -r -p "Install Blueprint now? (y/N): " ANS < /dev/tty
  if [ "$ANS" != "y" ] && [ "$ANS" != "Y" ]; then
    echo -e "${RED}Blueprint is required. Exiting.${RESET}"
    exit 1
  fi

  echo -e "${YELLOW}Tip: take a backup of your panel before continuing.${RESET}"
  read -r -p "Continue? (y/N): " ANS2 < /dev/tty
  if [ "$ANS2" != "y" ] && [ "$ANS2" != "Y" ]; then
    echo -e "${RED}Cancelled.${RESET}"
    exit 1
  fi

  if ! install_blueprint_framework; then
    echo -e "${RED}Blueprint install failed. Check the errors above.${RESET}"
    exit 1
  fi
  cd "$PANEL" || exit 1
  sleep 2
fi

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
  if is_theme_name "$n"; then
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
  local n count k CHOICE CONFIRM MARK NAME DOT

  if [ "$TOTAL" -eq 0 ]; then
    echo -e "${RED}No ${TITLE} found in the latest release.${RESET}"
    pause
    return 0
  fi

  while true; do
    banner
    echo -e "  ${BOLD}${TITLE}${RESET}"
    echo ""

    # List is redrawn every loop, so the dot refreshes right after an install
    for ((n=1; n<=TOTAL; n++)); do
      NAME="$(basename "${LIST[$((n-1))]}" .blueprint)"

      if [ "${SEL[$n]}" = "1" ]; then
        MARK="${GREEN}[+]${RESET}"
      else
        MARK="[ ]"
      fi

      if is_installed "$NAME"; then
        DOT="${GREEN}●${RESET}"
      else
        DOT="${RED}○${RESET}"
      fi

      printf "   %b ${GREEN}%2d)${RESET} %b %s\n" "$MARK" "$n" "$DOT" "$NAME"
    done

    count=0
    for k in "${!SEL[@]}"; do
      [ "${SEL[$k]}" = "1" ] && count=$((count+1))
    done

    echo ""
    echo -e "   ${GREEN}●${RESET} = installed   ${RED}○${RESET} = not installed"
    echo ""
    if [ "$SINGLE" -eq 0 ]; then
      echo -e "   ${GREEN} A)${RESET} Select All"
    fi
    echo -e "   ${YELLOW} B)${RESET} Back"
    echo -e "   ${CYAN}Enter)${RESET} Install selected (${count} selected)"
    echo ""
    echo -e "${CYAN}  ------------------------------------------------------${RESET}"
    read -r -p "  Enter a number to select/unselect: " CHOICE < /dev/tty

    case "$CHOICE" in
      B|b)
        return 0
        ;;
      A|a)
        if [ "$SINGLE" -eq 1 ]; then
          echo -e "${RED}Select All is not available here (only one theme at a time).${RESET}"
          pause
          continue
        fi
        # If everything is already selected, A again will unselect all
        if [ "$count" -eq "$TOTAL" ]; then
          SEL=()
        else
          for ((n=1; n<=TOTAL; n++)); do
            SEL[$n]=1
          done
        fi
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
  echo -e "   ${YELLOW} 3)${RESET} Delete / Uninstall"
  echo -e "   ${RED} 0)${RESET} Exit"
  echo ""
  echo -e "${CYAN}  ------------------------------------------------------${RESET}"
  read -r -p "  Select an option: " TOP < /dev/tty

  case "$TOP" in
    1) section_menu "Blueprints" BP_URLS 0 ;;
    2) section_menu "Themes" THEME_URLS 1 ;;
    3) remove_menu ;;
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
