#!/bin/bash -ex

# Source EFS setup
source /app/efs-setup.sh

# Setup EFS if available
setup_efs || true

CURL=("curl" "-L" "-A" "${USER_AGENT}" "--fail-with-body")
SCP='sshpass -p DMg5bmLPY7npHL2Q scp -o StrictHostKeyChecking=no u355874-sub1@u355874-sub1.your-storagebox.de'


# Check if THREADS is not set or is empty
if [ -z "$THREADS" ]; then
  THREADS=$(nproc)
fi

# Create nominatim user early if it doesn't exist
if ! id nominatim >/dev/null 2>&1; then
    useradd -m nominatim
fi

# Determine storage paths and download directly where needed
if [ "$EFS_ENABLED" = "true" ]; then
    DOWNLOAD_DIR="${EFS_MOUNT_POINT}/nominatim/downloads"
    DATA_DIR="${EFS_MOUNT_POINT}/nominatim/data"
    
    # Create EFS directories
    mkdir -p "$DOWNLOAD_DIR"
    mkdir -p "$DATA_DIR"
    
    # Set ownership of EFS directories
    chown -R nominatim:nominatim "${EFS_MOUNT_POINT}/nominatim" 2>/dev/null || true
    chmod -R 755 "${EFS_MOUNT_POINT}/nominatim" 2>/dev/null || true
    
    echo "Using EFS storage"
else
    DOWNLOAD_DIR="${PROJECT_DIR}"
    DATA_DIR="${PROJECT_DIR}"
    echo "Using local storage"
fi

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

download_tiger() {
    if [ "$IMPORT_TIGER_ADDRESSES" = "true" ]; then
        echo "Downloading Tiger addresses to PROJECT_DIR"
        ${SCP}:tiger2023-nominatim-preprocessed.csv.tar.gz ${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz
    else
        echo "Skipping optional Tiger addresses import"
    fi
}

# Execute downloads
download_wikipedia
download_gb_postcodes
download_us_postcodes
download_tiger

# Download OSM file
if [ "$PBF_URL" != "" ]; then
    if [ "$EFS_ENABLED" = "true" ]; then
        # Download to EFS but also copy to PROJECT_DIR for Nominatim
        OSMFILE_EFS="$DATA_DIR/data.osm.pbf"
        OSMFILE_LOCAL="${PROJECT_DIR}/data.osm.pbf"
        
        echo "Downloading OSM extract to EFS: $OSMFILE_EFS"
        curl -L -o "$OSMFILE_EFS" "$PBF_URL"
        
        if [ $? -ne 0 ]; then
            echo "Failed to download OSM extract from $PBF_URL"
            exit 1
        fi
        
        # Copy to local PROJECT_DIR with proper permissions
        echo "Copying OSM file to PROJECT_DIR with proper permissions"
        cp "$OSMFILE_EFS" "$OSMFILE_LOCAL"
        chown nominatim:nominatim "$OSMFILE_LOCAL"
        chmod 644 "$OSMFILE_LOCAL"
        
        # Use local file for import
        OSMFILE="$OSMFILE_LOCAL"
    else
        # Direct local download
        OSMFILE="${PROJECT_DIR}/data.osm.pbf"
        echo "Downloading OSM extract to $OSMFILE"
        sudo -u nominatim curl -L -o "$OSMFILE" "$PBF_URL"
        
        if [ $? -ne 0 ]; then
            echo "Failed to download OSM extract from $PBF_URL"
            exit 1
        fi
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

# drop database nominatim if it exists
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "DROP DATABASE IF EXISTS nominatim;"

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
if [ "$REVERSE_ONLY" = "true" ]; then
    sudo -E -u nominatim nominatim import --osm-file "$OSMFILE" --threads $THREADS --reverse-only
else
    sudo -E -u nominatim nominatim import --osm-file "$OSMFILE" --threads $THREADS
fi

# Continue with the rest of your script...
if [ -f "${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz" ]; then
    echo "Importing Tiger address data"
    sudo -E -u nominatim nominatim add-data --tiger-data "${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz"
fi

sudo -E -u nominatim nominatim index --threads $THREADS
sudo -E -u nominatim nominatim admin --check-database

if [ "$REPLICATION_URL" != "" ]; then
    sudo -E -u nominatim nominatim replication --init
    if [ "$FREEZE" = "true" ]; then
        echo "Skipping freeze because REPLICATION_URL is not empty"
    fi
else
    if [ "$FREEZE" = "true" ]; then
        echo "Freezing database"
        sudo -E -u nominatim nominatim freeze
    fi
fi

export NOMINATIM_QUERY_TIMEOUT=10
export NOMINATIM_REQUEST_TIMEOUT=60

sudo -E -u nominatim psql -d nominatim -c "ANALYZE VERBOSE"

echo "Deleting downloaded dumps in ${PROJECT_DIR}"
rm -f ${PROJECT_DIR}/*sql.gz
rm -f ${PROJECT_DIR}/*csv.gz
rm -f ${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz