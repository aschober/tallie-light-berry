#!/bin/bash

# Version bump helper for sports-lamp-berry.
#
# Versioning model:
#   - Release tags are always vA.B.C.0, created by this script
#   - CI derives snapshot build numbers by counting commits since the last .0 tag;
#     the in-file build component is ignored for non-release builds
#   - The next --patch/--minor/--major release bumps the appropriate component and
#     resets build to .0
#
# What this script does:
# - updates version in manifest.json, src/oa_service.be, and src/tl_service.be
# - creates a release commit and semantic tag (vA.B.C.D)
#
# Typical usage:
# - release now:   --patch / --minor / --major
# - preview only:  --dry-run

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Terminal colors for status output.
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Print usage help and exit.
show_usage() {
  cat <<EOF
Usage: $0 [options] [new-version]

Options:
  --major              Bump major version (e.g., 0x01020100 -> 0x02000000)
  --minor              Bump minor version (e.g., 0x01020100 -> 0x01030000)
  --patch              Bump patch version (e.g., 0x01020100 -> 0x01020200)
  --dry-run            Show what would happen without making changes
  --no-commit          Update files only; skip the git commit and tag
  -h, --help           Show this help

Arguments:
  new-version          Version in semantic format (e.g., v1.2.1.0)
                       or hex format (e.g., 0x01020100)
                       Ignored if a bump flag is provided

Examples:
  $0 --patch --dry-run
    Preview a patch release (no files changed, no commit, no tag)

  $0 --patch
    Release patch: bump patch, reset build to .0, create commit and tag
    Example: v1.2.1.5 -> release v1.2.2.0

  $0
    Interactive mode (prompts for semantic or hex version)

Version Format:
  Internal: 0x[MAJOR][MINOR][PATCH][BUILD] where each component is 2 hex digits
  Example: 0x01020100 = major.1 minor.2 patch.1 build.0

  Git Tag: v[MAJOR].[MINOR].[PATCH].[BUILD] (semantic versioning)
  Example: v1.2.1.0

Environment:
  The script updates:
    - manifest.json (version field)
    - src/oa_service.be (static VERSION)
    - src/tl_service.be (static VERSION)

  Then creates a commit and git tag (in semantic version format).
EOF
  exit "$1"
}

# Get current version from manifest
get_current_version() {
  grep '"version"' "$SCRIPT_DIR/manifest.json" | sed -E 's/.*"version": "([^"]+)".*/\1/'
}

# Validate hex version format
validate_hex_version() {
  if [[ ! $1 =~ ^0x[0-9A-Fa-f]{8}$ ]]; then
    echo -e "${RED}Invalid version format: $1${NC}" >&2
    echo "Expected format: 0xHHHHHHHH (8 hex digits)" >&2
    exit 1
  fi
}

# Parse hex version into components (major, minor, patch, build)
parse_version() {
  local version=$1
  # Remove 0x prefix and convert to uppercase (portable for older bash)
  version="${version#0x}"
  version=$(echo "$version" | tr 'a-z' 'A-Z')

  local major=$(echo "$version" | cut -c1-2)
  local minor=$(echo "$version" | cut -c3-4)
  local patch=$(echo "$version" | cut -c5-6)
  local build=$(echo "$version" | cut -c7-8)

  echo "$major $minor $patch $build"
}

# Reconstruct hex version from components
format_version() {
  local major=$1
  local minor=$2
  local patch=$3
  local build=$4

  # Pad with zeros and format as hex
  printf "0x%02X%02X%02X%02X" "$major" "$minor" "$patch" "$build"
}

