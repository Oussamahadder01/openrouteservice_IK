#!/bin/bash
source /utils.sh

# Initialize logging and variables
INIT_TIMESTAMP=$(date +"%d%m%Y")
INIT_LOG="${LOGS_DIR}/init-ors_${INIT_TIMESTAMP}.log"
export BUILD_DIR="/efs/ors-build"

# Global variables that need to be accessible across functions
OSM_FILE=""
OSM_IK_FILE=""
ors_config_location=""
ors_engine_profile_default_graph_path=""

exec 1> >(tee -a "${INIT_LOG}")
exec 2> >(tee -a "${INIT_LOG}" >&2)

echo "################################"
echo "# ORS Container Setup #"
echo "################################"
echo "Init log started at: $(date)"
echo "Log file: ${INIT_LOG}"

set_log_level
jar_file="/ors.jar"
REBUILD_GRAPHS=$(echo "${REBUILD_GRAPHS:-false}" | tr '[:upper:]' '[:lower:]')

# Setup directories and permissions
setup_directories() {
    echo "###########################"       
    echo "# Container folders preparation #"
    echo "###########################"
    
    local dirs=("${RUNTIME_DIR}"/{graphs,config} "${LOGS_DIR}" "${BUILD_DIR}")
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir" || warning "Could not create directory: $dir"
    done
    
    if [ ! -w "${RUNTIME_DIR}" ]; then
        warning "RUNTIME_DIR=${RUNTIME_DIR} is not writable, changing permissions"
        chmod -R 777 "${RUNTIME_DIR}" || warning "Could not change permissions of ${RUNTIME_DIR}"
    fi
    
    chown -R "$(whoami)" "${RUNTIME_DIR}" && debug "Changed ownership of ${RUNTIME_DIR} to $(whoami)" || warning "Could not change ownership"
    rm -f "${OSM_UPDATE_MARKER}" 2>/dev/null
}

# Handle OSM file download and extraction
handle_osm_data() {
    # Use global OSM_FILE variable
    OSM_FILE=$(find_osm_file)
    
    if [ -z "$OSM_FILE" ] || [ ! -f "$OSM_FILE" ]; then 
        warning "PBF file not found, proceeding to download it."
        OSM_FILE="${OSM_DATA_DIR}/planet_${INIT_TIMESTAMP}.osm.pbf"
        
        if wget --progress=bar:force:noscroll -O "${OSM_FILE}" "${OSM_URL}"; then
            touch "${OSM_UPDATE_MARKER}"
            success "OSM data downloaded and marked as ready"
            info "proceeding with extraction"
            # Set global OSM_IK_FILE variable
            OSM_IK_FILE="${OSM_DATA_DIR}/data_ik_${INIT_TIMESTAMP}.osm.pbf"
            /extractor.sh "$OSM_IK_FILE" || error "Extraction failed"
            success "Extraction completed. New file: ${OSM_IK_FILE}"
        else
            error "Failed to download OSM data"
            exit 1
        fi
        OSM_FILE=$(find_osm_file)
    else
        # If OSM file exists, we need to set OSM_IK_FILE
        # Extract the timestamp from existing file or use current
        local existing_timestamp
        existing_timestamp=$(echo "$OSM_FILE" | grep -oE '[0-9]{8}' | head -1)
        OSM_IK_FILE="${OSM_DATA_DIR}/data_ik_${existing_timestamp:-${INIT_TIMESTAMP}}.osm.pbf"
        
        # Check if IK file exists, if not create it
        if [ ! -f "$OSM_IK_FILE" ]; then
            info "Extracting from existing OSM file: $OSM_FILE"
            /extractor.sh "$OSM_IK_FILE" || error "Extraction failed"
            success "Extraction completed. New file: ${OSM_IK_FILE}"
        fi
    fi

    # Validate that OSM_IK_FILE is set and exists
    if [ -z "$OSM_IK_FILE" ] || [ ! -f "$OSM_IK_FILE" ]; then
        error "OSM_IK_FILE is not set or does not exist: ${OSM_IK_FILE}"
        exit 1
    fi
}

