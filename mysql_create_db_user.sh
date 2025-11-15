#!/usr/bin/env bash
set -euo pipefail

# mysql_create_db_user.sh
# Reads MySQL credentials from .env (for local/dev/prod).
# Does NOT print credentials to stdout.
# Saves them to ./db_credential/<database>_<env>.cred with secure permissions.

timestamp() { date +"%Y%m%d_%H%M%S"; }

# --- Check if mysql client is available ---
check_mysql_client() {
  if command -v mysql >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# --- Find MySQL Docker container ---
find_mysql_container() {
  if ! command -v docker >/dev/null 2>&1; then
    return 1
  fi
  
  # Try to find MySQL/MariaDB containers
  MYSQL_CONTAINERS=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -E "(mysql|mariadb)" || true)
  if [[ -n "$MYSQL_CONTAINERS" ]]; then
    # Return first container found
    echo "$MYSQL_CONTAINERS" | head -n1
    return 0
  fi
  return 1
}

# --- Load .env if exists ---
if [[ -f .env ]]; then
  export $(grep -v '^#' .env | xargs)
fi

echo "=== MySQL DB & User Creator ==="

# Check if mysql client is available, if not try to use Docker
USE_DOCKER_FOR_CLIENT=false
DOCKER_CONTAINER_FOR_CLIENT=""
if ! check_mysql_client; then
  echo "MySQL client not found. Checking for MySQL Docker containers..."
  DOCKER_CONTAINER_FOR_CLIENT=$(find_mysql_container)
  if [[ -n "$DOCKER_CONTAINER_FOR_CLIENT" ]]; then
    USE_DOCKER_FOR_CLIENT=true
    echo "Found MySQL container: $DOCKER_CONTAINER_FOR_CLIENT"
    echo "Will use MySQL from Docker container instead of local mysql-client."
  else
    echo "WARNING: MySQL client not found and no MySQL Docker containers detected."
    echo "You may need to install mysql-client or start a MySQL Docker container."
  fi
fi

# 1) Select environment
while true; do
  read -rp "Select environment (local, dev, or prod) [dev]: " ENV
  ENV=${ENV:-dev}
  ENV_LOWER=$(echo "$ENV" | tr '[:upper:]' '[:lower:]')
  case "$ENV_LOWER" in
    local|dev|production|prod)
      break
      ;;
    *)
      echo "Please enter local, dev, or prod."
      ;;
  esac
done

# Normalize
ENV_LOWER=$(echo "$ENV" | tr '[:upper:]' '[:lower:]')
[[ "$ENV_LOWER" == "production" ]] && ENV="prod"

# 2) Check if using Docker
USE_DOCKER=false
DOCKER_CONTAINER=""
if [[ "${ENV_LOWER}" == "local" ]]; then
  if [[ -n "${LOCAL_DOCKER_CONTAINER:-}" ]]; then
    USE_DOCKER=true
    DOCKER_CONTAINER=${LOCAL_DOCKER_CONTAINER}
  fi
elif [[ "${ENV_LOWER}" == "dev" ]]; then
  if [[ -n "${DEV_DOCKER_CONTAINER:-}" ]]; then
    USE_DOCKER=true
    DOCKER_CONTAINER=${DEV_DOCKER_CONTAINER}
  fi
else
  if [[ -n "${PROD_DOCKER_CONTAINER:-}" ]]; then
    USE_DOCKER=true
    DOCKER_CONTAINER=${PROD_DOCKER_CONTAINER}
  fi
fi

# Ask if using Docker if not set in .env
if [[ "$USE_DOCKER" == false ]]; then
  read -rp "Is MySQL running in Docker? (y/n) [n]: " DOCKER_CHOICE
  DOCKER_CHOICE=${DOCKER_CHOICE:-n}
  DOCKER_CHOICE_LOWER=$(echo "$DOCKER_CHOICE" | tr '[:upper:]' '[:lower:]')
  if [[ "$DOCKER_CHOICE_LOWER" == "y" || "$DOCKER_CHOICE_LOWER" == "yes" ]]; then
    USE_DOCKER=true
    # Try to detect MySQL container
    if command -v docker >/dev/null 2>&1; then
      MYSQL_CONTAINERS=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -E "(mysql|mariadb)" || true)
      if [[ -n "$MYSQL_CONTAINERS" ]]; then
        echo "Found MySQL containers:"
        echo "$MYSQL_CONTAINERS" | nl
        read -rp "Enter container name or number [1]: " CONTAINER_INPUT
        CONTAINER_INPUT=${CONTAINER_INPUT:-1}
        if [[ "$CONTAINER_INPUT" =~ ^[0-9]+$ ]]; then
          DOCKER_CONTAINER=$(echo "$MYSQL_CONTAINERS" | sed -n "${CONTAINER_INPUT}p")
        else
          DOCKER_CONTAINER="$CONTAINER_INPUT"
        fi
      else
        read -rp "Enter Docker container name: " DOCKER_CONTAINER
      fi
    else
      read -rp "Enter Docker container name: " DOCKER_CONTAINER
    fi
  fi
