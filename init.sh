#!/bin/bash -e

# Production initialization script for Nominatim
# Optimized for AWS ECS deployment with EFS and RDS

# Logging functions (reuse from start.sh)
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INIT: $1" | tee -a "/var/log/nominatim/nominatim.log"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INIT ERROR: $1" | tee -a "/var/log/nominatim/error.log" >&2
}

# Set OSM file location in EFS
OSMFILE=${EFS_DIR}/data/osm-data.pbf

# Download configuration
CURL=("curl" "-L" "-A" "${USER_AGENT}" "--fail-with-body" "--retry" "3" "--retry-delay" "5")

# Create data directory in EFS
mkdir -p "${EFS_DIR}/data"

log "Starting Nominatim initialization process..."
log "OSM file will be stored at: $OSMFILE"

# Configure threading based on available resources
if [ -z "$THREADS" ]; then
  THREADS=$(nproc)
  # Cap threads for stability in containerized environment
  if [ "$THREADS" -gt 8 ]; then
    THREADS=8
  fi
fi

log "Using $THREADS threads for import process"

# Optional data imports (Wikipedia, postcodes, etc.)
# These are optional for production and can be skipped to reduce import time

if [ "$IMPORT_WIKIPEDIA" = "true" ]; then
  log "Downloading Wikipedia importance dump..."
  if "${CURL[@]}" "https://nominatim.org/data/wikimedia-importance.csv.gz" -o "${PROJECT_DIR}/wikimedia-importance.csv.gz"; then
    log "Wikipedia importance data downloaded successfully"
  else
    log_error "Failed to download Wikipedia importance data. Continuing without it."
  fi
elif [ -f "$IMPORT_WIKIPEDIA" ]; then
  log "Using local Wikipedia importance file: $IMPORT_WIKIPEDIA"
  ln -s "$IMPORT_WIKIPEDIA" "${PROJECT_DIR}/wikimedia-importance.csv.gz"
else
  log "Skipping optional Wikipedia importance import"
fi

if [ "$IMPORT_GB_POSTCODES" = "true" ]; then
  log "Downloading GB postcodes..."
  if "${CURL[@]}" "https://nominatim.org/data/gb_postcodes.csv.gz" -o "${PROJECT_DIR}/gb_postcodes.csv.gz"; then
    log "GB postcodes downloaded successfully"
  else
    log_error "Failed to download GB postcodes. Continuing without them."
  fi
elif [ -f "$IMPORT_GB_POSTCODES" ]; then
  log "Using local GB postcodes file: $IMPORT_GB_POSTCODES"
  ln -s "$IMPORT_GB_POSTCODES" "${PROJECT_DIR}/gb_postcodes.csv.gz"
else
  log "Skipping optional GB postcode import"
fi

if [ "$IMPORT_US_POSTCODES" = "true" ]; then
  log "Downloading US postcodes..."
  if "${CURL[@]}" "https://nominatim.org/data/us_postcodes.csv.gz" -o "${PROJECT_DIR}/us_postcodes.csv.gz"; then
    log "US postcodes downloaded successfully"
  else
    log_error "Failed to download US postcodes. Continuing without them."
  fi
elif [ -f "$IMPORT_US_POSTCODES" ]; then
  log "Using local US postcodes file: $IMPORT_US_POSTCODES"
  ln -s "$IMPORT_US_POSTCODES" "${PROJECT_DIR}/us_postcodes.csv.gz"
else
  log "Skipping optional US postcode import"
fi

if [ "$IMPORT_TIGER_ADDRESSES" = "true" ]; then
  log "Downloading TIGER address data..."
  if "${CURL[@]}" "https://nominatim.org/data/tiger2023-nominatim-preprocessed.csv.tar.gz" -o "${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz"; then
    log "TIGER address data downloaded successfully"
  else
    log_error "Failed to download TIGER address data. Continuing without it."
  fi
elif [ -f "$IMPORT_TIGER_ADDRESSES" ]; then
  log "Using local TIGER addresses file: $IMPORT_TIGER_ADDRESSES"
  ln -s "$IMPORT_TIGER_ADDRESSES" "${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz"
else
  log "Skipping optional Tiger addresses import"
fi

