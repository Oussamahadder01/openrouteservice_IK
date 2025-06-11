#!/usr/bin/env bash

# Source the original entrypoint functions
source /utils.sh

echo "################################"
echo "# ORS Container Setup #"
echo "################################"

set_log_level
jar_file=/ors.jar
REBUILD_GRAPHS=${REBUILD_GRAPHS:-"false"}
REBUILD_GRAPHS=$(echo "$REBUILD_GRAPHS" | tr '[:upper:]' '[:lower:]') # Convert to lowercase
#perform initial setup
initial_setup

# Fail if ORS_HOME env var is not set or if it is empty or set to /
if [ -z "${ORS_HOME}" ] || [ "${ORS_HOME}" = "/" ]; then
  critical "ORS_HOME is not set or empty or set to /. This is not allowed. Exiting."
fi

#sanity checks and file system prep
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

# Make sure ORS_HOME is a directory
if [ ! -d "${ORS_HOME}" ]; then
  critical "ORS_HOME: ${ORS_HOME} doesn't exist. Exiting."
elif [ ! -w "${ORS_HOME}" ]; then
  error "ORS_HOME: ${ORS_HOME} is not writable."
  error "Make sure the file permission of ${ORS_HOME} in your volume mount are set to $(id -u):$(id -g)."
  error "Under linux the command for a volume would be: sudo chown -R $(id -u):$(id -g) /path/to/ors/volume"
  critical "Exiting."
fi
success "ORS_HOME: ${ORS_HOME} exists and is writable."

mkdir -p "${ORS_HOME}"/{files,logs,graphs,elevation_cache,config} || warning "Could not create the default folders in ${ORS_HOME}: files, logs, graphs, elevation_cache, config"
debug "Populated ORS_HOME=${ORS_HOME} with the default folders: files, logs, graphs, elevation_cache, config"
# Check if the original jar file exists
if [ ! -f "${jar_file}" ]; then
  critical "Jar file not found. This shouldn't happen. Exiting."
fi

ors_engine_profile_default_graph_path=$(extract_config_info "${ors_config_location}" '.ors.engine.profile_default.graph_path')
ors_engine_profile_default_build_source_file=$(extract_config_info "${ors_config_location}" '.ors.engine.profile_default.build.source_file')

if [ -n "${ors_engine_profile_default_graph_path}" ]; then
  success "Using graphs folder ${ors_engine_profile_default_graph_path}"
else
  info "Default to graphs folder: ${ORS_HOME}/graphs"
  ors_engine_profile_default_graph_path="${ORS_HOME}/graphs"
fi

info "Any ENV variables will have precedence over configuration variables from config files."
success "All checks passed. For details set CONTAINER_LOG_LEVEL=DEBUG."

echo "#####################################"
echo "# Container file system preparation #"
echo "#####################################"
# Check if uid or gid is different from 1000
chown -R "$(whoami)" "${ORS_HOME}"; debug "Changed ownership of ${ORS_HOME} to $(whoami)" || warning "Could not change ownership of ${ORS_HOME} to $(whoami)"


# Remove existing graphs if BUILD_GRAPHS is set to true
if [ "${ors_rebuild_graphs}" = "true" ]; then
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
setup_cronjob

echo "#####################"
echo "# ORS startup phase #"
echo "#####################"
# Start the jar with the given arguments and add the ORS_HOME env var
success "🙭 Ready to start the ORS application 🙭"
debug "Startup command: java ${JAVA_OPTS} ${CATALINA_OPTS} -jar ${jar_file}"
# Export ORS_CONFIG_LOCATION to the environment of child processes
export ORS_CONFIG_LOCATION=${ors_config_location}
# shellcheck disable=SC2086 # we need word splitting here
exec java ${JAVA_OPTS} ${CATALINA_OPTS} -jar "${jar_file}" "$@"
# Setup cronjob for graph updates
