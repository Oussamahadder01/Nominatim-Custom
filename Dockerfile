ARG NOMINATIM_VERSION=5.1.0
ARG USER_AGENT=mediagis/nominatim-docker:${NOMINATIM_VERSION}

FROM registry.access.redhat.com/ubi9/ubi:latest AS build

ENV LANG=C.UTF-8

WORKDIR /app

# Install EPEL and other required repositories
RUN dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm && \
    dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm && \
    dnf config-manager --enable codeready-builder-for-rhel-9-x86_64-rpms || \
    dnf config-manager --enable ubi-9-codeready-builder-rpms || \
    dnf config-manager --enable ubi-9-codeready-builder || \
    /usr/bin/crb enable || true

# Update and install base packages
RUN dnf -y update && \
    dnf -y install --allowerasing \
        # Build tools
        gcc \
        gcc-c++ \
        make \
        cmake \
        pkg-config \
        # Python and dependencies
        python3 \
        python3-devel \
        python3-pip \
        # Basic utilities
        curl \
        wget \
        sudo \
        openssh-clients \
        cronie \
        which \
        # Development libraries
        expat-devel \
        zlib-devel \
        bzip2-devel \
        proj-devel \
        procps-ng \
        libicu \
        libicu-devel \
    && dnf clean all

# Install PostgreSQL packages (without problematic dependencies first)
RUN dnf -y install \
        postgresql16 \
        postgresql16-server \
        postgresql16-contrib \
    && dnf clean all

# Try to install postgresql16-devel and its dependencies
RUN dnf -y install perl-IPC-Run3 || \
    dnf -y install perl-IPC-Run || \
    dnf -y install perl || true && \
    dnf -y install postgresql16-devel || true && \
    dnf clean all

# Install GDAL and PostGIS (handle missing qhull)
RUN dnf -y install gdal310 gdal310-libs || \
    dnf -y install gdal-libs gdal || true && \
    dnf -y install qhull-devel || \
    dnf -y install qhull || true && \
    dnf -y install postgis34_16 || \
    dnf -y install postgis || true && \
    dnf -y install osm2pgsql || true && \
    dnf clean all

# Try to install optional packages
RUN dnf -y install boost169-devel || dnf -y install boost-devel || true && \
    dnf -y install protobuf-c-devel || dnf -y install protobuf-devel || true && \
    dnf -y install lua-devel || dnf -y install lua53-devel || true && \
    dnf clean all

# Set up PostgreSQL paths for RHEL
ENV PATH="/usr/pgsql-16/bin:$PATH"
ENV LD_LIBRARY_PATH="/usr/pgsql-16/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

ARG NOMINATIM_VERSION
ARG USER_AGENT

# Nominatim install - using virtual environment
RUN python3 -m venv /opt/nominatim-venv && \
    source /opt/nominatim-venv/bin/activate && \
    pip install --upgrade pip && \
    pip install \
        nominatim-db \
        osmium \
        psycopg[binary] \
        falcon \
        uvicorn \
        gunicorn \
        nominatim-api

# Set up virtual environment in PATH
ENV PATH="/opt/nominatim-venv/bin:$PATH"
ENV VIRTUAL_ENV="/opt/nominatim-venv"

# Copy scripts
COPY config.sh /app/config.sh
COPY init.sh /app/init.sh
COPY start.sh /app/start.sh
COPY updater.sh /app/updater.sh

# Make all shell scripts executable
RUN chmod +x /app/*.sh

# Collapse image to single layer
FROM scratch

COPY --from=build / /


ENV PROJECT_DIR="/nominatim"
ARG USER_AGENT
ENV USER_AGENT=${USER_AGENT}

# PostgreSQL SSL certificate path to avoid errors with SSL connections
ENV PGSSLCERT=/tmp/postgresql.crt 

# Add PostgreSQL and virtual environment to PATH
ENV PATH="/usr/pgsql-16/bin:/opt/nominatim-venv/bin:$PATH"
ENV LD_LIBRARY_PATH="/usr/pgsql-16/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
ENV VIRTUAL_ENV="/opt/nominatim-venv"

WORKDIR /${PROJECT_DIR}

EXPOSE 5432
EXPOSE 8080

COPY conf.d/env $PROJECT_DIR/.env

# Set up cron job
RUN echo "* * * * * /app/updater.sh >> /efs/logs/nominatim/nominatim-cron.log 2>&1" | crontab - 

CMD ["/app/start.sh"]