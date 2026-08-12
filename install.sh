#!/bin/bash
# Downloads the latest MeshChat macOS build straight from GitHub Releases,
# strips the Gatekeeper quarantine flag (the build is unsigned/free), and
# installs it into ~/Applications.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/parth0072/p2pchat/main/install.sh | bash

set -e

REPO="parth0072/p2pchat"
ZIP_URL="https://github.com/$REPO/releases/download/latest/MeshChat-macOS.zip"
INSTALL_DIR="$HOME/Applications"
TMP_DIR=$(mktemp -d)

echo "Downloading latest MeshChat build..."
curl -fsSL "$ZIP_URL" -o "$TMP_DIR/MeshChat-macOS.zip"

echo "Unzipping..."
unzip -oq "$TMP_DIR/MeshChat-macOS.zip" -d "$TMP_DIR"

echo "Removing quarantine flag (unsigned build, bypasses Gatekeeper)..."
xattr -cr "$TMP_DIR/MeshChat.app"

echo "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/MeshChat.app"
mv "$TMP_DIR/MeshChat.app" "$INSTALL_DIR/"
rm -rf "$TMP_DIR"

echo "Launching MeshChat..."
open "$INSTALL_DIR/MeshChat.app"
