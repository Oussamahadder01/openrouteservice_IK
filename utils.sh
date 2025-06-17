#!/usr/bin/env bash

########################
# Set Helper functions #
########################
CONTAINER_LOG_LEVEL=${CONTAINER_LOG_LEVEL:-"INFO"}
#common environment variables, write it here to include it in the cron job
OSM_DATA_DIR=/efs/data 
LOG_DIR="/efs/logs/ors_ik"
export OSM_UPDATE_MARKER="${OSM_DATA_DIR}/.osm_data_ready"


#extraction variables
BBOX=${BBOX:-"-10.03529,36.26156,8.195,51.14464"}  # France + Spain bounding box
POLY_FILE=${POLY_FILE:-"/polygon_fr_esp.poly"}  # Default polygon file path


# Success message in green. Always printed
function success() {
  echo -e "\e[32m✓ $1\e[0m"
  return 0
}
# Critical message in bold red and exit. Always printed
function critical() {
  echo -e "\e[1;31m $1\e[0m"
  exit 1
}
function critical_0() {
  echo -e "\e[1;31m $1\e[0m"
  exit 0
}
# Error message in red.
function error() {
  echo -e "\e[31m✗ $1\e[0m"
  return 0
}
# Warning message in yellow
function warning() {
  if [ "${container_log_level_int}" -le 30 ]; then
    echo -e "\e[33m⚠ $1\e[0m"
  fi
  return 0
}
# Info message in blue
function info() {
  if [ "${container_log_level_int}" -le 20 ]; then
    echo -e "\e[34mⓘ $1\e[0m"
  fi
  return 0
}

# Debug message in cyan
function debug() {
  if [ "${container_log_level_int}" -le 10 ]; then
    echo -e "\e[36m▢ $1\e[0m"
  fi
  return 0
}
function set_log_level() {
  case ${CONTAINER_LOG_LEVEL} in
  "DEBUG")
    container_log_level_int=10
    ;;
  "INFO")
    container_log_level_int=20
    ;;
  "WARN")
    container_log_level_int=30
    ;;
  "ERROR")
    container_log_level_int=40
    ;;
  "CRITICAL")
    container_log_level_int=50
    ;;
  *)
    debug "No matching log level found: ${CONTAINER_LOG_LEVEL}."
    debug "Defaulting to INFO."
    CONTAINER_LOG_LEVEL="INFO"
    container_log_level_int=20
    ;;
  esac
  success "CONTAINER_LOG_LEVEL: ${CONTAINER_LOG_LEVEL}. Set CONTAINER_LOG_LEVEL=DEBUG for more details."
}


update_file() {
  local target_file_path="$1"
  local original_file_path="$2"

  if [ ! -f "${target_file_path}" ] || ! cmp -s "${original_file_path}" "${target_file_path}"; then
    success "Update the file ${target_file_path} with ${original_file_path}"
    cp -f "${original_file_path}" "${target_file_path}" || warning "Could not copy ${original_file_path} to ${target_file_path}"
  else
    success "The file ${target_file_path} is up to date"
  fi
}

extract_config_info() {
  local config_location="$1"
  local config_variable="$2"
  local config_value=""
  if [[ "${config_location}" = *.yml ]]; then
    config_value=$(yq -r "${config_variable}" "${config_location}")
  fi
  # Validate the config value
  if [ -z "${config_value}" ] || [ "${config_value}" = null ]; then
    config_value=""
  fi
  # Return the value
  echo "${config_value}"
}

# Initial setup function
initial_setup() {
    info "Performing initial setup"
    
    # Set up EFS directories
    RUNTIME_DIR="/efs/ors-run"
    mkdir -p "${RUNTIME_DIR}"/{graphs,logs,config,files,elevation_cache}
    
    # Check if this is first run (no graphs exist)
    if [ ! -d "${RUNTIME_DIR}/graphs" ] || [ -z "$(ls -A "${RUNTIME_DIR}/graphs" 2>/dev/null)" ]; then
        info "First run detected - building initial graphs"
        
        export ORS_HOME="${RUNTIME_DIR}"
        
        update_file "${RUNTIME_DIR}/config/ors-config.yml" "/ors-config.yml"
        
        export REBUILD_GRAPHS="true"
        
        success "Initial setup completed"
        return 0
    else
        info "Existing graphs found, using runtime directory"
        export ORS_HOME="${RUNTIME_DIR}"
        return 0
    fi
}

# Health check with retry logic
wait_for_health() {
    local max_retries=${1:-60}
    local retry_interval=${2:-5}
    local retries=0
    
    info "Waiting for service to become healthy..."
    
    while [ ${retries} -lt ${max_retries} ]; do
        if wget --quiet --tries=1 --spider "http://localhost:8082/ors/v2/health" 2>/dev/null; then
            success "Service is healthy and ready"
            return 0
        fi
        
        retries=$((retries + 1))
        info "Health check ${retries}/${max_retries} failed, retrying in ${retry_interval}s..."
        sleep ${retry_interval}
    done
    
    critical "Service failed to become healthy after ${max_retries} attempts"
}

function cleanup() {
    rm -f "${LOCK_FILE}"
    if [ "$1" = 0 ]; then
        critical_0 "Exiting with code 0"
    else
        critical "Exiting with code $1"
    fi
}

# Cronjob setup function
setup_cronjob() {
    info "Setting up graph update cronjob"
    
    # Create cron job (runs every Sunday at 2 AM)
    CRON_SCHEDULE="${GRAPH_UPDATE_CRON:-* * * * *}"
    echo "${CRON_SCHEDULE} /updater.sh >> /var/log/updater.log 2>&1" | crontab -
    
    # Start cron daemon
    cronx
    success "Cronjob configured to run: ${CRON_SCHEDULE}"
}

find_osm_file() {
    local pattern="${OSM_DATA_DIR}/planet_*"
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
    local pattern="${OSM_DATA_DIR}/data_ik_*"
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

set_log_level