fi

# 2) Resolve host, user, pass from .env or prompt
ENV_LOWER=$(echo "$ENV" | tr '[:upper:]' '[:lower:]')
if [[ "$USE_DOCKER" == true ]]; then
  # For Docker, we'll use docker exec, so host is not needed
  MYSQL_HOST="localhost"
  if [[ "$ENV_LOWER" == "local" ]]; then
    ADMIN_USER=${LOCAL_ADMIN_USER:-root}
    ADMIN_PASS=${LOCAL_ADMIN_PASS:-}
  elif [[ "$ENV_LOWER" == "dev" ]]; then
    ADMIN_USER=${DEV_ADMIN_USER:-root}
    ADMIN_PASS=${DEV_ADMIN_PASS:-}
  else
    ADMIN_USER=${PROD_ADMIN_USER:-root}
    ADMIN_PASS=${PROD_ADMIN_PASS:-}
  fi
else
  # Regular MySQL connection
  if [[ "$ENV_LOWER" == "local" ]]; then
    MYSQL_HOST=${LOCAL_MYSQL_HOST:-127.0.0.1}
    ADMIN_USER=${LOCAL_ADMIN_USER:-root}
    ADMIN_PASS=${LOCAL_ADMIN_PASS:-}
  elif [[ "$ENV_LOWER" == "dev" ]]; then
    MYSQL_HOST=${DEV_MYSQL_HOST:-127.0.0.1}
    ADMIN_USER=${DEV_ADMIN_USER:-root}
    ADMIN_PASS=${DEV_ADMIN_PASS:-}
  else
    MYSQL_HOST=${PROD_MYSQL_HOST:-127.0.0.1}
    ADMIN_USER=${PROD_ADMIN_USER:-root}
    ADMIN_PASS=${PROD_ADMIN_PASS:-}
  fi
fi

if [[ -z "$ADMIN_PASS" ]]; then
  read -rsp "Admin password for ${ADMIN_USER}@${MYSQL_HOST} (input hidden): " ADMIN_PASS
  echo
fi

# 3) Database name
while true; do
  read -rp "New database name (example: myapp_db): " DB_NAME
  if [[ -n "$DB_NAME" ]]; then break; else echo "Database name cannot be empty."; fi
done

# 4) Username for new db user
while true; do
  read -rp "New username (example: myapp_user): " NEW_USER
  if [[ -n "$NEW_USER" ]]; then break; else echo "Username cannot be empty."; fi
done

# 4.5) Host for the new db user
while true; do
  read -rp "MySQL user host (%, localhost, or IP) [%]: " NEW_HOST
  NEW_HOST=${NEW_HOST:-%}
  if [[ -n "$NEW_HOST" ]]; then break; else echo "Host cannot be empty."; fi
done

# 5) Password generation
while true; do
  read -rp "Do you want to (m)anually provide password or (g)enerate automatically? [g]: " PW_CHOICE
  PW_CHOICE=${PW_CHOICE:-g}
  PW_CHOICE_LOWER=$(echo "$PW_CHOICE" | tr '[:upper:]' '[:lower:]')
  case "$PW_CHOICE_LOWER" in
    m|manual)
      read -rsp "Enter password for ${NEW_USER}: " NEW_PASS
      echo
      if [[ -z "$NEW_PASS" ]]; then
        echo "Password cannot be empty."
      elif [[ "$NEW_PASS" =~ [\\/] ]]; then
        echo "Password cannot contain '/' or '\\'."
      else
        break
      fi
      ;;
    g|gen|generate)
      if command -v openssl >/dev/null 2>&1; then
        # Use hex to avoid '/', '\\', and other symbols
        NEW_PASS=$(openssl rand -hex 16)
      else
        # Alphanumeric-only fallback
        NEW_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
      fi
      break
      ;;
    *)
      echo "Enter 'm' or 'g'."
      ;;
  esac
done

