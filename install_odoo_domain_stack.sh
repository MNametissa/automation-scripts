#!/usr/bin/env bash
set -Eeuo pipefail

# Odoo domain installer
# - Supports shared or isolated PostgreSQL
# - Maps one subdomain to one database through dbfilter=^%d$
# - Enforces: DB name == first label of domain (e.g. erp.hkdigitals.com -> erp)
# - Configures Nginx and Certbot
# - Allows multiple side-by-side Odoo instances on the same host
#
# Run as root on Ubuntu.

ODOO_VERSION_DEFAULT="19"
POSTGRES_IMAGE_DEFAULT="postgres:15"
BASE_DIR_ROOT_DEFAULT="/opt/odoo-stacks"
SHARED_PG_DIR_DEFAULT="/opt/odoo-shared-postgres"
NGINX_LOG_DIR_DEFAULT="/var/log/nginx"
DOCKER_SHARED_NETWORK_DEFAULT="odoo-shared-net"
PG_CONTAINER_NAME_SHARED_DEFAULT="odoo-shared-pg"
PG_HOSTNAME_SHARED_DEFAULT="odoo-shared-pg"
MODE_DEFAULT="shared"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
okay()  { echo -e "${GREEN}[OK]${NC} $*"; }

trap 'error "Script failed on line $LINENO."; exit 1' ERR

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
  python3 - "$domain" <<'PY'
import re, sys
pat = re.compile(r'^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$')
print('1' if pat.match(sys.argv[1]) else '0')
PY
}

validate_db_name() {
  local db_name="$1"
  python3 - "$db_name" <<'PY'
import re, sys
pat = re.compile(r'^[a-z0-9][a-z0-9_-]{0,62}$')
print('1' if pat.match(sys.argv[1]) else '0')
PY
}

