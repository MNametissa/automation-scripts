#!/usr/bin/env bash
set -Eeuo pipefail

# Odoo 18 + PostgreSQL 15 + Nginx + Certbot installer
# - Creates one Odoo stack on the server
# - Maps one subdomain to one database through dbfilter=^%d$
# - Enforces: DB name == first label of domain (e.g. erp.hkdigitals.com -> erp)
# - Uses Certbot nginx plugin for SSL
#
# Run as root on a fresh Ubuntu server.

ODDO_VERSION_DEFAULT="18"
POSTGRES_IMAGE_DEFAULT="postgres:15"
ODOO_IMAGE_DEFAULT="odoo:18"
BASE_DIR_DEFAULT="/opt/odoo-stack"
NGINX_LOG_DIR_DEFAULT="/var/log/nginx"
PUBLIC_HTTP_PORT_DEFAULT="80"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
okay()  { echo -e "${GREEN}[OK]${NC} $*"; }

trap 'error "Script failed on line $LINENO."
exit 1' ERR

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "Run this script as root."
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

random_secret() {
  openssl rand -hex 24
}

prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="${3:-}"
  local secret="${4:-false}"
  local value

  if [[ -n "$default_value" ]]; then
    if [[ "$secret" == "true" ]]; then
      read -r -s -p "$prompt_text [$default_value]: " value
      echo
    else
      read -r -p "$prompt_text [$default_value]: " value
    fi
    value="${value:-$default_value}"
  else
    if [[ "$secret" == "true" ]]; then
      read -r -s -p "$prompt_text: " value
      echo
    else
      read -r -p "$prompt_text: " value
    fi
  fi

  printf -v "$var_name" '%s' "$value"
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

