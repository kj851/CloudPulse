#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RSC="$(command -v Rscript || true)"
if [ -z "$RSC" ]; then
  echo "Rscript not found. Install R before running this script."
  exit 1
fi

# Run installer with sudo if not root (so packages install to system library)
if [ "$(id -u)" -ne 0 ]; then
  echo "Running R installer as root (sudo) so packages install to system library..."
  sudo "$RSC" "$SCRIPT_DIR/install_R_packages.R"
else
  "$RSC" "$SCRIPT_DIR/install_R_packages.R"
fi
