#!/usr/bin/env bash
set -eo pipefail

# installer for Ubuntu: logs, waits for apt/dpkg locks, and uses timeouts.

LOG=/tmp/install-deps.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
set -x

run_with_timeout() {
  local T=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$T" "$@"
  else
    "$@"
  fi
}

wait_for_package_manager() {
  local tries=0
  local max=60
  while [ $tries -lt $max ]; do
    # look for apt, apt-get, or dpkg processes
    if ! pgrep -x apt >/dev/null 2>&1 && ! pgrep -x apt-get >/dev/null 2>&1 && ! pgrep -x dpkg >/dev/null 2>&1; then
      return 0
    fi
    echo "$(date --iso-8601=seconds) - Waiting for other package manager to finish..."
    sleep 5
    tries=$((tries + 1))
  done
  echo "Timed out waiting for other package manager (apt/apt-get/dpkg). Check running processes and logs."
  return 1
}

echo "$(date --iso-8601=seconds) - Starting system dependency installation"

# Wait for any other package manager to finish
if ! wait_for_package_manager; then
  echo "Resolve the existing package manager activity or reboot, then re-run this script."
  exit 1
fi
run_with_timeout 600 sudo apt-get update
run_with_timeout 1200 sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  r-base r-base-dev \
  gcc g++ make cmake \
  libcurl4-openssl-dev libssl-dev libxml2-dev zlib1g-dev \
  libbz2-dev liblzma-dev uuid-dev pkg-config \
  libffi-dev libpng-dev libfreetype6-dev libfontconfig1-dev \
  libjpeg-dev libpq-dev \
  libcairo2-dev libxt-dev libharfbuzz-dev libfribidi-dev librsvg2-dev \
  libgdal-dev libproj-dev libgeos-dev libudunits2-dev libsodium-dev

echo "$(date --iso-8601=seconds) - System dependencies installed."
echo "Installer log: $LOG"
echo "Now run: sudo Rscript /home/keaton/dashboard-tips/install_R_packages.R"
