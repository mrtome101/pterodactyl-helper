#!/bin/bash

REPO="mrtome101/pterodactyl-helper"
PANEL="/var/www/pterodactyl"
BACKUP_DIR="/root/blueprint-backups"

# Names listed here show up under Themes. Everything else is a Blueprint.
THEME_NAMES=("nebula")

# IP is fetched only once (banner redraws many times)
CACHED_IP=""

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------- System info helpers ----------
get_ip() {
  local ip
  ip="$(curl -s4 --max-time 3 https://api.ipify.org 2>/dev/null)"
  [ -z "$ip" ] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "${ip:-N/A}"
}

get_os() {
  if [ -f /etc/os-release ]; then
    ( . /etc/os-release; echo "${PRETTY_NAME:-$NAME}" )
  else
    uname -sr
  fi
}

get_uptime() {
  local s h m
  s="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
  s="${s:-0}"
  h=$((s / 3600))
  m=$(((s % 3600) / 60))
  echo "up ${h} hours, ${m} minutes"
}

get_mem() {
  free -h 2>/dev/null | awk '/^Mem:/ {print $3 " / " $2}'
}

get_disk() {
  df -h / 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 " used)"}'
}

banner() {
  clear
  local NAME HOST IP OS UP MEM DISK
  NAME="$(hostname -s 2>/dev/null || hostname)"
  HOST="$(hostname -f 2>/dev/null || hostname)"
  [ -z "$CACHED_IP" ] && CACHED_IP="$(get_ip)"
  IP="$CACHED_IP"
  OS="$(get_os)"
  UP="$(get_uptime)"
  MEM="$(get_mem)"
  DISK="$(get_disk)"

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
  echo -e "  ${MAGENTA}🚀  INFRASTRUCTURE, ELEVATED${RESET}"
  echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
  echo -e "  ${BOLD}🖥️  SERVER IDENTITY${RESET}"
  echo -e "  ${CYAN}▸${RESET} Name         │ ${NAME}"
  echo -e "  ${CYAN}▸${RESET} Hostname     │ ${HOST}"
  echo -e "  ${CYAN}▸${RESET} Primary IPv4 │ ${IP}"
  echo ""
  echo -e "  ${BOLD}⚙️  SYSTEM INFORMATION${RESET}"
  echo -e "  ${CYAN}▸${RESET} Operating System │ ${OS}"
  echo ""
  echo -e "  ${BOLD}⚡ PERFORMANCE${RESET}"
  echo -e "  🚀 Uptime       │ ${UP}"
  echo -e "  🧠 Memory       │ ${MEM}"
  echo -e "  💾 Disk Usage   │ ${DISK}"
  echo ""
  echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  ${GREEN}● ONLINE${RESET}  │ TomeStudios Infrastructure"
  echo ""
  echo -e "  ${BOLD}🌐 TomeStudios LINKS${RESET}"
  echo ""
  echo -e "  💬 Discord → https://discord.gg/pjCFdWsgCV"
  echo -e "  🌍 Website → https://www.tomestudios.fun/"
  echo -e "  🗳️ Github → https://github.com/mrtome101"
  echo ""
  echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""
}

pause() {
  echo ""
  read -r -p "Press Enter to continue..." _ < /dev/tty
}

