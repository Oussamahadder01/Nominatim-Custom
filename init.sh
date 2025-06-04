#!/bin/bash -ex

OSMFILE=${PROJECT_DIR}/data.osm.pbf

CURL=("curl" "-L" "-A" "${USER_AGENT}" "--fail-with-body")

URL_DOWNLOAD=https://nominatim.org/data/

# Check if THREADS is not set or is empty
if [ -z "$THREADS" ]; then
  THREADS=$(nproc)
fi

# we re-host the files on a Hetzner storage box because inconsiderate users eat up all of
# nominatim.org's bandwidth
# https://github.com/mediagis/nominatim-docker/issues/416

# https://nominatim.org/release-docs/5.1/admin/Import/#wikipediawikidata-rankings
# TODO: Should we need a new env var $IMPORT_SECONDARY_WIKIPEDIA
#  (using wget -O secondary_importance.sql.gz https://nominatim.org/data/wikimedia-secondary-importance.sql.gz)
if [ "$IMPORT_WIKIPEDIA" = "true" ]; then
  echo "Downloading Wikipedia importance dump"
  wget -O ${PROJECT_DIR}/wikimedia-importance.csv.gz ${URL_DOWNLOAD}/wikimedia-importance.csv.gz
else
  echo "Skipping optional Wikipedia importance import"
fi;

if [ "$IMPORT_GB_POSTCODES" = "true" ]; then
  wget -O ${PROJECT_DIR}/gb_postcodes.csv.gz ${URL_DOWNLOAD}/gb_postcodes.csv.gz
else \
  echo "Skipping optional GB postcode import"
fi;

if [ "$IMPORT_US_POSTCODES" = "true" ]; then
  wget -O ${PROJECT_DIR}/us_postcodes.csv.gz ${URL_DOWNLOAD}/us_postcodes.csv.gz
else
  echo "Skipping optional US postcode import"
fi;

if [ "$IMPORT_TIGER_ADDRESSES" = "true" ]; then
  wget -O ${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz ${URL_DOWNLOAD}/tiger-nominatim-preprocessed-latest.csv.tar.gz 
else
  echo "Skipping optional Tiger addresses import"
fi

if [ "$PBF_URL" != "" ]; then
  echo Downloading OSM extract from "$PBF_URL"
  "${CURL[@]}" "$PBF_URL" --create-dirs -o $OSMFILE
  if [ $? -ne 0 ]; then
    echo "Failed to download OSM extract from $PBF_URL"
    exit 1
  fi
  elif [ "$PBF_PATH" = "" ] && [ "$PBF_URL" = "" ]; then
  echo "No PBF_PATH or PBF_URL provided, exiting."
  exit 1
fi

if [ "$PBF_PATH" != "" ]; then
  echo Reading OSM extract from "$PBF_PATH"
  OSMFILE=$PBF_PATH
fi

echo "Setting up database users..."

# Create nominatim user if it doesn't exist
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='nominatim'" | grep -q 1 || \
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "CREATE USER nominatim WITH PASSWORD '$NOMINATIM_PASSWORD';"
# Grant RDS superuser role to nominatim
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "GRANT rds_superuser TO nominatim;"


# Create www-data user if it doesn't exist
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='www-data'" | grep -q 1 || \
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "CREATE USER \"www-data\" WITH PASSWORD '$NOMINATIM_PASSWORD';"

# drop table nominatim if it exists (because it throws error when importing with nominatim)
PGPASSWORD=$PGPASSWORD psql -h $PGHOST -p $PGPORT -U $PGUSER -d postgres -c "DROP DATABASE IF EXISTS nominatim;"

echo "Database users configured successfully."

chown -R nominatim:nominatim ${PROJECT_DIR}
cd ${PROJECT_DIR}

if [ "$REVERSE_ONLY" = "true" ]; then
  sudo -E -u nominatim nominatim import --osm-file $OSMFILE --threads $THREADS --reverse-only
else
  sudo -E -u nominatim nominatim import --osm-file $OSMFILE --threads $THREADS
fi

if [ -f tiger-nominatim-preprocessed.csv.tar.gz ]; then
  echo "Importing Tiger address data"
  sudo -E -u nominatim nominatim add-data --tiger-data tiger-nominatim-preprocessed.csv.tar.gz
fi

# Sometimes Nominatim marks parent places to be indexed during the initial
# import which leads to '123 entries are not yet indexed' errors in --check-database
# Thus another quick additional index here for the remaining places
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

# gather statistics for query planner to potentially improve query performance
# see, https://github.com/osm-search/Nominatim/issues/1023
# and  https://github.com/osm-search/Nominatim/issues/1139
sudo -E -u nominatim psql -d nominatim -c "ANALYZE VERBOSE"


echo "Deleting downloaded dumps in ${PROJECT_DIR}"
rm -f ${PROJECT_DIR}/*sql.gz
rm -f ${PROJECT_DIR}/*csv.gz
rm -f ${PROJECT_DIR}/tiger-nominatim-preprocessed.csv.tar.gz
