#!/bin/bash
# =============================================================================
#  FestiPatch Server Setup Script
#  Tested on Ubuntu Server 24.04 LTS
#  Run as the 'festipatch' user: bash festipatch-setup.sh
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Colours
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
info()    { echo -e "${BLUE}[→]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
section() { echo -e "\n${BOLD}══════════════════════════════════════════${NC}"; echo -e "${BOLD}  $1${NC}"; echo -e "${BOLD}══════════════════════════════════════════${NC}\n"; }

# -----------------------------------------------------------------------------
# Must run as festipatch user, not root
# -----------------------------------------------------------------------------
if [ "$EUID" -eq 0 ]; then
    error "Do not run as root. Run as the 'festipatch' user: bash festipatch-setup.sh"
fi

if [ "$USER" != "festipatch" ]; then
    warn "This script is designed to run as the 'festipatch' user. Current user: $USER"
    read -rp "Continue anyway? (y/N): " CONTINUE
    [[ "$CONTINUE" =~ ^[Yy]$ ]] || exit 1
fi

section "FestiPatch Server Setup"
echo -e "  This script will configure a fresh Ubuntu Server installation"
echo -e "  for the FestiPatch application.\n"

# -----------------------------------------------------------------------------
# Network configuration (nmtui) — runs first so apt/git have connectivity
# -----------------------------------------------------------------------------
section "0. Network Configuration"

info "Installing network-manager if not present..."
apt-get install -y network-manager 2>/dev/null || sudo apt-get install -y network-manager 2>/dev/null || true

echo -e "  Configure your wired and WiFi connections now."
echo -e "  Add all networks this machine will need, then select Quit when done.\n"
read -rp "  Press Enter to open nmtui..."
sudo nmtui
echo ""
log "Network configuration complete"

# Prompt for machine name
while true; do
    read -rp "  Enter a name for this machine (e.g. 'Glastonbury FOH'): " MACHINE_NAME
    if [ -n "$MACHINE_NAME" ]; then
        break
    fi
    warn "Machine name cannot be empty."
done

# Persist machine name so MOTD can read it after setup
echo "$MACHINE_NAME" | sudo tee /etc/festipatch-machine-name > /dev/null

# Prompt for Tailscale auth key
echo ""
echo -e "  You need a Tailscale auth key to connect this machine to your account."
echo -e "  Generate one at: ${BLUE}https://login.tailscale.com/admin/settings/keys${NC}"
echo -e "  Make sure it is set to ${BOLD}Reusable${NC} so it works for future installs.\n"
while true; do
    read -rp "  Enter your Tailscale auth key (tskey-auth-...): " TAILSCALE_AUTH_KEY
    if [[ "$TAILSCALE_AUTH_KEY" == tskey-auth-* ]]; then
        break
    fi
    warn "Key should start with tskey-auth- — please check and try again."
done

echo ""
read -rp "  Press Enter to begin..."

# -----------------------------------------------------------------------------
# 1. Sudo
# -----------------------------------------------------------------------------
section "1. Sudo"

info "Installing sudo..."
sudo apt-get install -y sudo 2>/dev/null || apt-get install -y sudo 2>/dev/null || true

info "Ensuring $USER is in sudoers..."
if sudo grep -q "^$USER" /etc/sudoers 2>/dev/null || sudo grep -q "^%sudo" /etc/sudoers; then
    if id -nG "$USER" | grep -qw sudo; then
        log "$USER is already in the sudo group"
    else
        sudo usermod -aG sudo "$USER"
        log "Added $USER to sudo group"
        warn "You may need to log out and back in for sudo group changes to take effect"
    fi
fi

# -----------------------------------------------------------------------------
# 2. System update
# -----------------------------------------------------------------------------
section "2. System Update"

info "Updating package lists..."
sudo apt-get update -y
info "Upgrading packages..."
sudo apt-get upgrade -y
log "System updated"

# -----------------------------------------------------------------------------
# 3. Core dependencies
# -----------------------------------------------------------------------------
section "3. Core Dependencies"

info "Installing core packages..."
sudo apt-get install -y \
    curl \
    git \
    ufw \
    avahi-daemon \
    avahi-utils \
    libnss-mdns \
    unzip \
    build-essential
log "Core packages installed"

# -----------------------------------------------------------------------------
# 4. mDNS (festipatch.local)
# -----------------------------------------------------------------------------
section "4. mDNS (festipatch.local)"

info "Enabling avahi-daemon..."
sudo systemctl enable avahi-daemon
sudo systemctl start avahi-daemon
log "avahi-daemon running — device should be reachable as festipatch.local"

# -----------------------------------------------------------------------------
# 5. Node.js (latest LTS via NodeSource)
# -----------------------------------------------------------------------------
section "5. Node.js"

if command -v node &>/dev/null; then
    log "Node.js already installed: $(node --version)"
else
    info "Installing Node.js LTS..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
    log "Node.js installed: $(node --version)"
fi

log "npm version: $(npm --version)"

# -----------------------------------------------------------------------------
# 6. PM2
# -----------------------------------------------------------------------------
section "6. PM2"

if command -v pm2 &>/dev/null; then
    log "PM2 already installed: $(pm2 --version)"
else
    info "Installing PM2 globally..."
    sudo npm install -g pm2
    log "PM2 installed: $(pm2 --version)"
fi

# -----------------------------------------------------------------------------
# 7. MySQL Server
# -----------------------------------------------------------------------------
section "7. MySQL Server"

if systemctl is-active --quiet mysql; then
    log "MySQL already running"
else
    info "Installing MySQL Server..."
    sudo apt-get install -y mysql-server
    sudo systemctl enable mysql
    sudo systemctl start mysql
    log "MySQL installed and started"
fi

# Re-enable mysql_native_password (required for mysql2 Node client)
info "Configuring MySQL for mysql_native_password compatibility..."
MYSQLD_CNF="/etc/mysql/mysql.conf.d/mysqld.cnf"

if ! sudo grep -q "mysql_native_password" "$MYSQLD_CNF"; then
    echo "" | sudo tee -a "$MYSQLD_CNF" > /dev/null
    echo "[mysqld]" | sudo tee -a "$MYSQLD_CNF" > /dev/null
    echo "mysql_native_password=ON" | sudo tee -a "$MYSQLD_CNF" > /dev/null
    log "mysql_native_password enabled"
else
    log "mysql_native_password already configured"
fi

# Set bind-address to all interfaces
if sudo grep -q "^bind-address" "$MYSQLD_CNF"; then
    sudo sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' "$MYSQLD_CNF"
else
    echo "bind-address = 0.0.0.0" | sudo tee -a "$MYSQLD_CNF" > /dev/null
fi
log "MySQL bind-address set to 0.0.0.0"

sudo systemctl restart mysql
log "MySQL restarted"

# -----------------------------------------------------------------------------
# 8. Generate MySQL password and create database/user
# -----------------------------------------------------------------------------
section "8. MySQL Database & User"

# Generate a strong random password
DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=\n' | head -c 32)
DB_NAME="festipatch"
DB_USER="festipatch"

info "Creating database '${DB_NAME}'..."
sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

info "Creating MySQL user '${DB_USER}'..."
sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_PASSWORD}';"
sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED WITH mysql_native_password BY '${DB_PASSWORD}';"