# Bash regex with spaces is annoying; use a safer fallback.
validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^([A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

# Portable validator without relying on non-capturing groups.
validate_domain() {
  local domain="$1"
  python3 - "$domain" <<'PY'
import re, sys
pat = re.compile(r'^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$')
print('1' if pat.match(sys.argv[1]) else '0')
PY
}

extract_db_from_domain() {
  local domain="$1"
  echo "$domain" | cut -d'.' -f1 | tr '[:upper:]' '[:lower:]'
}

get_public_ip() {
  local ip=""
  if command_exists curl; then
    ip="$(curl -4fsS https://ifconfig.me 2>/dev/null || true)"
    [[ -n "$ip" ]] || ip="$(curl -4fsS https://api.ipify.org 2>/dev/null || true)"
  fi
  echo "$ip"
}

get_domain_a_record() {
  local domain="$1"
  if command_exists dig; then
    dig +short A "$domain" | tail -n1
  elif command_exists getent; then
    getent ahostsv4 "$domain" | awk '{print $1}' | head -n1
  else
    echo ""
  fi
}

install_packages() {
  info "Installing required packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    nginx \
    certbot \
    python3-certbot-nginx \
    docker.io \
    docker-compose-plugin \
    unzip

  systemctl enable --now docker
  systemctl enable --now nginx
  okay "Packages installed."
}

prepare_directories() {
  info "Preparing directories under $BASE_DIR ..."
  mkdir -p "$BASE_DIR"/{config,addons,data/odoo,data/db,bin,backups}
  chmod 755 "$BASE_DIR"
  okay "Directories ready."
}

write_env_file() {
  info "Writing environment file..."
  cat > "$BASE_DIR/.env" <<EOF_ENV
POSTGRES_USER=odoo
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=postgres
ODOO_VERSION=$ODOO_VERSION
ODOO_IMAGE=$ODOO_IMAGE
POSTGRES_IMAGE=$POSTGRES_IMAGE
ODOO_ADMIN_PASSWORD=$ODOO_ADMIN_PASSWORD
EOF_ENV
  chmod 600 "$BASE_DIR/.env"
  okay "Environment file written."
}

write_odoo_conf() {
  info "Writing Odoo configuration..."
  cat > "$BASE_DIR/config/odoo.conf" <<EOF_CONF
[options]
admin_passwd = $ODOO_ADMIN_PASSWORD
db_host = db
db_port = 5432
db_user = odoo
db_password = $POSTGRES_PASSWORD
proxy_mode = True
list_db = False
dbfilter = ^%d$
addons_path = /usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons
logfile = /var/lib/odoo/odoo.log
data_dir = /var/lib/odoo
limit_time_cpu = 600
limit_time_real = 1200
EOF_CONF
  chmod 640 "$BASE_DIR/config/odoo.conf"
  okay "Odoo configuration written."
}

write_compose_file() {
  info "Writing Docker Compose stack..."
  cat > "$BASE_DIR/docker-compose.yml" <<'EOF_COMPOSE'
services:
  db:
    image: ${POSTGRES_IMAGE}
    container_name: odoo-db
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./data/db:/var/lib/postgresql/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 10

  odoo:
    image: ${ODOO_IMAGE}
    container_name: odoo-app
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "127.0.0.1:8069:8069"
      - "127.0.0.1:8072:8072"
    environment:
      HOST: db
      USER: ${POSTGRES_USER}
      PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./data/odoo:/var/lib/odoo
      - ./config:/etc/odoo
      - ./addons:/mnt/extra-addons
    command: ["odoo", "--config=/etc/odoo/odoo.conf"]
    restart: unless-stopped
EOF_COMPOSE
  okay "Docker Compose file written."
}

start_stack() {
  info "Starting Docker stack..."
  (cd "$BASE_DIR" && docker compose up -d)
  okay "Docker stack started."
}

wait_for_postgres() {
  info "Waiting for PostgreSQL to become ready..."
  local retries=60
  until docker exec odoo-db pg_isready -U odoo -d postgres >/dev/null 2>&1; do
    retries=$((retries-1))
    if [[ "$retries" -le 0 ]]; then
      error "PostgreSQL did not become ready in time."
      exit 1
    fi
    sleep 2
  done
  okay "PostgreSQL is ready."
}

ensure_database_exists() {
  info "Ensuring database '$DB_NAME' exists..."
  if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" odoo-db psql -U odoo -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    warn "Database '$DB_NAME' already exists."
  else
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" odoo-db createdb -U odoo "$DB_NAME"
    okay "Database '$DB_NAME' created."
  fi
}

site_conf_path() {
  echo "/etc/nginx/sites-available/${DOMAIN}.conf"
}

write_nginx_site() {
  local conf_path
  conf_path="$(site_conf_path)"
  info "Writing Nginx site for $DOMAIN ..."

  cat > "$conf_path" <<EOF_NGINX
upstream odoo_${DB_NAME} {
    server 127.0.0.1:8069;
}

upstream odoochat_${DB_NAME} {
    server 127.0.0.1:8072;
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    access_log ${NGINX_LOG_DIR}/odoo_${DB_NAME}_access.log;
    error_log  ${NGINX_LOG_DIR}/odoo_${DB_NAME}_error.log;

    client_max_body_size 100M;

    location / {
        proxy_read_timeout 720s;
        proxy_connect_timeout 720s;
        proxy_send_timeout 720s;
        proxy_redirect off;

        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;

        proxy_pass http://odoo_${DB_NAME};
    }

    location /longpolling {
        proxy_read_timeout 720s;
        proxy_connect_timeout 720s;
        proxy_send_timeout 720s;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://odoochat_${DB_NAME};
    }

    location /websocket {
        proxy_read_timeout 720s;
        proxy_connect_timeout 720s;
        proxy_send_timeout 720s;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://odoochat_${DB_NAME};
    }

    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        proxy_buffering on;
        expires 864000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_pass http://odoo_${DB_NAME};
    }

    # Recommended when dbfilter is used in production.
    location /web/database {
        return 403;
    }

    gzip on;
    gzip_min_length 1000;
    gzip_types text/css text/scss text/plain text/xml application/xml application/json application/javascript;
}
EOF_NGINX

  ln -sfn "$conf_path" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  nginx -t
  systemctl reload nginx
  okay "Nginx site enabled for $DOMAIN."
}

request_ssl_certificate() {
  info "Requesting Let's Encrypt certificate with Certbot..."
  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --redirect \
    -m "$LETSENCRYPT_EMAIL" \
    -d "$DOMAIN"

  nginx -t
  systemctl reload nginx
  okay "SSL configured for $DOMAIN."
}

print_summary() {
  cat <<EOF_SUMMARY

============================================================
ODDO STACK READY
============================================================
Base directory : $BASE_DIR
Domain         : $DOMAIN
Database       : $DB_NAME
Odoo URL       : https://$DOMAIN

Containers:
  - odoo-app
  - odoo-db

Useful paths:
  - Compose stack : $BASE_DIR/docker-compose.yml
  - Odoo config   : $BASE_DIR/config/odoo.conf
  - Addons        : $BASE_DIR/addons
  - Odoo data     : $BASE_DIR/data/odoo
  - Postgres data : $BASE_DIR/data/db

Next steps:
  1) Copy your custom addons into: $BASE_DIR/addons
  2) Restore your production/preprod dump into database: $DB_NAME
  3) Restart Odoo after addons restore:
       cd $BASE_DIR && docker compose restart odoo
  4) Check logs if needed:
       cd $BASE_DIR && docker compose logs -f odoo

