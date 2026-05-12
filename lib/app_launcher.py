#!/usr/bin/env python3
"""
CloudPulse Desktop Wrapper:
Launches Shiny R app in a native desktop window using PyQt5 then
Lauches the Shiny server as a subprocess, monitors its output, 
and loads the dashboard in a QWebEngineView.
Author: Keaton Szantho

"""

import sys
import os
import subprocess
import threading
import time
import socket
from pathlib import Path

# Force unbuffered output
sys.stdout = open(sys.stdout.fileno(), mode='w', buffering=1)
sys.stderr = open(sys.stderr.fileno(), mode='w', buffering=1)

from PyQt5.QtWidgets import QApplication, QMainWindow, QVBoxLayout, QWidget, QLabel, QProgressBar
from PyQt5.QtWebEngineWidgets import QWebEngineView
from PyQt5.QtCore import Qt, QTimer, QUrl
from PyQt5.QtGui import QIcon, QFont

class FinOpsApp(QMainWindow):
    def __init__(self):
        super().__init__()
        self.shiny_process = None
        self.browser = None
        self.port = 3456
        self.localhost_url = f"http://127.0.0.1:{self.port}"
        self.max_retries = 60
        self.retry_count = 0
        self.is_root = os.geteuid() == 0 if hasattr(os, 'geteuid') else False
        self.server_ready_time = None
        self.connection_time = None
        
        # App config
        self.setWindowTitle("FinOps Dashboard")
        self.setGeometry(100, 100, 1400, 900)
        
        # Icon (optional)
        try:
            icon_path = Path(__file__).parent / "assets" / "icon.png"
            if icon_path.exists():
                self.setWindowIcon(QIcon(str(icon_path)))
        except:
            pass
        
        # Loading screen
        self.setup_loading_screen()
        
        # Kill any lingering processes on the port
        self._kill_port_process()
        time.sleep(0.5)
        
        # Start Shiny server
        print("[FinOps] Starting Shiny server...")
        self.start_time = time.time()
        self.start_shiny_server()
        
        # Timer to check if server is ready
        self.check_timer = QTimer()
        self.check_timer.timeout.connect(self.check_server_ready)
        self.check_timer.start(200)  # Check more frequently
    
    def setup_loading_screen(self):
        """Display loading screen while server starts"""
        widget = QWidget()
        layout = QVBoxLayout()
        
        self.loading_label = QLabel("Starting CloudPulse Dashboard...")
        self.loading_label.setAlignment(Qt.AlignCenter)
        font = QFont()
        font.setPointSize(14)
        self.loading_label.setFont(font)
        
        progress = QProgressBar()
        progress.setRange(0, 0)  # Indeterminate progress
        
        layout.addStretch()
        layout.addWidget(self.loading_label)
        layout.addWidget(progress)
        layout.addStretch()
        
        widget.setLayout(layout)
        self.setCentralWidget(widget)
        self.show()
    
    def _kill_port_process(self):
        """Kill any process using the configured port"""
        try:
            subprocess.run(
                ['fuser', '-k', f'{self.port}/tcp'],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2
            )
            print(f"[FinOps] Cleaned up port {self.port}")
        except:
            pass
    
    def start_shiny_server(self):
        """Start the Shiny R server"""
        app_path = Path(__file__).parent / "FInOpsApp.R"
        
        if not app_path.exists():
            self.show_error(f"App not found: {app_path}")
            return
        
        try:
            env = os.environ.copy()
            # Always use these flags for better compatibility
            env['QTWEBENGINE_CHROMIUM_FLAGS'] = '--no-sandbox --disable-gpu'
            
            r_script_path = Path(__file__).parent / ".shiny_launcher.R"
            r_script = f"""
options(warn=-1)
suppressPackageStartupMessages({{
  library(shiny)
}})

options(shiny.port={self.port})
options(shiny.host='127.0.0.1')
options(shiny.maxRequestSize=100*1024^2)

cat('[Shiny] Server initializing...\n')
shiny::runApp('{app_path}', 
             host='127.0.0.1', 
             port={self.port}, 
             launch.browser=FALSE)
"""
            r_script_path.write_text(r_script)
            
            self.shiny_process = subprocess.Popen(
                ['Rscript', str(r_script_path)],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env=env
            )
            
            print(f"[FinOps] Shiny server started (PID: {self.shiny_process.pid})")
            
            output_thread = threading.Thread(target=self._capture_server_output, daemon=True)
            output_thread.start()
            
        except Exception as e:
            self.show_error(f"Failed to start Shiny server: {e}")
    
    def _capture_server_output(self):
        """Capture and log server output"""
        try:
            for line in iter(self.shiny_process.stdout.readline, ''):
                if line:
                    line = line.strip()
                    if line:
                        elapsed = time.time() - self.start_time
                        print(f"[{elapsed:.1f}s] [Shiny] {line}")
                        if "Listening on" in line:
                            self.server_ready_time = time.time()
        except:
            pass
    
    def check_server_ready(self):
        """Check if Shiny server is ready to accept connections"""
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(0.5)
            result = sock.connect_ex(('127.0.0.1', self.port))
            sock.close()
            
            if result == 0:
                if not self.connection_time:
                    self.connection_time = time.time()
                    elapsed = self.connection_time - self.start_time
                    print(f"[{elapsed:.1f}s] [FinOps] Port {self.port} is now accepting connections")
                
                if time.time() - self.connection_time > 0.5:
                    self.check_timer.stop()
                    self.load_dashboard()
                return
        except:
            pass
        
        self.retry_count += 1
        elapsed = time.time() - self.start_time
        self.loading_label.setText(f"Starting FinOps Dashboard... ({elapsed:.0f}s)")
        
        if self.retry_count >= self.max_retries:
            self.check_timer.stop()
            error_msg = f"Failed to connect to Shiny server after {self.max_retries} seconds.\n\n"
            error_msg += "Please ensure:\n"
            error_msg += "1. All R packages are installed\n"
            error_msg += "2. No other app is using port 3456\n"
            error_msg += "3. R and Shiny are properly configured"
            self.show_error(error_msg)
    
    def load_dashboard(self):
        """Load the dashboard in QWebEngineView"""
        elapsed = time.time() - self.start_time
        print(f"[{elapsed:.1f}s] [CloudPulse] Loading dashboard in browser...")
        sys.stdout.flush()
        
        # Create browser
        elapsed = time.time() - self.start_time
        print(f"[{elapsed:.1f}s] [CloudPulse] Creating QWebEngineView...")
        sys.stdout.flush()
        self.browser = QWebEngineView()
        
        elapsed = time.time() - self.start_time
        print(f"[{elapsed:.1f}s] [CloudPulse] Getting settings object...")
        sys.stdout.flush()
        settings = self.browser.settings()
        
        elapsed = time.time() - self.start_time
        print(f"[{elapsed:.1f}s] [CloudPulse] Setting PluginsEnabled...")
        sys.stdout.flush()
        settings.setAttribute(settings.PluginsEnabled, True)
        
        elapsed = time.time() - self.start_time
        print(f"[{elapsed:.1f}s] [CloudPulse] Setting central widget...")
        sys.stdout.flush()
        self.setCentralWidget(self.browser)
        
        elapsed = time.time() - self.start_time
        print(f"[{elapsed:.1f}s] [CloudPulse] Showing window...")
        sys.stdout.flush()
        self.show()
        
        # Use a timer to load the page after event loop has processed  
        elapsed = time.time() - self.start_time
        print(f"[{elapsed:.1f}s] [CloudPulse] Scheduling page load via timer...")
        sys.stdout.flush()
        
        load_timer = QTimer()
        load_timer.setSingleShot(True)
        load_timer.timeout.connect(self.do_page_load)
        load_timer.start(100)  # Give event loop 100ms to process
    
    def do_page_load(self):
        """Actually load the page - called after Qt event loop has processed"""
        elapsed = time.time() - self.start_time
        print(f"[{elapsed:.1f}s] [CloudPulse] Timer fired, calling browser.load()...")
        sys.stdout.flush()
        self.browser.load(QUrl(self.localhost_url))
        
        elapsed = time.time() - self.start_time
        print(f"[{elapsed:.1f}s] [CloudPulse] Dashboard setup complete: {self.localhost_url}")
        sys.stdout.flush()
    
    def show_error(self, message):
        """Display error and exit"""
        from PyQt5.QtWidgets import QMessageBox
        QMessageBox.critical(self, "CloudPulse Dashboard - Error", message)
        self.cleanup()
        sys.exit(1)
    
    def closeEvent(self, event):
        """Handle window close event"""
        self.cleanup()
        event.accept()
    
    def cleanup(self):
        """Gracefully shutdown Shiny server"""
        if self.shiny_process and self.shiny_process.poll() is None:
            print("[FinOps] Shutting down Shiny server...")
            try:
                self.shiny_process.terminate()
                self.shiny_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.shiny_process.kill()
            print("[FinOps] Shiny server stopped")
        
        try:
            temp_script = Path(__file__).parent / ".shiny_launcher.R"
            if temp_script.exists():
                temp_script.unlink()
        except:
            pass
    
    def __del__(self):
        self.cleanup()

def main():
    try:
        if hasattr(os, 'geteuid') and os.geteuid() == 0:
            os.environ['QTWEBENGINE_CHROMIUM_FLAGS'] = '--no-sandbox --disable-gpu'
        
        app = QApplication(sys.argv)
        window = FinOpsApp()
        sys.exit(app.exec_())
    except Exception as e:
        print(f"[FinOps] ERROR: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    main()
