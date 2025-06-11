#!/usr/bin/env bash
source /utils.sh
source /downloader.sh

# Configuration
BUILD_DIR="/efs/ors-build"
RUNTIME_DIR="/efs/ors-run"
HEALTH_CHECK_URL="http://localhost:8082/ors/v2/health"
MAX_HEALTH_RETRIES=5
HEALTH_RETRY_INTERVAL=10

# Lock file to prevent multiple instances
LOCK_FILE="/tmp/updater.lock"


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
yq -i e '.ors.engine.profiles.driving-car.graph_path = "/efs/ors-build/graphs/"' ${BUILD_DIR}/config/ || critical "Failed to update driving-car graph path in config"

# Set temporary ORS_HOME for building
export TEMP_ORS_HOME="${ORS_HOME}"
export ORS_HOME="${BUILD_DIR}"

# Build graphs with forced rebuild
info "Building new graphs in ${BUILD_DIR}"

# Start ORS in background for graph building
java ${JAVA_OPTS} ${CATALINA_OPTS} -jar /ors.jar --server.port=8083 > "${BUILD_DIR}/logs/build.log" 2>&1 &
BUILD_PID=$!

# Wait for build to complete and service to be healthy
info "Waiting for graph build to complete..."
HEALTH_COUNT=0
while [ ${HEALTH_COUNT} -lt ${MAX_HEALTH_RETRIES} ]; do
    if wget --quiet --tries=1 --spider "http://localhost:8083/ors/v2/health" 2>/dev/null; then
        success "New graphs built successfully and service is healthy"
        break
    fi
    
    # Check if build process is still running
    if ! kill -0 ${BUILD_PID} 2>/dev/null; then
        error "Graph build process died unexpectedly"
        cleanup 1
    fi
    
    HEALTH_COUNT=$((HEALTH_COUNT + 1))
    info "Health check ${HEALTH_COUNT}/${MAX_HEALTH_RETRIES} failed, retrying in ${HEALTH_RETRY_INTERVAL}s..."
    sleep ${HEALTH_RETRY_INTERVAL}
done

# Kill the build process
kill ${BUILD_PID} 2>/dev/null || true
wait ${BUILD_PID} 2>/dev/null || true

if [ ${HEALTH_COUNT} -ge ${MAX_HEALTH_RETRIES} ]; then
    error "Graph build failed health checks after ${MAX_HEALTH_RETRIES} attempts"
    cleanup 1
fi

# Restore original ORS_HOME
export ORS_HOME="${TEMP_ORS_HOME}"


# Replace runtime graphs with new ones
info "Replacing runtime graphs with newly built ones"
cp -r "${BUILD_DIR}/graphs/"* "${RUNTIME_DIR}/graphs/" || {
    error "Failed to copy new graphs to runtime directory"
    cleanup 1
}

# Clean up build directory
rm -rf "${BUILD_DIR}"

success "Graph update completed successfully"
cleanup 0