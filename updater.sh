#!/bin/bash
source /utils.sh

# Configuration
readonly MAX_HEALTH_RETRIES=5
readonly HEALTH_RETRY_INTERVAL=10
readonly MAX_GRAPH_RETRIES=10000
readonly GRAPH_CHECK_INTERVAL=30
readonly TIMESTAMP=$(date +"%d%m%Y")
readonly LOCK_FILE="/tmp/updater.lock"

# Export directories
export OSM_DATA_DIR="/efs/data"
export LOGS_DIR="/efs/logs/ors_ik"  
export BUILD_DIR="/efs/ors-build"
export RUNTIME_DIR="/efs/ors-run"

# Global variables
BUILD_PID=""

# Comprehensive cleanup function
cleanup() {
    local exit_code=${1:-$?}
    
    # Remove lock file
    [ -f "${LOCK_FILE}" ] && rm -f "${LOCK_FILE}" && info "Lock file removed"
    
    # Kill build process if running
    if [ -n "${BUILD_PID}" ] && kill -0 ${BUILD_PID} 2>/dev/null; then
        info "Stopping build process ${BUILD_PID}"
        kill -TERM ${BUILD_PID} 2>/dev/null || true
        sleep 2
        kill -0 ${BUILD_PID} 2>/dev/null && kill -KILL ${BUILD_PID} 2>/dev/null || true
        wait ${BUILD_PID} 2>/dev/null || true
    fi
    
    # Clean up old logs
    cleanup_old_logs
    
    if [ ${exit_code} -eq 0 ]; then
        success "Update process completed successfully"
    else
        error "Update process failed with exit code ${exit_code}"
    fi
    
    exit ${exit_code}
}

# Emergency cleanup for unexpected exits
emergency_cleanup() {
    echo "Emergency cleanup triggered" >&2
    [ -f "${LOCK_FILE}" ] && rm -f "${LOCK_FILE}"
}

# Setup comprehensive traps
setup_traps() {
    trap cleanup EXIT
    trap 'cleanup 130' INT TERM HUP QUIT
    trap emergency_cleanup ERR
    set -E
}

# Initialize logging and check prerequisites
initialize() {
    mkdir -p "${LOGS_DIR}" || warning "Could not create logs directory"
    
    # Setup logging
    local general_log="${LOGS_DIR}/update-ors_${TIMESTAMP}.log"
    exec 1> >(tee -a "${general_log}")
    exec 2> >(tee -a "${general_log}" >&2)
    
    info "Starting scheduled graph update"
    
    # Find planet file
    local planet_file=$(find_osm_file)
    if [ -z "$planet_file" ]; then
        error "No planet file found"
        exec /entrypoint.sh
    fi
    
    info "Found planet file: $planet_file"
    echo "$planet_file"
}

# Check and create lock file
acquire_lock() {
    if [ -f "${LOCK_FILE}" ]; then
        local old_pid=$(cat "${LOCK_FILE}" 2>/dev/null || echo "")
        if [ -n "${old_pid}" ] && kill -0 ${old_pid} 2>/dev/null; then
            warning "Graph update already in progress (PID: ${old_pid}). Exiting."
            exit 1
        else
            warning "Removing stale lock file"
            rm -f "${LOCK_FILE}"
        fi
    fi
    
    echo $$ > "${LOCK_FILE}" || {
        error "Failed to create lock file"
        exit 1
    }
}

# Download and extract OSM data
update_osm_data() {
    local osm_ik_file="${OSM_DATA_DIR}/data_ik_${TIMESTAMP}.osm.pbf"
    local latest_extracted=$(find_extract_file)
    
    echo "======================================"
    info "Starting extraction process"
    echo "======================================"
    
    # Download new OSM data
    wget --progress=bar:force:noscroll -O "${OSM_DATA_DIR}/planet_${TIMESTAMP}.osm.pbf" "${OSM_URL}" || {
        error "Failed to update OSM data"
        exit 1
    }
    
    # Extract data
    /extractor.sh "$osm_ik_file" || {
        error "Extraction failed"
        exit 1
    }
    
    success "Extraction completed. New file: ${osm_ik_file}"
    
    # Remove old extracted file if different
    if [ -n "${latest_extracted}" ] && [ "${latest_extracted}" != "${osm_ik_file}" ]; then
        rm -f "${latest_extracted}" && info "Removed old extracted file: ${latest_extracted}" || warning "Failed to remove old extracted file"
    fi
    
    echo "$osm_ik_file"
}

