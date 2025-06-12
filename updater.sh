#!/bin/bash -ex
source /utils.sh


if source /downloader.sh; then
    info "Download completed or file was refreshed"
else
    info "Using existing OSM file, proceeding with graph build"
fi

# Configuration
BUILD_DIR="/efs/ors-build"
RUNTIME_DIR="/efs/ors-run"
HEALTH_CHECK_URL="http://localhost:8082/ors/v2/health"
MAX_HEALTH_RETRIES=5
HEALTH_RETRY_INTERVAL=10

# Lock file to prevent multiple instances
LOCK_FILE="/tmp/updater.lock"

REBUILD_GRAPHS="true"
trap cleanup INT TERM

# Check if another update is running
if [ -f "${LOCK_FILE}" ]; then
    warning "Graph update already in progress. Exiting."
    critical "exiting with error code 1"
fi

# Create lock file
echo $$ > "${LOCK_FILE}"

info "Starting scheduled graph update..."

# Create build directory
mkdir -p "${BUILD_DIR}"/{graphs,logs,config,files,elevation_cache} || {
    error "Failed to create build directory structure"
    cleanup 1
}

# Copy current config to build directory
cp -r "${RUNTIME_DIR}/config/"* "${BUILD_DIR}/config/" 2>/dev/null || true

# Rewrite the example config to use the right files in the container
yq -i e '.ors.engine.profiles.driving-car.graph_path = "/efs/ors-build/graphs"' ${BUILD_DIR}/config/ors-config.yml || critical "Failed to update driving-car graph path in config"

# Set temporary ORS_HOME for building
export TEMP_ORS_HOME="${ORS_HOME}"
export ORS_HOME="${BUILD_DIR}"

# Build graphs with forced rebuild
info "Building new graphs in ${BUILD_DIR}"


echo "#######################################"
echo "# Prepare CATALINA_OPTS and JAVA_OPTS #"
echo "#######################################"
# Let the user define every parameter via env vars if not, default to the values below
management_jmxremote_port=${MANAGEMENT_JMXREMOTE_PORT:-9002}
management_jmxremote_rmi_port=${MANAGEMENT_JMXREMOTE_RMI_PORT:-9002}
management_jmxremote_authenticate=${MANAGEMENT_JMXREMOTE_AUTHENTICATE:-false}
management_jmxremote_ssl=${MANAGEMENT_JMXREMOTE_SSL:-false}
java_rmi_server_hostname=${JAVA_RMI_SERVER_HOSTNAME:-localhost}
additional_catalina_opts=${ADDITIONAL_CATALINA_OPTS:-""}
# Let the user define every parameter via env vars if not, default to the values below
target_survivor_ratio=${TARGET_SURVIVOR_RATIO:-75}
survivor_ratio=${SURVIVOR_RATIO:-64}
max_tenuring_threshold=${MAX_TENURING_THRESHOLD:-3}
parallel_gc_threads=${PARALLEL_GC_THREADS:-4}

xms=${XMS:-1g}
xmx=${XMX:-2g}
additional_java_opts=${ADDITIONAL_JAVA_OPTS:-""}

CATALINA_OPTS="-Dcom.sun.management.jmxremote \
-Dcom.sun.management.jmxremote.port=${management_jmxremote_port} \
-Dcom.sun.management.jmxremote.rmi.port=${management_jmxremote_rmi_port} \
-Dcom.sun.management.jmxremote.authenticate=${management_jmxremote_authenticate} \
-Dcom.sun.management.jmxremote.ssl=${management_jmxremote_ssl} \
-Djava.rmi.server.hostname=${java_rmi_server_hostname} \
${additional_catalina_opts}"
debug "CATALINA_OPTS: ${CATALINA_OPTS}"

JAVA_OPTS="-Djava.awt.headless=true \
-server -XX:TargetSurvivorRatio=${target_survivor_ratio} \
-XX:SurvivorRatio=${survivor_ratio} \
-XX:MaxTenuringThreshold=${max_tenuring_threshold} \
-XX:+UseG1GC \
-XX:+ScavengeBeforeFullGC \
-XX:ParallelGCThreads=${parallel_gc_threads} \
-Xms${xms} \
-Xmx${xmx} \
${additional_java_opts}"
# Start ORS in background for graph building
export ORS_CONFIG_LOCATION="${BUILD_DIR}/config/ors-config.yml"
export REBUILD_GRAPHS="true"


nohup java ${JAVA_OPTS} ${CATALINA_OPTS} -jar /ors.jar --server.port=8083 > "${BUILD_DIR}/logs/build.log" 2>&1 &
BUILD_PID=$!

# Wait for graph building to complete by monitoring gh.lock
info "Waiting for graph building to complete..."
GRAPH_BUILD_COUNT=0
MAX_GRAPH_RETRIES=10000

while [ ${GRAPH_BUILD_COUNT} -lt ${MAX_GRAPH_RETRIES} ]; do
    # Check if gh.lock file exists (indicates building in progress)
    if [ ! -f "${BUILD_DIR}/graphs/gh.lock" ] && [ ! -f "${BUILD_DIR}/graphs/driving-car/gh.lock" ]; then
        # No lock file means building is complete
        if [ -d "${BUILD_DIR}/graphs/driving-car" ]; then
            success "Graph building completed (no gh.lock found)!"
            break
        fi
    fi
    
    # Check if build process is still running
    if ! kill -0 ${BUILD_PID} 2>/dev/null; then
        error "Graph build process died unexpectedly"
        cleanup 1
    fi
    
    GRAPH_BUILD_COUNT=$((GRAPH_BUILD_COUNT + 1))
    info "Graph building in progress (gh.lock exists)... (${GRAPH_BUILD_COUNT}/${MAX_GRAPH_RETRIES})"
    sleep 30  # Check every 10 seconds
done

info "Graph building complete, verifying service health..."
if wget --quiet --tries=1 --spider "http://localhost:8083/ors/v2/health" 2>/dev/null; then
    success "Service is healthy and ready!"
else
    error "Service not healthy after graph building completed"
    cleanup 1
fi

# Kill the build process
kill ${BUILD_PID} 2>/dev/null || true
wait ${BUILD_PID} 2>/dev/null || true


# Restore original ORS_HOME
export ORS_HOME="${TEMP_ORS_HOME}"


# Replace runtime graphs with new ones
info "Replacing runtime graphs with newly built ones"
cp -r "${BUILD_DIR}/graphs/"* "${RUNTIME_DIR}/graphs/" || {
    error "Failed to copy new graphs to runtime directory"
    cleanup 1
}

# Clean up build directory
rm -rf "${BUILD_DIR}/graphs"/* || {
    warning "Failed to clean up build graphs directory"
}

success "Graph update completed successfully"
cleanup 0