ARG NOMINATIM_VERSION=5.1.0
ARG USER_AGENT=mediagis/nominatim-docker:${NOMINATIM_VERSION}

FROM ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

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
        -y cron \
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
        wget \
        sudo \
        sshpass \
        openssh-client



ARG NOMINATIM_VERSION
ARG USER_AGENT

# Nominatim install.
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked pip install --break-system-packages \
    nominatim-db\
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
COPY updater.sh /app/updater.sh

# Make all shell scripts executable
RUN chmod +x /app/start.sh
RUN chmod +x /app/config.sh
RUN chmod +x /app/init.sh
# Collapse image to single layer.
FROM scratch

COPY --from=build / /

# Please override this
ENV NOMINATIM_PASSWORD=""
ENV PGHOST=""
ENV PGPORT=5432
ENV PGDATABASE=""
ENV PGUSER=""
ENV PGPASSWORD=""
ENV PBF_URL=https://download.geofabrik.de/europe/monaco-latest.osm.pbf
ENV REPLICATION_URL=


ENV PROJECT_DIR="/nominatim"
ARG USER_AGENT
ENV USER_AGENT=${USER_AGENT}
ENV EFS_MOUNT_POINT=""
ENV EFS_ENABLED="false"


# important to set to avoid "could not open certificate file "/root/.postgresql/postgresql.crt": Permission denied" error
ENV PGSSLCERT=/tmp/postgresql.crt 


WORKDIR /app

EXPOSE 5432
EXPOSE 8080

COPY conf.d/env $PROJECT_DIR/.env

RUN echo "* * * * * /app/updater.sh >> /var/log/nominatim-cron.log 2>&1" | crontab -


CMD ["/app/start.sh"]
