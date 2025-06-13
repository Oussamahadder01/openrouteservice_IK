#!/bin/bash -ex

#########################################
# OSM Data Extractor for France + Spain
# Usage: ./extractor.sh [METHOD] [TARGET_FILE]
# METHOD: bbox | poly (default: poly)
#########################################
source /utils.sh

# Configuration
METHOD=${1:-"poly"}  # bbox or poly
TARGET_FILE=$2

#function to get file timestamp (modification date in DDMMYYYY format)
get_file_timestamp() {
    local file_path="$1"
    if [ -f "${file_path}" ]; then
        date -r "${file_path}" +"%d%m%Y"
    else
        echo ""
    fi
}

#retrieve timestamp for log file (DDMMYYYY format)
TIMESTAMP=$(get_file_timestamp "${TARGET_FILE}")
EXTRACTOR_LOG="${LOG_DIR}/extractor-ors_${TIMESTAMP}.log"

mkdir -p "${LOG_DIR}"

#redirect all output to log file
exec 1> >(tee -a "${EXTRACTOR_LOG}")
exec 2> >(tee -a "${EXTRACTOR_LOG}" >&2)

#determine target file
if [ -n "${TARGET_FILE}" ]; then
    OSM_IK_FILE="${TARGET_FILE}"
elif [ -n "${OSM_IK_FILE}" ]; then
    # Use from environment (set by updater.sh)
    OSM_IK_FILE="${OSM_IK_FILE}"
else
    # Default timestamped filename
    critical "No target file specified. Please provide a target file as the second argument or set OSM_IK_FILE environment variable."
fi

#function to cleanup old extracted files
function cleanup_old_extractions() {
  info "Cleaning up old extracted OSM files..."
  
  # Get the directory and base pattern from the current file
  local target_dir=$(dirname "${OSM_IK_FILE}")
  local base_name=$(basename "${OSM_IK_FILE}" | sed 's/_[0-9]\{8\}\.osm\.pbf$//')
  
  # Find all files matching the pattern except the current one
  local old_files=$(find "${target_dir}" -name "${base_name}_*.osm.pbf" -not -name "$(basename ${OSM_IK_FILE})" -type f)
  
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

#function to extract using bounding box, to use only if polygon extraction is not available and not possible.
function extract_with_bbox() {
  info "Using BBOX method: extracting France + Spain from planet file"
  info "Extracting France + Spain using bbox: ${BBOX}"
  info "Source: ${OSM_FILE}"
  info "Target: ${OSM_IK_FILE}"
  info "This process may take 10-30 minutes..."
  
  local start_time=$(date +%s)
  
  # Extract to temporary file first
  local temp_file="${OSM_IK_FILE}.tmp"
  if osmium extract -b ${BBOX} ${OSM_FILE} -O ${temp_file}; then
    # Move temp file to final location only if extraction succeeded
    mv "${temp_file}" "${OSM_IK_FILE}"
    
    # Calculate extraction time
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    local elapsed_formatted=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))
    
    success "Successfully extracted France + Spain to ${OSM_IK_FILE} ($(du -h "${OSM_IK_FILE}" | cut -f1)) in ${elapsed_formatted}"
    
    # Cleanup old files after successful extraction
    cleanup_old_extractions
  else
    # Remove temp file if extraction failed
    rm -f "${temp_file}"
    critical "Failed to extract France + Spain from planet PBF file"
  fi
}

#function to extract using polygon. the polygon should be a .poly file that contains the coordinates of the area to extract.
#geojson format is not correctly supported by osmium in the case of multypolygons, so we use the .poly format.
#HINT : use convert_geo_poly.py to convert a geojson file to a .poly file.
function extract_with_polygon() {
  info "Using Polygon method: extracting France + Spain from planet file"
  info "Source: ${OSM_FILE}"
  info "Target: ${OSM_IK_FILE}"
  info "Polygon: ${POLY_FILE}"
  
  local start_time=$(date +%s)
  
  if [ -f "${POLY_FILE}" ]; then
    info "Extracting France + Spain OSM data to ${OSM_IK_FILE}"
    info "This may take 10-30 minutes depending on your connection..."
    
    # Extract to temporary file first
    local temp_file="${OSM_IK_FILE}.tmp"
    if osmium extract -p ${POLY_FILE} ${OSM_FILE} -O -o ${temp_file}; then
      # Move temp file to final location only if extraction succeeded
      mv "${temp_file}" "${OSM_IK_FILE}"
      
      # Calculate extraction time
      local end_time=$(date +%s)
      local elapsed=$((end_time - start_time))
      local elapsed_formatted=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))
      
      success "Successfully extracted France + Spain to ${OSM_IK_FILE} ($(du -h "${OSM_IK_FILE}" | cut -f1)) in ${elapsed_formatted}"
      
      # Cleanup old files after successful extraction
      cleanup_old_extractions
    else
      # Remove temp file if extraction failed
      rm -f "${temp_file}"
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
  echo "Target: ${OSM_IK_FILE}"
  echo "Timestamp: ${TIMESTAMP}"
  echo "Log file: ${EXTRACTOR_LOG}"
  echo "========================================="

  #check if source planet file exists
  if [ ! -f "${OSM_FILE}" ]; then
    warning "Planet PBF file not found: ${OSM_FILE}. proceeding with download."
    info "Downloading planet PBF file from ${OSM_URL} to ${OSM_FILE}"
    /downloader.sh "${OSM_URL}" || critical "Failed to download planet PBF file"
  else
    info "Planet PBF file found: ${OSM_FILE}"
    local existing_size=$(du -h "${OSM_FILE}" | cut -f1)
    info "Using existing planet PBF file: ${OSM_FILE} (${existing_size})"
    info "Skipping download as file already exists"
    info "Extraction will proceed with existing file"
  fi

  #check if the specific target file already exists
  if [ -f "${OSM_IK_FILE}" ]; then
    local existing_size=$(du -h "${OSM_IK_FILE}" | cut -f1)
    warning "Target PBF file already exists: ${OSM_IK_FILE} (${existing_size})"
    info "Skipping extraction as file already exists"
    success "Extraction process completed at: $(date)"
    success "Log saved to: ${EXTRACTOR_LOG}"
    return 0
  fi

  #create target directory if it doesn't exist
  mkdir -p "$(dirname "${OSM_IK_FILE}")" || critical "Failed to create target directory"

  #execute chosen extraction method
  case ${METHOD} in
    "bbox")
      extract_with_bbox
      ;;
    "poly")
      extract_with_polygon
      ;;
    *)
      error "Unknown method: ${METHOD}"
      echo "Usage: $0 [bbox|poly] [TARGET_FILE]"
      echo "  bbox:  Extract using bounding box"
      echo "  poly:  Extract using polygon file"
      exit 1
      ;;
  esac

  success "OSM data extraction completed successfully at: $(date)"
  success "Created file: ${OSM_IK_FILE}"
  success "Log saved to: ${EXTRACTOR_LOG}"
}

#run the main function
main "$@"