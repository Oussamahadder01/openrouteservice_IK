#!/bin/bash 
source /utils.sh

# Generate timestamp for init log (DDMMYYYY format)
INIT_TIMESTAMP=$(date +"%d%m%Y")
INIT_LOG="${LOGS_DIR}/init-ors_${INIT_TIMESTAMP}.log"
export BUILD_DIR="/efs/ors-build"



# Redirect all entrypoint output to the init log
exec 1> >(tee -a "${INIT_LOG}")
exec 2> >(tee -a "${INIT_LOG}" >&2)

echo "################################"
echo "# ORS Container Setup #"
echo "################################"
echo "Init log started at: $(date)"
echo "Log file: ${INIT_LOG}"

set_log_level
jar_file=/ors.jar
REBUILD_GRAPHS=${REBUILD_GRAPHS:-"false"}
REBUILD_GRAPHS=$(echo "$REBUILD_GRAPHS" | tr '[:upper:]' '[:lower:]') # Convert to lowercase

# Perform initial setup
initial_setup

# Fail if RUNTIME_DIR env var is not set or if it is empty or set to /
if [ -z "${RUNTIME_DIR}" ] || [ "${RUNTIME_DIR}" = "/" ]; then
    critical "RUNTIME_DIR is not set or empty or set to /. This is not allowed. Exiting."
fi

# Sanity checks and file system prep
echo "###########################"
echo "# Container sanity checks #"
echo "###########################"
info "Running container as user $(whoami) with id $(id -u) and group $(id -g)"

if [[ $(id -u) -eq 0 ]] || [[ $(id -g) -eq 0 ]] ; then
    debug "User and group are set to root with id 0 and group 0."
elif [[ $(id -u) -eq 1000 ]] || [[ $(id -g) -eq 1000 ]] ; then
    debug "User and group are set to 1000 and group 1000."
else
    # Test if the user tampered with the user and group settings
    warning "Running container as user '$(whoami)' with id $(id -u) and group $(id -g)"
    warning "Changing these values is only recommended if you're an advanced docker user and can handle file permission issues yourself."
    warning "Consider leaving the user and group options as root with 0:0 or 1000:1000 or avoid that setting completely."
    warning "If you need to change the user and group, make sure to rebuild the docker image with the appropriate UID,GID build args."
fi

# Container folders preparation
echo "###########################"       
echo "# Container folders preparation #"
echo "###########################"

# Make sure RUNTIME_DIR is a directory  
if [ ! -d "${RUNTIME_DIR}" ]; then
    critical "RUNTIME_DIR: ${RUNTIME_DIR} doesn't exist. Exiting."
elif [ ! -w "${RUNTIME_DIR}" ]; then
    error "RUNTIME_DIR: ${RUNTIME_DIR} is not writable."
    error "Make sure the file permission of ${RUNTIME_DIR} in your volume mount are set to $(id -u):$(id -g)."
    error "Under linux the command for a volume would be: sudo chown -R $(id -u):$(id -g) /path/to/ors/volume"
    critical "Exiting."
fi
success "RUNTIME_DIR: ${RUNTIME_DIR} exists and is writable."

mkdir -p "${RUNTIME_DIR}"/{graphs,config} || warning "Could not create the default folders in ${RUNTIME_DIR}: graphs, config"
mkdir -p "${LOGS_DIR}" || warning "Could not create the logs folder at ${LOGS_DIR}"
mkdir -p "${BUILD_DIR}" || warning "Could not create the builds folder at ${BUILD_DIR}"
debug "Populated RUNTIME_DIR=${RUNTIME_DIR} with the default folders: graphs, config"


# Find the OSM file using glob handling
rm -f "${OSM_UPDATE_MARKER}" 2>/dev/null

# Find the OSM file using glob handling
OSM_FILE=$(find_osm_file)
echo "Found OSM file: ${OSM_FILE}"
if [ -z "$OSM_FILE" ] || [ ! -f "$OSM_FILE" ]; then 
    warning "PBF file not found, proceeding to download it."
    OSM_FILE="${OSM_DATA_DIR}/planet_${INIT_TIMESTAMP}.osm.pbf"
    if wget --progress=bar:force:noscroll -O "${OSM_FILE}" "${OSM_URL}"; then
        # Create marker file after successful download
        touch "${OSM_UPDATE_MARKER}"
        success "OSM data downloaded and marked as ready"
    else
        error "Failed to download OSM data"
        exit 1
    fi
    # Re-find the file after download
    OSM_FILE=$(find_osm_file)
else
    info "OSM file already exists: $OSM_FILE, proceeding to update it with diff files"
    if pyosmium-up-to-date -vvvv --size 10000 "${OSM_FILE}"; then
        mv "${OSM_FILE}" "${OSM_DATA_DIR}/planet_${INIT_TIMESTAMP}.osm.pbf"
        # Create marker file after successful update
        touch "${OSM_UPDATE_MARKER}"
        success "OSM data updated and marked as ready"
    else
        error "Failed to update OSM data"
        exit 1
    fi
fi

OSM_IK_FILE="${OSM_DATA_DIR}/data_ik_${INIT_TIMESTAMP}.osm.pbf"
if [ -f "${OSM_UPDATE_MARKER}" ]; then
    info "OSM data is ready, proceeding with extraction..."
    if ./extractor.sh "$OSM_IK_FILE"; then
        success "Extraction completed"
    else
        error "Extraction failed"
        exit 1
    fi
