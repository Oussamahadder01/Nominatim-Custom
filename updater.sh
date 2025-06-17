#!/bin/bash -x

cd ${PROJECT_DIR} 
export NOMINATIM_REPLICATION_MAX_DIFF=5000
sudo -E -u nominatim nominatim replication --catch-up --threads $THREADS