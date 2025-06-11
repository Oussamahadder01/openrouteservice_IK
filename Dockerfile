# Image is reused in the workflow builds for master and the latest version
FROM docker.io/maven:3.9.9-amazoncorretto-21-alpine AS build
ARG DEBIAN_FRONTEND=noninteractive

# hadolint ignore=DL3002
USER root

WORKDIR /tmp/ors

COPY ors-api/pom.xml /tmp/ors/ors-api/pom.xml
COPY ors-engine/pom.xml /tmp/ors/ors-engine/pom.xml
COPY pom.xml /tmp/ors/pom.xml
COPY mvnw /tmp/ors/mvnw
COPY .mvn /tmp/ors/.mvn

# Build the project
RUN ./mvnw -pl 'ors-api,ors-engine' -q dependency:go-offline

COPY ors-api /tmp/ors/ors-api
COPY ors-engine /tmp/ors/ors-engine

# Build the project
RUN ./mvnw -pl 'ors-api,ors-engine' \
    -q clean package -DskipTests -Dmaven.test.skip=true

FROM docker.io/golang:1.24.2-alpine3.21 AS build-go
# Setup the target system with the right user and folders.
RUN GO111MODULE=on go install github.com/mikefarah/yq/v4@v4.45.1

# build final image, just copying stuff inside
FROM ubuntu:22.04 AS publish

# Build ARGS
ARG UID=1000
ARG GID=1000
ARG ORS_HOME=/efs/ors-run
ARG DEBIAN_FRONTEND=noninteractive

# Set the default language
ENV LANG='en_US.UTF-8' LANGUAGE='en_US:en' LC_ALL='en_US.UTF-8'

# Setup the target system with the right user and folders.
RUN apt-get update && apt-get install -y \
    bash \
    jq \
    cron \
    openssl \
    wget \
    osmium-tool \
    openjdk-21-jre-headless \
    util-linux \
    && rm -rf /var/lib/apt/lists/* && \
    # Create group and user
    groupadd -g ${GID} ors && \
    mkdir -p ${ORS_HOME}/logs ${ORS_HOME}/files ${ORS_HOME}/graphs ${ORS_HOME}/elevation_cache && \
    useradd -d ${ORS_HOME} -u ${UID} -g ors -s /bin/bash ors && \
    chown ors:ors ${ORS_HOME} && \
    chmod -R 777 ${ORS_HOME}


# Copy over the needed bits and pieces from the other stages.
COPY --chown=ors:ors --from=build /tmp/ors/ors-api/target/ors.jar /ors.jar
COPY --chown=ors:ors ./entrypoint.sh /entrypoint.sh
COPY --chown=ors:ors ./downloader.sh /downloader.sh
COPY --chown=ors:ors ./utils.sh /utils.sh
COPY --chown=ors:ors --from=build-go /go/bin/yq /bin/yq
COPY --chown=ors:ors ./ors-config.yml /ors-config.yml
COPY --chown=ors:ors ./polygon/polygon_fr_esp.geojson /polygon_fr_esp.geojson
COPY --chown=ors:ors ./updater.sh /updater.sh

# Set the ARG to an ENV. Else it will be lost.
ENV ORS_HOME=${ORS_HOME}
#Set default environment variables
ENV OSM_DATA_DIR=/efs/osm 
ENV OSM_FILE=${OSM_DATA_DIR}/europe-latest.osm.pbf
ENV OSM_IK_FILE=${OSM_DATA_DIR}/data_IK.osm.pbf
ENV BUILD_GRAPHS="False"
ENV REBUILD_GRAPHS="False"

WORKDIR ${ORS_HOME}

# Healthcheck
HEALTHCHECK --interval=3s --timeout=2s CMD ["sh", "-c", "wget --quiet --tries=1 --spider http://localhost:8082/ors/v2/health || exit 1"]

# Start the container
ENTRYPOINT ["/entrypoint.sh"]