else
    error "OSM data is not ready (marker file missing)"
    exit 1
fi


# Check if the original jar file exists
if [ ! -f "${jar_file}" ]; then
    critical "Jar file not found. This shouldn't happen. Exiting."
fi
CONFIG_FILE="/ors-config.yml"
echo "Using configuration file: ${CONFIG_FILE}"

yq -i e ".ors.engine.profiles.driving-car.build.source_file = \"${OSM_IK_FILE}\"" "${CONFIG_FILE}"
yq -i e ".ors.engine.profile_default.build.source_file = \"${OSM_IK_FILE}\"" "${CONFIG_FILE}"
if ! yq -i e '.ors.engine.profiles.driving-car.graph_path = "/efs/ors-build/graphs"' "${CONFIG_FILE}"; then
    error "Failed to update driving-car graph path in config"
    exit 1
fi
update_file "${RUNTIME_DIR}/config/ors-config.yml" "/ors-config.yml"


ors_engine_profile_default_graph_path=$(extract_config_info "${ors_config_location}" '.ors.engine.profile_default.graph_path')
ors_engine_profile_default_build_source_file=$(extract_config_info "${ors_config_location}" '.ors.engine.profile_default.build.source_file')

if [ -n "${ors_engine_profile_default_graph_path}" ]; then
    success "Using graphs folder ${ors_engine_profile_default_graph_path}"
else
    info "Default to graphs folder: ${RUNTIME_DIR}/graphs"
    ors_engine_profile_default_graph_path="${RUNTIME_DIR}/graphs"
fi

info "Any ENV variables will have precedence over configuration variables from config files."
success "All checks passed. For details set CONTAINER_LOG_LEVEL=DEBUG."

echo "#####################################"
echo "# Container file system preparation #"
echo "#####################################"
# Check if uid or gid is different from 1000
chown -R "$(whoami)" "${RUNTIME_DIR}" && debug "Changed ownership of ${RUNTIME_DIR} to $(whoami)" || warning "Could not change ownership of ${RUNTIME_DIR} to $(whoami)"

# Remove existing graphs if REBUILD_GRAPHS is set to true
if [ "${REBUILD_GRAPHS}" = "true" ] || [ "${ors_rebuild_graphs}" = "true" ]; then
    if [ -d "${ors_engine_profile_default_graph_path}" ]; then
        # Check the ors.engine.profile_default.graph_path folder exists
        rm -rf "${ors_engine_profile_default_graph_path:?}"/* || warning "Could not remove ${ors_engine_profile_default_graph_path}"
        success "Removed graphs at ${ors_engine_profile_default_graph_path}/*."
    else
        debug "${ors_engine_profile_default_graph_path} does not exist (yet). Skipping cleanup."
    fi
    # Create the graphs folder again
    mkdir -p "${ors_engine_profile_default_graph_path}" || warning "Could not populate graph folder at ${ors_engine_profile_default_graph_path}"
fi

success "Container file system preparation complete. For details set CONTAINER_LOG_LEVEL=DEBUG."

echo "#######################################"
echo "# Prepare CATALINA_OPTS and JAVA_OPTS #"
echo "#######################################"
# Let the user define every parameter via env vars if not, default to the values below
management_jmxremote_port=${MANAGEMENT_JMXREMOTE_PORT:-9001}
management_jmxremote_rmi_port=${MANAGEMENT_JMXREMOTE_RMI_PORT:-9001}
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
debug "JAVA_OPTS: ${JAVA_OPTS}"
success "CATALINA_OPTS and JAVA_OPTS ready. For details set CONTAINER_LOG_LEVEL=DEBUG."

info "Setting up graph update cronjob"
    
# Create cron job (runs every 10 minutes by default)
CRON_SCHEDULE="${GRAPH_UPDATE_CRON:-0 18 * * 5}"
echo "${CRON_SCHEDULE} /updater.sh >> /var/log/updater.log 2>&1" | crontab -

# Start cron daemon
cron
success "Cronjob configured to run: ${CRON_SCHEDULE}"

echo "#####################"
echo "# ORS startup phase #"
echo "#####################"
# Start the jar with the given arguments and add the RUNTIME_DIR env var
success "🙭 Ready to start the ORS application 🙭"
success "Init log saved to: ${INIT_LOG}"
debug "Startup command: java ${JAVA_OPTS} ${CATALINA_OPTS} -jar ${jar_file}"

# Export ORS_CONFIG_LOCATION to the environment of child processes
export ORS_CONFIG_LOCATION=${ors_config_location}

# shellcheck disable=SC2086 # we need word splitting here
exec java ${JAVA_OPTS} ${CATALINA_OPTS} -jar "${jar_file}" "$@"
rm -f "${OSM_UPDATE_MARKER}"
mv "${BUILD_DIR}/graphs/"* "${RUNTIME_DIR}/graphs/" || {
    error "Failed to move built graphs to runtime directory"
    exit 1
}
rm -rf "${BUILD_DIR}/graphs" || {
    warning "Failed to clean up build graphs directory"
}

#clean old entrypoint logs

find "${LOGS_DIR}" -name "init-ors_*.log" -type f -mtime +7 -exec rm -f {} \; || warning "Failed to clean up old entrypoint logs"
success "ORS application started successfully. Logs are being written to ${LOGS_DIR}."

