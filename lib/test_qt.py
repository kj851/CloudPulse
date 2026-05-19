#!/usr/bin/env python3
import sys
import os
print("[Test] Setting environment variables...")
os.environ['QT_QPA_PLATFORM'] = 'offscreen'
os.environ['QTWEBENGINE_CHROMIUM_FLAGS'] = '--no-sandbox --disable-gpu'

print("[Test] Importing PyQt5...")
from PyQt5.QtWidgets import QApplication
from PyQt5.QtCore import Qt
QApplication.setAttribute(Qt.AA_ShareOpenGLContexts)

print("[Test] Creating QApplication...")
app = QApplication(sys.argv)
print("[Test] QApplication created successfully")

print("[Test] Importing QWebEngineView...")
from PyQt5.QtWebEngineWidgets import QWebEngineView

print("[Test] Creating QWebEngineView...")
view = QWebEngineView()
print("[Test] QWebEngineView created successfully")

print("[Test] Done!")
