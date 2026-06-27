# CloudPulse — Plumber API Backend Setup

## Architecture

```
┌──────────────────────────────┐
│   Shiny Frontend             │
│   lib/FInOpsApp.R            │
│   CLOUDPULSE_USE_API=true    │
└────────────┬─────────────────┘
             │ HTTP/REST (httr)
             │ X-API-Key header
             ▼
┌──────────────────────────────┐
│   Plumber REST API           │
│   api/plumber.R              │
│   http://127.0.0.1:8000      │
└────────────┬─────────────────┘
             │ in-process calls
             ▼
┌──────────────────────────────┐
│   Data Layer                 │
│   data/aws.r                 │
│   data/azure.r               │
│   data/GCP.r                 │
│   data/mock.r                │
│   data/forecast.r            │
│   data/kubernetes.r          │
└──────────────────────────────┘
```

## File layout

```
CloudPulse/
  lib/
    FInOpsApp.R          ← Shiny app (unchanged interface)
    api/
      plumber.R          ← API endpoint definitions
      entrypoint.R       ← Server startup script
      api_client.R       ← Drop-in replacement for data functions
    data/
      aws.r
      azure.r
      GCP.r
      mock.r
      forecast.r
      kubernetes.r
    www/
      logo.png
      styles.css
```

## Install R dependencies

```r
install.packages(c("plumber", "httr", "jsonlite"))
```

---

## Running the API

### 1. Set environment variables

```bash
# Required in production — clients must send this in X-API-Key header
export CLOUDPULSE_API_KEY="your-secret-key-here"

# Optional — defaults shown
export CLOUDPULSE_API_HOST="127.0.0.1"
export CLOUDPULSE_API_PORT="8000"
```

On Windows (PowerShell):
```powershell
$env:CLOUDPULSE_API_KEY = "your-secret-key-here"
$env:CLOUDPULSE_API_HOST = "127.0.0.1"
$env:CLOUDPULSE_API_PORT = "8000"
```

### 2. Start the API server

Run from the project root (`CloudPulse/lib/`):

```bash
Rscript api/entrypoint.R
```

You should see:
```
[CloudPulse API] Starting on http://127.0.0.1:8000
  Docs: http://127.0.0.1:8000/__docs__/
```

### 3. Test the API

```bash
# Health check (no auth required)
curl http://127.0.0.1:8000/health

# Mock metadata (auth required)
curl -H "X-API-Key: your-secret-key-here" \
  "http://127.0.0.1:8000/metadata?provider=AWS&mock=true"

# Mock cost
curl -H "X-API-Key: your-secret-key-here" \
  "http://127.0.0.1:8000/cost?provider=AWS&start=2024-01-01&end=2024-02-01&mock=true"

# K8s clusters
curl -H "X-API-Key: your-secret-key-here" \
  "http://127.0.0.1:8000/k8s/clusters"
```

Open the Swagger UI for interactive docs and testing:
```
http://127.0.0.1:8000/__docs__/
```

---

## Running Shiny with the API backend

### Terminal 1 — start the API
```bash
cd CloudPulse/lib
export CLOUDPULSE_API_KEY="your-secret-key-here"
Rscript api/entrypoint.R
```

### Terminal 2 — start Shiny in API mode
```bash
cd CloudPulse/lib
export CLOUDPULSE_USE_API="true"
export CLOUDPULSE_API_URL="http://127.0.0.1:8000"
export CLOUDPULSE_API_KEY="your-secret-key-here"
Rscript -e "shiny::runApp('FInOpsApp.R', port=3456)"
```

Without the env vars (direct mode — default, no API needed):
```bash
Rscript -e "shiny::runApp('FInOpsApp.R', port=3456)"
```

---

## Deploying the API as a background service

### Linux (systemd)

Create `/etc/systemd/system/cloudpulse-api.service`:

```ini
[Unit]
Description=CloudPulse Plumber API
After=network.target

[Service]
Type=simple
User=your-user
WorkingDirectory=/home/your-user/CloudPulse/lib
Environment=CLOUDPULSE_API_KEY=your-secret-key-here
Environment=CLOUDPULSE_API_HOST=0.0.0.0
Environment=CLOUDPULSE_API_PORT=8000
ExecStart=/usr/bin/Rscript api/entrypoint.R
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable cloudpulse-api
sudo systemctl start  cloudpulse-api
sudo systemctl status cloudpulse-api
```

### Windows (as a background process)

```powershell
$env:CLOUDPULSE_API_KEY = "your-secret-key-here"
Start-Process Rscript -ArgumentList "api/entrypoint.R" -NoNewWindow
```

Or use [NSSM](https://nssm.cc) to register it as a proper Windows service.

---

## API endpoints reference

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check — no auth required |
| GET | `/metadata` | Instance/database list |
| GET | `/instances` | Instance names only |
| GET | `/usage` | CPU usage time series |
| GET | `/cost` | Cost by instance |
| GET | `/forecast` | CPU usage forecast |
| GET | `/k8s/clusters` | All K8s clusters |
| GET | `/k8s/nodes` | Nodes for a cluster |
| GET | `/k8s/pods` | Pods for a cluster |
| GET | `/k8s/deployments` | Deployments for a cluster |
| GET | `/k8s/events` | Events for a cluster |
| GET | `/k8s/metrics` | Metrics time series |
| GET | `/k8s/namespaces` | Namespaces for a cluster |

All endpoints except `/health` require the `X-API-Key` header in production.

Query parameters common to all cloud endpoints:
- `provider` — `AWS`, `Azure`, `GCP`, or `mock`
- `mock` — `true` or `false` (default `true`)

---

## Why use the API backend?

| | Direct mode | API mode |
|---|---|---|
| Setup | None | Start `entrypoint.R` first |
| Performance | Function call overhead | Network round-trip (~1-5ms local) |
| Scalability | Single R process | API can run on separate server |
| Access control | Shiny auth only | API key + Shiny auth |
| External clients | No | Any language can call the API |
| CI testing | Mock functions | `curl` or `pytest` against live API |
| Production | Fine for single user | Preferred for teams |

---

## Troubleshooting

### "API connection failed: is the plumber server running?"
The Shiny app can't reach the API. Check:
```bash
curl http://127.0.0.1:8000/health
```
If that fails, the API server isn't running or is on a different port.

### "API: unauthorized"
`CLOUDPULSE_API_KEY` in Shiny doesn't match the key the API was started with.
Both processes must have identical values.

### "API: endpoint not found"
The `CLOUDPULSE_API_URL` points to the wrong server or port.

### Port already in use
```bash
lsof -i :8000          # Linux/Mac
netstat -ano | findstr :8000   # Windows
```
Change `CLOUDPULSE_API_PORT` to a free port and update `CLOUDPULSE_API_URL` to match.
