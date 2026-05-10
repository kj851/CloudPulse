#!/usr/bin/env python3
"""
FinOps Dashboard Desktop Wrapper
Launches Shiny R app in a native desktop window using PyQt5
"""

import sys
import subprocess
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
        self.max_retries = 30
        self.retry_count = 0
        
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
        self.check_timer.start(1000)  # Check every second
    
    def setup_loading_screen(self):
        """Display loading screen while server starts"""
        widget = QWidget()
        layout = QVBoxLayout()
        
        label = QLabel("Starting FinOps Dashboard...")
        label.setAlignment(Qt.AlignCenter)
        font = QFont()
        font.setPointSize(14)
        label.setFont(font)
        
        progress = QProgressBar()
        progress.setRange(0, 0)  # Indeterminate progress
        
        layout.addStretch()
        layout.addWidget(label)
        layout.addWidget(progress)
        layout.addStretch()
        
        widget.setLayout(layout)
        self.setCentralWidget(widget)
    
    def start_shiny_server(self):
        """Start the Shiny R server"""
        app_path = Path(__file__).parent / "FInOpsApp.R"
        
        if not app_path.exists():
            self.show_error(f"App not found: {app_path}")
            return
        
        try:
            # Start Shiny server as subprocess
            r_cmd = f"""
            Rscript -e "
            library(shiny)
            shiny::runApp('{app_path}', 
                         host='127.0.0.1', 
                         port={self.port}, 
                         launch.browser=FALSE)
            "
            """
            
            self.shiny_process = subprocess.Popen(
                r_cmd,
                shell=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            
            print(f"[FinOps] Shiny server started (PID: {self.shiny_process.pid})")
        except Exception as e:
            self.show_error(f"Failed to start Shiny server: {e}")
    
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
        if self.retry_count >= self.max_retries:
            self.check_timer.stop()
            self.show_error("Failed to connect to Shiny server after 30 seconds")
    
    def load_dashboard(self):
        """Load the dashboard in QWebEngineView"""
        browser = QWebEngineView()
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
    
    def __del__(self):
        self.cleanup()

def main():
    app = QApplication(sys.argv)
    window = FinOpsApp()
    sys.exit(app.exec_())

if __name__ == "__main__":
    main()
