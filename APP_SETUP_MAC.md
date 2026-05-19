# CloudPulse — macOS Setup Guide

## Prerequisites

| Requirement | Version | Download |
|---|---|---|
| Python | 3.8+ | [python.org](https://www.python.org/downloads/) or Homebrew |
| R | 4.x | [cran.r-project.org](https://cran.r-project.org/bin/macosx/) |
| Homebrew (recommended) | latest | [brew.sh](https://brew.sh) |
| Xcode CLI tools | latest | `xcode-select --install` |

---

## Quick Start

### 1. Install Homebrew (if not already installed)
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2. Install Python and R
```bash
brew install python
brew install --cask r
```

Or download R directly from [cran.r-project.org](https://cran.r-project.org/bin/macosx/) — the `.pkg` installer is easiest.

### 3. Clone the repository
```bash
git clone https://github.com/kj851/CloudPulse
cd CloudPulse
```

### 4. Install Python dependencies
```bash
pip3 install -r requirements.txt
pip3 install pillow
```

### 5. Install R packages
```bash
Rscript install_R_packages.R
```

This takes 10–20 minutes on first run. Packages only need to be installed once.

### 6. Run the app
```bash
python3 lib/app_launcher.py
```

The launcher will:
- Show a loading splash while the Shiny R server starts
- Automatically open the dashboard in your default browser
- Keep the R server running until you close the terminal

---

## Running as a Standalone .app Bundle

PyInstaller on macOS produces a `.app` bundle that lives in your Applications folder like any other Mac app.

### 1. Install PyInstaller
```bash
pip3 install pyinstaller
```

### 2. Build the .app
```bash
pyinstaller CloudPulse.spec
```

The app bundle is at `dist/CloudPulse.app`. Drag it to `/Applications` to install.

### 3. Fix "cannot be opened because the developer cannot be verified"
macOS Gatekeeper blocks unsigned apps. To allow it:
```bash
xattr -cr dist/CloudPulse.app
```
Or: right-click the `.app` → Open → Open anyway.

---

## Architecture

```
CloudPulse.app  (or python3 lib/app_launcher.py)
      │
      ├── tkinter splash window (loading screen)
      │
      ├── Rscript subprocess → Shiny server → localhost:3456
      │
      └── System browser → http://127.0.0.1:3456
```

The app opens the dashboard in Chrome in app mode (no browser tabs/toolbar) if available, falling back to Safari or your default browser.

---

## macOS-specific Notes

### Apple Silicon (M1/M2/M3)
If you installed R for Intel and are running Apple Silicon Python, you may see architecture mismatch errors. Use the native ARM builds:
- Python: install via Homebrew on Apple Silicon — it installs the ARM version automatically
- R: download the **"Apple silicon arm64"** build from CRAN

### Tkinter on macOS
macOS ships a broken system tkinter. Always use the Homebrew Python version:
```bash
brew install python-tk
```

Verify:
```bash
python3 -c "import tkinter; tkinter._test()"
```
A small window should appear. If it errors, run `brew install python-tk@3.x` matching your Python version.

### Port conflicts
```bash
lsof -i :3456
kill -9 <PID>
```

---

## Troubleshooting

### "command not found: Rscript"
R is not on your PATH. Add it:
```bash
echo 'export PATH="/Library/Frameworks/R.framework/Resources/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### "No module named tkinter"
```bash
brew install python-tk
```

### App splash opens but browser never loads
- Wait up to 60 seconds on first run
- Check the terminal for R error output
- Run Shiny directly to isolate R errors:
```bash
Rscript -e "shiny::runApp('lib/FInOpsApp.R', port=3456)"
```

### R package install fails (compilation errors)
Xcode CLI tools are required to compile R packages from source:
```bash
xcode-select --install
```

Then retry:
```bash
Rscript install_R_packages.R
```

### .app won't open — "developer cannot be verified"
```bash
xattr -cr dist/CloudPulse.app
```

### Chrome app mode not working on macOS
Chrome on macOS may require the full path. If the app falls back to Safari, set Chrome as your default browser or adjust the path in `app_launcher.py`:
```python
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
```

---

## Uninstall

```bash
# Remove the app bundle
rm -rf dist/CloudPulse.app

# Remove Python packages
pip3 uninstall pyinstaller pillow

# Remove R packages (optional)
Rscript -e "remove.packages(c('shiny','bslib','plotly','DT'))"

# Remove the project folder
rm -rf ~/CloudPulse
```
