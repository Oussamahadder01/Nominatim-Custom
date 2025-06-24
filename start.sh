#!/bin/bash -e

tailpid=0
replicationpid=0
GUNICORN_PID_FILE=/tmp/gunicorn.pid
# send gunicorn logs straight to the console without buffering: https://stackoverflow.com/questions/59812009
export PYTHONUNBUFFERED=1
crond || true


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


# Function to run a command as nominatim or directly depending on what works
run_as_nominatim() {
  # First try with sudo from correct directory
  if cd ${PROJECT_DIR} && sudo -E -u nominatim "$@" 2>/dev/null; then
    return 0
  else
    echo "Warning: Failed to run command as nominatim user. Trying directly from correct directory..."
    # Try running directly but from correct directory
    cd ${PROJECT_DIR} && "$@"
    return $?
  fi
}


# Function to check if Nominatim database has been initialized properly
check_database_initialized() {
  echo "Checking if database is already initialized..."
  # Connect to the database and check for key Nominatim tables
  # Return 0 (true) if already initialized, 1 (false) if not
  if ! PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d nominatim -t -c "
      SELECT EXISTS (
        SELECT 1 FROM import_progress
        WHERE status='completed'
      )" 2>/dev/null | grep -q 't'; then
    echo "Database not initialized or missing required tables."
    return 1
  else
  echo "Database already initialized with Nominatim tables."
  return 0
  fi
}


# First check if database exists and has been initialized
DB_EXISTS=$(PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname='nominatim'" 2>/dev/null | grep -c 1 || echo "0")
SKIP_IMPORT=false

if [ "$DB_EXISTS" -eq "1" ]; then
  echo "Database nominatim exists, checking if it's properly initialized..."
  check_database_initialized
  DB_INITIALIZED=$?
  if [ "$DB_INITIALIZED" -eq 0 ]; then
    echo "Database is properly initialized with Nominatim tables."
    SKIP_IMPORT=true
  else
    echo "Database exists but is not properly initialized. Will proceed with import."
  fi
else
  echo "Database doesn't exist. Will proceed with import."
  /app/config.sh
fi

# Only run the init.sh script if we're not skipping the import
if [ "$SKIP_IMPORT" = "false" ]; then
    echo "Running full import with init.sh..."
    /app/init.sh
  else
    echo "Will skip import but this may cause issues. Consider removing ${IMPORT_FINISHED} to force reimport."
    chown -R nominatim:nominatim ${PROJECT_DIR} 2>/dev/null || true
  fi

# Ensure tokenizer setup regardless of prior steps
echo "Ensuring tokenizer is properly set up..."
mkdir -p ${PROJECT_DIR}/tokenizer
chown -R nominatim:nominatim ${PROJECT_DIR}/tokenizer 2>/dev/null || true

cd ${PROJECT_DIR}
nominatim refresh --word-tokens || echo "Word token refresh failed, but continuing"
nominatim refresh --word-counts || echo "Word count refresh failed, but continuing"

# Refresh functions
cd ${PROJECT_DIR} && nominatim refresh --functions || echo "Function refresh failed, but continuing"

# start continous replication process
if [ "$REPLICATION_URL" != "" ] && [ "$FREEZE" != "true" ]; then
  # run init in case replication settings changed
  sudo -E -u nominatim nominatim replication --project-dir ${PROJECT_DIR} --init
  if [ "$UPDATE_MODE" == "continuous" ]; then
    echo "starting continuous replication"
    sudo -E -u nominatim nominatim replication --project-dir ${PROJECT_DIR} &> /var/log/replication.log &
    replicationpid=${!}
  elif [ "$UPDATE_MODE" == "once" ]; then
    echo "starting replication once"
    sudo -E -u nominatim nominatim replication --project-dir ${PROJECT_DIR} --once &> /var/log/replication.log &
    replicationpid=${!}
  elif [ "$UPDATE_MODE" == "catch-up" ]; then
    echo "starting replication once in catch-up mode"
    sudo -E -u nominatim nominatim replication --project-dir ${PROJECT_DIR} --catch-up &> /var/log/replication.log &
    replicationpid=${!}
  else
    echo "skipping replication"
  fi
fi

# Start a tail process to keep the container running
tail -f /dev/null &
tailpid=${!}

# Warm the database caches
export NOMINATIM_QUERY_TIMEOUT=10
export NOMINATIM_REQUEST_TIMEOUT=60
if [ "$REVERSE_ONLY" = "true" ]; then
  echo "Warm database caches for reverse queries"
  nominatim admin --warm --reverse-only > /dev/null || echo "Warming failed but continuing"
else
  echo "Warm database caches for search and reverse queries"
  nominatim admin --warm --search-only > /dev/null || echo "Warming failed but continuing"
fi

echo "Warming finished"

echo "--> Nominatim is ready to accept requests"

# Start the Nominatim API server
cd "$PROJECT_DIR"
gunicorn \
  --bind :8080 \
  --pid $GUNICORN_PID_FILE \
  --daemon \
  --workers 4 \
  --enable-stdio-inheritance \
  --worker-class uvicorn.workers.UvicornWorker \
  nominatim_api.server.falcon.server:run_wsgi

# Keep the container running

wait $tailpid || true