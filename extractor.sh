#!/bin/bash 

#########################################
# OSM Data Extractor for France + Spain
# Usage: ./extractor.sh [METHOD] [TARGET_FILE]
# METHOD: bbox | poly (default: poly)
#########################################
source /utils.sh
export OSM_DATA_DIR="/efs/data"
export OSM_URL=https://download.geofabrik.de/europe-latest.osm.pbf
export LOGS_DIR="/efs/logs/ors_ik"

OSM_FILE=$(find_osm_file)

TARGET_FILE=$1

#retrieve timestamp for log file (DDMMYYYY format)
TIMESTAMP=$(get_file_timestamp "${TARGET_FILE}")
EXTRACTOR_LOG="${LOGS_DIR}/extractor-ors_${TIMESTAMP}.log"
mkdir -p "${LOGS_DIR}"

#redirect all output to log file
exec 1> >(tee -a "${EXTRACTOR_LOG}")
exec 2> >(tee -a "${EXTRACTOR_LOG}" >&2)

# Check if OSM_FILE is set
if [ -z "${OSM_FILE}" ]; then
    critical "OSM file not found. Please ensure the entrypoint has run successfully."
fi

#function to cleanup old extracted files
function cleanup_old_extractions() {
  info "Cleaning up old extracted OSM files..."
  
  # Get the directory and base pattern from the current file
  local target_dir=$(dirname "${TARGET_FILE}")
  local base_name=$(basename "${TARGET_FILE}" | sed 's/_[0-9]\{8\}\.osm\.pbf$//')
  
  # Find all files matching the pattern except the current one
  local old_files=$(find "${target_dir}" -name "${base_name}_*.osm.pbf" -not -name "$(basename ${TARGET_FILE})" -type f)
  
  if [ -n "$old_files" ]; then
    echo "$old_files" | while read -r file; do
      if [ -f "$file" ]; then
        local file_size=$(du -h "$file" | cut -f1)
        info "Removing old extraction: $file (${file_size})"
        rm -f "$file" || warning "Failed to remove: $file"
      fi
    done
    success "Cleanup of old extractions completed"
  else
    info "No old extracted files found to clean up"
  fi
}


#function to extract using polygon. the polygon should be a .poly file that contains the coordinates of the area to extract.
#geojson format is not correctly supported by osmium in the case of multypolygons, so we use the .poly format.
#HINT : use convert_geo_poly.py to convert a geojson file to a .poly file.
function extract_with_polygon() {
  info "Using Polygon method: extracting France + Spain from planet file"
  info "Source: ${OSM_FILE}"
  info "Target: ${TARGET_FILE}"
  info "Polygon: ${POLY_FILE}"
  
  local start_time=$(date +%s)
  
  if [ -f "${POLY_FILE}" ]; then
    info "Extracting France + Spain OSM data to ${TARGET_FILE}"
    info "This may take 10-30 minutes depending on your connection..."
    
    if osmium extract -p ${POLY_FILE} ${OSM_FILE} -O -o ${TARGET_FILE}; then
      
      # Calculate extraction time
      local end_time=$(date +%s)
      local elapsed=$((end_time - start_time))
      local elapsed_formatted=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))
      
      success "Successfully extracted France + Spain to ${TARGET_FILE} ($(du -h "${TARGET_FILE}" | cut -f1)) in ${elapsed_formatted}"
      cleanup_old_extractions
    else
      critical "Failed to extract France + Spain PBF file using polygon"
    fi
  else
    critical "Polygon file not found: ${POLY_FILE}"
  fi
}

function main() {
  echo "========================================="
  echo "🗺️  OSM Data Extractor for France + Spain"
  echo "========================================="
  echo "Started at: $(date)"
  echo "Method: ${METHOD}"
  echo "Source: ${OSM_FILE}"
  echo "Target: ${TARGET_FILE}"
  echo "Timestamp: ${TIMESTAMP}"
  echo "Log file: ${EXTRACTOR_LOG}"
  echo "========================================="

  #check if the specific target file already exists
  if [ -f "${TARGET_FILE}" ]; then
    local existing_size=$(du -h "${TARGET_FILE}" | cut -f1)
    warning "Target PBF file already exists: ${TARGET_FILE} (${existing_size})"
    info "Skipping extraction as file already exists"
    success "Extraction process completed at: $(date)"
    success "Log saved to: ${EXTRACTOR_LOG}"
    return 0
  fi

  #create target directory if it doesn't exist
  mkdir -p "$(dirname "${TARGET_FILE}")" || critical "Failed to create target directory"

  extract_with_polygon || critical "Failed to extract OSM data with polygon method"
  success "OSM data extraction completed successfully at: $(date)"
  success "Created file: ${TARGET_FILE}"
  success "Log saved to: ${EXTRACTOR_LOG}"
}
  #clean old extraction logs 
find "${LOGS_DIR}" -name "extractor-ors_*.log" -type f -mtime +7 -exec rm -f {} \; || warning "Failed to clean up old extraction logs"

#run the main function
main "$@"