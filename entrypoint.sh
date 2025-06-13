#!/bin/bash 
source /utils.sh

# Generate timestamp for init log (DDMMYYYY format)
INIT_TIMESTAMP=$(date +"%d%m%Y")
INIT_LOG="${LOGS_DIR}/init-ors_${INIT_TIMESTAMP}.log"

# Function to find the planet file using glob pattern
find_osm_file() {
    local pattern="${OSM_DATA_DIR}/planet_*.osm.pbf"
    local files=( $pattern )  # This expands the glob
    
    if [ ${#files[@]} -eq 0 ] || [ ! -f "${files[0]}" ]; then
        echo ""
        return 1
    elif [ ${#files[@]} -gt 1 ]; then
        warning "Multiple planet files found, using the most recent one"
        # Sort by modification time and get the newest
        local newest=$(ls -t $pattern 2>/dev/null | head -n1)
        echo "$newest"
    else
        echo "${files[0]}"
    fi
}
find_extract_file() {
    local pattern="${OSM_DATA_DIR}/data_ik_*.osm.pbf"
    local files=( $pattern )  # This expands the glob
    
    if [ ${#files[@]} -eq 0 ] || [ ! -f "${files[0]}" ]; then
        echo ""
        return 1
    elif [ ${#files[@]} -gt 1 ]; then
        warning "Multiple planet files found, using the most recent one"
        # Sort by modification time and get the newest
        local newest=$(ls -t $pattern 2>/dev/null | head -n1)
        echo "$newest"
    else
        echo "${files[0]}"
    fi
}

get_file_timestamp() {
    local file_path="$1"
    if [ -f "${file_path}" ]; then
        date -r "${file_path}" +"%d%m%Y"
    else
        echo ""
    fi
}

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
debug "Populated RUNTIME_DIR=${RUNTIME_DIR} with the default folders: graphs, config"

# Find the OSM file using improved glob handling
OSM_FILE=$(find_osm_file)
if [ -z "$OSM_FILE" ]; then
    info "No OSM file found matching pattern: ${OSM_DATA_DIR}/planet_*.osm.pbf"
else
    info "Found OSM file: $OSM_FILE"
fi

# Compare timestamps of the existing OSM file and the current date, download if the file is older than 5 days or if it doesn't exist
if [ -z "$OSM_FILE" ] || [ ! -f "$OSM_FILE" ]; then 
    warning "PBF file not found, proceeding to download it."
    ./downloader.sh "$@"
    # Re-find the file after download
    OSM_FILE=$(find_osm_file)
else
    FILE_TIMESTAMP=$(get_file_timestamp "$OSM_FILE")
    CURRENT_TIMESTAMP=$(date +"%d%m%Y")
    
    if [ "$FILE_TIMESTAMP" != "$CURRENT_TIMESTAMP" ]; then
        # Convert timestamps to seconds for day difference calculation
        FILE_DATE="${FILE_TIMESTAMP:4:4}-${FILE_TIMESTAMP:2:2}-${FILE_TIMESTAMP:0:2}"
        CURRENT_DATE=$(date +"%Y-%m-%d")
        
        FILE_SECONDS=$(date -d "$FILE_DATE" +%s 2>/dev/null)
        CURRENT_SECONDS=$(date -d "$CURRENT_DATE" +%s)
        
        # Check if date conversion was successful
        if [ -z "$FILE_SECONDS" ]; then
            warning "Could not parse file timestamp: $FILE_TIMESTAMP"
            ./downloader.sh "$@"
            OSM_FILE=$(find_osm_file)
        else
            DIFF_DAYS=$(( (CURRENT_SECONDS - FILE_SECONDS) / 86400 )) # 86400 seconds in a day
            
            if [ $DIFF_DAYS -gt 5 ]; then
                warning "File is $DIFF_DAYS days old, proceeding with download."
                ./downloader.sh "$@"
                OSM_FILE=$(find_osm_file)
            else
                info "File is only $DIFF_DAYS days old, using existing file."
            fi
        fi
    else
        info "File is from today, using existing file: $OSM_FILE"
    fi
fi

# Get the timestamp for the IK file
PLANET_TIMESTAMP=$(get_file_timestamp "$OSM_FILE")
OSM_IK_FILE="${OSM_DATA_DIR}/data_ik_${PLANET_TIMESTAMP}.osm.pbf"

# Extract france and spain from the OSM file if the OSM file is newer than the extracted file or if the extracted file doesn't exist
if [ ! -f "$OSM_IK_FILE" ]; then
    warning "Extracted file not found, proceeding to extract it."
    ./extractor.sh poly "$OSM_IK_FILE"
    OSM_IK_FILE="${OSM_DATA_DIR}/data_ik_*.osm.pbf"
else 
    info "Extracted file already exists: $OSM_IK_FILE"
    OSM_IK_FILE=$(find_extract_file)

fi

# Check if the original jar file exists
if [ ! -f "${jar_file}" ]; then
    critical "Jar file not found. This shouldn't happen. Exiting."
fi


CONFIG_FILE="/ors-config.yml"
echo "Using configuration file: ${CONFIG_FILE}"

yq -i e ".ors.engine.profiles.driving-car.build.source_file = \"${OSM_IK_FILE}\"" "${CONFIG_FILE}"
yq -i e ".ors.engine.profile_default.build.source_file = \"${OSM_IK_FILE}\"" "${CONFIG_FILE}"
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
CRON_SCHEDULE="${GRAPH_UPDATE_CRON:-* * * * *}"
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