# 6) Full access
while true; do
  read -rp "Grant FULL (ALL PRIVILEGES) to this user? (y/n) [y]: " FULL
  FULL=${FULL:-y}
  FULL_LOWER=$(echo "$FULL" | tr '[:upper:]' '[:lower:]')
  case "$FULL_LOWER" in
    y|yes|n|no) break ;;
    *) echo "Please enter y or n." ;;
  esac
done

# 7) Temporary credentials file (only for non-Docker connections)
TMP_CNF=""
if [[ "$USE_DOCKER" == false ]]; then
  TMP_CNF=$(mktemp /tmp/mysql_creds.XXXX.cnf)
  chmod 600 "$TMP_CNF"
  cat > "$TMP_CNF" <<EOF
[client]
user=${ADMIN_USER}
password=${ADMIN_PASS}
host=${MYSQL_HOST}
EOF
fi

# 8) Escape function
esc_id() {
  printf "%s" "\`${1//\`/``}\`"
}
DB_ESC=$(esc_id "$DB_NAME")
USER_ESC=$(printf "%s" "$NEW_USER" | sed "s/'/''/g")

# 9) SQL commands (MySQL 8.0 compatible)
HOST_ESC=$(printf "%s" "$NEW_HOST" | sed "s/'/''/g")
# Escape password once for SQL literal usage (single quotes)
PW_ESC=$(printf "%s" "$NEW_PASS" | sed "s/'/''/g")
FULL_LOWER=$(echo "$FULL" | tr '[:upper:]' '[:lower:]')
if [[ "$FULL_LOWER" == "y" || "$FULL_LOWER" == "yes" ]]; then
  GRANT_SQL="GRANT ALL PRIVILEGES ON ${DB_ESC}.* TO '${USER_ESC}'@'${HOST_ESC}';"
else
  GRANT_SQL="GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER ON ${DB_ESC}.* TO '${USER_ESC}'@'${HOST_ESC}';"
fi

SQL=$(cat <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_ESC} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
-- Ensure user exists with the chosen host
CREATE USER IF NOT EXISTS '${USER_ESC}'@'${HOST_ESC}' IDENTIFIED BY '${PW_ESC}';
-- Always ensure password is set/updated for existing users
ALTER USER '${USER_ESC}'@'${HOST_ESC}' IDENTIFIED BY '${PW_ESC}';
${GRANT_SQL}
FLUSH PRIVILEGES;
SQL
)

# 10) Run with better error handling
if [[ "$USE_DOCKER" == true ]]; then
  echo "Attempting to connect to MySQL in Docker container: ${DOCKER_CONTAINER}..."
  # Check if container is running
  if ! docker ps --format "{{.Names}}" | grep -q "^${DOCKER_CONTAINER}$"; then
    echo "ERROR: Docker container '${DOCKER_CONTAINER}' is not running."
    echo "Please start the container first: docker start ${DOCKER_CONTAINER}"
    exit 1
  fi
  
  # Use docker exec to run MySQL commands
  # Pass password via environment variable for security
  DOCKER_ERROR=false
  if [[ -n "$ADMIN_PASS" ]]; then
    if ! echo "$SQL" | docker exec -i -e MYSQL_PWD="${ADMIN_PASS}" "$DOCKER_CONTAINER" mysql -u"${ADMIN_USER}" 2>/tmp/mysql_error.log; then
      DOCKER_ERROR=true
    fi
  else
    if ! echo "$SQL" | docker exec -i "$DOCKER_CONTAINER" mysql -u"${ADMIN_USER}" 2>/tmp/mysql_error.log; then
      DOCKER_ERROR=true
    fi
  fi
  
  if [[ "$DOCKER_ERROR" == true ]]; then
    echo "ERROR: Failed to execute MySQL commands in Docker container '${DOCKER_CONTAINER}'."
    echo
    echo "Common causes and solutions:"
    echo "1. Authentication failed - Check your password"
    echo "2. Container not running - Verify container is running: docker ps"
    echo "3. Wrong container name - Check container name: docker ps"
    echo "4. MySQL not installed in container - Verify MySQL is installed in the container"
    echo
    echo "Error details:"
    cat /tmp/mysql_error.log 2>/dev/null || echo "No detailed error information available"
    echo
    rm -f /tmp/mysql_error.log
    exit 1
  fi
