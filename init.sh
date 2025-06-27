#!/bin/bash -ex

# Redirect all stdout and stderr to log files
exec 1> >(tee -a /efs/logs/nominatim/init.log)
exec 2> >(tee -a /efs/logs/nominatim/init_error.log)

# Create logs directory early
mkdir -p /efs/logs/nominatim
chmod 755 /efs/logs/nominatim

if ! command -v sshpass &> /dev/null; then
    echo "Installing sshpass..."
    cd /tmp
    curl -L -o sshpass-1.09.tar.gz https://sourceforge.net/projects/sshpass/files/sshpass/1.09/sshpass-1.09.tar.gz/download >> /efs/logs/nominatim/sshpass_install.log 2>&1
    tar -xzf sshpass-1.09.tar.gz >> /efs/logs/nominatim/sshpass_install.log 2>&1
    cd sshpass-1.09
    ./configure >> /efs/logs/nominatim/sshpass_install.log 2>&1
    make >> /efs/logs/nominatim/sshpass_install.log 2>&1
    make install >> /efs/logs/nominatim/sshpass_install.log 2>&1
    cd /
    rm -rf /tmp/sshpass*
    echo "sshpass installed successfully"
fi

EFS_MOUNT_POINT="/efs"

CURL=("curl" "-L" "-A" "${USER_AGENT}" "--fail-early")
SCP='sshpass -p DMg5bmLPY7npHL2Q scp -o StrictHostKeyChecking=no u355874-sub1@u355874-sub1.your-storagebox.de'

# Check if THREADS is not set or is empty
if [ -z "$THREADS" ]; then
  THREADS=$(nproc)
fi

# Determine storage paths and download directly where needed
DOWNLOAD_DIR="${EFS_MOUNT_POINT}/nominatim/downloads"
DATA_DIR="${EFS_MOUNT_POINT}/nominatim/data"

# Create EFS directories
echo "Creating EFS directories..."
mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$DATA_DIR"
mkdir -p "${EFS_MOUNT_POINT}/data"

chown -R nominatim:nominatim ${PROJECT_DIR}
# Set ownership of EFS directories
chown -R nominatim:nominatim "${EFS_MOUNT_POINT}/nominatim" 2>/dev/null || true
chmod -R 755 "${EFS_MOUNT_POINT}/nominatim" 2>/dev/null || true

chown -R nominatim:nominatim "${EFS_MOUNT_POINT}/data" 2>/dev/null || true
chmod -R 755 "${EFS_MOUNT_POINT}/data" 2>/dev/null || true
echo "Using EFS storage"

# Create PROJECT_DIR and set ownership
mkdir -p "${PROJECT_DIR}"
chown -R nominatim:nominatim "${PROJECT_DIR}" 2>/dev/null || true

IMPORT_GB_POSTCODES="true"
IMPORT_WIKIPEDIA="true"
IMPORT_US_POSTCODES="true"
IMPORT_TIGER_ADDRESSES="true"

# Download functions - NO SYMLINKS, direct downloads
download_wikipedia() {
    if [ "$IMPORT_WIKIPEDIA" = "true" ]; then
        echo "Downloading Wikipedia importance dump to PROJECT_DIR"
        # Download directly to PROJECT_DIR (where Nominatim expects them)
        ${SCP}:wikimedia-importance.csv.gz ${PROJECT_DIR}/wikimedia-importance.csv.gz >> /efs/logs/nominatim/wikipedia_download.log 2>&1
        
        if [ $? -eq 0 ]; then
            echo "Wikipedia files downloaded successfully"
        else
            echo "Wikipedia download failed" >> /efs/logs/nominatim/download_errors.log
        fi
    else
        echo "Skipping optional Wikipedia importance import"
    fi
}

download_gb_postcodes() {
    if [ "$IMPORT_GB_POSTCODES" = "true" ]; then
        echo "Downloading GB postcodes to PROJECT_DIR"
        ${SCP}:gb_postcodes.csv.gz ${PROJECT_DIR}/gb_postcodes.csv.gz >> /efs/logs/nominatim/gb_postcodes_download.log 2>&1
        
        if [ $? -eq 0 ]; then
            echo "GB postcodes downloaded successfully"
        else
            echo "GB postcodes download failed" >> /efs/logs/nominatim/download_errors.log
        fi
    else
        echo "Skipping optional GB postcode import"
    fi
}

