#!/bin/bash -ex

if ! command -v sshpass &> /dev/null; then
    echo "Installing sshpass..."
    cd /tmp
    curl -L -o sshpass-1.09.tar.gz https://sourceforge.net/projects/sshpass/files/sshpass/1.09/sshpass-1.09.tar.gz/download
    tar -xzf sshpass-1.09.tar.gz
    cd sshpass-1.09
    ./configure
    make
    make install
    cd /
    rm -rf /tmp/sshpass*
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
        ${SCP}:wikimedia-importance.csv.gz ${PROJECT_DIR}/wikimedia-importance.csv.gz
        
        echo "Wikipedia files downloaded successfully"
    else
        echo "Skipping optional Wikipedia importance import"
    fi
}

download_gb_postcodes() {
    if [ "$IMPORT_GB_POSTCODES" = "true" ]; then
        echo "Downloading GB postcodes to PROJECT_DIR"
        ${SCP}:gb_postcodes.csv.gz ${PROJECT_DIR}/gb_postcodes.csv.gz
    else
        echo "Skipping optional GB postcode import"
    fi
}

download_us_postcodes() {
    if [ "$IMPORT_US_POSTCODES" = "true" ]; then
        echo "Downloading US postcodes to PROJECT_DIR"
        ${SCP}:us_postcodes.csv.gz ${PROJECT_DIR}/us_postcodes.csv.gz
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
        "${CURL[@]}" "$PBF_URL" -C - --create-dirs -o $OSMFILE
        
        if [ $? -ne 0 ]; then
            echo "Failed to download OSM extract from $PBF_URL"
            exit 1
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
if ! PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='nominatim'" | grep -q 1; then
    echo "Creating nominatim user..."
    PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "CREATE USER nominatim WITH PASSWORD '$NOMINATIM_PASSWORD';"
else
    echo "User nominatim already exists"
fi

# Grant RDS superuser role to nominatim
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "GRANT rds_superuser TO nominatim;"

# Create www-data user if it doesn't exist
if ! PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='www-data'" | grep -q 1; then
    echo "Creating www-data user..."
    PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "CREATE USER \"www-data\" WITH PASSWORD '$NOMINATIM_PASSWORD';"
else
    echo "User www-data already exists"
fi


skip_import=false
# drop database nominatim if it exists and if import_progress table doens't exists and doesn't have "completed" status
if PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='nominatim'" | grep -q 1; then
    if ! PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d nominatim -tAc "SELECT 1 FROM import_progress WHERE status='completed'" | grep -q 1; then
        echo "Dropping existing nominatim database..."
        PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "DROP DATABASE nominatim;"
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
echo "=== DEBUGGING PERMISSIONS ==="
echo "File path: $OSMFILE"
echo "File exists: $(test -f "$OSMFILE" && echo YES || echo NO)"
echo "File details:"
ls -la "$OSMFILE" 2>/dev/null || echo "ls failed"
echo "Current user: $(whoami)"
echo "Nominatim user UID/GID: $(id nominatim 2>/dev/null || echo 'User not found')"
echo "Can nominatim read: $(sudo -u nominatim test -r "$OSMFILE" && echo YES || echo NO)"
echo "================================="

# Import with the determined OSMFILE path
if [ "${skip_import}" = false ]; then
    nominatim import --osm-file "$OSMFILE" --threads $THREADS
fi

#initialize replication table 
nominatim replication --init --threads $THREADS


PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d nominatim << EOF
CREATE TABLE IF NOT EXISTS import_progress (
    id SERIAL PRIMARY KEY,
    status VARCHAR(20) NOT NULL,
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO import_progress (status) 
    VALUES ('completed')
    ON CONFLICT DO NOTHING;
EOF



nominatim index --threads $THREADS
nominatim admin --check-database


export NOMINATIM_QUERY_TIMEOUT=10
export NOMINATIM_REQUEST_TIMEOUT=60

psql -d nominatim -c "ANALYZE VERBOSE"

echo "Deleting downloaded dumps in ${PROJECT_DIR}"
rm -f ${EFS_MOUNT_POINT}/nominatim/downloads/*sql.gz
rm -f ${EFS_MOUNT_POINT}/nominatim/downloads/*csv.gz
rm -f ${EFS_MOUNT_POINT}/nominatim/downloads/tiger-nominatim-preprocessed.csv.tar.gz

rm -f ${PROJECT_DIR}/*sql.gz
rm -f ${PROJECT_DIR}/*csv.gz
rm -f ${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz