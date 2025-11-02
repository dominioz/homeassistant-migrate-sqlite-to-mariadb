#!/usr/bin/env bash
#
# SQLite → MariaDB table-by-table migration
# Author: Slawek 
# Code writing: ChatGPT (GPT-5)
# --------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'

# === ARGUMENTS =================================================
SQLITE_DB="${1:-}"
MYSQL_HOST="${2:-}"
MYSQL_USER="${3:-}"
MYSQL_PWD="${4:-${MYSQL_PWD:-}}"
MYSQL_DB="${5:-}"
CHARSET="utf8mb4"
CSV_DIR="./sqlite_csv"
PARALLEL_JOBS=2
FORCE_MODE=false
# ===============================================================

# === VALIDATION ================================================
if [[ -z "$SQLITE_DB" || -z "$MYSQL_HOST" || -z "$MYSQL_USER" || -z "$MYSQL_DB" ]]; then
  echo "Usage: $0 <sqlite_db> <mysql_host> <mysql_user> <mysql_password|env> <mysql_db>"
  echo "Example:"
  echo "  MYSQL_PWD=secret ./sqlite_to_mariadb.sh home-assistant_v2.db 192.168.1.2 homeassistant secret homeassistant"
  exit 1
fi

if [[ -z "$MYSQL_PWD" ]]; then
  echo "❌ MYSQL_PWD not set or passed as 4th argument."
  exit 1
fi

mkdir -p "$CSV_DIR"
start_time=$(date +%s)

echo "====================================================="
echo " SQLite → MariaDB Migration Tool"
echo "-----------------------------------------------------"
echo " Source DB: $SQLITE_DB"
echo " Target DB: $MYSQL_DB on $MYSQL_HOST (user: $MYSQL_USER)"
echo "====================================================="

# === STEP 1: discover tables ===================================
echo "[*] Fetching table list..."
mapfile -t TABLES < <(
  sqlite3 "$SQLITE_DB" "
    SELECT name FROM sqlite_master
      WHERE type='table' AND name NOT LIKE 'sqlite_%'
      ORDER BY name;
  "
)

echo ""
echo "Found ${#TABLES[@]} tables:"
for i in "${!TABLES[@]}"; do
  printf "  [%2d] %s\n" "$((i+1))" "${TABLES[$i]}"
done

echo ""
read -r -p "Select tables to import (e.g. 1,3,5 or 'all'): " selection
if [[ "$selection" == "all" ]]; then
  SELECTED_TABLES=("${TABLES[@]}")