ask_yn() {
  local a=""
  read -r -p "$1 (y/N): " a < /dev/tty
  [ "$a" = "y" ] || [ "$a" = "Y" ]
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

# Checks if the Blueprint framework itself is installed
blueprint_installed() {
  [ -f "$PANEL/blueprint.sh" ] && [ -d "$PANEL/.blueprint" ]
}

# =====================================================================
#  Blueprint framework: safe install / remove
#  - full backup first (files + .env + database dump)
#  - panel goes into maintenance mode while working
#  - if anything fails, the panel is restored from the backup
#  - users, servers, nodes and the database are never deleted
# =====================================================================
BP_BACKUP_FILE=""
BP_ENV_FILE=""
BP_DB_FILE=""
BP_BACKUP_DONE=0
BP_PANEL_DOWN=0
BP_TMP=""
BP_BIN=""
WEBUSER="www-data"
WEBGROUP="www-data"

artisan() { ( cd "$PANEL" && php artisan "$@" ); }

envget() {
  grep -E "^$1=" "$PANEL/.env" 2>/dev/null | head -n1 | cut -d= -f2- \
    | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

# Web user = owner of the panel files (falls back to www-data / nginx)
detect_webuser() {
  WEBUSER="$(stat -c '%U' "$PANEL/artisan" 2>/dev/null)"
  WEBGROUP="$(stat -c '%G' "$PANEL/artisan" 2>/dev/null)"
  if [ -z "$WEBUSER" ] || [ "$WEBUSER" = "root" ]; then
    WEBUSER="www-data"
    if ! id "$WEBUSER" >/dev/null 2>&1 && id nginx >/dev/null 2>&1; then
      WEBUSER="nginx"
    fi
    WEBGROUP="$WEBUSER"
  fi
}

bp_preflight() {
  if [ ! -f "$PANEL/artisan" ] || [ ! -f "$PANEL/.env" ]; then
    echo -e "${RED}Valid Pterodactyl panel not found in ${PANEL}.${RESET}"
    return 1
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo -e "${RED}This only supports Debian/Ubuntu (apt).${RESET}"
    return 1
  fi
  if ! command -v php >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED}php, tar and curl are required.${RESET}"
    return 1
  fi
  return 0
}

bp_backup() {
  local TS
  TS="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || return 1

  BP_BACKUP_FILE="$BACKUP_DIR/panel-$TS.tar.gz"
  BP_ENV_FILE="$BACKUP_DIR/env-$TS.bak"
  BP_DB_FILE="$BACKUP_DIR/db-$TS.sql"
  BP_BACKUP_DONE=0

  echo -e "${YELLOW}Creating backup (this can take a while)...${RESET}"
  if ! tar -czf "$BP_BACKUP_FILE" --exclude='node_modules' \
       -C "$(dirname "$PANEL")" "$(basename "$PANEL")"; then
    rm -f "$BP_BACKUP_FILE"
    echo -e "${RED}Backup failed (disk full?). Nothing was changed.${RESET}"
    return 1
  fi
  chmod 600 "$BP_BACKUP_FILE"
  cp -p "$PANEL/.env" "$BP_ENV_FILE" && chmod 600 "$BP_ENV_FILE"
  BP_BACKUP_DONE=1
  echo -e "${GREEN}Files backup: ${BP_BACKUP_FILE}${RESET}"

  # Database dump (optional, best effort)
  local H P U D PW
  H="$(envget DB_HOST)"; P="$(envget DB_PORT)"; U="$(envget DB_USERNAME)"
  D="$(envget DB_DATABASE)"; PW="$(envget DB_PASSWORD)"
  if command -v mysqldump >/dev/null 2>&1; then
    if MYSQL_PWD="$PW" mysqldump -h "${H:-127.0.0.1}" -P "${P:-3306}" -u "$U" \
         --single-transaction "$D" > "$BP_DB_FILE" 2>/dev/null; then
      chmod 600 "$BP_DB_FILE"
      echo -e "${GREEN}Database backup: ${BP_DB_FILE}${RESET}"
    else
      rm -f "$BP_DB_FILE"
      echo -e "${YELLOW}Database dump skipped (could not connect).${RESET}"
    fi
  else
    echo -e "${YELLOW}mysqldump not found, database dump skipped.${RESET}"
  fi
  return 0
}

bp_rollback() {
  echo ""
  echo -e "${RED}Something went wrong. Restoring the panel from backup...${RESET}"
  if [ "$BP_BACKUP_DONE" = "1" ] && [ -f "$BP_BACKUP_FILE" ] \
     && [ -n "$PANEL" ] && tar -tzf "$BP_BACKUP_FILE" >/dev/null 2>&1; then
    find "$PANEL" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    if tar -xzf "$BP_BACKUP_FILE" -C "$(dirname "$PANEL")"; then
      echo -e "${GREEN}Panel files restored.${RESET}"
    else
      echo -e "${RED}Restore failed! Restore manually with:${RESET}"
      echo "  tar -xzf $BP_BACKUP_FILE -C $(dirname "$PANEL")"
    fi
  else
    echo -e "${RED}Backup is not usable, nothing restored.${RESET}"
  fi
  artisan up >/dev/null 2>&1
  BP_PANEL_DOWN=0
  echo -e "${YELLOW}Backup folder: ${BACKUP_DIR}${RESET}"
}

# Runs a function in a strict subshell (stops at the first error).
# On any failure or Ctrl+C the panel is rolled back from the backup.
bp_run_guarded() {
  local rc
  trap ':' INT
  ( set -Eeuo pipefail; "$1" )
  rc=$?
  trap - INT
  if [ "$rc" -ne 0 ]; then
    bp_rollback
    return 1
  fi
  return 0
}

_bp_install_steps() {
  export DEBIAN_FRONTEND=noninteractive

  echo -e "${YELLOW}Installing dependencies...${RESET}"
  apt-get update -y
  apt-get install -y curl wget unzip zip git ca-certificates gnupg

  # Node.js 22 (as per the official Blueprint guide)
  local NODE_MAJOR=0
  if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -v | sed 's/^v\([0-9]*\).*/\1/')"
  fi
  if [ "$NODE_MAJOR" -lt 22 ]; then
    echo -e "${YELLOW}Installing Node.js 22...${RESET}"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list
    apt-get update -y
    apt-get install -y nodejs
  fi

  command -v yarn >/dev/null 2>&1 || npm i -g yarn

  cd "$PANEL"

  echo -e "${YELLOW}Downloading latest Blueprint release...${RESET}"
  wget -q -O "$PANEL/release.zip" \
    "https://github.com/BlueprintFramework/framework/releases/latest/download/release.zip"
  unzip -o -q release.zip
  rm -f release.zip

  echo -e "${YELLOW}Running yarn install in panel...${RESET}"
  yarn install

  cat > .blueprintrc << RC
WEBUSER="${WEBUSER}";
OWNERSHIP="${WEBUSER}:${WEBGROUP}";
USERSHELL="/bin/bash";
RC

  echo -e "${YELLOW}Running Blueprint (building assets, please wait)...${RESET}"
  chmod +x blueprint.sh
  bash blueprint.sh
}