info "Granting privileges..."
sudo mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
sudo mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';"
sudo mysql -e "GRANT PROCESS ON *.* TO '${DB_USER}'@'localhost';"
sudo mysql -e "GRANT PROCESS ON *.* TO '${DB_USER}'@'%';"
sudo mysql -e "FLUSH PRIVILEGES;"
log "Database and user created"

# Write root credentials file to avoid password prompts in scripts
info "Writing /root/.my.cnf..."
sudo bash -c "cat > /root/.my.cnf" << MYCNF
[client]
user=root
socket=/var/run/mysqld/mysqld.sock
MYCNF
sudo chmod 600 /root/.my.cnf
log "/root/.my.cnf created"

# -----------------------------------------------------------------------------
# 9. UFW Firewall
# -----------------------------------------------------------------------------
section "9. Firewall (UFW)"

info "Configuring UFW rules..."
sudo ufw allow OpenSSH
sudo ufw allow 3001/tcp comment 'FestiPatch app'

# Dynamically discover all connected non-loopback subnets and allow MySQL from each
info "Detecting network interfaces for MySQL access rules..."
ip -o -f inet addr show | grep -v '127\.' | while read -r _ iface _ cidr _; do
    # cidr is e.g. 10.10.3.106/16 — derive the network address
    SUBNET=$(python3 -c "import ipaddress; print(ipaddress.ip_interface('${cidr}').network)" 2>/dev/null)
    if [ -n "$SUBNET" ]; then
        sudo ufw allow from "$SUBNET" to any port 3306 comment "MySQL LAN ($iface)"
        log "  MySQL allowed from $SUBNET ($iface)"
    fi
done

sudo ufw --force enable
log "UFW enabled with rules:"
sudo ufw status numbered

# -----------------------------------------------------------------------------
# 10. Tailscale
# -----------------------------------------------------------------------------
section "10. Tailscale"

info "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

info "Enabling and starting Tailscale service..."
sudo systemctl enable tailscaled
sudo systemctl start tailscaled

info "Connecting to your Tailscale account..."
sudo tailscale up --authkey="$TAILSCALE_AUTH_KEY" --hostname="festipatch-$(hostname)"

log "Tailscale status:"
tailscale status

# -----------------------------------------------------------------------------
# 11. SSH Key for GitHub
# -----------------------------------------------------------------------------
section "11. SSH Key for GitHub"

SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

if [ -f "$SSH_KEY_PATH" ]; then
    warn "SSH key already exists at $SSH_KEY_PATH"
else
    info "Generating SSH key..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -C "festipatch@$(hostname)" -f "$SSH_KEY_PATH" -N ""
    log "SSH key generated"
fi

echo ""
echo -e "${BOLD}${YELLOW}  ┌─────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${YELLOW}  │  ACTION REQUIRED: Add this public key to GitHub      │${NC}"
echo -e "${BOLD}${YELLOW}  └─────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${BOLD}  Your public key:${NC}"
echo ""
cat "$SSH_KEY_PATH.pub"
echo ""
echo -e "  1. Go to: ${BLUE}https://github.com/settings/keys${NC}"
echo -e "  2. Click 'New SSH key'"
echo -e "  3. Paste the key above"
echo -e "  4. Title it: festipatch-$(hostname)"
echo ""
read -rp "  Press Enter once you have added the key to GitHub..."

info "Testing GitHub SSH connection..."
ssh -T git@github.com -o StrictHostKeyChecking=accept-new 2>&1 || true
log "SSH key step complete"

# -----------------------------------------------------------------------------
# 11. Clone FestiPatch repository
# -----------------------------------------------------------------------------
section "12. Clone FestiPatch Repository"

APP_DIR="/var/www/festipatch"

if [ -d "$APP_DIR/.git" ]; then
    warn "Repository already exists at $APP_DIR — pulling latest..."
    cd "$APP_DIR"
    git pull
else
    info "Creating /var/www and cloning repository..."
    sudo mkdir -p /var/www
    sudo chown "$USER:$USER" /var/www
    git clone git@github.com:georgeveys/festipatch.git "$APP_DIR"
    log "Repository cloned to $APP_DIR"
fi

# -----------------------------------------------------------------------------
# 12. Install Node dependencies
# -----------------------------------------------------------------------------
section "13. Node Dependencies"

info "Installing npm dependencies..."
cd "$APP_DIR/server"
npm install
log "npm install complete"

# -----------------------------------------------------------------------------
# 13. Generate .env file
# -----------------------------------------------------------------------------
section "14. Environment File (.env)"

JWT_SECRET=$(openssl rand -base64 48 | tr -d '/+=\n' | head -c 48)
ENV_FILE="$APP_DIR/server/.env"

if [ -f "$ENV_FILE" ]; then
    warn ".env already exists — backing up to .env.bak"
    cp "$ENV_FILE" "$ENV_FILE.bak"
fi

cat > "$ENV_FILE" << ENV
PORT=3001
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
JWT_SECRET=${JWT_SECRET}
JWT_EXPIRES_IN=24h
UPLOAD_DIR=./uploads
MAX_FILE_SIZE_MB=50
CLIENT_URL=http://festipatch.local:3001
ENV

chmod 600 "$ENV_FILE"
log ".env written to $ENV_FILE"

# -----------------------------------------------------------------------------
# 14. PM2 app startup
# -----------------------------------------------------------------------------
section "15. PM2 App Startup"

info "Starting FestiPatch via PM2..."
pm2 delete festipatch 2>/dev/null || true
pm2 start npm --name festipatch --cwd "$APP_DIR/server" -- start

info "Saving PM2 process list..."
pm2 save

info "Configuring PM2 to start on boot..."
PM2_STARTUP=$(pm2 startup systemd -u "$USER" --hp "$HOME" | grep "sudo env")
if [ -n "$PM2_STARTUP" ]; then
    eval "$PM2_STARTUP"
    log "PM2 startup configured"
else
    warn "Could not auto-configure PM2 startup. Run 'pm2 startup' manually and follow the instructions."
fi

log "PM2 status:"
pm2 list

# -----------------------------------------------------------------------------
# 15. MySQL automated backups
# -----------------------------------------------------------------------------
section "16. MySQL Automated Backups"

BACKUP_SCRIPT="/usr/local/bin/festipatch-backup.sh"
BACKUP_DIR="/var/backups/festipatch"
BACKUP_LOG="/var/log/festipatch-backup.log"

sudo mkdir -p "$BACKUP_DIR"

sudo bash -c "cat > $BACKUP_SCRIPT" << 'BACKUPSCRIPT'
#!/bin/bash
BACKUP_DIR="/var/backups/festipatch"
LOG="/var/log/festipatch-backup.log"
DB_NAME="festipatch"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
TODAY=$(date +"%Y%m%d")
FILE="$BACKUP_DIR/${DB_NAME}_${TIMESTAMP}.sql.gz"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting backup..." >> "$LOG"

if mysqldump "$DB_NAME" 2>>"$LOG" | gzip > "$FILE"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup written: $FILE" >> "$LOG"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup FAILED" >> "$LOG"
    exit 1
fi

# Keep all of today's backups, one per previous day, purge after 7 days
find "$BACKUP_DIR" -name "*.sql.gz" | grep -v "_${TODAY}_" | sort | while read -r f; do
    DAY=$(basename "$f" | grep -oP '\d{8}')
    LATEST=$(find "$BACKUP_DIR" -name "*_${DAY}_*.sql.gz" | sort | tail -1)
    if [ "$f" != "$LATEST" ]; then
        rm "$f"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Removed old backup: $f" >> "$LOG"
    fi
done

# Purge anything older than 7 days
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -exec rm {} \; -exec echo "[$(date '+%Y-%m-%d %H:%M:%S')] Purged: {}" >> "$LOG" \;

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup complete." >> "$LOG"
BACKUPSCRIPT

sudo chmod +x "$BACKUP_SCRIPT"
log "Backup script written to $BACKUP_SCRIPT"