else
  IFS=',' read -ra IDX <<< "$selection"
  SELECTED_TABLES=()
  for i in "${IDX[@]}"; do
    i=$((i-1))
    [[ $i -ge 0 && $i -lt ${#TABLES[@]} ]] && SELECTED_TABLES+=("${TABLES[$i]}")
  done
fi

echo ""
echo "Tables to migrate: ${SELECTED_TABLES[*]}"
read -r -p "Proceed? [y/N]: " ans
[[ "${ans,,}" != "y" ]] && exit 0

# === STEP 2: migrate one table =================================
migrate_table() {
  local TABLE="$1"
  local csv="$CSV_DIR/$TABLE.csv"

  echo ""
  echo "-----------------------------------------------------"
  echo "[+] Processing table: $TABLE"
  echo "-----------------------------------------------------"

  # Export to CSV (UTF-8)
  echo "[*] Exporting to CSV..."
  sqlite3 -csv -header "$SQLITE_DB" "SELECT * FROM \"$TABLE\";" > "$csv"

  # Generate CREATE TABLE SQL
  CREATE_SQL=$(sqlite3 "$SQLITE_DB" ".schema $TABLE" |
  awk '
    BEGIN { IGNORECASE=1 }
    /^CREATE TABLE/ { in_table=1 }
    in_table && /^);/ {
      print ") CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
      in_table=0
      next
    }
    {
      # Replace any TEXT/LONGTEXT/BLOB column used in keys with VARCHAR(255)
      gsub(/\bLONGTEXT\b/, "VARCHAR(255)")
      gsub(/\bTEXT\b/, "VARCHAR(255)")
      gsub(/\bBLOB\b/, "VARBINARY(255)")
      print
    }
  ')


  # --- normalize schema for MariaDB ----------------------------
  CREATE_SQL=$(echo "$CREATE_SQL" | \
    sed -E 's/IF NOT EXISTS//Ig' | \
    sed -E 's/REAL/DOUBLE PRECISION/Ig' | \
    sed -E 's/DOUBLE/DOUBLE PRECISION/Ig' | \
    sed -E 's/FLOAT/DOUBLE PRECISION/Ig' | \
    sed -E 's/NUMERIC/DOUBLE PRECISION/Ig' | \
    sed -E 's/AUTOINCREMENT/AUTO_INCREMENT/Ig' | \
    sed -E 's/DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP/CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP/Ig' | \
    sed -E 's/DEFAULT CURRENT_TIMESTAMP/CURRENT_TIMESTAMP/Ig')

  # Fix known large JSON columns
  if [[ "$TABLE" == "state_attributes" ]]; then
    CREATE_SQL=$(echo "$CREATE_SQL" | sed -E 's/`shared_attrs`[^,]*/`shared_attrs` LONGTEXT/')
  fi

  # Fix backticks
  CREATE_SQL=$(echo "$CREATE_SQL" | sed -E 's/"([^"]+)"/`\1`/g')

  # Drop and recreate
  echo "[*] Recreating table in MariaDB..."
  mariadb --host="$MYSQL_HOST" --user="$MYSQL_USER" --password="$MYSQL_PWD" \
    "$MYSQL_DB" --default-character-set="$CHARSET" -e "
      SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;
      DROP TABLE IF EXISTS \`$TABLE\`;
      $CREATE_SQL
      SET FOREIGN_KEY_CHECKS=1; SET UNIQUE_CHECKS=1;
    "

  # Fix auto-increment on primary key integer fields
  ALTER_SQL=$(mariadb --host="$MYSQL_HOST" --user="$MYSQL_USER" --password="$MYSQL_PWD" \
      --batch --skip-column-names "$MYSQL_DB" -e "
      SELECT CONCAT(
        'ALTER TABLE \`', table_name, '\` MODIFY COLUMN \`', column_name, '\` ',
        column_type, ' AUTO_INCREMENT;'
      )
      FROM information_schema.columns
      WHERE table_schema = DATABASE()
        AND table_name = '$TABLE'
        AND column_key = 'PRI'
        AND extra NOT LIKE '%auto_increment%'
        AND data_type IN ('int','bigint','mediumint','smallint','tinyint');
  ")

  if [[ -n "$ALTER_SQL" ]]; then
    echo "[*] Adding AUTO_INCREMENT to primary key(s)..."
    echo "$ALTER_SQL" | mariadb --host="$MYSQL_HOST" --user="$MYSQL_USER" --password="$MYSQL_PWD" "$MYSQL_DB"
  fi

  # Specific fix for Home Assistant statistics_meta.shared_attrs
  if [[ "$TABLE" == "statistics_meta" ]]; then
    echo "[*] Ensuring shared_attrs is LONGTEXT..."
    mariadb --host="$MYSQL_HOST" --user="$MYSQL_USER" --password="$MYSQL_PWD" "$MYSQL_DB" \
      -e "ALTER TABLE statistics_meta MODIFY COLUMN shared_attrs LONGTEXT;"
  fi

  # Import data
  echo "[*] Importing $(wc -l < "$csv") rows via LOAD DATA LOCAL INFILE..."
  t0=$(date +%s)
  mariadb --host="$MYSQL_HOST" --user="$MYSQL_USER" --password="$MYSQL_PWD" \
    --local-infile=1 --default-character-set="$CHARSET" "$MYSQL_DB" -e "
      SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0;
      LOAD DATA LOCAL INFILE '$(realpath "$csv")'
      INTO TABLE \`$TABLE\`
      FIELDS TERMINATED BY ',' ENCLOSED BY '\"'
      LINES TERMINATED BY '\n'
      IGNORE 1 LINES;
      SET FOREIGN_KEY_CHECKS=1; SET UNIQUE_CHECKS=1;
    "
  t1=$(date +%s)
  printf "[✓] Imported %s successfully in %02d:%02d minutes.\n" \
         "$TABLE" $(( (t1-t0)/60 )) $(( (t1-t0)%60 ))
}

export -f migrate_table
export SQLITE_DB MYSQL_HOST MYSQL_USER MYSQL_DB MYSQL_PWD CHARSET CSV_DIR

echo ""
echo "[+] Starting parallel migration..."
echo "-------------------------------------------------------"
printf "%s\n" "${SELECTED_TABLES[@]}" | xargs -I{} -P "$PARALLEL_JOBS" bash -c 'migrate_table "$@"' _ {}

end_time=$(date +%s)
elapsed=$(( end_time - start_time ))

echo ""
echo "====================================================="
echo "✅ Migration completed successfully!"
echo "CSV dumps are saved in: $CSV_DIR"
printf "⏱  Total elapsed time: %02d:%02d minutes\n" $((elapsed/60)) $((elapsed%60))
echo "====================================================="