# Handle OSM data source
if [ "$PBF_URL" != "" ]; then
  log "Downloading OSM extract from: $PBF_URL"
  
  # Check if file already exists and is valid
  if [ -f "$OSMFILE" ] && [ "$KEEP_PBF" = "true" ]; then
    log "OSM file already exists at $OSMFILE. Checking if it's valid..."
    if file "$OSMFILE" | grep -q "data"; then
      log "Existing OSM file appears valid. Skipping download."
    else
      log "Existing OSM file appears corrupted. Re-downloading..."
      rm -f "$OSMFILE"
    fi
  fi
  
  # Download if file doesn't exist or was removed
  if [ ! -f "$OSMFILE" ]; then
    log "Starting download of OSM data..."
    if "${CURL[@]}" "$PBF_URL" --create-dirs -o "$OSMFILE"; then
      log "OSM data downloaded successfully to $OSMFILE"
      log "File size: $(du -h "$OSMFILE" | cut -f1)"
    else
      log_error "Failed to download OSM data from $PBF_URL"
      exit 1
    fi
  fi
elif [ "$PBF_PATH" != "" ]; then
  log "Using OSM extract from local path: $PBF_PATH"
  if [ ! -f "$PBF_PATH" ]; then
    log_error "Specified PBF file does not exist: $PBF_PATH"
    exit 1
  fi
  OSMFILE="$PBF_PATH"
else
  log_error "No OSM data source specified. Set either PBF_URL or PBF_PATH environment variable."
  exit 1
fi



# Database preparation for production
log "Preparing database for Nominatim import..."

# Test database connectivity
if ! PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "SELECT 1" >/dev/null 2>&1; then
  log_error "Cannot connect to PostgreSQL database. Check connection parameters."
  exit 1
fi

log "Database connection successful"

# Check if database exists
DB_EXISTS=$(PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$PGDATABASE'" 2>/dev/null || echo "0")

if [ "$DB_EXISTS" = "1" ]; then
  log "Database $PGDATABASE already exists. Dropping and recreating for fresh import..."
  PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "DROP DATABASE IF EXISTS $PGDATABASE"
fi

log "Creating database $PGDATABASE..."
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "CREATE DATABASE $PGDATABASE OWNER $PGUSER"

# Enable required extensions
log "Enabling PostGIS and other required extensions..."
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -c "CREATE EXTENSION IF NOT EXISTS postgis"
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -c "CREATE EXTENSION IF NOT EXISTS hstore"

log "Database preparation completed"


# Set proper ownership and permissions
chown -R nominatim:nominatim ${PROJECT_DIR}
chown -R nominatim:nominatim ${EFS_DIR}/data

cd ${PROJECT_DIR}

# Start the import process
log "Starting Nominatim import process..."
log "OSM file: $OSMFILE"
log "Threads: $THREADS"
log "Reverse only: ${REVERSE_ONLY:-false}"

# Import with proper error handling
if [ "$REVERSE_ONLY" = "true" ]; then
  log "Starting reverse-only import..."
  if sudo -E -u nominatim nominatim import --osm-file "$OSMFILE" --threads $THREADS --reverse-only; then
    log "Reverse-only import completed successfully"
  else
    log_error "Reverse-only import failed"
    exit 1
  fi
else
  log "Starting full import..."
  if sudo -E -u nominatim nominatim import --osm-file "$OSMFILE" --threads $THREADS; then
    log "Full import completed successfully"
  else
    log_error "Full import failed"
    exit 1
  fi
fi

# Import additional data if available
if [ -f tiger-nominatim-preprocessed.csv.tar.gz ]; then
  log "Importing TIGER address data..."
  if sudo -E -u nominatim nominatim add-data --tiger-data tiger-nominatim-preprocessed.csv.tar.gz; then
    log "TIGER address data imported successfully"
  else
    log_error "Failed to import TIGER address data"
  fi
fi

# Post-import indexing
log "Running post-import indexing..."
if sudo -E -u nominatim nominatim index --threads $THREADS; then
  log "Post-import indexing completed successfully"
else
  log_error "Post-import indexing failed"
  exit 1
fi

# Database integrity check
log "Performing database integrity check..."
if sudo -E -u nominatim nominatim admin --check-database; then
  log "Database integrity check passed"
else
  log "Database integrity check found issues, but continuing (may be non-critical)"
fi

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

export NOMINATIM_QUERY_TIMEOUT=600
export NOMINATIM_REQUEST_TIMEOUT=3600
export NOMINATIM_QUERY_TIMEOUT=10
export NOMINATIM_REQUEST_TIMEOUT=60

# gather statistics for query planner to potentially improve query performance
# see, https://github.com/osm-search/Nominatim/issues/1023
# and  https://github.com/osm-search/Nominatim/issues/1139
sudo -E -u nominatim psql -d nominatim -c "ANALYZE VERBOSE"


echo "Deleting downloaded dumps in ${PROJECT_DIR}"
rm -f ${PROJECT_DIR}/*sql.gz
rm -f ${PROJECT_DIR}/*csv.gz
rm -f ${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz
