#!/bin/bash -x

source /nominatim_env.sh
cd /nominatim
nominatim replication --catch-up --threads 15