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
ARG DEBIAN_FRONTEND=noninteractive


ARG RUNTIME_DIR=/efs/ors-run
ARG BUILD_DIR=/efs/ors-build
ARG LOGS_DIR=/efs/logs/ors_ik
ARG OSM_DATA_DIR=/efs/data

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
    pyosmium \
    openjdk-21-jre-headless \
    util-linux \
    && rm -rf /var/lib/apt/lists/* && \
    # Create group and user
    groupadd -g ${GID} ors && \
    mkdir -p ${RUNTIME_DIR}/graphs  && \
    mkdir -p ${BUILD_DIR} && \
    mkdir -p ${LOGS_DIR} && \
    mkdir -p ${OSM_DATA_DIR} && \
    useradd -d ${RUNTIME_DIR} -u ${UID} -g ors -s /bin/bash ors && \
    chown ors:ors ${RUNTIME_DIR} && \
    chmod -R 777 ${RUNTIME_DIR}

# Copy over the needed bits and pieces from the other stages.
COPY --chown=ors:ors --from=build /tmp/ors/ors-api/target/ors.jar /ors.jar
COPY --chown=ors:ors ./entrypoint.sh /entrypoint.sh
COPY --chown=ors:ors ./downloader.sh /downloader.sh
COPY --chown=ors:ors ./utils.sh /utils.sh
COPY --chown=ors:ors --from=build-go /go/bin/yq /bin/yq
COPY --chown=ors:ors ./ors-config.yml /ors-config.yml
COPY --chown=ors:ors ./polygon/polygon_fr_esp.poly /polygon_fr_esp.poly
COPY --chown=ors:ors ./updater.sh /updater.sh
COPY --chown=ors:ors ./extractor.sh /extractor.sh

#Set default environment variables
ENV RUNTIME_DIR=${RUNTIME_DIR}
ENV BUILD_DIR=${BUILD_DIR}
ENV LOGS_DIR=${LOGS_DIR}
ENV OSM_DATA_DIR=${OSM_DATA_DIR}
ENV OSM_FILE=${OSM_DATA_DIR}/planet_*
ENV OSM_URL=https://download.geofabrik.de/europe-latest.osm.pbf


ENV REBUILD_GRAPHS="False"

WORKDIR ${RUNTIME_DIR}

# Healthcheck
HEALTHCHECK --interval=3s --timeout=2s CMD ["sh", "-c", "wget --quiet --tries=1 --spider http://localhost:8082/ors/v2/health || exit 1"]

# Start the container
ENTRYPOINT ["/entrypoint.sh"]
