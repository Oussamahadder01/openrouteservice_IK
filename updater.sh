#!/bin/bash
source /utils.sh

# Configuration
MAX_HEALTH_RETRIES=5
HEALTH_RETRY_INTERVAL=10
export OSM_DATA_DIR="/efs/data"
export LOGS_DIR="/efs/logs/ors_ik"  
export BUILD_DIR="/efs/ors-build"
export RUNTIME_DIR="/efs/ors-run"

# Lock file to prevent multiple instances
LOCK_FILE="/tmp/updater.lock"

# Cleanup function
cleanup() {
    local exit_code=${1:-$?}  # Use passed exit code or last command's exit code
    
    # Always remove lock file first
    if [ -f "${LOCK_FILE}" ]; then
        rm -f "${LOCK_FILE}" || true
        info "Lock file removed"
    fi
    
    # Kill any running build process
    if [ -n "${BUILD_PID}" ] && kill -0 ${BUILD_PID} 2>/dev/null; then
        info "Killing build process ${BUILD_PID}"
        kill -TERM ${BUILD_PID} 2>/dev/null || true
        # Give it time to terminate gracefully
        sleep 2
        # Force kill if still running
        if kill -0 ${BUILD_PID} 2>/dev/null; then
            kill -KILL ${BUILD_PID} 2>/dev/null || true
        fi
        wait ${BUILD_PID} 2>/dev/null || true
    fi
    
    if [ ${exit_code} -eq 0 ]; then
        success "Update process completed successfully"
    else
        error "Update process failed with exit code ${exit_code}"
    fi
    
    exit ${exit_code}
}

# Emergency cleanup function for unexpected exits
emergency_cleanup() {
    echo "Emergency cleanup triggered" >&2
    if [ -f "${LOCK_FILE}" ]; then
        rm -f "${LOCK_FILE}" || true
    fi
}

# Set comprehensive trap for cleanup on all exit signals
trap cleanup EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM
trap 'cleanup 129' HUP
trap 'cleanup 131' QUIT
trap emergency_cleanup ERR

# Also handle script errors when -e is set
set -E  # Inherit ERR trap in functions and subshells

# Create logs directory in efs if it doesn't exist
mkdir -p "${LOGS_DIR}" || warning "Could not create logs directory in ${LOGS_DIR}"

# Find the planet file
PLANET_FILE=$(find_osm_file)
if [ -z "$PLANET_FILE" ]; then
    error "No planet file found matching pattern: $PLANET_FILE"
    exec /entrypoint.sh
fi
info "Found planet file: $PLANET_FILE"

# Get timestamps and set log files
PLANET_TIMESTAMP=$(get_file_timestamp "${PLANET_FILE}")
GENERAL_LOG="${LOGS_DIR}/update-ors_${PLANET_TIMESTAMP}.log"
ORS_LOG="${LOGS_DIR}/build-ors_${PLANET_TIMESTAMP}.log"
CURRENT_TIMESTAMP=$(date +"%d%m%Y")
OSM_IK_FILE="${OSM_DATA_DIR}/data_ik_${CURRENT_TIMESTAMP}.osm.pbf"
LATEST_EXTRACTED_FILE=$(find_extract_file)
if [ -n "${LATEST_EXTRACTED_FILE}" ]; then
    info "Latest extracted file: ${LATEST_EXTRACTED_FILE}"
else
    info "No previous extracted file found"
fi

# Redirect all script output to general log
exec 1> >(tee -a "${GENERAL_LOG}")
exec 2> >(tee -a "${GENERAL_LOG}" >&2)

info "Starting scheduled graph update"
info "Planet file: ${PLANET_FILE}"
info "Planet timestamp: ${PLANET_TIMESTAMP}"

# Check if another update is running
if [ -f "${LOCK_FILE}" ]; then
    # Check if the process is still running
    OLD_PID=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
    if [ -n "${OLD_PID}" ] && kill -0 ${OLD_PID} 2>/dev/null; then
        warning "Graph update already in progress (PID: ${OLD_PID}). Exiting."
        exit 1
    else
        warning "Removing stale lock file"
        rm -f "${LOCK_FILE}"
    fi
fi

# Create lock file with current PID
echo $$ > "${LOCK_FILE}" || {
    error "Failed to create lock file"
    exit 1
}

# Create build directory
mkdir -p "${BUILD_DIR}"/{graphs,config} || {
    error "Failed to create build directory structure"
    exit 1
}

# Run extraction if needed
echo "======================================"
info "Starting extraction process"
echo "======================================"

