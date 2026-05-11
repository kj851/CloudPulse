#!/usr/bin/env bash
set -euo pipefail

# Configuration (can override via env HOST/PORT or CLI args)
# Usage: run_app.sh [-H host] [-P port]  OR  run_app.sh <port>
usage() {
  echo "Usage: $0 [-H host] [-P port]" >&2
  echo "Environment: HOST, PORT" >&2
  exit 1
}

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-3838}"

while getopts ":H:P:" opt; do
  case "${opt}" in
    H) HOST="$OPTARG" ;;
    P) PORT="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done
shift $((OPTIND-1))

# allow a single positional arg to set the port: ./run_app.sh 3840
if [ -n "${1-}" ]; then
  PORT="$1"
fi

# validate port is numeric
if ! printf "%s" "$PORT" | grep -Eq "^[0-9]+$"; then
  echo "Invalid PORT: $PORT" >&2
  usage
fi
APP_DIR="/dashboard-tips"
APP_FILE="${APP_DIR}/FInOpsApp.R"
LOG="${LOG:-${APP_DIR}/finops_app.log}"
PIDFILE="${PIDFILE:-${APP_DIR}/finops_app.pid}"

RSC="$(command -v Rscript || true)"
if [ -z "$RSC" ]; then
  echo "Rscript not found in PATH. Install R and ensure Rscript is available." >&2
  exit 1
fi

if [ ! -f "$APP_FILE" ]; then
  echo "App file not found: $APP_FILE" >&2
  exit 1
fi

echo "$(date --iso-8601=seconds) Starting FinOpsApp on ${HOST}:${PORT}, logging to ${LOG}"
# Source the app file in a non-interactive R session and then explicitly run the app object.
# Using double quotes so HOST/PORT expand in the -e expression.
nohup "$RSC" -e "source('${APP_FILE}'); shiny::runApp(list(ui=ui, server=server), host='${HOST}', port=${PORT}, launch.browser=FALSE)" >"$LOG" 2>&1 &
echo $! > "$PIDFILE"
echo "Started FinOpsApp (PID $(cat $PIDFILE)). To stop: kill \$(cat $PIDFILE)"