# Convert hex version to semantic version (vA.B.C.D)
hex_to_semver() {
  local hex_version=$1
  read -r major minor patch build <<< "$(parse_version "$hex_version")"
  major=$((16#$major))
  minor=$((16#$minor))
  patch=$((16#$patch))
  build=$((16#$build))
  printf "v%d.%d.%d.%d" "$major" "$minor" "$patch" "$build"
}

# Convert semantic version (vA.B.C.D) to hex version
semver_to_hex() {
  local semver=$1
  # Remove 'v' prefix and split by dots
  semver="${semver#v}"
  local IFS='.'
  read -r major minor patch build <<< "$semver"
  format_version "${major:-0}" "${minor:-0}" "${patch:-0}" "${build:-0}"
}

# Validate semantic version format and component range (0-255)
validate_semver() {
  local semver=$1
  if [[ ! $semver =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo -e "${RED}Invalid version format: $semver${NC}" >&2
    echo "Expected format: vA.B.C.D (e.g., v1.2.1.5)" >&2
    exit 1
  fi

  local major minor patch build
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  patch="${BASH_REMATCH[3]}"
  build="${BASH_REMATCH[4]}"

  for n in "$major" "$minor" "$patch" "$build"; do
    if (( n < 0 || n > 255 )); then
      echo -e "${RED}Invalid semantic version component: $n${NC}" >&2
      echo "Each component in vA.B.C.D must be between 0 and 255" >&2
      exit 1
    fi
  done
}

# Normalize a user-supplied version to internal hex format.
# Accepts semantic (vA.B.C.D) or hex (0xHHHHHHHH).
normalize_version_input() {
  local input=$1
  if [[ $input == v* ]]; then
    validate_semver "$input"
    semver_to_hex "$input"
    return 0
  fi

  if [[ $input == 0x* ]]; then
    validate_hex_version "$input"
    echo "$input"
    return 0
  fi

  echo -e "${RED}Invalid version format: $input${NC}" >&2
  echo "Expected semantic (vA.B.C.D) or hex (0xHHHHHHHH)" >&2
  return 1
}

# Bump version component
bump_component() {
  local current=$1
  local component=$2

  read -r major minor patch build <<< "$(parse_version "$current")"
  major=$((16#$major))
  minor=$((16#$minor))
  patch=$((16#$patch))
  build=$((16#$build))

  case "$component" in
    major)
      major=$((major + 1))
      minor=0
      patch=0
      build=0
      ;;
    minor)
      minor=$((minor + 1))
      patch=0
      build=0
      ;;
    patch)
      patch=$((patch + 1))
      build=0
      ;;
  esac

  format_version "$major" "$minor" "$patch" "$build"
}

# Main logic
main() {
  local new_version=""
  local bump_type=""
  local dry_run=false
  local no_commit=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      --major)
        bump_type="major"
        shift
        ;;
      --minor)
        bump_type="minor"
        shift
        ;;
      --patch)
        bump_type="patch"
        shift
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --no-commit)
        no_commit=true
        shift
        ;;
      -h|--help)
        show_usage 0
        ;;
      --*)
        echo -e "${RED}Unknown option: $1${NC}"
        show_usage 1
        ;;
      *)
        if [ -n "$new_version" ]; then
          echo -e "${RED}Too many version arguments: $1${NC}"
          show_usage 1
        fi
        new_version=$(normalize_version_input "$1") || exit 1
        shift
        ;;
    esac
  done

  local current_version=$(get_current_version)

  # If bump type specified, calculate new version
  if [ -n "$bump_type" ]; then
    new_version=$(bump_component "$current_version" "$bump_type")
  fi

  # If still no version, prompt user
  if [ -z "$new_version" ]; then
    local current_semver
    current_semver=$(hex_to_semver "$current_version")
    echo "Current Version: $current_semver ($current_version)"
    local input_version
    read -p "Enter new version (semantic or hex): " input_version
    new_version=$(normalize_version_input "$input_version") || exit 1
  fi

  # Validate
  validate_hex_version "$new_version"

  if [ "$new_version" = "$current_version" ]; then
    echo -e "${YELLOW}New version is same as current version ($current_version)${NC}"
    exit 1
  fi

  local semver=$(hex_to_semver "$new_version")

  if [ "$dry_run" = true ]; then
    echo -e "${YELLOW}DRY RUN - No changes will be made${NC}"
    echo ""
    echo "Would bump version from $current_version to $new_version"
    echo ""
    echo "Files that would be updated:"
    echo "  - manifest.json"
    echo "  - src/oa_service.be"
    echo "  - src/tl_service.be"
    echo ""
    echo "Would create:"
    echo "  - Commit: \"Bump version to $semver\""
    echo "  - Tag: $semver"
    echo ""
    echo "To apply these changes, run without --dry-run"
    echo "To update files only (no commit/tag), add --no-commit"
    return 0
  fi

  echo -e "${GREEN}Bumping version from $current_version to $new_version${NC}"

  # Update manifest.json
  echo "Updating manifest.json..."
  sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"$new_version\"/" "$SCRIPT_DIR/manifest.json"

  # Update oa_service.be
  echo "Updating oa_service.be..."
  sed -i '' "s/static VERSION = 0x[0-9A-Fa-f]*/static VERSION = $new_version/" "$SCRIPT_DIR/src/oa_service.be"

  # Update tl_service.be
  echo "Updating tl_service.be..."
  sed -i '' "s/static VERSION = 0x[0-9A-Fa-f]*/static VERSION = $new_version/" "$SCRIPT_DIR/src/tl_service.be"

  # Check git status
  cd "$SCRIPT_DIR"
  if ! git diff --quiet; then
    echo -e "${GREEN}Files changed:${NC}"
    git --no-pager diff --name-only
  fi

  if [ "$no_commit" = true ]; then
    echo -e "${GREEN}✓ Version bumped successfully (no commit)${NC}"
    echo "  Hex:    $new_version"
    echo "  Semver: $semver"
    return 0
  fi

  # Commit
  echo -e "${GREEN}Creating commit...${NC}"
  git add manifest.json src/oa_service.be src/tl_service.be
  git commit -m "Bump version to $semver"

  # Create git tag with semantic version
  echo -e "${GREEN}Creating git tag...${NC}"
  git tag "$semver"

  echo -e "${GREEN}✓ Version bumped successfully${NC}"
  echo "  Hex:    $new_version"
  echo "  Tag:    $semver"
  echo "  Commit: $(git rev-parse --short HEAD)"
  echo ""
  echo "Push to remote with: git push origin $semver && git push origin main"
}

main "$@"