#update the osm.pbf file and run extraction  
pyosmium-up-to-date -vvvv --size 10000 ${PLANET_FILE} && mv ${PLANET_FILE} "${OSM_DATA_DIR}/planet_${CURRENT_TIMESTAMP}.osm.pbf"|| {
    error "Failed to update OSM data"
    exit 1
}
if ! /extractor.sh "$OSM_IK_FILE"; then
    error "Extraction failed"
    exit 1
fi
success "Extraction completed. New file: ${OSM_IK_FILE}"



#remove old extracted files if they exist and are different
if [ -n "${LATEST_EXTRACTED_FILE}" ] && [ "${LATEST_EXTRACTED_FILE}" != "${OSM_IK_FILE}" ]; then
    rm -f "${LATEST_EXTRACTED_FILE}" || {
        warning "Failed to remove old extracted file: ${LATEST_EXTRACTED_FILE}"
    }
    info "Removed old extracted file: ${LATEST_EXTRACTED_FILE}"
fi

#copy current config to build directory
cp -r "${RUNTIME_DIR}/config/"* "${BUILD_DIR}/config/" 2>/dev/null || {
    error "Failed to copy config files"
    exit 1
}

# Update config to use the latest extracted file
info "Updating configuration file"
CONFIG_FILE="${BUILD_DIR}/config/ors-config.yml"

if [ ! -f "${CONFIG_FILE}" ]; then
    error "Config file not found: ${CONFIG_FILE}"
    exit 1
fi

yq -i e ".ors.engine.profiles.driving-car.build.source_file = \"${OSM_IK_FILE}\"" "${CONFIG_FILE}" || {
    error "Failed to update source file in config"
    exit 1
}
yq -i e ".ors.engine.profile_default.build.source_file = \"${OSM_IK_FILE}\"" "${CONFIG_FILE}" || {
    error "Failed to update source file in config"
    exit 1
}
if ! yq -i e '.ors.engine.profiles.driving-car.graph_path = "/efs/ors-build/graphs"' "${CONFIG_FILE}"; then
    error "Failed to update driving-car graph path in config"
    exit 1
fi
success "Configuration updated !!"

# Build graphs with forced rebuild
info "Building new graphs in ${BUILD_DIR} using file: ${OSM_IK_FILE}"

# Prepare CATALINA_OPTS and JAVA_OPTS (using same logic as main script)
management_jmxremote_port=${MANAGEMENT_JMXREMOTE_PORT:-9002}
management_jmxremote_rmi_port=${MANAGEMENT_JMXREMOTE_RMI_PORT:-9002}
management_jmxremote_authenticate=${MANAGEMENT_JMXREMOTE_AUTHENTICATE:-false}
management_jmxremote_ssl=${MANAGEMENT_JMXREMOTE_SSL:-false}
java_rmi_server_hostname=${JAVA_RMI_SERVER_HOSTNAME:-localhost}
additional_catalina_opts=${ADDITIONAL_CATALINA_OPTS:-""}

target_survivor_ratio=${TARGET_SURVIVOR_RATIO:-75}
survivor_ratio=${SURVIVOR_RATIO:-64}
max_tenuring_threshold=${MAX_TENURING_THRESHOLD:-3}
parallel_gc_threads=${PARALLEL_GC_THREADS:-4}

# Use more memory for building
xms=${BUILD_XMS:-8g}
xmx=${BUILD_XMX:-8g}
additional_java_opts=${ADDITIONAL_JAVA_OPTS:-""}

CATALINA_OPTS="-Dcom.sun.management.jmxremote \
-Dcom.sun.management.jmxremote.port=${management_jmxremote_port} \
-Dcom.sun.management.jmxremote.rmi.port=${management_jmxremote_rmi_port} \
-Dcom.sun.management.jmxremote.authenticate=${management_jmxremote_authenticate} \
-Dcom.sun.management.jmxremote.ssl=${management_jmxremote_ssl} \
-Djava.rmi.server.hostname=${java_rmi_server_hostname} \
${additional_catalina_opts}"

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

# Clean up any existing graphs in build directory
rm -rf "${BUILD_DIR}/graphs/"* 2>/dev/null || true

# Start ORS in background for graph building
export ORS_CONFIG_LOCATION="${BUILD_DIR}/config/ors-config.yml"
export REBUILD_GRAPHS="true"

info "Starting ORS build process with separate logging"
info "Build command: java ${JAVA_OPTS} ${CATALINA_OPTS} -jar /ors.jar --server.port=8083"

# Start the build process
nohup java ${JAVA_OPTS} ${CATALINA_OPTS} -jar /ors.jar --server.port=8083 > "${ORS_LOG}" 2>&1 &
BUILD_PID=$!