extract_db_from_domain() {
  local domain="$1"
  echo "$domain" | cut -d'.' -f1 | tr '[:upper:]' '[:lower:]'
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

make_upstream_name() {
  echo "$1" | tr '-' '_'
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

port_in_use() {
  local port="$1"
  ss -ltnH "sport = :$port" 2>/dev/null | grep -q .
}

find_free_port() {
  local port="$1"
  while port_in_use "$port"; do
    port=$((port + 1))
  done
  echo "$port"
}

install_base_packages() {
  info "Installing base packages..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    nginx \
    certbot \
    python3 \
    python3-certbot-nginx \
    unzip \
    dnsutils

  systemctl enable --now nginx
  okay "Base packages installed."
}

setup_docker_repo() {
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  cat > /etc/apt/sources.list.d/docker.sources <<EOF_REPO
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF_REPO
}

install_or_reuse_docker() {
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    okay "Docker and Docker Compose are already available. Skipping Docker installation."
    systemctl enable --now docker >/dev/null 2>&1 || true
    return
  fi

  info "Installing Docker Engine from Docker's official apt repository..."
  export DEBIAN_FRONTEND=noninteractive

  apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc >/dev/null 2>&1 || true

  setup_docker_repo
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  okay "Docker Engine installed."
}

prepare_instance_directories() {
  info "Preparing instance directories under $BASE_DIR ..."
  mkdir -p "$BASE_DIR"/{config,addons,data/odoo,bin,backups}
  if [[ "$DEPLOYMENT_MODE" == "isolated" ]]; then
    mkdir -p "$BASE_DIR/data/db"
  fi
  chmod 755 "$BASE_DIR"
  okay "Instance directories ready."
}

prepare_shared_pg_directories() {
  info "Preparing shared PostgreSQL directories under $SHARED_PG_DIR ..."
  mkdir -p "$SHARED_PG_DIR"/{data/db,backups}
  chmod 755 "$SHARED_PG_DIR"
  okay "Shared PostgreSQL directories ready."
}

load_existing_shared_pg_env_if_any() {
  if [[ -f "$SHARED_PG_DIR/.env" ]]; then
    info "Existing shared PostgreSQL environment detected at $SHARED_PG_DIR/.env"
    # shellcheck disable=SC1090
    source "$SHARED_PG_DIR/.env"
    EXISTING_SHARED_PG_ENV="true"
  else
    EXISTING_SHARED_PG_ENV="false"
  fi
}

collect_shared_pg_settings() {
  prompt SHARED_PG_DIR "Shared PostgreSQL installation directory" "$SHARED_PG_DIR_DEFAULT"
  SHARED_PG_DIR="$(echo "$SHARED_PG_DIR" | xargs)"
  load_existing_shared_pg_env_if_any

  DOCKER_SHARED_NETWORK="${DOCKER_SHARED_NETWORK:-$DOCKER_SHARED_NETWORK_DEFAULT}"
  PG_CONTAINER_NAME="${PG_CONTAINER_NAME:-$PG_CONTAINER_NAME_SHARED_DEFAULT}"
  PG_HOSTNAME="${PG_HOSTNAME:-$PG_HOSTNAME_SHARED_DEFAULT}"
  POSTGRES_IMAGE="${POSTGRES_IMAGE:-$POSTGRES_IMAGE_DEFAULT}"

  if [[ "$EXISTING_SHARED_PG_ENV" == "true" ]]; then
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?Existing shared PostgreSQL .env is missing POSTGRES_PASSWORD}"
    okay "Reusing existing shared PostgreSQL credentials and settings."
  else
    GENERATED_PG_PASSWORD="$(random_secret)"
    prompt POSTGRES_PASSWORD "PostgreSQL password for shared Odoo user" "$GENERATED_PG_PASSWORD" true
  fi
}

collect_instance_settings() {
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

  local db_valid
  db_valid="$(validate_db_name "$DB_NAME")"
  if [[ "$db_valid" != "1" ]]; then
    error "Invalid database name: $DB_NAME"
    exit 1
  fi

  if [[ "$DB_NAME" != "$SUGGESTED_DB" ]]; then
    error "Invalid mapping: database '$DB_NAME' does not match the first label of '$DOMAIN' (expected '$SUGGESTED_DB')."
    exit 1
  fi

  prompt LETSENCRYPT_EMAIL "Enter the email for Let's Encrypt notices"
  INSTANCE_DEFAULT_DIR="$BASE_DIR_ROOT_DEFAULT/$DB_NAME"
  prompt BASE_DIR "Instance installation directory" "$INSTANCE_DEFAULT_DIR"
  BASE_DIR="$(echo "$BASE_DIR" | xargs)"

  prompt DEPLOYMENT_MODE "PostgreSQL mode (shared/isolated)" "$MODE_DEFAULT"
  DEPLOYMENT_MODE="$(echo "$DEPLOYMENT_MODE" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "$DEPLOYMENT_MODE" in
    shared|isolated) ;;
    *) error "Invalid mode '$DEPLOYMENT_MODE'. Use 'shared' or 'isolated'."; exit 1 ;;
  esac

  prompt ODOO_VERSION "Odoo major version" "$ODOO_VERSION_DEFAULT"
  ODOO_IMAGE="odoo:${ODOO_VERSION}"

  GENERATED_ADMIN_PASSWORD="$(random_secret)"
  prompt ODOO_ADMIN_PASSWORD "Odoo admin/master password" "$GENERATED_ADMIN_PASSWORD" true

  ODOO_HTTP_PORT_DEFAULT="$(find_free_port 8069)"
  ODOO_CHAT_PORT_DEFAULT="$(find_free_port 8072)"
  prompt ODOO_HTTP_PORT "Odoo HTTP bind port on localhost" "$ODOO_HTTP_PORT_DEFAULT"
  prompt ODOO_CHAT_PORT "Odoo longpolling/websocket bind port on localhost" "$ODOO_CHAT_PORT_DEFAULT"

  INSTANCE_SLUG="$(slugify "$DB_NAME")"
  INSTANCE_UPSTREAM_SLUG="$(make_upstream_name "$INSTANCE_SLUG")"
  ODOO_CONTAINER_NAME="odoo-${INSTANCE_SLUG}"

  if [[ "$DEPLOYMENT_MODE" == "isolated" ]]; then
    GENERATED_PG_PASSWORD="$(random_secret)"
    prompt POSTGRES_PASSWORD "PostgreSQL password for Odoo user" "$GENERATED_PG_PASSWORD" true
    POSTGRES_IMAGE="$POSTGRES_IMAGE_DEFAULT"
    PG_CONTAINER_NAME="odoo-db-${INSTANCE_SLUG}"
    PG_HOSTNAME="db"
  else
    collect_shared_pg_settings
  fi
}

verify_dns_if_possible() {
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
}

