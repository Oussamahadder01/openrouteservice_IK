#!/bin/bash -ex

#########################################
# OSM Data Downloader for France + Spain
# Usage: ./downloader.sh [METHOD] [ORS_HOME]
# METHOD: bbox | merge (default: merge)
#########################################
source /utils.sh
# Configuration
METHOD=${1:-"poly"}  # bbox ou merge
ORS_HOME=${2:-"/efs/ors-run"}
BBOX=${BBOX:-"-10.03529,36.26156,8.195,51.14464"}  # France + Spain bounding box
OSM_DATA_DIR=/efs/osm 
OSM_FILE=${OSM_DATA_DIR}/europe-latest.osm.pbf
OSM_IK_FILE=${OSM_DATA_DIR}/data_IK.osm.pbf
OSM_URL=${OSM_URL:-"https://download.geofabrik.de/europe-latest.osm.pbf"}  # Default OSM URL
POLY_FILE=${POLY_FILE:-"/polygon_fr_esp.poly"}  # Default polygon file path


#download planet OSM data
if [ ! -f "${OSM_FILE}" ]; then
info "Downloading planet OSM data from ${OSM_URL}"
info "This may take 30-60 minutes depending on your connection..."
wget --progress=bar:force:noscroll -O "${OSM_FILE}" "${OSM_URL}" || critical "Failed to download planet PBF file"
success "Downloaded planet PBF file ($(du -h "${OSM_FILE}" | cut -f1))"
else
info "planet PBF file already exists, using cached version"
fi

#function to extract IK zone data including France and Spain using bounding box, bounding box can be retrieved using openstreetmap tools.
function download_with_bbox() {
  info "Using BBOX method: downloading planet and extracting France + Spain"
  warning "This method downloads ~30GB temporarily!"
  info "Extracting France + Spain using bbox: ${BBOX}"
  info "This process may take 10-30 minutes..."
  info "current directory: $(pwd)"
  local start_time=$(date +%s)
  
  osmium extract -b ${BBOX} ${OSM_FILE} -O ${OSM_IK_FILE} || critical "Failed to extract France + Spain from planet PBF file"
  #calculate download time
  local end_time=$(date +%s)
  local elapsed=$((end_time - start_time))
  local elapsed_formatted=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))
  
  success "Successfully extracted France + Spain to ${OSM_IK_FILE} ($(du -h "${OSM_IK_FILE}" | cut -f1)) in ${elapsed_formatted}"
  if [ -f "${OSM_IK_FILE}" ]; then
    local final_size=$(du -h "${OSM_IK_FILE}" | cut -f1)
    success "Final France + Spain file size: ${final_size}"
  fi
}

#function to extract IK zone data from provided polygon, polygon file can be downloaded from overpass turbo or other sources.
function download_with_polygon() {
    info "Using Polygon method: downloading France + Spain with polygon"
    warning "This method downloads ~6GB temporarily!"
    local start_time=$(date +%s)
    if [ ! -f "${OSM_IK_FILE}" ] && [ -f "${POLY_FILE}" ]; then
        info "Downloading France + Spain OSM data from ${OSM_URL}"
        info "This may take 10-30 minutes depending on your connection..."
        osmium extract -p ${POLY_FILE} ${OSM_FILE} -O -o ${OSM_IK_FILE} || critical "Failed to download France + Spain PBF file using polygon"
        #calculate download time
        local end_time=$(date +%s)
        local elapsed=$((end_time - start_time))
        local elapsed_formatted=$(printf '%02d:%02d:%02d' $((elapsed/3600)) $((elapsed%3600/60)) $((elapsed%60)))
        success "Successfully extracted France + Spain to ${OSM_IK_FILE} ($(du -h "${OSM_IK_FILE}" | cut -f1)) in ${elapsed_formatted}"
    else
        if [ ! -f "${POLY_FILE}" ]; then
            critical "Polygon file not found: ${POLY_FILE}"
        else
            critical "France + Spain PBF file already exists, using cached version"
        fi
    fi
}


function main() {
  echo "========================================="
  echo "🗺️  OSM Data Downloader for France + Spain"
  echo "========================================="
  echo "Method: ${METHOD}"
  echo "Target: ${OSM_DATA_DIR}/data_IK.osm.pbf"
  echo "========================================="

#verify if extracted osm file (spain + france) already exists
if [ -f "${OSM_IK_FILE}" ]; then
  local existing_size=$(du -h "${OSM_IK_FILE}" | cut -f1)
  warning "France + Spain PBF file already exists: ${OSM_IK_FILE} (${existing_size})"
  # read -p "Do you want to recreate it? (Y/n): " -t 10 -n 1 -r
  # echo
  # if [ $? -eq 142 ] || [ -z "$REPLY" ]; then
  #   info "No response received, defaulting to Yes."
  #   REPLY="y"
  # fi
  # if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  #       info "Keeping existing file. Skipping download."
  #       return 1  # Return 1 to indicate "no action taken"
  #   fi
  # rm -f "${OSM_IK_FILE}"
  return 1
fi

#execute choosen method
  case ${METHOD} in
    "bbox")
      download_with_bbox
      ;;
    "poly")
      download_with_polygon
      ;;
    *)
      error "Unknown method: ${METHOD}"
      echo "Usage: $0 [bbox|poly] [ORS_HOME]"
      echo "  bbox:  Download planet and extract with bounding box"
      echo "  poly: Download planet and extract with polygon)"
      exit 1
      ;;
  esac

  success "OSM data processing completed successfully!"
}
# Run the main function
main "$@"