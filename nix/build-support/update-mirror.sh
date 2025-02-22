#!/bin/sh
#
# This script generates a directory that can be uploaded to blob
# storage to mirror our dependencies. The dependencies are unmodified
# so their checksum and content hashes will match.

set -e  # Exit immediately if a command exits with a non-zero status

SCRIPT_PATH="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
INPUT_FILE="$SCRIPT_PATH/../../build.zig.zon2json-lock"
OUTPUT_DIR="blob"

# Ensure the output directory exists
mkdir -p "$OUTPUT_DIR"

# Use jq to iterate over the JSON and download files
jq -r 'to_entries[] | "\(.key) \(.value.name) \(.value.url)"' "$INPUT_FILE" | while read -r key name url; do
  # Skip URLs that don't start with http(s). They aren't necessary for
  # our mirror.
  if ! echo "$url" | grep -Eq "^https?://"; then
    continue
  fi

  # Extract the file extension from the URL
  extension=$(echo "$url" | grep -oE '\.[a-z0-9]+(\.[a-z0-9]+)?$')

  filename="${name}-${key}${extension}"
  echo "$url -> $filename"
  curl -L -o "$OUTPUT_DIR/$filename" "$url"
done