write_instance_env_file() {
  info "Writing instance environment file..."
  cat > "$BASE_DIR/.env" <<EOF_ENV
POSTGRES_USER=odoo
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=postgres
POSTGRES_IMAGE=${POSTGRES_IMAGE}
ODOO_VERSION=$ODOO_VERSION
ODOO_IMAGE=$ODOO_IMAGE
ODOO_ADMIN_PASSWORD=$ODOO_ADMIN_PASSWORD
ODOO_HTTP_PORT=$ODOO_HTTP_PORT
ODOO_CHAT_PORT=$ODOO_CHAT_PORT
ODOO_CONTAINER_NAME=$ODOO_CONTAINER_NAME
PG_CONTAINER_NAME=$PG_CONTAINER_NAME
PG_HOSTNAME=$PG_HOSTNAME
DOCKER_SHARED_NETWORK=${DOCKER_SHARED_NETWORK:-}
EOF_ENV
  chmod 600 "$BASE_DIR/.env"
  okay "Instance environment file written."
}

write_shared_pg_env_file() {
  info "Writing shared PostgreSQL environment file..."
  cat > "$SHARED_PG_DIR/.env" <<EOF_ENV
POSTGRES_USER=odoo
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=postgres
POSTGRES_IMAGE=${POSTGRES_IMAGE}
PG_CONTAINER_NAME=$PG_CONTAINER_NAME
PG_HOSTNAME=$PG_HOSTNAME
DOCKER_SHARED_NETWORK=$DOCKER_SHARED_NETWORK
EOF_ENV
  chmod 600 "$SHARED_PG_DIR/.env"
  okay "Shared PostgreSQL environment file written."
}

write_odoo_conf() {
  info "Writing Odoo configuration..."
  cat > "$BASE_DIR/config/odoo.conf" <<EOF_CONF
[options]
admin_passwd = $ODOO_ADMIN_PASSWORD
db_host = $PG_HOSTNAME
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

write_shared_pg_compose_file() {
  info "Writing shared PostgreSQL Docker Compose stack..."
  cat > "$SHARED_PG_DIR/docker-compose.yml" <<'EOF_COMPOSE'
services:
  db:
    image: ${POSTGRES_IMAGE}
    container_name: ${PG_CONTAINER_NAME}
    hostname: ${PG_HOSTNAME}
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
    networks:
      default:
        aliases:
          - ${PG_HOSTNAME}

networks:
  default:
    name: ${DOCKER_SHARED_NETWORK}
EOF_COMPOSE
  okay "Shared PostgreSQL Compose file written."
}

write_isolated_compose_file() {
  info "Writing isolated Docker Compose stack..."
  cat > "$BASE_DIR/docker-compose.yml" <<'EOF_COMPOSE'
services:
  db:
    image: ${POSTGRES_IMAGE}
    container_name: ${PG_CONTAINER_NAME}
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
    container_name: ${ODOO_CONTAINER_NAME}
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "127.0.0.1:${ODOO_HTTP_PORT}:8069"
      - "127.0.0.1:${ODOO_CHAT_PORT}:8072"
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
  okay "Isolated Compose file written."
}

write_shared_mode_instance_compose_file() {
  info "Writing Odoo instance Docker Compose stack (shared PostgreSQL mode)..."
  cat > "$BASE_DIR/docker-compose.yml" <<'EOF_COMPOSE'
services:
  odoo:
    image: ${ODOO_IMAGE}
    container_name: ${ODOO_CONTAINER_NAME}
    ports:
      - "127.0.0.1:${ODOO_HTTP_PORT}:8069"
      - "127.0.0.1:${ODOO_CHAT_PORT}:8072"
    environment:
      HOST: ${PG_HOSTNAME}
      USER: ${POSTGRES_USER}
      PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./data/odoo:/var/lib/odoo
      - ./config:/etc/odoo
      - ./addons:/mnt/extra-addons
    command: ["odoo", "--config=/etc/odoo/odoo.conf"]
    restart: unless-stopped
    networks:
      - default
      - shared_pg

networks:
  shared_pg:
    external: true
    name: ${DOCKER_SHARED_NETWORK}
EOF_COMPOSE
  okay "Shared-mode instance Compose file written."
}

start_compose_stack() {
  local compose_dir="$1"
  info "Starting Docker stack in $compose_dir ..."
  (cd "$compose_dir" && docker compose up -d)
  okay "Docker stack started in $compose_dir."
}

wait_for_postgres_container() {
  local container_name="$1"
  info "Waiting for PostgreSQL container '$container_name' to become ready..."
  local retries=90
  until docker exec "$container_name" pg_isready -U odoo -d postgres >/dev/null 2>&1; do
    retries=$((retries - 1))
    if [[ "$retries" -le 0 ]]; then
      error "PostgreSQL container '$container_name' did not become ready in time."
      exit 1
    fi
    sleep 2
  done
  okay "PostgreSQL container '$container_name' is ready."
}

ensure_database_exists() {
  info "Ensuring database '$DB_NAME' exists on '$PG_CONTAINER_NAME' ..."
  if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$PG_CONTAINER_NAME" psql -U odoo -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    warn "Database '$DB_NAME' already exists."
  else
    docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$PG_CONTAINER_NAME" createdb -U odoo "$DB_NAME"
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
upstream odoo_${INSTANCE_UPSTREAM_SLUG} {
    server 127.0.0.1:${ODOO_HTTP_PORT};
}

upstream odoochat_${INSTANCE_UPSTREAM_SLUG} {
    server 127.0.0.1:${ODOO_CHAT_PORT};
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    access_log ${NGINX_LOG_DIR_DEFAULT}/odoo_${INSTANCE_SLUG}_access.log;
    error_log  ${NGINX_LOG_DIR_DEFAULT}/odoo_${INSTANCE_SLUG}_error.log;

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

        proxy_pass http://odoo_${INSTANCE_UPSTREAM_SLUG};
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
        proxy_pass http://odoochat_${INSTANCE_UPSTREAM_SLUG};
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
        proxy_pass http://odoochat_${INSTANCE_UPSTREAM_SLUG};
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
        proxy_pass http://odoo_${INSTANCE_UPSTREAM_SLUG};
    }

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
ODOO STACK READY
============================================================
Mode           : $DEPLOYMENT_MODE
Instance dir   : $BASE_DIR
Domain         : $DOMAIN
Database       : $DB_NAME
Odoo version   : $ODOO_VERSION
Odoo URL       : https://$DOMAIN
Odoo ports     : 127.0.0.1:${ODOO_HTTP_PORT}->8069, 127.0.0.1:${ODOO_CHAT_PORT}->8072
Odoo container : $ODOO_CONTAINER_NAME

EOF_SUMMARY

  if [[ "$DEPLOYMENT_MODE" == "shared" ]]; then
    cat <<EOF_SUMMARY
Shared PostgreSQL:
  - Dir           : $SHARED_PG_DIR
  - Container     : $PG_CONTAINER_NAME
  - Docker network: $DOCKER_SHARED_NETWORK

EOF_SUMMARY
  else
    cat <<EOF_SUMMARY
Isolated PostgreSQL:
  - Container     : $PG_CONTAINER_NAME
  - Data dir      : $BASE_DIR/data/db

EOF_SUMMARY
  fi

  cat <<EOF_SUMMARY
Useful paths:
  - Compose stack : $BASE_DIR/docker-compose.yml
  - Odoo config   : $BASE_DIR/config/odoo.conf
  - Addons        : $BASE_DIR/addons
  - Odoo data     : $BASE_DIR/data/odoo

Next steps:
  1) Copy your custom addons into: $BASE_DIR/addons
  2) Restore your dump into database: $DB_NAME
  3) Restart Odoo after restore/addons sync:
       cd $BASE_DIR && docker compose restart odoo
  4) Check logs if needed:
       cd $BASE_DIR && docker compose logs -f odoo

