# Nominatim Production Docker Image

A production-ready Docker image for Nominatim geocoding service, optimized for deployment on AWS ECS with EFS storage and RDS PostgreSQL.

## Features

- **Production-optimized**: Multi-stage Docker build with security hardening
- **AWS ECS ready**: Designed for Fargate deployment with proper health checks
- **EFS integration**: Persistent storage for OSM data files
- **RDS PostgreSQL**: External database support with connection pooling
- **Auto-scaling friendly**: Stateless design with shared storage
- **Comprehensive logging**: Structured logging for production monitoring
- **Security hardened**: Non-root user, minimal attack surface

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Application   │    │   Load Balancer │    │      Users      │
│   Load Balancer │◄───┤      (ALB)      │◄───┤                 │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │
         ▼
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   ECS Cluster   │    │   EFS Storage   │    │  RDS PostgreSQL │
│                 │◄───┤   (OSM Data)    │    │   (Nominatim    │
│  ┌───────────┐  │    │                 │    │    Tables)      │
│  │Nominatim  │  │    └─────────────────┘    │                 │
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

#### Step 2: Set up AWS Infrastructure

1. **Create RDS PostgreSQL Instance**
   - Engine: PostgreSQL 15+
   - Instance class: db.r6g.xlarge or larger
   - Storage: GP3 SSD, 100GB minimum
   - Enable automated backups
   - Configure security groups

2. **Create EFS File System**
   - Performance mode: General Purpose
   - Throughput mode: Provisioned (adjust based on needs)
   - Enable encryption at rest
   - Create access points for ECS

3. **Configure ECS Cluster**
   - Use Fargate for serverless deployment
   - Configure VPC with private subnets
   - Set up Application Load Balancer

#### Step 3: Deploy ECS Service

```bash
# Update the task definition with your values
vim ecs-task-definition.json

# Register task definition
aws ecs register-task-definition --cli-input-json file://ecs-task-definition.json

# Create ECS service
aws ecs create-service \
  --cluster your-cluster-name \
  --service-name nominatim-production \
  --task-definition nominatim-production:1 \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-12345,subnet-67890],securityGroups=[sg-abcdef],assignPublicIp=DISABLED}"
```

## Table of contents

  - [Configuration](#configuration)
    - [Environment Variables](#environment-variables)
    - [Performance Tuning](#performance-tuning)
  - [Monitoring](#monitoring)
    - [Health Checks](#health-checks)
    - [Logging](#logging)
    - [Metrics](#metrics)
  - [Security](#security)
    - [Best Practices](#best-practices)
    - [Network Security](#network-security)
  - [Troubleshooting](#troubleshooting)
    - [Common Issues](#common-issues)
    - [Debug Commands](#debug-commands)
  - [Scaling](#scaling)
    - [Horizontal Scaling](#horizontal-scaling)
    - [Vertical Scaling](#vertical-scaling)
  - [Backup and Recovery](#backup-and-recovery)
    - [Database Backup](#database-backup)
    - [EFS Backup](#efs-backup)
  - [Cost Optimization](#cost-optimization)

---

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

### Performance Tuning

#### Memory Allocation
- **4GB RAM**: Basic setup, small regions
- **8GB RAM**: Recommended for country-level imports
- **16GB+ RAM**: Large countries or multiple countries

#### CPU Allocation
- **2 vCPU**: Minimum for production
- **4 vCPU**: Recommended for good performance
- **8+ vCPU**: High-traffic deployments

#### Database Sizing
- **Small region** (city): 1-5GB
- **Country** (France): 20-50GB
- **Large country** (Germany): 50-100GB
- **Planet**: 500GB+


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

### Metrics

Monitor these key metrics:
- Response time (target: <100ms for simple queries)
- Error rate (target: <1%)
- Memory usage
- Database connections
- EFS throughput

## Security

### Best Practices

1. **Use AWS Secrets Manager** for database passwords
2. **Enable VPC Flow Logs** for network monitoring
3. **Use IAM roles** instead of access keys
4. **Enable EFS encryption** at rest and in transit
5. **Configure security groups** with minimal required access
6. **Regular security updates** of base images

### Network Security

```
Internet Gateway
       │
   ┌───▼───┐
   │  ALB  │ (Public Subnet)
   └───┬───┘
       │
   ┌───▼───┐
   │  ECS  │ (Private Subnet)
   └───┬───┘
       │
   ┌───▼───┐
   │  RDS  │ (Private Subnet)
   └───────┘
```

## Troubleshooting

### Common Issues

1. **Import fails with memory error**
   - Increase container memory
   - Reduce `OSM2PGSQL_CACHE` value
   - Use smaller OSM extract

2. **Database connection timeout**
   - Check security groups
   - Verify RDS endpoint
   - Check VPC routing

3. **EFS mount fails**
   - Verify EFS security groups
   - Check ECS task role permissions
   - Ensure EFS is in same VPC

4. **Slow query performance**
   - Check database indexes
   - Increase RDS instance size
   - Optimize query parameters

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

## Scaling

### Horizontal Scaling

- Multiple ECS tasks can run simultaneously
- Shared EFS storage ensures consistency
- Load balancer distributes traffic
- Database handles concurrent connections

### Vertical Scaling

- Increase ECS task CPU/memory
- Scale RDS instance size
- Increase EFS throughput

## Backup and Recovery

### Database Backup

```bash
# Automated RDS snapshots (recommended)
# Manual backup
pg_dump -h $PGHOST -U $PGUSER $PGDATABASE > nominatim_backup.sql
```

### EFS Backup

- Enable AWS Backup for EFS
- OSM data can be re-downloaded if needed
- Keep PBF files for faster recovery

## Cost Optimization

1. **Use Spot instances** for non-critical workloads
2. **Schedule scaling** based on usage patterns
3. **Optimize EFS storage class** (IA for infrequent access)
4. **Right-size RDS instances** based on actual usage
5. **Use reserved instances** for predictable workloads

