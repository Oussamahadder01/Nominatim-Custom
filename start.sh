#!/bin/bash -e

# Production startup script for Nominatim
# Optimized for AWS ECS deployment with EFS and RDS

tailpid=0
replicationpid=0
GUNICORN_PID_FILE=/tmp/gunicorn.pid

# Logging configuration
export PYTHONUNBUFFERED=1
LOG_FILE="/var/log/nominatim/nominatim.log"
ERROR_LOG_FILE="/var/log/nominatim/error.log"

# Create log files if they don't exist
mkdir -p /var/log/nominatim
touch "$LOG_FILE" "$ERROR_LOG_FILE"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" | tee -a "$ERROR_LOG_FILE" >&2
}


stopServices() {
  # Check if the replication process is active
  if [ $replicationpid -ne 0 ]; then
    echo "Shutting down replication process"
    kill $replicationpid
  fi
  if [ $tailpid -ne 0 ] && kill -0 $tailpid 2>/dev/null; then
    kill $tailpid
  fi
  if [ -f "$GUNICORN_PID_FILE" ]; then
    cat $GUNICORN_PID_FILE | xargs kill
  fi

  # Force exit code 0 to signal a successful shutdown to Docker
  exit 0
}
trap stopServices SIGTERM TERM INT

# Validate required environment variables
required_vars=("PGHOST" "PGPORT" "PGDATABASE" "PGUSER" "PGPASSWORD" "NOMINATIM_PASSWORD")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        log_error "Required environment variable $var is not set"
        exit 1
    fi
done

log "Starting Nominatim production container..."
log "Database: $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
log "EFS Directory: $EFS_DIR"
log "Project Directory: $PROJECT_DIR"

# Verify EFS mount is available
if [ ! -d "$EFS_DIR" ]; then
    log_error "EFS directory $EFS_DIR not found. Ensure EFS is properly mounted."
    exit 1
fi

# Test EFS write access
if ! touch "$EFS_DIR/.write_test" 2>/dev/null; then
    log_error "Cannot write to EFS directory $EFS_DIR. Check permissions."
    exit 1
fi
rm -f "$EFS_DIR/.write_test"
log "EFS mount verified and writable"

# Create necessary directories
mkdir -p ${PROJECT_DIR}/tokenizer
mkdir -p ${EFS_DIR}/data
mkdir -p /var/log/nominatim

# Set proper permissions (running as nominatim user)
chown -R nominatim:nominatim ${PROJECT_DIR} 2>/dev/null || true
chown -R nominatim:nominatim /var/log/nominatim 2>/dev/null || true

log "Directory structure created and permissions set"

# Fix the replication URL in the configuration file
if [ "$REPLICATION_URL" != "" ]; then
  echo "Setting up replication URL: $REPLICATION_URL"
  # Replace the placeholder in the .env file
  sed -i "s|NOMINATIM_REPLICATION_URL=__REPLICATION_URL__|NOMINATIM_REPLICATION_URL=$REPLICATION_URL|g" ${PROJECT_DIR}/.env
  cat ${PROJECT_DIR}/.env | grep REPLICATION_URL
else
  echo "No replication URL provided. Skipping replication setup."
  # Clear the placeholder to avoid errors
  sed -i "s|NOMINATIM_REPLICATION_URL=__REPLICATION_URL__|NOMINATIM_REPLICATION_URL=|g" ${PROJECT_DIR}/.env
fi

# Function to run a command as nominatim or directly depending on what works
run_as_nominatim() {
  # First try with sudo
  if sudo -E -u nominatim "$@" 2>/dev/null; then
    return 0
  else
    echo "Warning: Failed to run command as nominatim user. Trying directly..."
    # Try running directly
    "$@"
    return $?
  fi
}

# Enhanced database initialization check
check_database_initialized() {
  log "Checking database initialization status..."
  
  # Test database connectivity first
  if ! PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -c "SELECT 1" >/dev/null 2>&1; then
    log_error "Cannot connect to database. Check connection parameters."
    return 1
  fi
  
  # Check for key Nominatim tables
  if ! PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -t -c "
  SELECT EXISTS (
    SELECT FROM pg_tables 
    WHERE schemaname='public' 
    AND tablename IN ('placex', 'place', 'search_name', 'word')
  )" 2>/dev/null | grep -q 't'; then
    log "Database not initialized or missing required tables."
    return 1
  fi
  
  log "Database already initialized with Nominatim tables."
  
  # Check for presence of data
  local place_count=$(PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -t -c "SELECT COUNT(*) FROM placex LIMIT 1" 2>/dev/null || echo "0")
  log "Database contains approximately $place_count entries in placex table."
  
  # Check database integrity with better error handling
  log "Checking database integrity..."
  local db_check_output=$(run_as_nominatim nominatim admin --check-database 2>&1 || true)
  local db_check_status=$?
  
  log "Database check output: $db_check_output"
  
  # Accept Wikipedia warnings as non-critical
  if [ $db_check_status -ne 0 ]; then
    if echo "$db_check_output" | grep -q "Wikipedia/Wikidata importance tables missing"; then
      log "Only Wikipedia/Wikidata tables are missing. This is acceptable for production."
      return 0
    else
      echo "Database integrity check failed with status $db_check_status. May need repair."
      return 2
    fi
  else
    echo "Database integrity check passed."
    return 0
  fi
}