# Add hourly cron job for root
CRON_LINE="0 * * * * $BACKUP_SCRIPT"
( sudo crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT"; echo "$CRON_LINE" ) | sudo crontab -
log "Hourly backup cron job added"

# -----------------------------------------------------------------------------
# 16. Custom MOTD
# -----------------------------------------------------------------------------
section "17. MOTD"

info "Disabling default Ubuntu MOTD scripts..."
for f in /etc/update-motd.d/00-header \
          /etc/update-motd.d/10-help-text \
          /etc/update-motd.d/50-motd-news \
          /etc/update-motd.d/91-release-upgrade \
          /etc/update-motd.d/95-hwe-eol; do
    [ -f "$f" ] && sudo chmod -x "$f" && log "Disabled $(basename $f)"
done

MOTD_SCRIPT="/etc/update-motd.d/99-festipatch"
sudo bash -c "cat > $MOTD_SCRIPT" << 'MOTDSCRIPT'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

APP_STATUS=$(sudo -u festipatch pm2 jlist 2>/dev/null | python3 -c "
import sys, json
try:
    procs = json.load(sys.stdin)
    match = [p for p in procs if p['name'] == 'festipatch']
    if match:
        s = match[0]['pm2_env']['status']
        uptime = match[0]['pm2_env'].get('pm_uptime', 0)
        restarts = match[0]['pm2_env'].get('restart_time', 0)
        print(f'{s} (restarts: {restarts})')
    else:
        print('not found')
except:
    print('unknown')
" 2>/dev/null || echo 'unknown')

if echo "$APP_STATUS" | grep -q "^online"; then
    STATUS_COLOR=$GREEN
else
    STATUS_COLOR=$RED
fi

MACHINE_NAME=$(cat /etc/festipatch-machine-name 2>/dev/null || echo "Unknown")

# Pad machine name to fill the box (box inner width = 37 chars)
BOX_WIDTH=37
NAME_LEN=${#MACHINE_NAME}
PADDING=$(( (BOX_WIDTH - NAME_LEN) / 2 ))
PADDING_STR=$(printf '%*s' "$PADDING" '')
NAME_LINE="${PADDING_STR}${MACHINE_NAME}"
# Pad right side to fill box
RIGHT_PAD=$(( BOX_WIDTH - ${#NAME_LINE} ))
RIGHT_PAD_STR=$(printf '%*s' "$RIGHT_PAD" '')

echo ""
echo -e "${BOLD}  ┌─────────────────────────────────────┐${NC}"
echo -e "${BOLD}  │        festiPatch Server             │${NC}"
echo -e "${BOLD}  │     Copyright George Veys 2026       │${NC}"
echo -e "${BOLD}  │${NAME_LINE}${RIGHT_PAD_STR}│${NC}"
echo -e "${BOLD}  └─────────────────────────────────────┘${NC}"
echo ""
echo -e "  ${BOLD}Hostname:${NC}  $(hostname)"
echo -e "  ${BOLD}IP:${NC}        $(hostname -I | awk '{print $1}')"
echo -e "  ${BOLD}Uptime:${NC}    $(uptime -p)"
echo -e "  ${BOLD}Load:${NC}      $(cut -d' ' -f1-3 /proc/loadavg)"
echo ""
echo -e "  ${BOLD}CPU:${NC}       $(top -bn1 | grep 'Cpu(s)' | awk '{print $2}')% used"
echo -e "  ${BOLD}Memory:${NC}    $(free -h | awk '/^Mem:/ {print $3 " used of " $2}')"
echo -e "  ${BOLD}Disk:${NC}      $(df -h / | awk 'NR==2 {print $3 " used of " $4 " (" $5 ")"}')"
echo ""
echo -e "  ${BOLD}MySQL:${NC}     $(systemctl is-active mysql)"
echo -e "  ${BOLD}App:${NC}       ${STATUS_COLOR}${APP_STATUS}${NC}"
echo ""
MOTDSCRIPT

sudo chmod +x "$MOTD_SCRIPT"
log "Custom MOTD installed"

# Static pre-login banner for TTY (includes machine name)
BOX_WIDTH=37
NAME_LEN=${#MACHINE_NAME}
PADDING=$(( (BOX_WIDTH - NAME_LEN) / 2 ))
PADDING_STR=$(printf '%*s' "$PADDING" '')
NAME_LINE="${PADDING_STR}${MACHINE_NAME}"
RIGHT_PAD=$(( BOX_WIDTH - ${#NAME_LINE} ))
RIGHT_PAD_STR=$(printf '%*s' "$RIGHT_PAD" '')

sudo bash -c "cat > /etc/issue" << ISSUE

  ┌─────────────────────────────────────┐
  │        festiPatch Server             │
  │     Copyright George Veys 2026       │
  │${NAME_LINE}${RIGHT_PAD_STR}│

  Authorised access only.

ISSUE
log "/etc/issue updated"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
section "Setup Complete"

echo -e "${BOLD}  Credentials (save these securely):${NC}"
echo ""
echo -e "  ${BOLD}MySQL Database:${NC}  $DB_NAME"
echo -e "  ${BOLD}MySQL User:${NC}      $DB_USER"
echo -e "  ${BOLD}MySQL Password:${NC}  ${YELLOW}$DB_PASSWORD${NC}"
echo -e "  ${BOLD}JWT Secret:${NC}      ${YELLOW}$JWT_SECRET${NC}"
echo ""
echo -e "  ${BOLD}App .env:${NC}        $ENV_FILE"
echo -e "  ${BOLD}Backups:${NC}         /var/backups/festipatch/"
echo -e "  ${BOLD}Backup log:${NC}      /var/log/festipatch-backup.log"
echo ""
echo -e "  ${BOLD}App URL:${NC}         ${BLUE}http://festipatch.local:3001${NC}"
echo ""
echo -e "${GREEN}${BOLD}  All done. Run 'pm2 list' to confirm the app is online.${NC}"
echo ""
