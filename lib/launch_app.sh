#!/bin/bash
# FinOps Dashboard Launcher
# Run this to launch the desktop app
# This script checks for dependencies, then starts the PyQt5 app which loads the Shiny dashboard.
# Author: Keaton Szantho

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check Python dependencies
python3 << 'PYCHECK'
try:
    import PyQt5.QtWidgets
    import PyQt5.QtWebEngineWidgets
    print("✓ PyQt5 and dependencies found")
except ImportError as e:
    print(f"✗ Missing dependency: {e}")
    print("\nInstall with:")
    print("  sudo apt-get install python3-pyqt5 python3-pyqt5.qtwebengine")
    exit(1)
PYCHECK

# Check R and Shiny
if ! Rscript -e "if (!requireNamespace('shiny', quietly = TRUE)) stop('Shiny not found'); cat('✓ R and Shiny found\n')" 2>/dev/null; then
  echo "✗ R or Shiny not available"
  echo "Install with: sudo Rscript install_R_packages.R"
  exit 1
fi

# Launch app
echo "Launching FinOps Dashboard..."
python3 app_launcher.py
