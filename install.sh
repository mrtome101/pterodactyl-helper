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
  echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
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
  echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  ${GREEN}● ONLINE${RESET}  │ TomeStudios Infrastructure"
  echo ""
  echo -e "  ${BOLD}🌐 TomeStudios LINKS${RESET}"
  echo ""
  echo -e "  💬 Discord → https://discord.gg/pjCFdWsgCV"
  echo -e "  🌍 Website → https://www.tomestudios.fun/"
  echo -e "  🗳️ Github → https://github.com/mrtome101"
  echo ""
  echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
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
      printf "   %b ${GREEN}%2d)${RESET} ${GREEN}●${RESET} %s%b\n" "$MARK" "$n" "${INSTALLED[$((n-1))]}" "$TAG"
    done

    count=0
    for k in "${!SEL[@]}"; do
      [ "${SEL[$k]}" = "1" ] && count=$((count+1))
    done

    echo ""
    echo -e "   ${GREEN}●${RESET} = installed"
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

# ---------- Database setup ----------
MARIADB_CNF="/etc/mysql/mariadb.conf.d/50-server.cnf"
DB_ROOT_PW=""

db_sql() {
  if [ -n "$DB_ROOT_PW" ]; then
    MYSQL_PWD="$DB_ROOT_PW" mysql -u root "$@"
  else
    mysql -u root "$@"
  fi
}

# Escapes a value for use inside '...' in SQL
sql_esc() {
  local s="${1//\\/\\\\}"
  s="${s//\'/\\\'}"
  printf '%s' "$s"
}

db_connect() {
  if ! command -v mysql >/dev/null 2>&1; then
    echo -e "${RED}mysql / mariadb client not found. Install mariadb-server first.${RESET}"
    return 1
  fi
  DB_ROOT_PW=""
  db_sql -e "SELECT 1" >/dev/null 2>&1 && return 0

  read -r -s -p "  MySQL root password: " DB_ROOT_PW < /dev/tty
  echo ""
  if ! db_sql -e "SELECT 1" >/dev/null 2>&1; then
    echo -e "${RED}Could not connect as root (wrong password or server down).${RESET}"
    DB_ROOT_PW=""
    return 1
  fi
  return 0
}

db_restart() {
  systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null
}

db_create_user() {
  local DBN DBU DBH DBP MODE GEN=0

  db_connect || return 1

  read -r -p "  Username: " DBU < /dev/tty
  if ! [[ "$DBU" =~ ^[A-Za-z0-9_]{1,32}$ ]]; then
    echo -e "${RED}Username: only letters, numbers, underscore (max 32).${RESET}"
    return 1
  fi

  read -r -p "  Allowed host [% = anywhere, or e.g. 127.0.0.1] (default %): " DBH < /dev/tty
  DBH="${DBH:-%}"
  if ! [[ "$DBH" =~ ^[A-Za-z0-9._%:-]+$ ]]; then
    echo -e "${RED}Invalid host.${RESET}"
    return 1
  fi

  read -r -s -p "  Password (leave empty to auto-generate): " DBP < /dev/tty
  echo ""
  if [ -z "$DBP" ]; then
    DBP="$(openssl rand -base64 48 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 24)"
    [ -z "$DBP" ] && DBP="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)"
    GEN=1
  fi

  echo ""
  echo -e "   ${GREEN}1)${RESET} Limited  - access to ONE database only (recommended)"
  echo -e "   ${RED}2)${RESET} Full admin - ALL privileges on everything (dangerous)"
  read -r -p "  Select access type: " MODE < /dev/tty

  local EU EH EP
  EU="$(sql_esc "$DBU")"; EH="$(sql_esc "$DBH")"; EP="$(sql_esc "$DBP")"

  case "$MODE" in
    1)
      read -r -p "  Database name (will be created if missing): " DBN < /dev/tty
      if ! [[ "$DBN" =~ ^[A-Za-z0-9_]{1,64}$ ]]; then
        echo -e "${RED}Database name: only letters, numbers, underscore.${RESET}"
        return 1
      fi
      if ! db_sql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DBN}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${EU}'@'${EH}' IDENTIFIED BY '${EP}';