install_blueprint_framework() {
  bp_preflight || return 1

  if blueprint_installed; then
    echo -e "${GREEN}Blueprint is already installed.${RESET}"
    return 0
  fi

  echo ""
  echo -e "${YELLOW}The panel will be in maintenance mode for a few minutes.${RESET}"
  echo -e "${YELLOW}Game servers keep running. Best done at a low-traffic time.${RESET}"
  if ! ask_yn "Install Blueprint now?"; then
    echo -e "${RED}Cancelled.${RESET}"
    return 1
  fi

  detect_webuser
  bp_backup || return 1

  echo -e "${YELLOW}Putting panel into maintenance mode...${RESET}"
  artisan down >/dev/null 2>&1
  BP_PANEL_DOWN=1

  if ! bp_run_guarded _bp_install_steps; then
    echo -e "${RED}Blueprint install failed. Panel was restored.${RESET}"
    return 1
  fi

  artisan up >/dev/null 2>&1
  BP_PANEL_DOWN=0
  hash -r

  if blueprint_installed; then
    echo -e "${GREEN}Blueprint installed successfully.${RESET}"
    echo -e "${CYAN}Backup kept in ${BACKUP_DIR} (delete it when you no longer need it).${RESET}"
    return 0
  fi
  echo -e "${RED}Install finished but Blueprint files were not found.${RESET}"
  return 1
}

