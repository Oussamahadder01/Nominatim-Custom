# Nominatim Production Docker Image

A production-ready Docker image for Nominatim geocoding service, customized for deployment on AWS ECS with EFS storage and RDS PostgreSQL.

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Application   │    │   Load Balancer │    │      User       │
│   Load Balancer │◄───┤      (ALB)      │◄───┤                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │
         ▼
┌─────────────────┐    ┌─────────────────┐      ┌─────────────────┐
│   ECS Cluster   │    │   EFS Storage   │      │  RDS PostgreSQL │
│                 │◄───┤   (OSM Data)    │      │   (Nominatim    │
│  ┌───────────┐  │    │                 │      │    Tables)      │
│  │Nominatim  │  │    └─────────────────┘      │                 │
│  │Container  │◄─┼─────────────────────────────┤                 │
│  └───────────┘  │                             │                 │
└─────────────────┘                             └─────────────────┘
```

## Quick Start

### 1. Prerequisites

- AWS Account with ECS, EFS, and RDS access
- Docker and Docker Compose
- AWS CLI configured

### 2. Environment Configuration

```bash
# Copy the example environment file
cp .env.example .env

# Edit the configuration
vim .env
```

Configure the following required variables:

```bash
# Database (RDS)
PGHOST=your-rds-endpoint.region.rds.amazonaws.com
PGUSER=nominatim
PGPASSWORD=your-secure-password
PGDATABASE=nominatim

# OSM Data
PBF_URL=https://download.geofabrik.de/europe/france-latest.osm.pbf
```

### 3. Local Development

```bash
# Build the image
docker-compose build

# Start the service
docker-compose up
```

### 4. Production Deployment

#### Step 1: Build and Push to ECR

```bash
# Create ECR repository
aws ecr create-repository --repository-name nominatim-production

# Get login token
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-west-2.amazonaws.com

# Build and tag
docker build -t nominatim-production .
docker tag nominatim-production:latest 123456789012.dkr.ecr.us-west-2.amazonaws.com/nominatim-production:latest

# Push
docker push 123456789012.dkr.ecr.us-west-2.amazonaws.com/nominatim-production:latest
```



## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `PGHOST` | Yes | - | PostgreSQL host (RDS endpoint) |
| `PGPORT` | No | 5432 | PostgreSQL port |
| `PGDATABASE` | Yes | - | Database name |
| `PGUSER` | Yes | - | Database user |
| `PGPASSWORD` | Yes | - | Database password |
| `PBF_URL` | Yes* | - | OSM data download URL |
| `PBF_PATH` | Yes* | - | Local OSM data file path |
| `THREADS` | No | 4 | Import/indexing threads |
| `OSM2PGSQL_CACHE` | No | 4000 | Cache size in MB |
| `IMPORT_STYLE` | No | full | Import style (full/admin/street) |
| `REVERSE_ONLY` | No | false | Reverse geocoding only |
| `REPLICATION_URL` | No | - | Updates URL |

*Either `PBF_URL` or `PBF_PATH` is required.


## Monitoring

### Health Checks

The container includes built-in health checks:

```bash
# Manual health check
curl http://localhost:8080/status
```

### Logging

Logs are structured and sent to:
- `/var/log/nominatim/nominatim.log` - Application logs
- `/var/log/nominatim/error.log` - Error logs
- CloudWatch Logs (in ECS deployment)



### Debug Commands

```bash
# Check container logs
docker logs nominatim-production

# Connect to running container
docker exec -it nominatim-production bash

# Test database connection
psql -h $PGHOST -U $PGUSER -d $PGDATABASE

# Check Nominatim status
nominatim admin --check-database
```