ALTER USER '${EU}'@'${EH}' IDENTIFIED BY '${EP}';
GRANT ALL PRIVILEGES ON \`${DBN}\`.* TO '${EU}'@'${EH}';
FLUSH PRIVILEGES;
SQL
      then
        echo -e "${RED}Failed to create database/user.${RESET}"
        return 1
      fi
      ;;
    2)
      echo -e "${RED}This user will be able to read/modify/delete EVERY database.${RESET}"
      ask_yn "Are you really sure?" || { echo -e "${RED}Cancelled.${RESET}"; return 1; }
      if ! db_sql <<SQL
CREATE USER IF NOT EXISTS '${EU}'@'${EH}' IDENTIFIED BY '${EP}';
ALTER USER '${EU}'@'${EH}' IDENTIFIED BY '${EP}';
GRANT ALL PRIVILEGES ON *.* TO '${EU}'@'${EH}' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
      then
        echo -e "${RED}Failed to create user.${RESET}"
        return 1
      fi
      ;;
    *)
      echo -e "${RED}Invalid option.${RESET}"
      return 1
      ;;
  esac

  echo ""
  echo -e "${GREEN}Done. Save these details:${RESET}"
  echo -e "  Host     : $(get_ip) (port 3306)"
  [ "$MODE" = "1" ] && echo -e "  Database : ${DBN}"
  echo -e "  Username : ${DBU}"
  echo -e "  Password : ${DBP}$([ "$GEN" = "1" ] && echo '  (auto-generated)')"
  echo -e "  Allowed  : ${DBH}"
  return 0
}

db_remote_status() {
  local v
  v="$(grep -E '^\s*bind-address' "$MARIADB_CNF" 2>/dev/null | head -n1 | awk -F= '{gsub(/ /,"",$2); print $2}')"
  echo "${v:-unknown}"
}

db_set_remote() {
  local MODE="$1"   # on / off
  if [ ! -f "$MARIADB_CNF" ]; then
    echo -e "${RED}Config not found: ${MARIADB_CNF}${RESET}"
    return 1
  fi

  cp -p "$MARIADB_CNF" "${MARIADB_CNF}.bak-$(date +%Y%m%d-%H%M%S)" || return 1

  local TARGET="127.0.0.1"
  [ "$MODE" = "on" ] && TARGET="0.0.0.0"

  if grep -qE '^\s*#?\s*bind-address' "$MARIADB_CNF"; then
    sed -i -E "s|^\s*#?\s*bind-address.*|bind-address = ${TARGET}|" "$MARIADB_CNF"
  else
    sed -i -E "/^\[mysqld\]/a bind-address = ${TARGET}" "$MARIADB_CNF"
  fi

  echo -e "${YELLOW}Restarting database service...${RESET}"
  if db_restart; then
    echo -e "${GREEN}bind-address is now ${TARGET}.${RESET}"
    if [ "$MODE" = "on" ]; then
      echo -e "${YELLOW}Open port 3306 in your firewall, ideally ONLY for trusted IPs:${RESET}"
      echo -e "  ufw allow from <YOUR_IP> to any port 3306 proto tcp"
    fi
  else
    echo -e "${RED}Restart failed. Config backup is next to ${MARIADB_CNF}.${RESET}"
    return 1
  fi
}

db_list_users() {
  db_connect || return 1
  echo ""
  db_sql -e "SELECT User, Host FROM mysql.user ORDER BY User;"
  echo ""
  db_sql -e "SHOW DATABASES;"
}

db_delete_user() {
  local U H
  db_connect || return 1
  read -r -p "  Username to delete: " U < /dev/tty
  read -r -p "  Host of that user (default %): " H < /dev/tty
  H="${H:-%}"
  if ! [[ "$U" =~ ^[A-Za-z0-9_]{1,32}$ ]] || [ "$U" = "root" ]; then
    echo -e "${RED}Invalid username (root cannot be deleted here).${RESET}"
    return 1
  fi
  if [[ "$U" = "pterodactyl" ]]; then
    echo -e "${YELLOW}Warning: this may be your panel's DB user!${RESET}"
  fi
  ask_yn "Delete '${U}'@'${H}'? (databases are NOT deleted)" || { echo -e "${RED}Cancelled.${RESET}"; return 1; }
  db_sql -e "DROP USER '$(sql_esc "$U")'@'$(sql_esc "$H")'; FLUSH PRIVILEGES;" \
    && echo -e "${GREEN}User deleted.${RESET}" \
    || echo -e "${RED}Failed.${RESET}"
}

database_menu() {
  local C R

  while true; do
    banner
    echo -e "  ${BOLD}Database Setup${RESET}"
    echo ""
    R="$(db_remote_status)"
    if [ "$R" = "0.0.0.0" ]; then
      echo -e "   Remote access: ${YELLOW}● ON  (bind-address ${R})${RESET}"
    else
      echo -e "   Remote access: ${GREEN}● local only (bind-address ${R})${RESET}"
    fi
    echo ""
    echo -e "   ${GREEN} 1)${RESET} Create database / user"
    echo -e "   ${YELLOW} 2)${RESET} Enable remote access (bind 0.0.0.0)"
    echo -e "   ${YELLOW} 3)${RESET} Disable remote access (bind 127.0.0.1)"
    echo -e "   ${CYAN} 4)${RESET} List users & databases"
    echo -e "   ${RED} 5)${RESET} Delete a user"
    echo -e "   ${YELLOW} B)${RESET} Back"
    echo ""
    echo -e "${CYAN}  ------------------------------------------------------${RESET}"
    read -r -p "  Select an option: " C < /dev/tty

    case "$C" in
      1) db_create_user; pause ;;
      2)
        if ask_yn "Allow outside connections to the database?"; then
          db_set_remote on
        else
          echo -e "${RED}Cancelled.${RESET}"
        fi
        pause
        ;;
      3) db_set_remote off; pause ;;
      4) db_list_users; pause ;;
      5) db_delete_user; pause ;;
      B|b) return 0 ;;
      *) echo -e "${RED}Invalid option.${RESET}"; pause ;;
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
# One table row. $1=left key  $2=left text  $3=right key  $4=right text  $5=key color
# Cell width = 1 space + "N) " (3) + 28 text + 1 space = 33, same as the border LINE below.
menu_row() {
  printf "   ${CYAN}│${RESET} ${5}%s)${RESET} %-28s ${CYAN}│${RESET} ${5}%s)${RESET} %-28s ${CYAN}│${RESET}\n" "$1" "$2" "$3" "$4"
}

while true; do
  banner
  LEFT="Blueprints (${#BP_URLS[@]})"
  RIGHT="Themes (${#THEME_URLS[@]})"
  LINE="─────────────────────────────────"   # 33 chars
  echo -e "   ${CYAN}┌${LINE}┬${LINE}┐${RESET}"
  menu_row 1 "$LEFT" 2 "$RIGHT" "$GREEN"
  echo -e "   ${CYAN}├${LINE}┼${LINE}┤${RESET}"
  menu_row 3 "Blueprint (Install / Remove)" 4 "Maintenance Mode ON/OFF" "$YELLOW"
  echo -e "   ${CYAN}├${LINE}┼${LINE}┤${RESET}"
  menu_row 5 "Create Admin User" 6 "Delete / Uninstall" "$YELLOW"
  echo -e "   ${CYAN}├${LINE}┼${LINE}┤${RESET}"
  menu_row 7 "Database Setup" 8 "Database Users / List" "$YELLOW"
  echo -e "   ${CYAN}└${LINE}┴${LINE}┘${RESET}"
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
    7) database_menu ;;
    8) db_list_users; pause ;;
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
