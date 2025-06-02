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
# Collapse image to single layer.
FROM scratch

COPY --from=build / /

# Please override this
ENV NOMINATIM_PASSWORD=Oussama0909!
ENV PGHOST=nominatimdb.c7gqmm4ayxos.eu-west-3.rds.amazonaws.com
ENV PGPORT=5432
ENV PGDATABASE=nominatimdb1
ENV PGUSER=nominatimdb
ENV PGPASSWORD=Oussama0909!
ENV NOMINATIM_DATABASE_DSN=pgsql:host=nominatimdb.c7gqmm4ayxos.eu-west-3.rds.amazonaws.com;port=5432;user=nominatimdb;password=Oussama0909!;dbname=nominatimdb1
ENV PBF_URL=https://download.geofabrik.de/europe/france/aquitaine-latest.osm.pbf
ENV REPLICATION_URL=https://download.geofabrik.de/europe/france/aquitaine-updates/


ENV PROJECT_DIR=/nominatim
ENV EFS_DIR=/mnt/efs

ARG USER_AGENT
ENV USER_AGENT=${USER_AGENT}
ENV PGSSLCERT /tmp/postgresql.crt


WORKDIR /app

EXPOSE 5432
EXPOSE 8080

COPY conf.d/env $PROJECT_DIR/.env

CMD ["/app/start.sh"]
