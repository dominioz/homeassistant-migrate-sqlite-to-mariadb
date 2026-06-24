SQLite → Mysql Migration Tool for Home Assistant
===================================================

A Bash script to migrate Home Assistant's SQLite database to MariaDB, table by table, 
with schema conversion and CSV import. Designed to handle large text/JSON fields 
and support parallel migration.

Features
--------
- Interactive table selection or migrate all tables.
- Automatic schema conversion from SQLite to MariaDB:
  - TEXT → VARCHAR(255) (exceptions for large JSON fields like state_attributes)
  - BLOB → VARBINARY(255)
  - REAL/NUMERIC/FLOAT/DOUBLE → DOUBLE PRECISION
  - AUTOINCREMENT → AUTO_INCREMENT
- Drop and recreate tables safely with foreign key and unique checks disabled during migration.
- Automatic addition of AUTO_INCREMENT to primary key integer fields.
- Parallel migration with configurable number of concurrent jobs.
- Progress reporting and timing for each table.
- CSV dump saved locally for backup and inspection.

Requirements
------------
- Bash (4+ recommended)
- SQLite3
- MariaDB/MySQL client
- realpath utility
- Linux, macOS, or WSL (Windows Subsystem for Linux)

Usage
-----
./migrate-ha-db.sh <sqlite_db> <mysql_host> <mysql_user> <mysql_password|env> <mysql_db>

Example with environment variable for password:

MYSQL_PWD=secret ./migrate-ha-db.sh home-assistant_v2.db 192.168.77.134 homeassistant secret homeassistant

Interactive Selection:
1. The script lists all tables in the SQLite database.
2. You can select specific tables by number (e.g., 1,3,5) or type 'all' to migrate all tables.
3. Confirm to proceed with migration.

Configuration
-------------
- CSV_DIR: Directory where temporary CSV files are stored (default: ./sqlite_csv)
- PARALLEL_JOBS: Number of tables to migrate in parallel (default: 2)
- CHARSET: Character set for MariaDB tables (default: utf8mb4)

Notes
-----
- Large JSON/text fields like state_attributes and statistics_meta.shared_attrs are automatically converted to LONGTEXT to prevent truncation.
- The script disables foreign key and unique checks during table creation and data import for speed.
- Always back up your databases before running the migration.
- Intended primarily for Home Assistant databases, but can be adapted to other SQLite → MariaDB migrations.

Troubleshooting
---------------
- MySQL/MariaDB connection errors: Ensure the host, username, password, and database exist and allow remote connections.
- LOAD DATA LOCAL INFILE errors: Make sure the MariaDB server and client allow local file imports.
- Parallel migration issues: Reduce PARALLEL_JOBS if you encounter table lock conflicts or high load.

License
-------
MIT License – free to use and modify.

Author
------
ChatGPT (GPT-5) – inspirated, adapted, enhanced and corrected by the user.
