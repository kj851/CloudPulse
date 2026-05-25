#!/usr/bin/env python3
"""
CloudPulse Desktop Launcher
Starts the Shiny R server as a subprocess, shows a tkinter loading window,
then opens the dashboard in the system browser (Windows/Linux/macOS).
No PyQt5 or GPU required.

Author: Keaton Szantho
"""

import os
import sys
import subprocess
import threading
import time
import socket
import webbrowser
import tkinter as tk
from tkinter import ttk, messagebox
from pathlib import Path

PORT        = 3456
MAX_WAIT_S  = 90          # seconds before giving up
POLL_MS     = 300         # ms between port-ready checks
APP_TITLE   = "CloudPulse Dashboard"


def find_rscript() -> str:
    """Find Rscript executable, checking common Windows install paths."""
    import shutil
    # Try PATH first (works if R is already on PATH)
    if shutil.which("Rscript"):
        return "Rscript"
    # Common Windows R install locations
    import glob
    patterns = [
        r"C:\Program Files\R\R-*\bin\Rscript.exe",
        r"C:\Program Files\R\R-*\bin\x64\Rscript.exe",
        r"C:\Program Files (x86)\R\R-*\bin\Rscript.exe",
        os.path.expanduser(r"~\AppData\Local\Programs\R\R-*\bin\Rscript.exe"),
    ]
    for pattern in patterns:
        matches = sorted(glob.glob(pattern), reverse=True)  # newest version first
        if matches:
            return matches[0]
    raise FileNotFoundError(
        "Rscript.exe not found.\n\n"
        "Install R from https://cran.r-project.org then re-run the app."
    )


def base_path() -> Path:
    """Return the base path — sys._MEIPASS when frozen, script dir otherwise."""
    if getattr(sys, 'frozen', False) and hasattr(sys, '_MEIPASS'):
        return Path(sys._MEIPASS)
    return Path(__file__).parent


def find_app_r() -> Path:
    """Locate FInOpsApp.R — checks PyInstaller _MEIPASS first, then common paths."""
    base = base_path()
    candidates = [
        base / "FInOpsApp.R",
        base / "lib" / "FInOpsApp.R",
        Path(__file__).parent / "FInOpsApp.R",
        Path(__file__).parent.parent / "FInOpsApp.R",
        Path(__file__).parent / "lib" / "FInOpsApp.R",
    ]
    for p in candidates:
        if p.exists():
            return p
    raise FileNotFoundError(
        "FInOpsApp.R not found.\n\n"
        f"Base path (MEIPASS or script dir): {base}\n"
        "Tried:\n" + "\n".join(str(c) for c in candidates)
    )