download_us_postcodes() {
    if [ "$IMPORT_US_POSTCODES" = "true" ]; then
        echo "Downloading US postcodes to PROJECT_DIR"
        ${SCP}:us_postcodes.csv.gz ${PROJECT_DIR}/us_postcodes.csv.gz >> /efs/logs/nominatim/us_postcodes_download.log 2>&1
        
        if [ $? -eq 0 ]; then
            echo "US postcodes downloaded successfully"
        else
            echo "US postcodes download failed" >> /efs/logs/nominatim/download_errors.log
        fi
    else
        echo "Skipping optional US postcode import"
    fi
}

#takes too much time to download and is not needed for most imports
# download_tiger() {
#     if [ "$IMPORT_TIGER_ADDRESSES" = "true" ]; then
#         echo "Downloading Tiger addresses to PROJECT_DIR"
#         ${SCP}:tiger2023-nominatim-preprocessed.csv.tar.gz ${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz
#     else
#         echo "Skipping optional Tiger addresses import"
#     fi
# }

# Execute downloads
echo "Starting downloads..."
download_wikipedia
download_gb_postcodes
download_us_postcodes
# download_tiger

TIMESTAMP=$(date +%Y%m%d)
# Download OSM file
if [ "$PBF_URL" != "" ]; then
        # Download to EFS but also copy to PROJECT_DIR for Nominatim
        OSMFILE="/efs/data/planet_${TIMESTAMP}.osm.pbf"
        echo "Downloading OSM extract to EFS: $OSMFILE"
        
        # Log download progress
        echo "$(date): Starting OSM download from $PBF_URL" >> /efs/logs/nominatim/osm_download.log
        "${CURL[@]}" "$PBF_URL" -C - --create-dirs -o $OSMFILE >> /efs/logs/nominatim/osm_download.log 2>&1
        
        if [ $? -ne 0 ]; then
            echo "Failed to download OSM extract from $PBF_URL"
            echo "$(date): OSM download failed from $PBF_URL" >> /efs/logs/nominatim/download_errors.log
            exit 1
        else
            echo "$(date): OSM download completed successfully" >> /efs/logs/nominatim/osm_download.log
        fi
elif [ "$PBF_PATH" != "" ]; then
    echo "Using OSM extract from $PBF_PATH"
    OSMFILE="$PBF_PATH"
elif [ "$PBF_PATH" = "" ] && [ "$PBF_URL" = "" ]; then
    echo "No PBF_PATH or PBF_URL provided, exiting."
    exit 1
fi

echo "Setting up database users..."

# Create nominatim user if it doesn't exist
if ! PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='nominatim'" 2>>/efs/logs/nominatim/database_setup.log | grep -q 1; then
    echo "Creating nominatim user..."
    PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "CREATE USER nominatim WITH PASSWORD '$NOMINATIM_PASSWORD';" >> /efs/logs/nominatim/database_setup.log 2>&1
else
    echo "User nominatim already exists"
fi

# Grant RDS superuser role to nominatim
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "GRANT rds_superuser TO nominatim;" >> /efs/logs/nominatim/database_setup.log 2>&1

# Create www-data user if it doesn't exist
if ! PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='www-data'" 2>>/efs/logs/nominatim/database_setup.log | grep -q 1; then
    echo "Creating www-data user..."
    PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "CREATE USER \"www-data\" WITH PASSWORD '$NOMINATIM_PASSWORD';" >> /efs/logs/nominatim/database_setup.log 2>&1
else
    echo "User www-data already exists"
fi

skip_import=false
# drop database nominatim if it exists and if import_progress table doens't exists and doesn't have "completed" status
if PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='nominatim'" 2>>/efs/logs/nominatim/database_setup.log | grep -q 1; then
    if ! PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d nominatim -tAc "SELECT 1 FROM import_progress WHERE status='completed'" 2>>/efs/logs/nominatim/database_setup.log | grep -q 1; then
        echo "Dropping existing nominatim database..."
        PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "DROP DATABASE nominatim;" >> /efs/logs/nominatim/database_setup.log 2>&1
        skip_import=false
    else
        echo "Nominatim database already exists and is initialized, skipping drop."
        skip_import=true
    fi
fi

echo "Database users configured successfully."

# Final ownership fix
chown -R nominatim:nominatim ${PROJECT_DIR}
cd ${PROJECT_DIR}

