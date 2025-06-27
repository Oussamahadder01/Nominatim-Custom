ARG NOMINATIM_VERSION=5.1.0
ARG USER_AGENT=mediagis/nominatim-docker:${NOMINATIM_VERSION}

# Build stage
FROM registry.access.redhat.com/ubi9/ubi:latest AS build

ENV LANG=C.UTF-8
WORKDIR /app

# Install repositories and base build dependencies
RUN dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm && \
    dnf config-manager --enable ubi-9-codeready-builder-rpms || \
    /usr/bin/crb enable || true && \
    dnf -y update && \
    dnf -y install --allowerasing \
        # Build essentials
        gcc gcc-c++ make cmake pkg-config openssh-clients  \
        # Python
        python3 python3-devel python3-pip postgresql \
        # Required libraries for building
        expat-devel zlib-devel bzip2-devel proj-devel \
        libicu-devel \
    && dnf clean all





# Set up PostgreSQL paths
ENV PATH="/usr/pgsql-16/bin:$PATH"
ENV LD_LIBRARY_PATH="/usr/pgsql-16/lib"

# Install Python packages in virtual environment
RUN python3 -m venv /opt/nominatim-venv && \
    source /opt/nominatim-venv/bin/activate && \
    pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir \
        nominatim-db \
        osmium \
        psycopg[binary] \
        falcon \
        uvicorn \
        gunicorn \
        nominatim-api

# Copy scripts
COPY config.sh init.sh start.sh updater.sh /app/
RUN chmod +x /app/*.sh

# Runtime stage
FROM registry.access.redhat.com/ubi9/ubi:latest

ENV LANG=C.UTF-8

# Install only runtime dependencies
RUN dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm && \
    dnf -y update && \
    dnf -y install --allowerasing \
        # Runtime essentials
        python3 \
        curl \
        sudo \
        cronie \
        which \
        # PostgreSQL client tools only
        postgresql16 \
        postgresql16-contrib \
        openssh-clients \
        # Required runtime libraries
        expat zlib bzip2 proj libicu \
        # For sshpass compilation in init.sh
        make gcc \
    && dnf clean all && \
    rm -rf /var/cache/dnf/*

# Try to install PostGIS and osm2pgsql (handle potential missing dependencies)
RUN dnf -y install postgis34_16 || dnf -y install postgis || true && \
    dnf -y install osm2pgsql || true && \
    dnf clean all && \
    rm -rf /var/cache/dnf/*

# Copy Python virtual environment
COPY --from=build /opt/nominatim-venv /opt/nominatim-venv

# Copy scripts
COPY --from=build /app/*.sh /app/

# Set up PostgreSQL paths
ENV PATH="/usr/pgsql-16/bin:/opt/nominatim-venv/bin:$PATH"
ENV LD_LIBRARY_PATH="/usr/pgsql-16/lib"
ENV VIRTUAL_ENV="/opt/nominatim-venv"

# Create nominatim user and directories
RUN useradd -m -s /bin/bash nominatim && \
    mkdir -p /nominatim && \
    chown nominatim:nominatim /nominatim

# Environment variables
ENV PBF_URL=https://download.geofabrik.de/europe/monaco-latest.osm.pbf
ENV PROJECT_DIR="/nominatim"
ARG USER_AGENT
ENV USER_AGENT=${USER_AGENT}
ENV PGSSLCERT=/tmp/postgresql.crt

WORKDIR ${PROJECT_DIR}

EXPOSE 8080

COPY conf.d/env $PROJECT_DIR/.env

# Set up cron job
RUN echo "* * * * * /app/updater.sh >> /var/log/nominatim-cron.log 2>&1" | crontab -u nominatim -

CMD ["/app/start.sh"]