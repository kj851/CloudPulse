# CloudPulse Desktop App - Setup & Deployment

## Quick Start (Ubuntu)

### 1. Install Python and R Dependencies
```bash
cd path/to/CloudPulse
sudo apt-get update
./setup/install-deps.sh
./setup/install_R_packages.sh
```

### 2. Make Launcher Executable
```bash
chmod +x launch_app.sh
```

### 3. Run the App
```bash
./launch_app.sh
```

The dashboard will:
- Automatically start the Shiny R server
- Open in a native desktop window
- Display a loading screen while initializing
- Fully shut down when you close the window

---

## Building a Standalone Executable

### Prerequisites
```bash
sudo apt-get install -y python3-pyinstaller
pip3 install setup/requirements.txt
```

### Build Command
```bash
pyinstaller --onefile \
  --icon=icon.png \
  --name=FinOpsDashboard \
  --windowed \
  --add-data="FInOpsApp.R:." \
  --add-data="data:data" \
  lib/app_launcher.py
```

### Considerations
- R must still be installed on the target machine (can't bundle R in PyInstaller)
- All R packages must be installed beforehand
- The executable embeds Python + PyQt5 (~200MB)

---

## Docker Containerization (Alternative)

### Dockerfile
```dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y \
    r-base r-base-dev \
    python3-pillow \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .
RUN Rscript setup/install_R_packages.R

EXPOSE 3456
CMD ["./launch_app.sh"]
```

Build: `docker build -t CloudPulse .`
Run: `docker run -it CloudPulse`

---

## Architecture

```
┌─────────────────────────────────────────┐
│   FinOps Desktop App (PyQt5)            │
│  ┌───────────────────────────────────┐  │
│  │  Native OS Window                 │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │  QWebEngineView (Chromium)  │  │  │
│  │  │  ↓                          │  │  │
│  │  │  localhost                  │  │  │
│  │  └─────────────────────────────┘  │  │
│  └───────────────────────────────────┘  │
└──────────────────┬──────────────────────┘
                   │
        ┌──────────▼─────────┐
        │  Shiny R Server    | 
        │  (Subprocess)      |
        │  localhost         | 
        └────────────────────┘
```

---

## Troubleshooting

### "Rscript: command not found"
```bash
sudo apt-get install r-base
```

### "Shiny package not found"
```bash
sudo ./setup/install_R_packages.sh
```

### App won't launch
- Check if port 3456 is already in use: `lsof -i :3456`
- Kill existing process: `pkill -f "port 3456"`
- Try a different port by editing `app_launcher.py` line 18

### Blank window/dashboard not loading
- Wait longer for R packages to load (first run can take 30-60s)
- Check system logs: `journalctl -xe`
- Verify Shiny works: `Rscript -e "shiny::runApp('FInOpsApp.R', port=3456)"`

---

## Uninstall

To remove the desktop app:
```bash
rm -rf /path/to/CloudPulse
```