# Setup build environment
setup_build_environment() {
    local osm_ik_file="$1"
    
    # Create build directory structure
    mkdir -p "${BUILD_DIR}"/{graphs,config} || {
        error "Failed to create build directory structure"
        exit 1
    }
    
    # Copy config files
    cp -r "${RUNTIME_DIR}/config/"* "${BUILD_DIR}/config/" 2>/dev/null || {
        error "Failed to copy config files"
        exit 1
    }
    
    # Update configuration
    local config_file="${BUILD_DIR}/config/ors-config.yml"
    [ ! -f "${config_file}" ] && { error "Config file not found: ${config_file}"; exit 1; }
    
    # Update config with new OSM file
    local config_updates=(
        ".ors.engine.profiles.driving-car.build.source_file = \"${osm_ik_file}\""
        ".ors.engine.profile_default.build.source_file = \"${osm_ik_file}\""
        ".ors.engine.profiles.driving-car.graph_path = \"/efs/ors-build/graphs\""
    )
    
    for update in "${config_updates[@]}"; do
        yq -i e "$update" "${config_file}" || {
            error "Failed to update config: $update"
            exit 1
        }
    done
    
    success "Configuration updated!"
    rm -rf "${BUILD_DIR}/graphs/"* 2>/dev/null || true
}

# Configure JVM options for build
configure_jvm_options() {
    # JMX settings with different ports for build
    local jmx_opts="-Dcom.sun.management.jmxremote"
    jmx_opts+=" -Dcom.sun.management.jmxremote.port=${MANAGEMENT_JMXREMOTE_PORT:-9002}"
    jmx_opts+=" -Dcom.sun.management.jmxremote.rmi.port=${MANAGEMENT_JMXREMOTE_RMI_PORT:-9002}"
    jmx_opts+=" -Dcom.sun.management.jmxremote.authenticate=${MANAGEMENT_JMXREMOTE_AUTHENTICATE:-false}"
    jmx_opts+=" -Dcom.sun.management.jmxremote.ssl=${MANAGEMENT_JMXREMOTE_SSL:-false}"
    jmx_opts+=" -Djava.rmi.server.hostname=${JAVA_RMI_SERVER_HOSTNAME:-localhost}"
    jmx_opts+=" ${ADDITIONAL_CATALINA_OPTS:-}"
    
    # GC settings with more memory for building
    local gc_opts="-Djava.awt.headless=true -server"
    gc_opts+=" -XX:TargetSurvivorRatio=${TARGET_SURVIVOR_RATIO:-75}"
    gc_opts+=" -XX:SurvivorRatio=${SURVIVOR_RATIO:-64}"
    gc_opts+=" -XX:MaxTenuringThreshold=${MAX_TENURING_THRESHOLD:-3}"
    gc_opts+=" -XX:+UseG1GC -XX:+ScavengeBeforeFullGC"
    gc_opts+=" -XX:ParallelGCThreads=${PARALLEL_GC_THREADS:-4}"
    gc_opts+=" -Xms${BUILD_XMS:-8g} -Xmx${BUILD_XMX:-8g}"
    gc_opts+=" ${ADDITIONAL_JAVA_OPTS:-}"
    
    export CATALINA_OPTS="$jmx_opts"
    export JAVA_OPTS="$gc_opts"
}

