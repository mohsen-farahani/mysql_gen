#!/usr/bin/env bash
set -euo pipefail

# mysql_create_db_user.sh
# Reads MySQL credentials from .env (for local/dev/prod).
# Does NOT print credentials to stdout.
# Saves them to ./db_credential/<database>_<env>.cred with secure permissions.

timestamp() { date +"%Y%m%d_%H%M%S"; }

# --- Load .env if exists ---
if [[ -f .env ]]; then
  export $(grep -v '^#' .env | xargs)
fi

echo "=== MySQL DB & User Creator ==="

# 1) Select environment
while true; do
  read -rp "Select environment (local, dev, or prod) [dev]: " ENV
  ENV=${ENV:-dev}
  case "${ENV,,}" in
    local|dev|production|prod)
      break
      ;;
    *)
      echo "Please enter local, dev, or prod."
      ;;
  esac
done

# Normalize
[[ "${ENV,,}" == "production" ]] && ENV="prod"

# 2) Resolve host, user, pass from .env or prompt
if [[ "${ENV,,}" == "local" ]]; then
  MYSQL_HOST=${LOCAL_MYSQL_HOST:-127.0.0.1}
  ADMIN_USER=${LOCAL_ADMIN_USER:-root}
  ADMIN_PASS=${LOCAL_ADMIN_PASS:-}
elif [[ "${ENV,,}" == "dev" ]]; then
  MYSQL_HOST=${DEV_MYSQL_HOST:-127.0.0.1}
  ADMIN_USER=${DEV_ADMIN_USER:-root}
  ADMIN_PASS=${DEV_ADMIN_PASS:-}
else
  MYSQL_HOST=${PROD_MYSQL_HOST:-127.0.0.1}
  ADMIN_USER=${PROD_ADMIN_USER:-root}
  ADMIN_PASS=${PROD_ADMIN_PASS:-}
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
  case "${PW_CHOICE,,}" in
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
  case "${FULL,,}" in
    y|yes|n|no) break ;;
    *) echo "Please enter y or n." ;;
  esac
done

# 7) Temporary credentials file
TMP_CNF=$(mktemp /tmp/mysql_creds.XXXX.cnf)
chmod 600 "$TMP_CNF"
cat > "$TMP_CNF" <<EOF
[client]
user=${ADMIN_USER}
password=${ADMIN_PASS}
host=${MYSQL_HOST}
EOF

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
if [[ "${FULL,,}" == "y" || "${FULL,,}" == "yes" ]]; then
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
  echo
  echo "Error details:"
  cat /tmp/mysql_error.log 2>/dev/null || echo "No detailed error information available"
  echo
  echo "To troubleshoot further, run: ./mysql_diagnostic.sh"
  rm -f "$TMP_CNF" /tmp/mysql_error.log
  exit 1
fi
rm -f "$TMP_CNF"

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
