ARG NOMINATIM_VERSION=5.1
ARG USER_AGENT=mediagis/nominatim-docker:${NOMINATIM_VERSION}

# Use the mediagis/nominatim base image - it has everything pre-installed
FROM mediagis/nominatim:${NOMINATIM_VERSION}


LABEL maintainer="Oussama Hadder up01316315"

RUN apt-get update && \
    apt-get install -y cron && \
    rm -rf /var/lib/apt/lists/*



# Copy your custom scripts
COPY config.sh init.sh start.sh updater.sh /app/
RUN chmod +x /app/*.sh

# Set your environment variables
ENV PBF_URL=https://download.geofabrik.de/europe/monaco-latest.osm.pbf
ENV PROJECT_DIR="/nominatim"
ARG USER_AGENT
ENV USER_AGENT=${USER_AGENT}
ENV PGSSLCERT=/tmp/postgresql.crt

WORKDIR ${PROJECT_DIR}

EXPOSE 8080

# Copy your environment configuration
COPY conf.d/env $PROJECT_DIR/.env

# Set up cron job (using the existing nominatim user from base image)
RUN echo "* * * * * /app/updater.sh >> /efs/logs/nominatim/nominatim-cron.log 2>&1" | crontab -

CMD ["/app/start.sh"]