# Configure ORS settings
configure_ors() {
    [ ! -f "${jar_file}" ] && critical "Jar file not found. This shouldn't happen. Exiting."
    
    CONFIG_FILE="/ors-config.yml"
    echo "Using configuration file: ${CONFIG_FILE}"
    
    update_file "${RUNTIME_DIR}/config/ors-config.yml" "/ors-config.yml"

    # Check if OSM_IK_FILE is set
    if [ -z "$OSM_IK_FILE" ]; then
        error "OSM_IK_FILE is not set. This should have been set in handle_osm_data()"
        exit 1
    fi
    
    echo "Using OSM file: $OSM_IK_FILE"
    
    # Update config with OSM file path
    yq -i e ".ors.engine.profiles.driving-car.build.source_file = \"${OSM_IK_FILE}\"" "${RUNTIME_DIR}/config/ors-config.yml"
    yq -i e ".ors.engine.profile_default.build.source_file = \"${OSM_IK_FILE}\"" "${RUNTIME_DIR}/config/ors-config.yml"
    
    if ! yq -i e '.ors.engine.profiles.driving-car.graph_path = "/efs/ors-run/graphs"' "${RUNTIME_DIR}/config/ors-config.yml"; then
        error "Failed to update driving-car graph path in config"
        exit 1
    fi
    
    # Set global variables
    ors_config_location="${RUNTIME_DIR}/config/ors-config.yml"
    ors_engine_profile_default_graph_path=$(extract_config_info "${ors_config_location}" '.ors.engine.profile_default.graph_path')
    ors_engine_profile_default_graph_path="${ors_engine_profile_default_graph_path:-${RUNTIME_DIR}/graphs}"
    
    success "Using graphs folder ${ors_engine_profile_default_graph_path}"
    info "Any ENV variables will have precedence over configuration variables from config files."
}