def kill_port(port: int):
    """Best-effort: kill any process already using the port."""
    try:
        subprocess.run(
            ["fuser", "-k", f"{port}/tcp"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=3,
        )
    except Exception:
        pass


def port_open(port: int) -> bool:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(0.3)
        ok = s.connect_ex(("127.0.0.1", port)) == 0
        s.close()
        return ok
    except Exception:
        return False


class LoadingWindow:
    """Minimal tkinter splash shown while the Shiny server starts."""

    def __init__(self):
        self.root = tk.Tk()
        self.root.title(APP_TITLE)
        self.root.resizable(False, False)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self._closed = False
        self._logo_img = None  # keep reference to prevent GC

        # ── Window icon (.ico)
        try:
            icon_path = Path(__file__).parent / "assets" / "icon.ico"
            if icon_path.exists():
                self.root.iconbitmap(str(icon_path))
        except Exception:
            pass

        frame = ttk.Frame(self.root, padding=30)
        frame.grid()

        try:
            from PIL import Image, ImageTk
            logo_path = Path(__file__).parent / "assets" / "logo.png"
            if logo_path.exists():
                img = Image.open(logo_path)
                img.thumbnail((220, 80), Image.LANCZOS)  # resize to fit splash
                self._logo_img = ImageTk.PhotoImage(img)
                tk.Label(frame, image=self._logo_img).grid(row=0, column=0, pady=(0, 10))
            else:
                raise FileNotFoundError
        except Exception:
            # Fallback to text if PIL not available or no logo file
            ttk.Label(
                frame,
                text="☁  CloudPulse",
                font=("Segoe UI", 18, "bold"),
            ).grid(row=0, column=0, pady=(0, 6))

        self.status_var = tk.StringVar(value="Starting server…")
        ttk.Label(
            frame,
            textvariable=self.status_var,
            font=("Segoe UI", 10),
            foreground="#555",
        ).grid(row=1, column=0, pady=(0, 14))

        self.bar = ttk.Progressbar(frame, mode="indeterminate", length=320)
        self.bar.grid(row=2, column=0)
        self.bar.start(12)

        self.elapsed_var = tk.StringVar(value="")
        ttk.Label(
            frame,
            textvariable=self.elapsed_var,
            font=("Segoe UI", 8),
            foreground="#aaa",
        ).grid(row=3, column=0, pady=(8, 0))

        self.root.update_idletasks()
        w, h = self.root.winfo_width(), self.root.winfo_height()
        x = (self.root.winfo_screenwidth()  // 2) - (w // 2)
        y = (self.root.winfo_screenheight() // 2) - (h // 2)
        self.root.geometry(f"+{x}+{y}")

    def set_status(self, msg: str):
        if not self._closed:
            self.status_var.set(msg)

    def set_elapsed(self, seconds: float):
        if not self._closed:
            self.elapsed_var.set(f"{seconds:.0f}s elapsed")

    def close(self):
        self._closed = True
        try:
            self.root.destroy()
        except Exception:
            pass

    def _on_close(self):
        """User closed the splash — treat as cancel."""
        self._closed = True
        self.root.destroy()

    @property
    def closed(self):
        return self._closed

    def mainloop_step(self):
        self.root.update()


class ShinyServer:
    def __init__(self, app_r: Path, port: int):
        self.app_r   = app_r
        self.port    = port
        self.process = None
        self._log    = []
        self._ready  = False

    def start(self):
        import tempfile
        # Write launcher script to a writable temp dir (required when frozen by PyInstaller)
        tmp_dir = Path(tempfile.gettempdir()) / "CloudPulse"
        tmp_dir.mkdir(exist_ok=True)
        launcher_r = tmp_dir / ".shiny_launcher.R"
        # Use forward slashes — R on Windows accepts them and avoids escape issues
        app_path_r = self.app_r.as_posix().replace("'", "\\'")
        app_dir_r  = self.app_r.parent.as_posix().replace("'", "\\'")
        launcher_r.write_text(f"""
            options(warn = -1)
            suppressPackageStartupMessages(library(shiny))
            options(shiny.port = {self.port}, shiny.host = '127.0.0.1')
            cat('[Shiny] Initializing...\\n')
            cat('[Shiny] App path: {app_path_r}\\n')
            if (!file.exists('{app_path_r}')) stop('App file not found: {app_path_r}')
            # Set working directory so relative paths (aws.r, azure.r etc.) resolve correctly
            setwd('{app_dir_r}')
            cat('[Shiny] Working dir: ', getwd(), '\\n')
            shiny::runApp('{app_path_r}',
                        host = '127.0.0.1',
                        port = {self.port},
                        launch.browser = FALSE)
            """)
        env = os.environ.copy()
        rscript = find_rscript()
        self.process = subprocess.Popen(
            [rscript, str(launcher_r)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            env=env,
        )
        threading.Thread(target=self._capture, daemon=True).start()

    def _capture(self):
        try:
            for line in iter(self.process.stdout.readline, ""):
                line = line.strip()
                if line:
                    self._log.append(line)
                    print(f"[Shiny] {line}")
                    if "Listening on" in line:
                        self._ready = True
        except Exception:
            pass

    def stop(self):
        if self.process and self.process.poll() is None:
            print("[CloudPulse] Stopping Shiny server…")
            try:
                self.process.terminate()
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        # Clean up temp launcher
        try:
            import tempfile
            launcher_r = Path(tempfile.gettempdir()) / "CloudPulse" / ".shiny_launcher.R"
            launcher_r.unlink(missing_ok=True)
        except Exception:
            pass

    def last_log(self, n=10) -> str:
        return "\n".join(self._log[-n:]) if self._log else "(no output captured)"

    def alive(self) -> bool:
        return self.process is not None and self.process.poll() is None


# ── Main controller ────────────────────────────────────────────────────────────

def run():
    try:
        app_r = find_app_r()
    except FileNotFoundError as e:
        messagebox.showerror(APP_TITLE, str(e))
        return

    kill_port(PORT)
    time.sleep(0.4)

    server  = ShinyServer(app_r, PORT)
    splash  = LoadingWindow()
    start_t = time.time()

    print(f"[CloudPulse] Starting Shiny server on port {PORT}…")
    server.start()

    url          = f"http://127.0.0.1:{PORT}"
    opened       = False
    gave_up      = False

    while not splash.closed:
        elapsed = time.time() - start_t

        if not server.alive():
            time.sleep(1.0)  # give output thread a moment to flush
            log_tail = server.last_log()
            messagebox.showerror(
                APP_TITLE,
                f"Shiny server crashed before it was ready.\n\n"
                f"Last R output:\n{log_tail}\n\n"
                f"Common fixes:\n"
                f"  1. Run: Rscript install_R_packages.R\n"
                f"  2. Check app path is correct\n"
                f"  3. Run Rscript directly to see full error:\n"
                f"     Rscript -e \"shiny::runApp('lib/FInOpsApp.R', port=3456)\"",
            )
            break

        if port_open(PORT) and not opened:
            # Give it one extra second to finish binding
            time.sleep(1.0)
            splash.set_status("Opening dashboard in browser…")
            splash.mainloop_step()
            try:
                subprocess.Popen([
                    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                    f"--app={url}", "--window-size=1400,900"
                ])
            except FileNotFoundError:
                try:
                    subprocess.Popen([
                        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
                        f"--app={url}", "--window-size=1400,900"
                    ])
                except FileNotFoundError:
                    webbrowser.open(url)  # fallback to default browser
            opened = True
            print(f"[CloudPulse] Dashboard opened: {url}")
            # Show a brief "ready" state, then close splash
            time.sleep(1.5)
            splash.close()
            break

        if elapsed > MAX_WAIT_S:
            gave_up = True
            messagebox.showerror(
                APP_TITLE,
                f"Server did not become ready after {MAX_WAIT_S}s.\n\n"
                "Try:\n"
                "  1. Run install_R_packages.R\n"
                f"  2. Check port {PORT} is free: lsof -i :{PORT}\n"
                "  3. Run FInOpsApp.R directly in R to see errors",
            )
            break

        splash.set_status(f"Starting server… (port {PORT})")
        splash.set_elapsed(elapsed)
        splash.mainloop_step()
        time.sleep(POLL_MS / 1000)

    if opened and not gave_up:
        print("[CloudPulse] Server running. Close this terminal to stop.")
        try:
            server.process.wait()   # Block until R exits on its own
        except KeyboardInterrupt:
            pass

    server.stop()
    print("[CloudPulse] Done.")


if __name__ == "__main__":
    run()