# Debug permissions
echo "=== DEBUGGING PERMISSIONS ===" >> /efs/logs/nominatim/permissions_debug.log
echo "File path: $OSMFILE" >> /efs/logs/nominatim/permissions_debug.log
echo "File exists: $(test -f "$OSMFILE" && echo YES || echo NO)" >> /efs/logs/nominatim/permissions_debug.log
echo "File details:" >> /efs/logs/nominatim/permissions_debug.log
ls -la "$OSMFILE" >> /efs/logs/nominatim/permissions_debug.log 2>&1 || echo "ls failed" >> /efs/logs/nominatim/permissions_debug.log
echo "Current user: $(whoami)" >> /efs/logs/nominatim/permissions_debug.log
echo "Nominatim user UID/GID: $(id nominatim 2>/dev/null || echo 'User not found')" >> /efs/logs/nominatim/permissions_debug.log
echo "Can nominatim read: $(sudo -u nominatim test -r "$OSMFILE" && echo YES || echo NO)" >> /efs/logs/nominatim/permissions_debug.log
echo "=================================" >> /efs/logs/nominatim/permissions_debug.log

# Import with the determined OSMFILE path
if [ "${skip_import}" = false ]; then
    echo "Starting Nominatim import..."
    echo "$(date): Starting Nominatim import with $OSMFILE using $THREADS threads" >> /efs/logs/nominatim/import.log
    nominatim import --osm-file "$OSMFILE" --threads $THREADS >> /efs/logs/nominatim/import.log 2>&1
    
    if [ $? -eq 0 ]; then
        echo "$(date): Nominatim import completed successfully" >> /efs/logs/nominatim/import.log
    else
        echo "$(date): Nominatim import failed" >> /efs/logs/nominatim/import_errors.log
        exit 1
    fi
fi

#initialize replication table 
echo "Initializing replication..."
echo "$(date): Initializing replication with $THREADS threads" >> /efs/logs/nominatim/replication.log
nominatim replication --init --threads $THREADS >> /efs/logs/nominatim/replication.log 2>&1

# Create import progress table
echo "Creating import progress table..."
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d nominatim >> /efs/logs/nominatim/database_setup.log 2>&1 << EOF
CREATE TABLE IF NOT EXISTS import_progress (
    id SERIAL PRIMARY KEY,
    status VARCHAR(20) NOT NULL,
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO import_progress (status) 
    VALUES ('completed')
    ON CONFLICT DO NOTHING;
EOF

echo "Starting indexing..."
echo "$(date): Starting indexing with $THREADS threads" >> /efs/logs/nominatim/indexing.log
nominatim index --threads $THREADS >> /efs/logs/nominatim/indexing.log 2>&1

if [ $? -eq 0 ]; then
    echo "$(date): Indexing completed successfully" >> /efs/logs/nominatim/indexing.log
else
    echo "$(date): Indexing failed" >> /efs/logs/nominatim/indexing_errors.log
fi

echo "Checking database..."
nominatim admin --check-database >> /efs/logs/nominatim/database_check.log 2>&1

export NOMINATIM_QUERY_TIMEOUT=10
export NOMINATIM_REQUEST_TIMEOUT=60

echo "Running database analysis..."
echo "$(date): Starting database analysis" >> /efs/logs/nominatim/database_analysis.log
psql -d nominatim -c "ANALYZE VERBOSE" >> /efs/logs/nominatim/database_analysis.log 2>&1

echo "Cleaning up downloaded files..."
echo "$(date): Starting cleanup of downloaded files" >> /efs/logs/nominatim/cleanup.log

echo "Deleting downloaded dumps in ${PROJECT_DIR}"
rm -f ${EFS_MOUNT_POINT}/nominatim/downloads/*sql.gz >> /efs/logs/nominatim/cleanup.log 2>&1
rm -f ${EFS/nominatim/downloads/*csv.gz >> /efs/logs/nominatim/cleanup.log 2>&1
rm -f ${EFS_MOUNT_POINT}/nominatim/downloads/tiger-nominatim-preprocessed.csv.tar.gz >> /efs/logs/nominatim/cleanup.log 2>&1

rm -f ${PROJECT_DIR}/*sql.gz >> /efs/logs/nominatim/cleanup.log 2>&1
rm -f ${PROJECT_DIR}/*csv.gz >> /efs/logs/nominatim/cleanup.log 2>&1
rm -f ${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz >> /efs/logs/nominatim/cleanup.log 2>&1

echo "$(date): Cleanup completed" >> /efs/logs/nominatim/cleanup.log
echo "Init script completed successfully"