IMPORT_FINISHED=/var/lib/postgresql/16/main/import-finished

# First check if database exists and has been initialized
DB_EXISTS=$(PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname='$PGDATABASE'" 2>/dev/null | grep -c 1 || echo "0")

SKIP_IMPORT=false

if [ "$DB_EXISTS" -eq "1" ]; then
  log "Database $PGDATABASE exists, checking if it's properly initialized..."
  check_database_initialized
  DB_STATUS=$?
  
  if [ $DB_STATUS -eq 0 ]; then
    log "Skipping import as database is already properly initialized."
    SKIP_IMPORT=true
    # Make sure the import finished flag is set
    touch ${IMPORT_FINISHED}
  elif [ $DB_STATUS -eq 2 ]; then
    log "Database exists but needs repair. Running repair operations..."
    # Run config.sh to ensure all required variables are set
    /app/config.sh || true
    
    cd ${PROJECT_DIR}
    # Setup tokenizer
    mkdir -p ${PROJECT_DIR}/tokenizer
    chown -R nominatim:nominatim ${PROJECT_DIR}/tokenizer 2>/dev/null || true
    
    # Refresh word tokens and tables
    log "Refreshing word tokens..."
    run_as_nominatim nominatim refresh --word-tokens || true
    
    log "Refreshing word counts..."
    run_as_nominatim nominatim refresh --word-counts || true
    
    # Refresh functions
    log "Refreshing database functions..."
    run_as_nominatim nominatim refresh --functions || true
    
    # Address levels
    log "Refreshing address levels..."
    run_as_nominatim nominatim refresh --address-levels || true
    
    # Index any leftover places
    log "Indexing any remaining places..."
    run_as_nominatim nominatim index --threads ${THREADS:-$(nproc)} || true
    
    # Check database again
    log "Checking database after repairs..."
    run_as_nominatim nominatim admin --check-database || log "Some issues remain but continuing anyway"
    
    # Mark as finished
    touch ${IMPORT_FINISHED}
    SKIP_IMPORT=true
  else
    log "Database exists but doesn't have Nominatim tables. Will proceed with import."
    
    # Check if we have OSM data source configured
    if [ -z "$PBF_URL" ] && [ -z "$PBF_PATH" ]; then
      log_error "No OSM data source configured. Set PBF_URL or PBF_PATH environment variable."
      exit 1
    fi
    
    # Run config.sh since we'll need to do an import
    /app/config.sh
  fi
else
  log "Database doesn't exist. Will proceed with import."
  
  # Check if we have OSM data source configured
  if [ -z "$PBF_URL" ] && [ -z "$PBF_PATH" ]; then
    log_error "No OSM data source configured. Set PBF_URL or PBF_PATH environment variable."
    exit 1
  fi
  
  # Run config.sh since we'll need to do an import
  /app/config.sh
fi

# Only run the init.sh script if we're not skipping the import
if [ "$SKIP_IMPORT" = "false" ]; then
  if [ ! -f ${IMPORT_FINISHED} ]; then
    log "Running full import with init.sh..."
    /app/init.sh
    touch ${IMPORT_FINISHED}
    log "Database initialization completed successfully"
  else
    log "Import appears to be finished based on marker file, but database checks failed."
    log "Will skip import but this may cause issues. Consider removing ${IMPORT_FINISHED} to force reimport."
    chown -R nominatim:nominatim ${PROJECT_DIR} 2>/dev/null || true
  fi
else
  log "Import skipped. Using existing database."
  chown -R nominatim:nominatim ${PROJECT_DIR} 2>/dev/null || true
fi

# Ensure tokenizer setup regardless of prior steps
echo "Ensuring tokenizer is properly set up..."
mkdir -p ${PROJECT_DIR}/tokenizer
chown -R nominatim:nominatim ${PROJECT_DIR}/tokenizer 2>/dev/null || true

cd ${PROJECT_DIR}
run_as_nominatim nominatim refresh --word-tokens || echo "Word token refresh failed, but continuing"
run_as_nominatim nominatim refresh --word-counts || echo "Word count refresh failed, but continuing"

# Refresh functions
cd ${PROJECT_DIR} && run_as_nominatim nominatim refresh --functions || echo "Function refresh failed, but continuing"

# Start continuous replication process - but only if REPLICATION_URL is valid and not a placeholder
if [ "$REPLICATION_URL" != "" ] && [ "$REPLICATION_URL" != "__REPLICATION_URL__" ] && [ "$FREEZE" != "true" ]; then
  echo "Setting up replication with URL: $REPLICATION_URL"
  
  # Make sure the replication URL is properly set in the configuration
  sed -i "s|NOMINATIM_REPLICATION_URL=.*|NOMINATIM_REPLICATION_URL=$REPLICATION_URL|g" ${PROJECT_DIR}/.env
  
  # Try to initialize replication
  if run_as_nominatim nominatim replication --project-dir ${PROJECT_DIR} --init; then
    echo "Replication initialized successfully"
    
    if [ "$UPDATE_MODE" == "continuous" ]; then
      echo "Starting continuous replication"
      run_as_nominatim nominatim replication --project-dir ${PROJECT_DIR} &> /var/log/replication.log &
      replicationpid=${!}
    elif [ "$UPDATE_MODE" == "once" ]; then
      echo "Starting replication once"
      run_as_nominatim nominatim replication --project-dir ${PROJECT_DIR} --once &> /var/log/replication.log &
      replicationpid=${!}
    elif [ "$UPDATE_MODE" == "catch-up" ]; then
      echo "Starting replication once in catch-up mode"
      run_as_nominatim nominatim replication --project-dir ${PROJECT_DIR} --catch-up &> /var/log/replication.log &
      replicationpid=${!}
    else
      echo "Skipping replication - no valid update mode specified"
    fi
  else
    echo "Replication initialization failed. Skipping replication."
  fi
else
  echo "Skipping replication - no valid replication URL provided or freeze is enabled"
fi

# Start a tail process to keep the container running
tail -f /dev/null &
tailpid=${!}

# Warm the database caches
export NOMINATIM_QUERY_TIMEOUT=600
export NOMINATIM_REQUEST_TIMEOUT=3600
if [ "$REVERSE_ONLY" = "true" ]; then
  echo "Warm database caches for reverse queries"
  run_as_nominatim nominatim admin --warm --reverse-only > /dev/null || echo "Warming failed but continuing"
else
  echo "Warm database caches for search and reverse queries"
  run_as_nominatim nominatim admin --warm --search-only > /dev/null || echo "Warming failed but continuing"
fi
export NOMINATIM_QUERY_TIMEOUT=10
export NOMINATIM_REQUEST_TIMEOUT=60
echo "Warming finished"

echo "--> Nominatim is ready to accept requests"

# Calculate optimal worker count based on available resources
WORKER_COUNT=${NOMINATIM_API_POOL_SIZE:-$(nproc)}
if [ "$WORKER_COUNT" -gt 8 ]; then
  WORKER_COUNT=8  # Cap at 8 workers for stability
fi

log "Starting Nominatim API server on port 8080 with $WORKER_COUNT workers..."

# Start the Nominatim API server
cd "$PROJECT_DIR"
run_as_nominatim gunicorn \
  --bind 0.0.0.0:8080 \
  --workers $WORKER_COUNT \
  --worker-class uvicorn.workers.UvicornWorker \
  --timeout ${NOMINATIM_REQUEST_TIMEOUT:-60} \
  --keep-alive 5 \
  --max-requests 2000 \
  --max-requests-jitter 200 \
  --worker-connections 1000 \
  --preload \
  --pid $GUNICORN_PID_FILE \
  --access-logfile "$LOG_FILE" \
  --error-logfile "$ERROR_LOG_FILE" \
  --log-level info \
  --capture-output \
  --daemon \
  --enable-stdio-inheritance \
  nominatim_api.server.falcon.server:run_wsgi

# Health monitoring and process management
log "Nominatim API server started successfully. Beginning health monitoring..."

# Wait for server to be ready
sleep 10

# Main monitoring loop
while true; do
  # Check if gunicorn is still running
  if [ -f "$GUNICORN_PID_FILE" ]; then
    GUNICORN_PID=$(cat $GUNICORN_PID_FILE)
    if ! kill -0 $GUNICORN_PID 2>/dev/null; then
      log_error "Gunicorn process died unexpectedly. Exiting."
      exit 1
    fi
  else
    log_error "Gunicorn PID file not found. Server may have crashed."
    exit 1
  fi
  
  # Health check via HTTP endpoint
  if ! curl -f -s http://localhost:8080/status >/dev/null 2>&1; then
    log_error "Health check failed. Server not responding properly."
    # Give it one more chance before failing
    sleep 5
    if ! curl -f -s http://localhost:8080/status >/dev/null 2>&1; then
      log_error "Health check failed twice. Exiting."
      exit 1
    fi
  fi
  
  # Check replication process if running
  if [ $replicationpid -ne 0 ] && ! kill -0 $replicationpid 2>/dev/null; then
    log_error "Replication process died. This may affect data freshness."
    replicationpid=0
  fi
  
  # Log status every 5 minutes
  if [ $(($(date +%s) % 300)) -eq 0 ]; then
    log "Health check passed. Server is running normally."
  fi
  
  sleep 30
done