Restore example:
  docker cp ./your_dump.sql odoo-db:/tmp/your_dump.sql
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -it odoo-db psql -U odoo -d $DB_NAME -f /tmp/your_dump.sql

============================================================
EOF_SUMMARY
}

main() {
  require_root

  info "This installer creates one reusable Odoo stack and one domain->database mapping."

  prompt DOMAIN "Enter the domain to expose" "erp.hkdigitals.com"
  DOMAIN="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | xargs)"

  local domain_valid
  domain_valid="$(validate_domain "$DOMAIN")"
  if [[ "$domain_valid" != "1" ]]; then
    error "Invalid domain: $DOMAIN"
    exit 1
  fi

  SUGGESTED_DB="$(extract_db_from_domain "$DOMAIN")"
  prompt DB_NAME "Enter the database name (must equal the first label of the domain)" "$SUGGESTED_DB"
  DB_NAME="$(echo "$DB_NAME" | tr '[:upper:]' '[:lower:]' | xargs)"

  if [[ "$DB_NAME" != "$SUGGESTED_DB" ]]; then
    error "Invalid mapping: database '$DB_NAME' does not match the first label of '$DOMAIN' (expected '$SUGGESTED_DB')."
    exit 1
  fi

  prompt LETSENCRYPT_EMAIL "Enter the email for Let's Encrypt notices"
  prompt BASE_DIR "Base installation directory" "$BASE_DIR_DEFAULT"
  prompt ODOO_VERSION "Odoo major version" "$ODDO_VERSION_DEFAULT"
  ODOO_IMAGE="odoo:${ODOO_VERSION}"
  POSTGRES_IMAGE="$POSTGRES_IMAGE_DEFAULT"

  GENERATED_PG_PASSWORD="$(random_secret)"
  GENERATED_ADMIN_PASSWORD="$(random_secret)"
  prompt POSTGRES_PASSWORD "PostgreSQL password for Odoo user" "$GENERATED_PG_PASSWORD" true
  prompt ODOO_ADMIN_PASSWORD "Odoo admin/master password" "$GENERATED_ADMIN_PASSWORD" true

  PUBLIC_IP="$(get_public_ip)"
  DOMAIN_IP="$(get_domain_a_record "$DOMAIN")"

  if [[ -n "$PUBLIC_IP" && -n "$DOMAIN_IP" && "$PUBLIC_IP" != "$DOMAIN_IP" ]]; then
    warn "DNS check: $DOMAIN resolves to $DOMAIN_IP but this server appears to be $PUBLIC_IP."
    warn "Certbot will fail until the domain points to this server on port 80."
    read -r -p "Continue anyway? [y/N]: " CONTINUE_ANYWAY
    if [[ ! "$CONTINUE_ANYWAY" =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi

  install_packages
  prepare_directories
  write_env_file
  write_odoo_conf
  write_compose_file
  start_stack
  wait_for_postgres
  ensure_database_exists
  write_nginx_site
  request_ssl_certificate
  print_summary
}

main "$@"
