#!/bin/bash -ex

tailpid=0
replicationpid=0
GUNICORN_PID_FILE=/tmp/gunicorn.pid
# send gunicorn logs straight to the console without buffering: https://stackoverflow.com/questions/59812009
export PYTHONUNBUFFERED=1


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

# Create nominatim user if it doesn't exist
if id nominatim >/dev/null 2>&1; then
  echo "user nominatim already exists"
else
  useradd -m -p ${NOMINATIM_PASSWORD} nominatim
fi

# Create tokenizer directories and set permissions
mkdir -p /nominatim/tokenizer
mkdir -p ${PROJECT_DIR}/tokenizer
chown -R nominatim:nominatim /nominatim/tokenizer 2>/dev/null || true
chown -R nominatim:nominatim ${PROJECT_DIR}/tokenizer 2>/dev/null || true

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

# Function to check if Nominatim database has been initialized properly
check_database_initialized() {
  echo "Checking if database is already initialized..."
  
  # Connect to the database and check for key Nominatim tables
  # Return 0 (true) if already initialized, 1 (false) if not
  if ! PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -t -c "
  SELECT EXISTS (
    SELECT FROM pg_tables 
    WHERE schemaname='public' 
    AND tablename IN ('placex', 'place', 'search_name', 'word')
  )" 2>/dev/null | grep -q 't'; then
    echo "Database not initialized or missing required tables."
    return 1
  fi
  
  echo "Database already initialized with Nominatim tables."
  
  # Check for presence of data
  local place_count=$(PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d $PGDATABASE -t -c "SELECT COUNT(*) FROM placex LIMIT 1" 2>/dev/null)
  echo "Database contains approximately $place_count entries in placex table."
  
  # Check database for integrity - but don't fail just on Wikipedia warnings
  echo "Checking database integrity..."
  local db_check_output=$(run_as_nominatim nominatim admin --check-database 2>&1)
  local db_check_status=$?
  
  echo "$db_check_output"
  
  # Check if it's just a Wikipedia warning (which is acceptable)
  if [ $db_check_status -ne 0 ]; then
    if echo "$db_check_output" | grep -q "Wikipedia/Wikidata importance tables missing"; then
      echo "Only Wikipedia/Wikidata tables are missing. This is acceptable."
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
  echo "Database $PGDATABASE exists, checking if it's properly initialized..."
  check_database_initialized
  DB_STATUS=$?
  
  if [ $DB_STATUS -eq 0 ]; then
    echo "Skipping import as database is already properly initialized."
    SKIP_IMPORT=true
    # Make sure the import finished flag is set
    touch ${IMPORT_FINISHED}
  elif [ $DB_STATUS -eq 2 ]; then
    echo "Database exists but needs repair. Running repair operations..."
    # Run config.sh to ensure all required variables are set
    /app/config.sh || true
    
    cd ${PROJECT_DIR}
    # Setup tokenizer
    mkdir -p ${PROJECT_DIR}/tokenizer
    chown -R nominatim:nominatim ${PROJECT_DIR}/tokenizer 2>/dev/null || true
    
    # Refresh word tokens and tables
    echo "Refreshing word tokens..."
    run_as_nominatim nominatim refresh --word-tokens || true
    
    echo "Refreshing word counts..."
    run_as_nominatim nominatim refresh --word-counts || true
    
    # Refresh functions
    echo "Refreshing database functions..."
    run_as_nominatim nominatim refresh --functions || true
    
    # Address levels
    echo "Refreshing address levels..."
    run_as_nominatim nominatim refresh --address-levels || true
    
    # Index any leftover places
    echo "Indexing any remaining places..."
    run_as_nominatim nominatim index --threads ${THREADS:-$(nproc)} || true
    
    # Check database again
    echo "Checking database after repairs..."
    run_as_nominatim nominatim admin --check-database || echo "Some issues remain but continuing anyway"
    
    # Mark as finished
    touch ${IMPORT_FINISHED}
    SKIP_IMPORT=true
  else
    echo "Database exists but doesn't have Nominatim tables. Will proceed with import."
    # Run config.sh since we'll need to do an import
    /app/config.sh
  fi
else
  echo "Database doesn't exist. Will proceed with import."
  # Run config.sh since we'll need to do an import
  /app/config.sh
fi

# Only run the init.sh script if we're not skipping the import
if [ "$SKIP_IMPORT" = "false" ]; then
  if [ ! -f ${IMPORT_FINISHED} ]; then
    echo "Running full import with init.sh..."
    /app/init.sh
    touch ${IMPORT_FINISHED}
  else
    echo "Import appears to be finished based on marker file, but database checks failed."
    echo "Will skip import but this may cause issues. Consider removing ${IMPORT_FINISHED} to force reimport."
    chown -R nominatim:nominatim ${PROJECT_DIR} 2>/dev/null || true
  fi
else
  echo "Import skipped. Using existing database."
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

# Start the Nominatim API server
cd "$PROJECT_DIR"
run_as_nominatim gunicorn \
  --bind :8080 \
  --pid $GUNICORN_PID_FILE \
  --daemon \
  --workers 4 \
  --enable-stdio-inheritance \
  --worker-class uvicorn.workers.UvicornWorker \
  nominatim_api.server.falcon.server:run_wsgi

# Keep the container running
wait $tailpid || true