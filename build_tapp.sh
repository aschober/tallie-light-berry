#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_FILE="$SCRIPT_DIR/manifest.json"
BUILD_DIR="$SCRIPT_DIR/build"

# Cross-platform in-place sed for macOS (BSD sed) and Linux (GNU sed)
sed_in_place() {
  local file="${@: -1}"
  local args=("${@:1:$#-1}")
  local e_args=()
  for arg in "${args[@]}"; do e_args+=(-e "$arg"); done
  if sed --version >/dev/null 2>&1; then
    sed -i "${e_args[@]}" "$file"
  else
    sed -i '' "${e_args[@]}" "$file"
  fi
}

# Source files to copy into build/ before packaging
SOURCE_FILES=(
  "manifest.json"
  "src/autoexec.be"
  "src/oauth.be"
  "src/oa_service.be"
  "src/tallielight.be"
  "src/tl_scoreboard_event.be"
  "src/tl_config.be"
  "src/tl_saved_light.be"
  "src/tl_run_state.be"
  "src/tl_light_controller.be"
  "src/tl_service.be"
  "src/tallielight_ui.be"
)

# Berry files to strip comments/blank lines from (paths relative to build/)
STRIP_FILES=(
  "oauth.be"
  "oa_service.be"
  "tallielight.be"
  "tl_scoreboard_event.be"
  "tl_config.be"
  "tl_saved_light.be"
  "tl_run_state.be"
  "tl_light_controller.be"
  "tl_service.be"
  "tallielight_ui.be"
)

# Files expected in build/ after prepare_build_dir + minify_html + generate_env
EXPECTED_BUILD_FILES=(
  "manifest.json"
  "autoexec.be"
  "oauth.be"
  "oa_service.be"
  "tallielight.be"
  "tl_scoreboard_event.be"
  "tl_config.be"
  "tl_saved_light.be"
  "tl_run_state.be"
  "tl_light_controller.be"
  "tl_service.be"
  "tallielight_ui.be"
  "tallielight_env.be"
  "tallielight_ui_min.html"
)

# Show usage
show_help() {
  echo "Usage: $0 [VERSION] [dev|prod]"
  echo "Packages TallieLight as a Tasmota Extension (.tapp)"
  echo ""
  echo "Arguments:"
  echo "  VERSION    Optional. Semantic version (e.g., 1.2.0) to update manifest."
  echo "             If not provided, uses existing version from manifest.json"
  echo "  ENV        Optional. Target environment: dev or prod (default: dev)"
  echo ""
  echo "Examples:"
  echo "  $0              # Build dev using existing version"
  echo "  $0 1.2.0        # Build dev, update manifest to v1.2.0"
  echo "  $0 1.2.0 prod   # Build prod, update manifest to v1.2.0"
  echo "  $0 prod         # Build prod using existing version"
}