# Give it some time to start
sleep 10

# Check if process started successfully
if ! kill -0 ${BUILD_PID} 2>/dev/null; then
    error "Failed to start ORS build process"
    tail -20 "${ORS_LOG}"
    exit 1
fi

info "ORS build process started with PID: ${BUILD_PID}"

# Wait for graph building to complete by monitoring gh.lock
info "Waiting for graph building to complete..."
GRAPH_BUILD_COUNT=0
MAX_GRAPH_RETRIES=720  # 6 hours with 30-second intervals

while [ ${GRAPH_BUILD_COUNT} -lt ${MAX_GRAPH_RETRIES} ]; do
    # Check for lock files in both possible locations
    LOCK_EXISTS=false
    if [ -f "${BUILD_DIR}/graphs/gh.lock" ] || [ -f "${BUILD_DIR}/graphs/driving-car/gh.lock" ]; then
        LOCK_EXISTS=true
    fi
    
    # Check if graph directory exists and lock is gone
    if [ "${LOCK_EXISTS}" = false ] && [ -d "${BUILD_DIR}/graphs/driving-car" ]; then
        # Verify the graph files actually exist
        if [ -f "${BUILD_DIR}/graphs/driving-car/edges" ] && [ -f "${BUILD_DIR}/graphs/driving-car/nodes" ]; then
            success "Graph building completed!"
            break
        fi
    fi
    
    # Check if build process is still running
    if ! kill -0 ${BUILD_PID} 2>/dev/null; then
        error "Graph build process died unexpectedly"
        echo "Last 50 lines of ORS log:"
        tail -50 "${ORS_LOG}"
        exit 1
    fi
    
    GRAPH_BUILD_COUNT=$((GRAPH_BUILD_COUNT + 1))
    
    # Show progress every 10 iterations (5 minutes)
    if [ $((GRAPH_BUILD_COUNT % 10)) -eq 0 ]; then
        info "Graph building in progress... (${GRAPH_BUILD_COUNT}/${MAX_GRAPH_RETRIES})"
        
        # Check log file size to ensure it's still writing
        if [ -f "${ORS_LOG}" ]; then
            LOG_SIZE=$(stat -f%z "${ORS_LOG}" 2>/dev/null || stat -c%s "${ORS_LOG}" 2>/dev/null)
            info "ORS log size: ${LOG_SIZE} bytes"
        fi
    fi
    
    sleep 30
done

if [ ${GRAPH_BUILD_COUNT} -ge ${MAX_GRAPH_RETRIES} ]; then
    error "Graph building timed out after 6 hours"
    tail -50 "${ORS_LOG}"
    exit 1
fi

# Verify service health
info "Graph building complete, verifying service health..."
HEALTH_COUNT=0

while [ ${HEALTH_COUNT} -lt ${MAX_HEALTH_RETRIES} ]; do
    if wget --quiet --tries=1 --timeout=10 --spider "http://localhost:8083/ors/v2/health" 2>/dev/null; then
        success "Service is healthy and ready!"
        break
    fi
    
    HEALTH_COUNT=$((HEALTH_COUNT + 1))
    info "Health check attempt ${HEALTH_COUNT}/${MAX_HEALTH_RETRIES}"
    sleep ${HEALTH_RETRY_INTERVAL}
done

if [ ${HEALTH_COUNT} -ge ${MAX_HEALTH_RETRIES} ]; then
    error "Service not healthy after graph building completed"
    tail -50 "${ORS_LOG}"
    exit 1
fi

# Gracefully stop the build process
info "Stopping build process..."
kill -TERM ${BUILD_PID} 2>/dev/null || true
wait ${BUILD_PID} 2>/dev/null || true


# Replace runtime graphs with new ones
info "Replacing runtime graphs with newly built ones"
mkdir -p "${RUNTIME_DIR}/graphs"
mv "${BUILD_DIR}/graphs/"* "${RUNTIME_DIR}/graphs/" || {
    error "Failed to move built graphs to runtime directory"
    exit 1
}

# Clean up build directory graphs but keep logs
rm -rf "${BUILD_DIR}/graphs" || {
    warning "Failed to clean up build graphs directory"
}

success "Graph update completed successfully"
# clean old updater logs 
find "${LOGS_DIR}" -name "update-ors_*.log" -type f -mtime +7 -exec rm -f {} \; || warning "Failed to clean up old updater logs"
find "${LOGS_DIR}" -name "build-ors_*.log" -type f -mtime +7 -exec rm -f {} \; || warning "Failed to clean up old build logs"

exit 0