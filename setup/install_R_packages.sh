#!/usr/bin/env bash
# Install R packages wrapper for Ubuntu/Linux
# Copyright (c) 2026, Keaton Szantho

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RSC="$(command -v Rscript || true)"
if [ -z "$RSC" ]; then
  echo "Rscript not found. Install R before running this script."
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Running R installer as root (sudo) so packages install to system library..."
  sudo "$RSC" "$SCRIPT_DIR/install_R_packages.R"
else
  "$RSC" "$SCRIPT_DIR/install_R_packages.R"
fi