else
  # Use Docker mysql if local mysql-client not available
  if [[ "$USE_DOCKER_FOR_CLIENT" == true && -n "$DOCKER_CONTAINER_FOR_CLIENT" ]]; then
    # Determine which container to use
    CLIENT_CONTAINER="$DOCKER_CONTAINER_FOR_CLIENT"
    # If MySQL server is also in Docker, use that container instead
    if [[ "$USE_DOCKER" == true && -n "$DOCKER_CONTAINER" ]]; then
      CLIENT_CONTAINER="$DOCKER_CONTAINER"
    fi
    
    echo "Attempting to connect to MySQL server at ${MYSQL_HOST} using Docker container: ${CLIENT_CONTAINER}..."
    # Check if container is running
    if ! docker ps --format "{{.Names}}" | grep -q "^${CLIENT_CONTAINER}$"; then
      echo "ERROR: Docker container '${CLIENT_CONTAINER}' is not running."
      echo "Please start the container first: docker start ${CLIENT_CONTAINER}"
      rm -f "$TMP_CNF" /tmp/mysql_error.log
      exit 1
    fi
    
    # Use docker exec to run MySQL commands
    # If connecting to MySQL in same container, use localhost, otherwise use MYSQL_HOST
    MYSQL_HOST_FOR_DOCKER="localhost"
    if [[ "$USE_DOCKER" == false ]]; then
      # MySQL server is not in Docker, use the provided host
      MYSQL_HOST_FOR_DOCKER="$MYSQL_HOST"
    fi
    
    DOCKER_CLIENT_ERROR=false
    if [[ -n "$ADMIN_PASS" ]]; then
      if ! echo "$SQL" | docker exec -i -e MYSQL_PWD="${ADMIN_PASS}" "$CLIENT_CONTAINER" mysql -h"${MYSQL_HOST_FOR_DOCKER}" -u"${ADMIN_USER}" 2>/tmp/mysql_error.log; then
        DOCKER_CLIENT_ERROR=true
      fi
    else
      if ! echo "$SQL" | docker exec -i "$CLIENT_CONTAINER" mysql -h"${MYSQL_HOST_FOR_DOCKER}" -u"${ADMIN_USER}" 2>/tmp/mysql_error.log; then
        DOCKER_CLIENT_ERROR=true
      fi
    fi
    
    if [[ "$DOCKER_CLIENT_ERROR" == true ]]; then
      echo "ERROR: Failed to execute MySQL commands using Docker container '${CLIENT_CONTAINER}'."
      echo
      echo "Common causes and solutions:"
      echo "1. Authentication failed - Check your password"
      echo "2. Container not running - Verify container is running: docker ps"
      echo "3. Wrong container name - Check container name: docker ps"
      echo "4. MySQL not installed in container - Verify MySQL is installed in the container"
      if [[ "$USE_DOCKER" == false ]]; then
        echo "5. Host ${MYSQL_HOST} not reachable from container - Check network connectivity"
      fi
      echo
      echo "Error details:"
      cat /tmp/mysql_error.log 2>/dev/null || echo "No detailed error information available"
      echo
      rm -f "$TMP_CNF" /tmp/mysql_error.log
      exit 1
    fi
  else
    echo "Attempting to connect to MySQL server at ${MYSQL_HOST}..."
    if ! mysql --defaults-extra-file="$TMP_CNF" -e "$SQL" 2>/tmp/mysql_error.log; then
      echo "ERROR: Failed to execute MySQL commands on ${MYSQL_HOST}."
      echo
      echo "Common causes and solutions:"
      echo "1. Authentication failed - Check your password"
      echo "2. Network connectivity - Verify the host is reachable"
      echo "3. MySQL service not running - Check if MySQL is running on target host"
      echo "4. Firewall blocking - Ensure port 3306 is open"
      echo "5. User permissions - Verify the user can connect from your IP"
      echo "6. If using Docker, make sure port is mapped (e.g., -p 3306:3306)"
      echo
      echo "Error details:"
      cat /tmp/mysql_error.log 2>/dev/null || echo "No detailed error information available"
      echo
      echo "To troubleshoot further, run: ./mysql_diagnostic.sh"
      rm -f "$TMP_CNF" /tmp/mysql_error.log
      exit 1
    fi
    rm -f "$TMP_CNF"
  fi
fi

# 11) Save credentials
OUT_DIR="./db_credential"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
OUT_FILE="${OUT_DIR}/${DB_NAME}_${ENV}.cred"

cat > "$OUT_FILE" <<EOF
# created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
environment: $ENV
mysql_host: $MYSQL_HOST
database: $DB_NAME
user: $NEW_USER
user_host: $NEW_HOST
password: $NEW_PASS
EOF
chmod 600 "$OUT_FILE"

# 12) Done
echo "SUCCESS: Database and user created."
echo "Credentials saved securely to: $OUT_FILE"