Restore example:
  docker cp ./your_dump.sql $PG_CONTAINER_NAME:/tmp/your_dump.sql
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" -it $PG_CONTAINER_NAME psql -U odoo -d $DB_NAME -f /tmp/your_dump.sql

============================================================
EOF_SUMMARY
}

main() {
  require_root

  info "This installer creates one Odoo instance and one domain->database mapping."
  info "It supports either a shared PostgreSQL service or a dedicated PostgreSQL per instance."

  collect_instance_settings
  install_base_packages
  install_or_reuse_docker
  verify_dns_if_possible

  if [[ "$DEPLOYMENT_MODE" == "shared" ]]; then
    prepare_shared_pg_directories
    prepare_instance_directories
    write_shared_pg_env_file
    write_shared_pg_compose_file
    write_instance_env_file
    write_odoo_conf
    write_shared_mode_instance_compose_file
    start_compose_stack "$SHARED_PG_DIR"
    wait_for_postgres_container "$PG_CONTAINER_NAME"
    ensure_database_exists
    start_compose_stack "$BASE_DIR"
  else
    prepare_instance_directories
    write_instance_env_file
    write_odoo_conf
    write_isolated_compose_file
    start_compose_stack "$BASE_DIR"
    wait_for_postgres_container "$PG_CONTAINER_NAME"
    ensure_database_exists
  fi

  write_nginx_site
  request_ssl_certificate
  print_summary
}

main "$@"
