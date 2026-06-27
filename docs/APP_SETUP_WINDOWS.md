# CloudPulse — Windows Setup Guide

## Prerequisites

| Requirement | Version | Download |
|---|---|---|
| Python | 3.8+ | [python.org](https://www.python.org/downloads/) |
| R | 4.x | [cran.r-project.org](https://cran.r-project.org/bin/windows/base/) |
| Git (optional) | latest | [git-scm.com](https://git-scm.com) |

> During Python install, check **"Add Python to PATH"** — required for all commands below to work.

---

## Quick Start

### 1. Clone the repository
```powershell
git clone https://github.com/kj851/CloudPulse
cd CloudPulse
```

### 2. Install Python dependencies
```powershell
pip install -r requirements.txt
pip install pillow
```

### 3. Install R packages
```powershell
Rscript setup\install_R_packages.R
```

This takes 10–20 minutes on first run. R packages are installed system-wide and only need to be run once.

If `Rscript` is not recognized, find your R installation and run it directly:
```powershell
"C:\Program Files\R\R-4.4.1\bin\Rscript.exe" setup\install_R_packages.R
```

### 4. Run the app
```powershell
python lib\app_launcher.py
```

The launcher will:
- Show a loading splash while the Shiny R server starts
- Automatically open the dashboard in your default browser
- Keep the R server running in the background until you close the terminal

---

## Running as a Standalone .exe

The `.exe` bundles Python and all dependencies so end users don't need Python installed. R must still be installed separately.

### 1. Install PyInstaller
```powershell
pip install pyinstaller
```

### 2. Build the exe
```powershell
pyinstaller CloudPulse.spec
```

The finished executable is staged in `dist\CloudPulse.exe`.

---

## Architecture

```
CloudPulse.exe  (or python lib\app_launcher.py)
      │
      ├── tkinter splash window (loading screen)
      │
      ├── Rscript subprocess → Shiny server → localhost:3456
      │
      └── System browser → http://127.0.0.1:3456
```

The app opens the dashboard in Chrome or Edge in app mode (no browser tabs/toolbar), falling back to your default browser if neither is found.

---

## Troubleshooting

### "Python is not recognized"
Python is not on your PATH. Re-run the Python installer and check **"Add Python to PATH"**, or manually add `C:\Users\<you>\AppData\Local\Programs\Python\Python3xx\` to your system PATH.

### "Rscript is not recognized"
R is not on your PATH. Either add `C:\Program Files\R\R-4.x.x\bin` to your system PATH, or use the full path to `Rscript.exe` directly.

### "pyinstaller is not recognized"
```powershell
python -m PyInstaller CloudPulse.spec
```

### App splash opens but browser never loads
- Wait up to 60 seconds on first run — R packages take time to load
- Check port 3456 is free:
```powershell
netstat -ano | findstr :3456
```
- Kill any process using it:
```powershell
# Replace <PID> with the number from the netstat output
taskkill /PID <PID> /F
```
- Run Shiny directly to see R errors:
```powershell
Rscript -e "shiny::runApp('lib/FInOpsApp.R', port=3456)"
```

### "FileNotFoundError: Rscript" at runtime
The launcher searches common R install paths automatically. If R is installed in a non-standard location, add it to your system PATH:
1. Search "environment variables" in the Start menu
2. Edit the `Path` system variable
3. Add the folder containing `Rscript.exe` (e.g. `C:\Program Files\R\R-4.4.1\bin`)

---

## Uninstall

```powershell
# Remove Python packages
pip uninstall pyinstaller pillow

# Remove R packages (optional — runs inside R)
Rscript -e "remove.packages(c('shiny','bslib','plotly','DT'))"

# Delete the app folder
rd /s /q C:\path\to\CloudPulse
```