# Handle graph rebuilding
handle_graphs() {
    echo "#####################################"
    echo "# Container file system preparation #"
    echo "#####################################"
    
    # Check if ors_engine_profile_default_graph_path is set
    if [ -z "$ors_engine_profile_default_graph_path" ]; then
        error "ors_engine_profile_default_graph_path is not set. This should have been set in configure_ors()"
        exit 1
    fi
    
    # Check if ors_rebuild_graphs is defined, use empty string as default
    local ors_rebuild_graphs="${ors_rebuild_graphs:-}"
    
    if [ "${REBUILD_GRAPHS}" = "true" ] || [ "${ors_rebuild_graphs}" = "true" ]; then
        if [ -d "${ors_engine_profile_default_graph_path}" ]; then
            rm -rf "${ors_engine_profile_default_graph_path:?}"/* || warning "Could not remove ${ors_engine_profile_default_graph_path}"
            success "Removed graphs at ${ors_engine_profile_default_graph_path}/*."
        else
            debug "${ors_engine_profile_default_graph_path} does not exist (yet). Skipping cleanup."
        fi
        mkdir -p "${ors_engine_profile_default_graph_path}" || warning "Could not populate graph folder"
    fi
    
    success "Container file system preparation complete."
}

# Setup JVM options
setup_jvm_options() {
    echo "#######################################"
    echo "# Prepare CATALINA_OPTS and JAVA_OPTS #"
    echo "#######################################"
    
    # JMX settings
    local jmx_port=${MANAGEMENT_JMXREMOTE_PORT:-9001}
    local jmx_rmi_port=${MANAGEMENT_JMXREMOTE_RMI_PORT:-9001}
    local jmx_auth=${MANAGEMENT_JMXREMOTE_AUTHENTICATE:-false}
    local jmx_ssl=${MANAGEMENT_JMXREMOTE_SSL:-false}
    local rmi_hostname=${JAVA_RMI_SERVER_HOSTNAME:-localhost}
    
    CATALINA_OPTS="-Dcom.sun.management.jmxremote \
-Dcom.sun.management.jmxremote.port=${jmx_port} \
-Dcom.sun.management.jmxremote.rmi.port=${jmx_rmi_port} \
-Dcom.sun.management.jmxremote.authenticate=${jmx_auth} \
-Dcom.sun.management.jmxremote.ssl=${jmx_ssl} \
-Djava.rmi.server.hostname=${rmi_hostname} \
${ADDITIONAL_CATALINA_OPTS:-}"
    
    # GC settings
    JAVA_OPTS="-Djava.awt.headless=true -server \
-XX:TargetSurvivorRatio=${TARGET_SURVIVOR_RATIO:-75} \
-XX:SurvivorRatio=${SURVIVOR_RATIO:-64} \
-XX:MaxTenuringThreshold=${MAX_TENURING_THRESHOLD:-3} \
-XX:+UseG1GC -XX:+ScavengeBeforeFullGC \
-XX:ParallelGCThreads=${PARALLEL_GC_THREADS:-4} \
-Xms${XMS:-1g} -Xmx${XMX:-2g} \
${ADDITIONAL_JAVA_OPTS:-}"
    
    debug "CATALINA_OPTS: ${CATALINA_OPTS}"
    debug "JAVA_OPTS: ${JAVA_OPTS}"
    success "JVM options configured."
}

# Setup cron job
setup_cron() {
    info "Setting up graph update cronjob"
    CRON_SCHEDULE="${GRAPH_UPDATE_CRON:-0 18 * * 5}"
    echo "${CRON_SCHEDULE} /updater.sh >> /var/log/updater.log 2>&1" | crontab -
    cron
    success "Cronjob configured to run: ${CRON_SCHEDULE}"
}

# Cleanup function
cleanup() {
    rm -f "${OSM_UPDATE_MARKER}"
    
    # Move built graphs to runtime directory
    if [ -d "${BUILD_DIR}/graphs" ]; then
        if [ -n "$ors_engine_profile_default_graph_path" ] && [ -d "$ors_engine_profile_default_graph_path" ]; then
            mv "${BUILD_DIR}/graphs/"* "${ors_engine_profile_default_graph_path}/" 2>/dev/null || {
                error "Failed to move built graphs to runtime directory"
                exit 1
            }
        else
            # Fallback to RUNTIME_DIR/graphs if ors_engine_profile_default_graph_path is not set
            mv "${BUILD_DIR}/graphs/"* "${RUNTIME_DIR}/graphs/" 2>/dev/null || {
                error "Failed to move built graphs to runtime directory"
                exit 1
            }
        fi
        rm -rf "${BUILD_DIR}/graphs" || warning "Failed to clean up build graphs directory"
    fi
    
    # Clean old logs
    find "${LOGS_DIR}" -name "init-ors_*.log" -type f -mtime +7 -exec rm -f {} \; 2>/dev/null || warning "Failed to clean up old logs"
}

# Validate required environment variables
validate_environment() {
    local required_vars=("RUNTIME_DIR" "LOGS_DIR" "OSM_DATA_DIR" "OSM_URL" "OSM_UPDATE_MARKER")
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        error "Missing required environment variables: ${missing_vars[*]}"
        exit 1
    fi
}

# Main execution flow
main() {
    # Validate environment before starting
    validate_environment
    
    setup_directories
    handle_osm_data
    configure_ors
    handle_graphs
    setup_jvm_options
    setup_cron
    
    echo "#####################"
    echo "# ORS startup phase #"
    echo "#####################"
    
    success "!! Ready to start the ORS application !!"
    success "Init log saved to: ${INIT_LOG}"
    debug "Startup command: java ${JAVA_OPTS} ${CATALINA_OPTS} -jar ${jar_file}"
    
    # Export for use in child processes
    export ORS_CONFIG_LOCATION=${ors_config_location}
    
    # Setup cleanup trap
    trap cleanup EXIT
    
    # shellcheck disable=SC2086
    exec java ${JAVA_OPTS} ${CATALINA_OPTS} -jar "${jar_file}" "$@"
}

# Run main function
main "$@"