ARG NOMINATIM_VERSION=5.1.0
ARG USER_AGENT=nominatim-production:${NOMINATIM_VERSION}

FROM ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

WORKDIR /app

# Inspired by https://github.com/reproducible-containers/buildkit-cache-dance?tab=readme-ov-file#apt-get-github-actions
RUN  \
    --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    # Keep downloaded APT packages in the docker build cache
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' >/etc/apt/apt.conf.d/keep-cache && \
    # Do not start daemons after installation.
    echo '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d \
    # Install all required packages.
    && apt-get -y update -qq \
    && apt-get -y install \
        locales \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8 \
    && apt-get -y install \
        -o APT::Install-Recommends="false" \
        -o APT::Install-Suggests="false" \
        # Build tools from sources. \
        build-essential \
        osm2pgsql \
        pkg-config \
        libicu-dev \
        python3-dev \
        python3-pip \
        python3-icu \
        # PostgreSQL.
        postgresql-postgis \
        postgresql-postgis-scripts \
        # Misc.
        curl \
        sudo \
        sshpass \
        openssh-client



ARG NOMINATIM_VERSION
ARG USER_AGENT

# Nominatim install.
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked pip install --break-system-packages \
    nominatim-db==$NOMINATIM_VERSION \
    osmium \
    psycopg[binary] \
    falcon \
    uvicorn \
    gunicorn \
    nominatim-api


# remove build-only packages
RUN true \
    # Remove development and unused packages.
    && apt-get -y remove --purge --auto-remove \
        build-essential \
    # Clear temporary files and directories.
    && rm -rf \
        /tmp/* \
        /var/tmp/* \
    && pip cache purge


COPY config.sh /app/config.sh
COPY init.sh /app/init.sh
COPY start.sh /app/start.sh

# Make all shell scripts executable
RUN chmod +x /app/start.sh
RUN chmod +x /app/config.sh
RUN chmod +x /app/init.sh
# Production runtime stage
FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Install only runtime dependencies
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    postgresql-client \
    python3 \
    python3-pip \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Copy built application from build stage
COPY --from=build /usr/local /usr/local
COPY --from=build /app /app

# Create non-root user for security
RUN groupadd -r nominatim && useradd -r -g nominatim -d /nominatim -s /bin/bash nominatim

# Environment variables (remove hardcoded credentials)
ENV PROJECT_DIR=/nominatim
ENV EFS_DIR=/efs
ENV THREADS=4
ENV NOMINATIM_API_POOL_SIZE=10
ENV NOMINATIM_QUERY_TIMEOUT=60
ENV NOMINATIM_REQUEST_TIMEOUT=60

# Database connection (to be overridden by ECS task definition)
ENV PGHOST=
ENV PGPORT=5432
ENV PGDATABASE=nominatim
ENV PGUSER=nominatim
ENV PGPASSWORD=
ENV NOMINATIM_PASSWORD=

# OSM Data configuration
ENV PBF_URL=
ENV PBF_PATH=
ENV REPLICATION_URL=
ENV IMPORT_STYLE=full
ENV REVERSE_ONLY=false
ENV KEEP_PBF=true

# Performance tuning for production
ENV NOMINATIM_OSMI_IMPORT_OPTIONS="--slim --drop --hstore-all --cache 4000 --number-processes 4"
ENV OSM2PGSQL_CACHE=4000
ARG USER_AGENT
ENV USER_AGENT=${USER_AGENT}
ENV PGSSLCERT /tmp/postgresql.crt

# Create necessary directories
RUN mkdir -p ${PROJECT_DIR} ${EFS_DIR} /var/log/nominatim \
    && chown -R nominatim:nominatim ${PROJECT_DIR} ${EFS_DIR} /var/log/nominatim

# Copy configuration files
COPY conf.d/env ${PROJECT_DIR}/.env

WORKDIR ${PROJECT_DIR}

# Health check for ECS
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/status || exit 1

EXPOSE 8080

# Use non-root user
USER nominatim

CMD ["/app/start.sh"]
