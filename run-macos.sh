#!/bin/bash
# Unzips the downloaded CI build, strips the Gatekeeper quarantine flag,
# and launches MeshChat.app.
#
# Usage:
#   1. Download MeshChat-macOS.zip from the GitHub Actions run's Artifacts section.
#   2. Put it in the same folder as this script (or pass its path as $1).
#   3. Run: chmod +x run-macos.sh && ./run-macos.sh

set -e

ZIP_PATH="${1:-MeshChat-macOS.zip}"
APP_NAME="MeshChat.app"

if [ ! -f "$ZIP_PATH" ]; then
  echo "Error: $ZIP_PATH not found."
  echo "Download it from: https://github.com/parth0072/p2pchat/actions -> latest run -> Artifacts"
  exit 1
fi

echo "Unzipping $ZIP_PATH..."
unzip -oq "$ZIP_PATH"

if [ ! -d "$APP_NAME" ]; then
  echo "Error: $APP_NAME not found after unzip."
  exit 1
fi

echo "Removing quarantine flag (unsigned build, bypasses Gatekeeper)..."
xattr -cr "$APP_NAME"

echo "Launching $APP_NAME..."
open "$APP_NAME"
