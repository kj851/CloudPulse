#!/usr/bin/env python3
"""
FinOps Dashboard Desktop Wrapper
Launches Shiny R app in a native desktop window using PyQt5
"""

import sys
import os
import subprocess
import threading
from pathlib import Path
from PyQt5.QtWidgets import QApplication, QMainWindow, QVBoxLayout, QWidget, QLabel, QProgressBar
from PyQt5.QtWebEngineWidgets import QWebEngineView
from PyQt5.QtCore import Qt, QTimer, QUrl
from PyQt5.QtGui import QIcon, QFont

class FinOpsApp(QMainWindow):
    def __init__(self):
        super().__init__()
        self.shiny_process = None
        self.port = 3456
        self.localhost_url = f"http://127.0.0.1:{self.port}"
        self.max_retries = 60
        self.retry_count = 0
        self.is_root = os.geteuid() == 0 if hasattr(os, 'geteuid') else False
        
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
        
        # Start Shiny server
        self.start_shiny_server()
        
        # Timer to check if server is ready
        self.check_timer = QTimer()
        self.check_timer.timeout.connect(self.check_server_ready)
        self.check_timer.start(500)  # Check every 500ms
    
    def setup_loading_screen(self):
        """Display loading screen while server starts"""
        widget = QWidget()
        layout = QVBoxLayout()
        
        self.loading_label = QLabel("Starting FinOps Dashboard...")
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
    
    def start_shiny_server(self):
        """Start the Shiny R server"""
        app_path = Path(__file__).parent / "FInOpsApp.R"
        
        if not app_path.exists():
            self.show_error(f"App not found: {app_path}")
            return
        
        try:
            # Use environment to set flags before starting
            env = os.environ.copy()
            if self.is_root:
                env['QTWEBENGINE_CHROMIUM_FLAGS'] = '--no-sandbox --disable-gpu'
            
            # Simpler approach: use Rscript with a file
            r_script_path = Path(__file__).parent / ".shiny_launcher.R"
            r_script = f"""
suppressPackageStartupMessages({{
  library(shiny)
}})
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
            
            # Start a thread to capture output
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
                        print(f"[Shiny] {line}")
        except:
            pass
    
    def check_server_ready(self):
        """Check if Shiny server is ready to accept connections"""
        import socket
        
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(1)
            result = sock.connect_ex(('127.0.0.1', self.port))
            sock.close()
            
            if result == 0:
                # Server is ready
                self.check_timer.stop()
                self.load_dashboard()
                return
        except:
            pass
        
        self.retry_count += 1
        # Update loading screen with progress
        self.loading_label.setText(f"Starting FinOps Dashboard... ({self.retry_count}s)")
        
        if self.retry_count >= self.max_retries:
            self.check_timer.stop()
            # Try to get last few lines of output
            error_msg = f"Failed to connect to Shiny server after {self.max_retries} seconds.\n\n"
            error_msg += "Please ensure:\n"
            error_msg += "1. All R packages are installed\n"
            error_msg += "2. No other app is using port 3456\n"
            error_msg += "3. R and Shiny are properly configured"
            self.show_error(error_msg)
    
    def load_dashboard(self):
        """Load the dashboard in QWebEngineView"""
        browser = QWebEngineView()
        
        # Configure WebEngine settings
        settings = browser.settings()
        settings.setAttribute(settings.PluginsEnabled, True)
        settings.setAttribute(settings.DomStorageEnabled, True)
        settings.setAttribute(settings.LocalStorageEnabled, True)
        
        browser.load(QUrl(self.localhost_url))
        self.setCentralWidget(browser)
        self.show()
        print(f"[FinOps] Dashboard loaded: {self.localhost_url}")
    
    def show_error(self, message):
        """Display error and exit"""
        from PyQt5.QtWidgets import QMessageBox
        QMessageBox.critical(self, "FinOps Dashboard - Error", message)
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
        
        # Clean up temporary script
        try:
            temp_script = Path(__file__).parent / ".shiny_launcher.R"
            if temp_script.exists():
                temp_script.unlink()
        except:
            pass
    
    def __del__(self):
        self.cleanup()

def main():
    # Set Chromium flags BEFORE creating QApplication if running as root
    if hasattr(os, 'geteuid') and os.geteuid() == 0:
        os.environ['QTWEBENGINE_CHROMIUM_FLAGS'] = '--no-sandbox --disable-gpu'
    
    app = QApplication(sys.argv)
    window = FinOpsApp()
    sys.exit(app.exec_())

if __name__ == "__main__":
    main()
