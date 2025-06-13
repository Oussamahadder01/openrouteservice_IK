#!/bin/bash -ex

#########################################
# OSM Planet Data Downloader
# Usage: ./downloader.sh [OSM_URL]
#########################################
source /utils.sh

# Configuration

# Generate timestamp for log file (DDMMYYYY format)
TIMESTAMP=$(date +"%d%m%Y")
LOG_DIR="/efs/logs/ors_ik"
DOWNLOAD_LOG="${LOG_DIR}/downloader-ors_${TIMESTAMP}.log"
OSM_FILE="${OSM_DATA_DIR}/planet_${TIMESTAMP}.osm.pbf"

# Create log directory if it doesn't exist
mkdir -p "${LOG_DIR}"
mkdir -p "${OSM_DATA_DIR}"

# Redirect all output to log file
exec 1> >(tee -a "${DOWNLOAD_LOG}")
exec 2> >(tee -a "${DOWNLOAD_LOG}" >&2)

function cleanup_old_files() {
  info "Cleaning up old planet OSM files..."
  
  # Find all planet_*.osm.pbf files except the current one
  local old_files=$(find "${OSM_DATA_DIR}" -name "planet_*.osm.pbf" -not -name "$(basename ${OSM_FILE})" -type f)
  
  if [ -n "$old_files" ]; then
    echo "$old_files" | while read -r file; do
      if [ -f "$file" ]; then
        local file_size=$(du -h "$file" | cut -f1)
        info "Removing old file: $file (${file_size})"
        rm -f "$file" || warning "Failed to remove: $file"
      fi
    done
    success "Cleanup completed"
  else
    info "No old planet files found to clean up"
  fi
}

function download_planet() {
  echo "========================================="
  echo "🌍 OSM Planet Data Downloader"
  echo "========================================="
  echo "Started at: $(date)"
  echo "Source URL: ${OSM_URL}"
  echo "Target: ${OSM_FILE}"
  echo "Log file: ${DOWNLOAD_LOG}"
  echo "========================================="

  # Create OSM data directory if it doesn't exist

  # Download planet OSM data
  if [ ! -f "${OSM_FILE}" ]; then
    info "Downloading planet OSM data from ${OSM_URL}"
    info "This may take 30-60 minutes depending on your connection..."
    
    local start_time=$(date +%s)
    
    # Download to a temporary file first
    local temp_file="${OSM_FILE}.tmp"
    if wget --progress=bar:force:noscroll -O "${temp_file}" "${OSM_URL}"; then
      # Move the temp file to final location only if download succeeded
      mv "${temp_file}" "${OSM_FILE}"
      
      local end_time=$(date +%s)
      local elapsed=$((end_time - start_time))
      local elapsed_formatted=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))
      
      success "Downloaded planet PBF file ($(du -h "${OSM_FILE}" | cut -f1)) in ${elapsed_formatted}"
      
      # Cleanup old files after successful download
      cleanup_old_files
    else
      # Remove temp file if download failed
      rm -f "${temp_file}"
      critical "Failed to download planet PBF file"
    fi
  else
    local existing_size=$(du -h "${OSM_FILE}" | cut -f1)
    info "Planet PBF file already exists: ${OSM_FILE} (${existing_size})"
    info "Skipping download"
  fi

  success "Planet download process completed at: $(date)"
  success "Log saved to: ${DOWNLOAD_LOG}"
}

# Run the download function
download_planet "$@"