# Start ORS build process
start_build_process() {
    export ORS_CONFIG_LOCATION="${BUILD_DIR}/config/ors-config.yml"
    export REBUILD_GRAPHS="true"
    
    local ors_log="${LOGS_DIR}/build-ors_${TIMESTAMP}.log"
    info "Starting ORS build process with logging to: ${ors_log}"
    
    # Start build process in background
    nohup java ${JAVA_OPTS} ${CATALINA_OPTS} -jar /ors.jar --server.port=8083 > "${ors_log}" 2>&1 &
    BUILD_PID=$!
    
    sleep 10
    
    # Verify process started
    if ! kill -0 ${BUILD_PID} 2>/dev/null; then
        error "Failed to start ORS build process"
        tail -20 "${ors_log}"
        exit 1
    fi
    
    info "ORS build process started with PID: ${BUILD_PID}"
}

# Wait for graph building completion
wait_for_graphs() {
    info "Waiting for graph building to complete..."
    local count=0
    
    while [ ${count} -lt ${MAX_GRAPH_RETRIES} ]; do
        # Check if graphs are built (no lock files and graph files exist)
        if [ ! -f "${BUILD_DIR}/graphs/gh.lock" ] && [ ! -f "${BUILD_DIR}/graphs/driving-car/gh.lock" ] && 
           [ -f "${BUILD_DIR}/graphs/driving-car/edges" ] && [ -f "${BUILD_DIR}/graphs/driving-car/nodes" ]; then
            success "Graph building completed!"
            return 0
        fi
        
        # Check if build process is still running
        if ! kill -0 ${BUILD_PID} 2>/dev/null; then
            error "Graph build process died unexpectedly"
            tail -50 "${LOGS_DIR}/build-ors_${TIMESTAMP}.log"
            exit 1
        fi
        
        count=$((count + 1))
        
        # Progress updates every 10 iterations
        if [ $((count % 10)) -eq 0 ]; then
            info "Graph building in progress... (${count}/${MAX_GRAPH_RETRIES})"
        fi
        
        sleep ${GRAPH_CHECK_INTERVAL}
    done
    
    error "Graph building timed out after $((MAX_GRAPH_RETRIES * GRAPH_CHECK_INTERVAL)) seconds"
    exit 1
}

# Verify service health
verify_service_health() {
    info "Verifying service health..."
    local count=0
    
    while [ ${count} -lt ${MAX_HEALTH_RETRIES} ]; do
        if wget --quiet --tries=1 --timeout=10 --spider "http://localhost:8083/ors/v2/health" 2>/dev/null; then
            success "Service is healthy and ready!"
            return 0
        fi
        
        count=$((count + 1))
        info "Health check attempt ${count}/${MAX_HEALTH_RETRIES}"
        sleep ${HEALTH_RETRY_INTERVAL}
    done
    
    error "Service not healthy after graph building completed"
    tail -50 "${LOGS_DIR}/build-ors_${TIMESTAMP}.log"
    exit 1
}

# Replace runtime graphs with new ones
deploy_graphs() {
    info "Deploying newly built graphs to runtime directory"
    
    mkdir -p "${RUNTIME_DIR}/graphs"
    
    # Move new graphs to runtime
    mv "${BUILD_DIR}/graphs/"* "${RUNTIME_DIR}/graphs/" || {
        error "Failed to move built graphs to runtime directory"
        exit 1
    }
    
    # Clean up build directory
    rm -rf "${BUILD_DIR}/graphs" || warning "Failed to clean up build graphs directory"
    
    success "Graph deployment completed successfully"
}

# Clean up old log files
cleanup_old_logs() {
    local log_patterns=("update-ors_*.log" "build-ors_*.log")
    
    for pattern in "${log_patterns[@]}"; do
        find "${LOGS_DIR}" -name "$pattern" -type f -mtime +7 -exec rm -f {} \; 2>/dev/null || true
    done
}

# Main execution flow
main() {
    setup_traps
    local planet_file=$(initialize)
    acquire_lock
    
    local osm_ik_file=$(update_osm_data)
    setup_build_environment "$osm_ik_file"
    configure_jvm_options
    
    start_build_process
    wait_for_graphs
    verify_service_health
    deploy_graphs
    
    exit 0
}

# Execute main function
main "$@"