_bp_remove_steps() {
  cd "$PANEL"

  echo -e "${YELLOW}Removing Blueprint files...${RESET}"
  rm -rf .blueprint blueprint.sh .blueprintrc node_modules \
         public/extensions public/assets app/BlueprintFramework
  if [ -n "$BP_BIN" ] && [ -f "$BP_BIN" ]; then
    rm -f "$BP_BIN"
  fi

  echo -e "${YELLOW}Restoring official Pterodactyl files...${RESET}"
  tar -xzf "$BP_TMP/panel.tar.gz" -C "$PANEL"
  chmod -R 755 storage/* bootstrap/cache

  echo -e "${YELLOW}Installing composer dependencies...${RESET}"
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction

  echo -e "${YELLOW}Clearing cache and migrating database...${RESET}"
  php artisan view:clear
  php artisan config:clear
  php artisan migrate --seed --force

  chown -R "$WEBUSER:$WEBGROUP" "$PANEL"/* "$PANEL"/.env
  php artisan queue:restart
}

remove_blueprint_framework() {
  bp_preflight || return 1

  if ! blueprint_installed; then
    echo -e "${RED}Blueprint is not installed.${RESET}"
    return 1
  fi
  if ! command -v composer >/dev/null 2>&1; then
    echo -e "${RED}composer is required to restore the panel but was not found.${RESET}"
    return 1
  fi

  get_installed
  echo ""
  echo -e "${BOLD}  Removing Blueprint will:${RESET}"
  echo -e "   ${RED}-${RESET} replace panel files with a fresh official Pterodactyl release"
  echo -e "   ${RED}-${RESET} remove Blueprint AND all its extensions/themes"
  if [ "${#INSTALLED[@]}" -gt 0 ]; then
    echo -e "     (installed now: ${INSTALLED[*]})"
  fi
  echo -e "   ${RED}-${RESET} remove any manual edits / custom themes made outside Blueprint"
  echo -e "   ${GREEN}+${RESET} .env, database, users, servers and nodes stay SAFE"
  echo -e "   ${GREEN}+${RESET} a full backup is created first in ${BACKUP_DIR}"
  echo ""
  if ! ask_yn "Remove Blueprint?"; then
    echo -e "${RED}Cancelled.${RESET}"
    return 1
  fi

  detect_webuser
  BP_BIN="$(command -v blueprint 2>/dev/null)"

  # Download + verify the official panel BEFORE touching anything
  BP_TMP="$(mktemp -d)"
  echo -e "${YELLOW}Downloading official Pterodactyl panel...${RESET}"
  if ! curl -fsSL -o "$BP_TMP/panel.tar.gz" \
       "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" \
     || ! tar -tzf "$BP_TMP/panel.tar.gz" >/dev/null 2>&1; then
    echo -e "${RED}Could not download the panel files. Nothing was changed.${RESET}"
    rm -rf "$BP_TMP"
    return 1
  fi

  if ! bp_backup; then
    rm -rf "$BP_TMP"
    return 1
  fi

  echo -e "${YELLOW}Putting panel into maintenance mode...${RESET}"
  artisan down >/dev/null 2>&1
  BP_PANEL_DOWN=1

  if ! bp_run_guarded _bp_remove_steps; then
    rm -rf "$BP_TMP"
    echo -e "${RED}Removal failed. Panel was restored to its previous state.${RESET}"
    return 1
  fi
  rm -rf "$BP_TMP"

  artisan up >/dev/null 2>&1
  BP_PANEL_DOWN=0
  hash -r

  echo -e "${GREEN}Blueprint removed. Your panel is now plain Pterodactyl.${RESET}"
  echo -e "${CYAN}Backup kept in ${BACKUP_DIR}.${RESET}"
  echo -e "${CYAN}If you added 'source blueprint;' to .bashrc, remove that line manually.${RESET}"
  return 0
}

_bp_upgrade_steps() {
  cd "$PANEL"
  echo -e "${YELLOW}Running blueprint -upgrade (building assets, please wait)...${RESET}"
  blueprint -upgrade < /dev/tty
}

update_blueprint_framework() {
  bp_preflight || return 1

  if ! blueprint_installed; then
    echo -e "${RED}Blueprint is not installed. Install it first.${RESET}"
    return 1
  fi
  if ! command -v blueprint >/dev/null 2>&1; then
    echo -e "${RED}'blueprint' command not found. Open a new terminal (or run: source ~/.bashrc) and try again.${RESET}"
    return 1
  fi

  echo ""
  echo -e "${YELLOW}The panel will be in maintenance mode for a few minutes.${RESET}"
  echo -e "${YELLOW}A full backup is created first. If the update fails, the panel is restored.${RESET}"
  if ! ask_yn "Update Blueprint to the latest version now?"; then
    echo -e "${RED}Cancelled.${RESET}"
    return 1
  fi

  detect_webuser
  bp_backup || return 1

  echo -e "${YELLOW}Putting panel into maintenance mode...${RESET}"
  artisan down >/dev/null 2>&1
  BP_PANEL_DOWN=1

  if ! bp_run_guarded _bp_upgrade_steps; then
    echo -e "${RED}Blueprint update failed. Panel was restored.${RESET}"
    return 1
  fi

  artisan up >/dev/null 2>&1
  BP_PANEL_DOWN=0
  hash -r

  echo -e "${GREEN}Blueprint updated successfully.${RESET}"
  echo -e "${CYAN}Backup kept in ${BACKUP_DIR} (delete it when you no longer need it).${RESET}"
  return 0
}

# ---------- Blueprint framework menu ----------
blueprint_menu() {
  local C

  while true; do
    banner
    echo -e "  ${BOLD}Blueprint Framework${RESET}"
    echo ""
    if blueprint_installed; then
      echo -e "   Status: ${GREEN}● installed${RESET}"
    else
      echo -e "   Status: ${RED}○ not installed${RESET}"
    fi
    echo ""
    echo -e "   ${GREEN} 1)${RESET} Install Blueprint"
    echo -e "   ${RED} 2)${RESET} Remove Blueprint"
    echo -e "   ${CYAN} 3)${RESET} Update Blueprint"
    echo -e "   ${YELLOW} B)${RESET} Back"
    echo ""
    echo -e "${CYAN}  ------------------------------------------------------${RESET}"
    read -r -p "  Select an option: " C < /dev/tty

    case "$C" in
      1)
        install_blueprint_framework
        pause
        ;;
      2)
        if remove_blueprint_framework; then
          echo ""
          echo -e "${YELLOW}This helper needs Blueprint to install extensions, so it will exit now.${RESET}"
          echo -e "${YELLOW}Run it again to install Blueprint back.${RESET}"
          exit 0
        fi
        pause
        ;;
      3)
        update_blueprint_framework
        pause
        ;;
      B|b)
        return 0
        ;;
      *)
        echo -e "${RED}Invalid option.${RESET}"
        pause
        ;;
    esac
  done
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

# ---------- Delete / Uninstall (extensions) ----------
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

# ---------- Panel tools: Create admin / Maintenance mode ----------

# Runs php artisan as the panel's web user (so files stay owned correctly)
artisan_web() {
  detect_webuser
  if command -v runuser >/dev/null 2>&1 && id "$WEBUSER" >/dev/null 2>&1; then
    ( cd "$PANEL" && runuser -u "$WEBUSER" -- php artisan "$@" )
  else
    ( cd "$PANEL" && php artisan "$@" )
  fi
}

maintenance_is_on() {
  [ -f "$PANEL/storage/framework/down" ]
}

create_admin_user() {
  banner
  echo -e "  ${BOLD}Create Admin User${RESET}"
  echo ""

  if [ ! -f "$PANEL/artisan" ] || [ ! -f "$PANEL/.env" ]; then
    echo -e "${RED}Valid Pterodactyl panel not found in ${PANEL}.${RESET}"
    pause
    return 1
  fi
  if ! command -v php >/dev/null 2>&1; then
    echo -e "${RED}php is required but was not found.${RESET}"
    pause
    return 1
  fi

  echo -e "${YELLOW}Answer the questions below (email, username, name, password).${RESET}"
  echo -e "${YELLOW}When it asks 'Is this user an administrator?' choose yes.${RESET}"
  echo ""

  if artisan_web p:user:make < /dev/tty; then
    echo ""
    echo -e "${GREEN}User created successfully.${RESET}"
  else
    echo ""
    echo -e "${RED}User creation failed or was cancelled.${RESET}"
  fi
  pause
}

maintenance_menu() {
  local C

  while true; do
    banner
    echo -e "  ${BOLD}Maintenance Mode${RESET}"
    echo ""
    if maintenance_is_on; then
      echo -e "   Status: ${RED}● ON  (panel is closed for visitors)${RESET}"
    else
      echo -e "   Status: ${GREEN}● OFF (panel is live)${RESET}"
    fi
    echo ""
    echo -e "   ${RED} 1)${RESET} Turn ON"
    echo -e "   ${GREEN} 2)${RESET} Turn OFF"
    echo -e "   ${YELLOW} B)${RESET} Back"
    echo ""
    echo -e "${CYAN}  ------------------------------------------------------${RESET}"
    read -r -p "  Select an option: " C < /dev/tty

    case "$C" in
      1)
        if maintenance_is_on; then
          echo -e "${YELLOW}Maintenance mode is already ON.${RESET}"
        elif ask_yn "Users will not be able to open the panel. Turn ON?"; then
          if artisan_web down >/dev/null 2>&1; then
            echo -e "${GREEN}Maintenance mode is now ON.${RESET}"
          else
            echo -e "${RED}Could not turn maintenance mode ON.${RESET}"
          fi
        else
          echo -e "${RED}Cancelled.${RESET}"
        fi
        pause
        ;;
      2)
        if ! maintenance_is_on; then
          echo -e "${YELLOW}Maintenance mode is already OFF.${RESET}"
        elif artisan_web up >/dev/null 2>&1; then
          echo -e "${GREEN}Maintenance mode is now OFF. Panel is live.${RESET}"
        else
          echo -e "${RED}Could not turn maintenance mode OFF.${RESET}"
        fi
        pause
        ;;
      B|b)
        return 0
        ;;
      *)
        echo -e "${RED}Invalid option.${RESET}"
        pause
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

if ! blueprint_installed; then
  echo -e "${YELLOW}Blueprint is not installed.${RESET}"
  install_blueprint_framework
  if ! blueprint_installed; then
    echo -e "${RED}Blueprint is required. Exiting.${RESET}"
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
  echo -e "   ${CYAN}┌─────────────────────────────────┬─────────────────────────────────┐${RESET}"
  printf "   ${CYAN}│${RESET} ${GREEN}1)${RESET} %-28s ${CYAN}│${RESET} ${GREEN}2)${RESET} %-28s ${CYAN}│${RESET}\n" "$LEFT" "$RIGHT"
  echo -e "   ${CYAN}├─────────────────────────────────┼─────────────────────────────────┤${RESET}"
  printf "   ${CYAN}│${RESET} ${YELLOW}3)${RESET} %-28s ${CYAN}│${RESET} ${YELLOW}4)${RESET} %-28s ${CYAN}│${RESET}\n" "Blueprint (Install / Remove)" "Maintenance Mode ON/OFF"
  echo -e "   ${CYAN}├─────────────────────────────────┼─────────────────────────────────┤${RESET}"
  printf "   ${CYAN}│${RESET} ${YELLOW}5)${RESET} %-28s ${CYAN}│${RESET} ${YELLOW}6)${RESET} %-28s ${CYAN}│${RESET}\n" "Create Admin User" "Delete / Uninstall"
  echo -e "   ${CYAN}└─────────────────────────────────┴─────────────────────────────────┘${RESET}"
  echo ""
  echo -e "   ${RED} 0)${RESET} Exit"
  echo ""
  echo -e "${CYAN}  ------------------------------------------------------${RESET}"
  read -r -p "  Select an option: " TOP < /dev/tty

  case "$TOP" in
    1) section_menu "Blueprints" BP_URLS 0 ;;
    2) section_menu "Themes" THEME_URLS 1 ;;
    3) blueprint_menu ;;
    4) maintenance_menu ;;
    5) create_admin_user ;;
    6) remove_menu ;;
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
