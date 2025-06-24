#!/bin/bash -x

cd /nominatim
export NOMINATIM_REPLICATION_MAX_DIFF=5000
export PGHOST=nominatimdb.c7gqmm4ayxos.eu-west-3.rds.amazonaws.com 
export NOMINATIM_PASSWORD='Oussama0909!' 
export PGUSER=postgres 
export PGDATABASE=nominatimdb 
export PGPORT=5432 
export PGPASSWORD='Oussama0909!' 
export PGSSLCERT=/tmp/postgresql.crt 
nominatim nominatim replication --catch-up --threads 15