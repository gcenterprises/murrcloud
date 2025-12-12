#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Settings
# -----------------------------
OE_USER="murrcloud1769"
OE_PORT="8069"
LONGPOLLING_PORT="8072"

OE_HOME="/${OE_USER}"
OE_HOME_EXT="${OE_HOME}/${OE_USER}-server"   # /murrcloud1769/murrcloud1769-server
OE_CONFIG="${OE_USER}-server"                # murrcloud1769-server
OE_VERSION="master"

IS_ENTERPRISE="False"

OE_SUPERADMIN="admin"
GENERATE_RANDOM_PASSWORD="False"

REPO_URL="https://github.com/ShaheenHossain/murrcloud_amyliu7778_17ent"
FALLBACK_REQUIREMENTS_URL="https://github.com/ShaheenHossain/requirements.txt/raw/master/requirements.txt"

# -----------------------------
# Helpers
# -----------------------------
log(){ echo -e "\n[INFO] $*"; }
die(){ echo -e "\n[ERROR] $*" >&2; exit 1; }

require_root(){
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root: sudo bash $0"
  fi
}

# -----------------------------
# Start
# -----------------------------
require_root

log "Updating apt + installing base packages"
apt-get update -y
apt-get upgrade -y

# NOTE: Do NOT add xenial repo. It's outdated and can break dependencies.
apt-get install -y \
  git curl ca-certificates gnupg lsb-release \
  python3 python3-pip python3-venv python3-dev python3-wheel python3-setuptools \
  build-essential \
  libpq-dev libxslt1-dev libzip-dev libldap2-dev libsasl2-dev \
  libjpeg-dev libpng-dev \
  nodejs npm \
  postgresql postgresql-server-dev-all \
  wkhtmltopdf \
  gdebi

log "Installing rtlcss"
npm install -g rtlcss

log "Creating system user (if missing): ${OE_USER}"
if ! id -u "${OE_USER}" >/dev/null 2>&1; then
  adduser --system --quiet --shell=/bin/bash --home="${OE_HOME}" --gecos "MURRCLOUD1769" --group "${OE_USER}"
fi

log "Creating PostgreSQL superuser (if missing): ${OE_USER}"
su - postgres -c "createuser -s ${OE_USER}" 2>/dev/null || true

log "Creating log directory"
mkdir -p "/var/log/${OE_USER}"
chown -R "${OE_USER}:${OE_USER}" "/var/log/${OE_USER}"
chmod 750 "/var/log/${OE_USER}"

log "Creating source directories"
mkdir -p "${OE_HOME}"
chown -R "${OE_USER}:${OE_USER}" "${OE_HOME}"

log "Cloning/Updating Murrcloud repo into ${OE_HOME_EXT}"
if [[ -d "${OE_HOME_EXT}/.git" ]]; then
  su - "${OE_USER}" -c "git -C '${OE_HOME_EXT}' fetch --depth 1 origin '${OE_VERSION}' && git -C '${OE_HOME_EXT}' reset --hard 'origin/${OE_VERSION}'"
else
  rm -rf "${OE_HOME_EXT}"
  su - "${OE_USER}" -c "git clone --depth 1 --branch '${OE_VERSION}' '${REPO_URL}' '${OE_HOME_EXT}'"
fi

log "Creating custom addons directory"
mkdir -p "${OE_HOME}/custom/addons"
chown -R "${OE_USER}:${OE_USER}" "${OE_HOME}/custom"

log "Python dependencies"
# Prefer repo requirements if it exists; fallback otherwise
if [[ -f "${OE_HOME_EXT}/requirements.txt" ]]; then
  pip3 install -r "${OE_HOME_EXT}/requirements.txt"
else
  pip3 install -r "${FALLBACK_REQUIREMENTS_URL}"
fi

# Enterprise extras (kept from your script, but only if enabled)
if [[ "${IS_ENTERPRISE}" == "True" ]]; then
  log "Enterprise mode enabled: installing extra python/node packages"
  pip3 install psycopg2-binary pdfminer.six num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
  npm install -g less less-plugin-clean-css
fi

log "Finding murrcloud-bin"
if [[ -x "${OE_HOME_EXT}/murrcloud-bin" ]]; then
  DAEMON="${OE_HOME_EXT}/murrcloud-bin"
elif [[ -x "${OE_HOME_EXT}/odoo-bin" ]]; then
  DAEMON="${OE_HOME_EXT}/odoo-bin"
else
  die "Could not find an executable murrcloud-bin or odoo-bin in ${OE_HOME_EXT}. Repo may be missing the binary."
fi

log "Creating config: /etc/${OE_CONFIG}.conf"
CONF_FILE="/etc/${OE_CONFIG}.conf"
touch "${CONF_FILE}"
chmod 640 "${CONF_FILE}"
chown "${OE_USER}:${OE_USER}" "${CONF_FILE}"

if [[ "${GENERATE_RANDOM_PASSWORD}" == "True" ]]; then
  OE_SUPERADMIN="$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)"
fi

# addons_path: keep BOTH core + custom
# NOTE: your original script used ${OE_HOME_EXT}/murrcloud/addons; keep that if it exists,
# otherwise fall back to ${OE_HOME_EXT}/addons.
CORE_ADDONS=""
if [[ -d "${OE_HOME_EXT}/murrcloud/addons" ]]; then
  CORE_ADDONS="${OE_HOME_EXT}/murrcloud/addons"
elif [[ -d "${OE_HOME_EXT}/addons" ]]; then
  CORE_ADDONS="${OE_HOME_EXT}/addons"
else
  die "Could not find core addons folder in ${OE_HOME_EXT} (checked murrcloud/addons and addons)."
fi

cat > "${CONF_FILE}" <<EOF
[options]
admin_passwd = ${OE_SUPERADMIN}
http_port = ${OE_PORT}
logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
addons_path = ${CORE_ADDONS},${OE_HOME}/custom/addons
; recommended:
proxy_mode = False
EOF

log "Creating systemd service: /etc/systemd/system/${OE_CONFIG}.service"
cat > "/etc/systemd/system/${OE_CONFIG}.service" <<EOF
[Unit]
Description=Murrcloud ${OE_CONFIG}
After=network.target postgresql.service

[Service]
Type=simple
User=${OE_USER}
Group=${OE_USER}
ExecStart=${DAEMON} -c ${CONF_FILE}
Restart=always
RestartSec=5
LimitNOFILE=65535
WorkingDirectory=${OE_HOME_EXT}

[Install]
WantedBy=multi-user.target
EOF

log "Reloading systemd and starting service"
systemctl daemon-reload
systemctl enable --now "${OE_CONFIG}.service"

log "Status + listening check"
systemctl --no-pager --full status "${OE_CONFIG}.service" || true
ss -lntp | grep ":${OE_PORT}" || true

log "DONE"
echo "-----------------------------------------------------------"
echo "Port: ${OE_PORT}"
echo "Service: ${OE_CONFIG}.service"
echo "Config: ${CONF_FILE}"
echo "Log: /var/log/${OE_USER}/${OE_CONFIG}.log"
echo "Core addons: ${CORE_ADDONS}"
echo "Custom addons: ${OE_HOME}/custom/addons"
echo "DB superadmin password: ${OE_SUPERADMIN}"
echo "Start:  sudo systemctl start ${OE_CONFIG}.service"
echo "Stop:   sudo systemctl stop ${OE_CONFIG}.service"
echo "Logs:   sudo tail -f /var/log/${OE_USER}/${OE_CONFIG}.log"
echo "-----------------------------------------------------------"