# Convert semantic version to Tasmota hex format
# 1.2.3 -> 0x01020300
version_to_hex() {
  local version="$1"
  IFS='.' read -ra parts <<< "$version"

  # Pad to 4 parts
  while [[ ${#parts[@]} -lt 4 ]]; do
    parts+=("0")
  done

  printf "0x%02X%02X%02X%02X" "${parts[0]}" "${parts[1]}" "${parts[2]}" "${parts[3]}"
}

# Read version from manifest.json
read_version() {
  grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$MANIFEST_FILE" | \
    sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/'
}

# Update version in manifest.json
update_version() {
  local new_version="$1"
  local hex_version
  hex_version=$(version_to_hex "$new_version")

  sed_in_place "s/\"version\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"version\": \"$hex_version\"/" "$MANIFEST_FILE"
  echo "Updated manifest.json to version $new_version ($hex_version)"
}

# Copy source files into build/
prepare_build_dir() {
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  for file in "${SOURCE_FILES[@]}"; do
    cp "$SCRIPT_DIR/$file" "$BUILD_DIR/$(basename "$file")"
  done
}

# Generate build/tallielight_env.be from environment variables or a .env file.
# Environment variables take precedence; .env file is the fallback.
# Reads the known keys in order: OAUTH_DOMAIN, OAUTH_CLIENT_ID, BACKEND_URL.
generate_env() {
  local known_keys="OAUTH_DOMAIN OAUTH_CLIENT_ID BACKEND_URL"
  local source_desc="env vars"
  [[ -f "$ENV_FILE" ]] && source_desc="${ENV}.env (with env var overrides)"
  echo "Generating tallielight_env.be from ${source_desc}..."
  {
    echo "var tallielight_env = module(\"tallielight_env\")"
    for key in $known_keys; do
      local value=""
      # Prefer environment variable
      if [[ -n "${!key+x}" ]]; then
        value="${!key}"
      elif [[ -f "$ENV_FILE" ]]; then
        # Fall back to .env file
        value=$(grep "^${key}=" "$ENV_FILE" | cut -d'=' -f2-)
      fi
      if [[ -n "$value" ]]; then
        echo "tallielight_env.${key} = \"${value}\""
      fi
    done
    echo "return tallielight_env"
  } > "$BUILD_DIR/tallielight_env.be"
}

# Minify HTML into build/
minify_html() {
  echo "Minifying src/tallielight_ui.html..."
  minify --html-keep-whitespace \
    -o "$BUILD_DIR/tallielight_ui_min.html" \
    "$SCRIPT_DIR/src/tallielight_ui.html"
}

# Strip single-line # comments, blank lines, and print statements from Berry files in build/
strip_berry() {
  echo "Stripping Berry files (comments, blank lines, print statements)..."
  local total_before=0
  local total_after=0
  for file in "${STRIP_FILES[@]}"; do
    local path="$BUILD_DIR/$file"
    local before
    before=$(wc -c < "$path")
    total_before=$((total_before + before))
    # Remove single-line # comments (but NOT #- block comment delimiters) and blank lines
    sed_in_place '/^[[:space:]]*#[^-]/d; /^[[:space:]]*$/d' "$path"
    # Remove print(...) statements — accumulate continuation lines until closing ), then delete
    sed_in_place '/^[[:space:]]*print(/{' ':l' '/)$/!{' 'N' 'bl' '}' 'd' '}' "$path"
    local after
    after=$(wc -c < "$path")
    total_after=$((total_after + after))
  done
  echo "Stripped $((total_before - total_after)) bytes from Berry files"
}

# Validate all expected files are present in build/
validate_files() {
  local missing=0
  for file in "${EXPECTED_BUILD_FILES[@]}"; do
    if [[ ! -f "$BUILD_DIR/$file" ]]; then
      echo "ERROR: Missing required file in build/: $file"
      missing=1
    fi
  done
  if [[ $missing -eq 1 ]]; then exit 1; fi
  echo "All ${#EXPECTED_BUILD_FILES[@]} required files present in build/"
}

# Create the .tapp archive from build/
create_tapp() {
  rm -f "$OUTPUT_FILE"
  cd "$BUILD_DIR"
  zip -j -0 "$OUTPUT_FILE" ./*
  cd "$SCRIPT_DIR"
}

# Main
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
  show_help
  exit 0
fi

echo "Tallie Light TAPP Builder"
echo "========================="

# Parse arguments: optional VERSION and optional ENV (dev|prod)
ENV="dev"
VERSION_ARG=""

for arg in "$@"; do
  if [[ "$arg" == "dev" || "$arg" == "prod" ]]; then
    ENV="$arg"
  else
    VERSION_ARG="$arg"
  fi
done

ENV_FILE="$SCRIPT_DIR/${ENV}.env"
# Require either a .env file or all three env vars to be set
if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -z "${OAUTH_DOMAIN+x}" || -z "${OAUTH_CLIENT_ID+x}" || -z "${BACKEND_URL+x}" ]]; then
    echo "ERROR: Missing env file '${ENV}.env' and env vars OAUTH_DOMAIN, OAUTH_CLIENT_ID, BACKEND_URL are not all set"
    exit 1
  fi
  echo "No ${ENV}.env file found — using environment variables"
fi

OUTPUT_FILE="$SCRIPT_DIR/TallieLight-${ENV}.tapp"
echo "Environment: $ENV"

# If version argument provided, update manifest
if [[ -n "$VERSION_ARG" ]]; then
  update_version "$VERSION_ARG"
fi

prepare_build_dir
minify_html
generate_env
strip_berry
validate_files
create_tapp

VERSION=$(read_version)
SIZE=$(ls -lh "$OUTPUT_FILE" | awk '{print $5}')
echo ""
echo "Created: $OUTPUT_FILE"
echo "Version: $VERSION"
echo "Size: $SIZE"
