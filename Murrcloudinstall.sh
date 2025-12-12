#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Settings (edit as needed)
# -----------------------------
OE_USER="murrcloud1769"
# Default application home (change to /$OE_USER if you prefer original behavior)
OE_HOME="/opt/${OE_USER}"
OE_HOME_EXT="${OE_HOME}/${OE_USER}-server"
INSTALL_WKHTMLTOPDF="True"
OE_PORT="8069"
# Default to 'main' instead of 'master'
OE_VERSION="main"
IS_ENTERPRISE="False"
# Installs PostgreSQL V14 instead of defaults - optional
INSTALL_POSTGRESQL_FOURTEEN="False"
INSTALL_NGINX="False"
OE_SUPERADMIN="admin"
# Set to "True" to generate a random password
GENERATE_RANDOM_PASSWORD="False"
OE_CONFIG="${OE_USER}-server"
WEBSITE_NAME="_"
LONGPOLLING_PORT="8072"
ENABLE_SSL="False"
ADMIN_EMAIL="partners@murrcloud.com"

# Repository to clone (ensure .git suffix) - updated to point to your public repo
REPO_URL="https://github.com/gcenterprises/murrcloud.git"

# Requirements fallback raw URL (fixed to raw.githubusercontent)
FALLBACK_REQUIREMENTS_URL="https://raw.githubusercontent.com/gcenterprises/murrcloud/main/requirements.txt"

# Node major version to install
NODE_MAJOR="18"

# wkhtmltopdf release to try (patched releases)
WKHTML_VERSION="0.12.6-1"

# Use python venv
USE_VENV="True"

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

wait_for_postgres_socket(){
  local tries=0
  while [[ ! -S /var/run/postgresql/.s.PGSQL.5432 && $tries -lt 20 ]]; do
    sleep 1
    ((tries++))
  done
}

install_wkhtmltopdf(){
  if [[ "${INSTALL_WKHTMLTOPDF}" != "True" ]]; then
    log "Skipping wkhtmltopdf as per configuration"
    return
  fi

  log "Installing patched wkhtmltopdf (attempting version ${WKHTML_VERSION})"
  if ! command -v lsb_release >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y lsb-release
  fi
  CODENAME="$(lsb_release -cs 2>/dev/null || true)"
  ARCH="$(dpkg --print-architecture || true)"

  if [[ "${ARCH}" != "amd64" ]]; then
    log "Unsupported architecture for automated wkhtmltopdf install: ${ARCH}. Please install wkhtmltopdf manually."
    return
  fi

  case "${CODENAME}" in
    jammy|focal|bionic) TARGET="${CODENAME}" ;;
    # Ubuntu 24.04 may lack direct builds — fall back to jammy
    *) 
      log "Unrecognized codename '${CODENAME}'. Falling back to 'jammy' package which commonly works on newer Ubuntus."
      TARGET="jammy"
      ;;
  esac

  DEB_NAME="wkhtmltox_${WKHTML_VERSION}.${TARGET}_amd64.deb"
  URL="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/${WKHTML_VERSION}/${DEB_NAME}"
  TMP_DEB="/tmp/${DEB_NAME}"

  apt-get remove -y wkhtmltopdf >/dev/null 2>&1 || true
  apt-get update -y

  if ! wget -q -O "${TMP_DEB}" "${URL}"; then
    log "Failed to download ${URL}. You may need to install wkhtmltopdf manually."
    return
  fi

  # Try to install using apt so dependencies are handled, fallback to dpkg+apt-get -f
  if apt install -y "${TMP_DEB}"; then
    log "wkhtmltopdf installed via apt"
  else
    log "apt failed to install .deb directly; attempting to fix deps and use dpkg"
    apt-get install -f -y
    dpkg -i "${TMP_DEB}" || { log "dpkg install failed; manual intervention required"; rm -f "${TMP_DEB}"; return; }
  fi

  rm -f "${TMP_DEB}"

  if command -v wkhtmltopdf >/dev/null 2>&1; then
    wkhtmltopdf --version || log "wkhtmltopdf installed but --version failed"
    log "wkhtmltopdf installed successfully"
  else
    log "wkhtmltopdf binary not found after install; please install manually"
  fi
}

# Determine which branch to use for cloning:
# - If OE_VERSION exists on the remote, use it.
# - Else try to detect remote default branch via ls-remote --symref HEAD.
# - Fallback to 'main'.
determine_branch_to_use(){
  local want="${OE_VERSION:-}"
  # If OE_VERSION explicitly set and exists remotely, use it
  if [[ -n "${want}" ]] && git ls-remote --heads "${REPO_URL}" "${want}" | grep -q 'refs/heads'; then
    echo "${want}"
    return 0
  fi

  # Try to detect remote default branch (HEAD -> refs/heads/<branch>)
  local remote_head
  remote_head="$(git ls-remote --symref "${REPO_URL}" HEAD 2>/dev/null | awk '/^ref:/ {print $2}' | sed 's#refs/heads/##' || true)"
  if [[ -n "${remote_head}" ]]; then
    echo "${remote_head}"
    return 0
  fi

  # Fallback
  echo "main"
  return 0
}

# -----------------------------
# Start
# -----------------------------
require_root

log "Updating apt + installing base packages (this may take a while)"
apt-get update -y
apt-get upgrade -y

# Essential packages for Ubuntu 24.04
apt-get install -y \
  git curl ca-certificates gnupg lsb-release software-properties-common \
  python3 python3-pip python3-venv python3-dev python3-wheel python3-setuptools \
  build-essential \
  libpq-dev libxslt1-dev libzip-dev libldap2-dev libsasl2-dev \
  libjpeg-dev libpng-dev \
  postgresql postgresql-contrib postgresql-server-dev-all \
  wget gdebi-core

# Optional: install PostgreSQL 14 from PGDG if requested
if [[ "${INSTALL_POSTGRESQL_FOURTEEN}" == "True" ]]; then
  log "Configuring PostgreSQL 14 repository and installing postgresql-14"
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg
  sh -c "echo 'deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main' > /etc/apt/sources.list.d/pgdg.list"
  apt-get update -y
  apt-get install -y postgresql-14
fi

# Install Node.js from NodeSource
log "Installing Node.js ${NODE_MAJOR} via NodeSource"
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
apt-get install -y nodejs
# install rtlcss for RTL/LTR transformations
log "Installing rtlcss globally"
npm install -g rtlcss || log "rtlcss install failed via npm"

# Install patched wkhtmltopdf via wget
install_wkhtmltopdf

log "Creating system user (if missing): ${OE_USER}"
if ! id -u "${OE_USER}" >/dev/null 2>&1; then
  # create system user with designated home
  adduser --system --quiet --shell=/bin/bash --home="${OE_HOME}" --gecos "MURRCLOUD" --group "${OE_USER}"
fi

# Ensure home directory exists and has correct ownership
mkdir -p "${OE_HOME}"
chown -R "${OE_USER}:${OE_USER}" "${OE_HOME}"

log "Creating log directory"
mkdir -p "/var/log/${OE_USER}"
chown -R "${OE_USER}:${OE_USER}" "/var/log/${OE_USER}"
chmod 750 "/var/log/${OE_USER}"

log "Creating application directories"
mkdir -p "${OE_HOME_EXT}"
chown -R "${OE_USER}:${OE_USER}" "${OE_HOME_EXT}"

# --- Clone / update repo (robust for public repos) ---
log "Cloning/Updating Murrcloud repo into ${OE_HOME_EXT}"
if [[ -d "${OE_HOME_EXT}/.git" ]]; then
  # update existing clone
  if ! su - "${OE_USER}" -c "git -C '${OE_HOME_EXT}' fetch --depth 1 origin '${OE_VERSION}' && git -C '${OE_HOME_EXT}' reset --hard 'origin/${OE_VERSION}'"; then
    log "Warning: failed to update existing repo as ${OE_USER}; attempting as root"
    if git -C "${OE_HOME_EXT}" fetch --depth 1 origin "${OE_VERSION}" && git -C "${OE_HOME_EXT}" reset --hard "origin/${OE_VERSION}"; then
      log "Updated existing repo as root"
      chown -R "${OE_USER}:${OE_USER}" "${OE_HOME_EXT}"
    else
      log "Warning: failed to update existing repo as root; you may need to update manually"
    fi
  fi
else
  rm -rf "${OE_HOME_EXT}"
  # Determine branch to use (handles repos using 'main' or other defaults)
  BRANCH_TO_USE="$(determine_branch_to_use)"
  log "Using branch '${BRANCH_TO_USE}' for clone (OE_VERSION='${OE_VERSION}')"

  # Try cloning as the app user preserving HOME and preventing interactive prompts
  if sudo -u "${OE_USER}" -H sh -c "GIT_TERMINAL_PROMPT=0 git -c credential.helper= -c core.askpass= clone --depth 1 --branch '${BRANCH_TO_USE}' '${REPO_URL}' '${OE_HOME_EXT}'"; then
    log "Cloned repo as ${OE_USER}"
  else
    log "Clone as ${OE_USER} failed; attempting clone as root and then chowning"
    if git clone --depth 1 --branch "${BRANCH_TO_USE}" "${REPO_URL}" "${OE_HOME_EXT}"; then
      chown -R "${OE_USER}:${OE_USER}" "${OE_HOME_EXT}"
      log "Cloned repo as root and changed ownership to ${OE_USER}"
    else
      die "Failed to clone repository ${REPO_URL}. Please check network and repo URL."
    fi
  fi
fi

log "Creating custom addons directory"
mkdir -p "${OE_HOME}/custom/addons"
chown -R "${OE_USER}:${OE_USER}" "${OE_HOME}/custom"

log "Starting PostgreSQL and ensuring it's ready"
systemctl enable --now postgresql
wait_for_postgres_socket

log "Creating PostgreSQL superuser (if missing): ${OE_USER}"
su - postgres -c "createuser -s ${OE_USER}" 2>/dev/null || true

# Python dependencies
REQ_FILE="${OE_HOME_EXT}/requirements.txt"

if [[ "${GENERATE_RANDOM_PASSWORD}" == "True" ]]; then
  OE_SUPERADMIN="$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)"
fi

if [[ "${USE_VENV}" == "True" ]]; then
  log "Creating Python virtualenv in ${OE_HOME_EXT}/venv"
  su - "${OE_USER}" -s /bin/bash -c "python3 -m venv '${OE_HOME_EXT}/venv'"
  VENV_PIP="${OE_HOME_EXT}/venv/bin/pip"
  chown -R "${OE_USER}:${OE_USER}" "${OE_HOME_EXT}/venv"

  if [[ -f "${REQ_FILE}" ]]; then
    log "Installing Python requirements into venv from ${REQ_FILE}"
    su - "${OE_USER}" -s /bin/bash -c "${VENV_PIP} install --upgrade pip setuptools wheel && ${VENV_PIP} install -r '${REQ_FILE}'"
  else
    log "Repo requirements.txt not found; using fallback URL ${FALLBACK_REQUIREMENTS_URL}"
    su - "${OE_USER}" -s /bin/bash -c "${VENV_PIP} install --upgrade pip setuptools wheel && ${VENV_PIP} install -r '${FALLBACK_REQUIREMENTS_URL}'"
  fi
else
  log "Installing Python requirements system-wide (pip3)"
  if [[ -f "${REQ_FILE}" ]]; then
    pip3 install -r "${REQ_FILE}"
  else
    pip3 install -r "${FALLBACK_REQUIREMENTS_URL}"
  fi
fi

# Enterprise extras (optional)
if [[ "${IS_ENTERPRISE}" == "True" ]]; then
  log "Enterprise mode enabled: installing extra python/node packages"
  if [[ "${USE_VENV}" == "True" ]]; then
    su - "${OE_USER}" -s /bin/bash -c "${VENV_PIP} install psycopg2-binary pdfminer.six num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL"
  else
    pip3 install psycopg2-binary pdfminer.six num2words ofxparse dbfread ebaysdk firebase_admin pyOpenSSL
  fi
  npm install -g less less-plugin-clean-css || log "less install failed"
fi

log "Finding murrcloud-bin or odoo-bin in ${OE_HOME_EXT}"
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

# addons path detection
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
proxy_mode = False
EOF
chown "${OE_USER}:${OE_USER}" "${CONF_FILE}"
chmod 640 "${CONF_FILE}"

log "Creating systemd service: /etc/systemd/system/${OE_CONFIG}.service"
if [[ "${USE_VENV}" == "True" ]]; then
  DAEMON_CMD="${OE_HOME_EXT}/venv/bin/python3 ${DAEMON}"
else
  DAEMON_CMD="${DAEMON}"
fi

cat > "/etc/systemd/system/${OE_CONFIG}.service" <<EOF
[Unit]
Description=Murrcloud ${OE_CONFIG}
After=network.target postgresql.service

[Service]
Type=simple
User=${OE_USER}
Group=${OE_USER}
ExecStart=${DAEMON_CMD} -c ${CONF_FILE}
Restart=always
RestartSec=5
LimitNOFILE=65535
WorkingDirectory=${OE_HOME_EXT}

[Install]
WantedBy=multi-user.target
EOF

log "Reloading systemd and enabling service"
systemctl daemon-reload
systemctl enable --now "${OE_CONFIG}.service" || log "Failed to start ${OE_CONFIG}.service; check journalctl -u ${OE_CONFIG}.service"

log "Status + listening check"
systemctl --no-pager --full status "${OE_CONFIG}.service" || true
ss -lntp | grep ":${OE_PORT}" || true

# Optional: Nginx setup (keeps original upstream config)
if [[ "${INSTALL_NGINX}" == "True" ]]; then
  log "Setting up Nginx reverse proxy"
  apt-get install -y nginx
  cat > "/etc/nginx/sites-available/${WEBSITE_NAME}" <<'NGCONF'
server {
  listen 80;
  server_name __WEBSITE_NAME_PLACEHOLDER__;
  proxy_set_header X-Forwarded-Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header X-Real-IP $remote_addr;
  add_header X-Frame-Options "SAMEORIGIN";
  add_header X-XSS-Protection "1; mode=block";
  proxy_set_header X-Client-IP $remote_addr;
  proxy_set_header HTTP_X_FORWARDED_HOST $remote_addr;
  access_log  /var/log/nginx/___OE_USER___-access.log;
  error_log       /var/log/nginx/___OE_USER___-error.log;
  proxy_buffers   16  64k;
  proxy_buffer_size   128k;
  proxy_read_timeout 900s;
  proxy_connect_timeout 900s;
  proxy_send_timeout 900s;
  proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;
  gzip    on;
  gzip_min_length 1100;
  gzip_buffers    4   32k;
  gzip_types  text/css text/less text/plain text/xml application/xml application/json application/javascript application/pdf image/jpeg image/png;
  gzip_vary   on;
  client_header_buffer_size 4k;
  large_client_header_buffers 4 64k;
  client_max_body_size 0;

  location / {
    proxy_pass    http://127.0.0.1:__OE_PORT__;
    proxy_redirect off;
  }

  location /longpolling {
    proxy_pass http://127.0.0.1:__LONGPOLLING_PORT__;
  }

  location ~* \.(js|css|png|jpg|jpeg|gif|ico)$ {
    expires 2d;
    proxy_pass http://127.0.0.1:__OE_PORT__;
    add_header Cache-Control "public, no-transform";
  }

  location ~ /[a-zA-Z0-9_-]*/static/ {
    proxy_cache_valid 200 302 60m;
    proxy_cache_valid 404 1m;
    proxy_buffering on;
    expires 864000;
    proxy_pass http://127.0.0.1:__OE_PORT__;
  }
}
NGCONF

  # replace placeholders
  sed -e "s|__WEBSITE_NAME_PLACEHOLDER__|${WEBSITE_NAME}|g" \
      -e "s|__OE_USER___|${OE_USER}|g" \
      -e "s|__OE_PORT__|${OE_PORT}|g" \
      -e "s|__LONGPOLLING_PORT__|${LONGPOLLING_PORT}|g" \
      /etc/nginx/sites-available/${WEBSITE_NAME} > /etc/nginx/sites-available/${WEBSITE_NAME}.tmp
  mv /etc/nginx/sites-available/${WEBSITE_NAME}.tmp /etc/nginx/sites-available/${WEBSITE_NAME}
  ln -sf /etc/nginx/sites-available/${WEBSITE_NAME} /etc/nginx/sites-enabled/${WEBSITE_NAME}
  rm -f /etc/nginx/sites-enabled/default
  systemctl restart nginx
  # enable proxy_mode in config
  if ! grep -q "^proxy_mode" "${CONF_FILE}"; then
    echo "proxy_mode = True" >> "${CONF_FILE}"
  fi
  log "Nginx configured and restarted"
fi

log "DONE"
echo "-----------------------------------------------------------"
echo "Port: ${OE_PORT}"
echo "Service: ${OE_CONFIG}.service"
echo "Config: ${CONF_FILE}"
echo "Log: /var/log/${OE_USER}/${OE_CONFIG}.log"
echo "Core addons: ${CORE_ADDONS}"
echo "Custom addons: ${OE_HOME}/custom/addons"
if [[ "${USE_VENV}" == "True" ]]; then
  echo "Python venv: ${OE_HOME_EXT}/venv"
fi
echo "DB superadmin password: ${OE_SUPERADMIN}"
echo "Start:  sudo systemctl start ${OE_CONFIG}.service"
echo "Stop:   sudo systemctl stop ${OE_CONFIG}.service"
echo "Logs:   sudo journalctl -u ${OE_CONFIG}.service -f"
echo "-----------------------------------------------------------"
