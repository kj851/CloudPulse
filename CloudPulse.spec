# Copyright (c) 2026, Keaton Szantho
# Build with:  pyinstaller CloudPulse.spec
#
# Requirements (Windows, run from repo root):
#   pip install pyinstaller pillow
#   pyinstaller CloudPulse.spec
#
# R must still be installed on the target machine.
# All R packages must be pre-installed (run install_R_packages.R once).
#
# Put your logo files in lib/assets/
#   icon.ico  — exe/taskbar icon  (convert PNG→ICO at icoconvert.com)
#   logo.png  — shown in splash window

from PyInstaller.utils.hooks import collect_submodules
import os

block_cipher = None

a = Analysis(
    ['lib/app_launcher.py'],
    pathex=['.'],
    binaries=[],
    datas=[
        ('lib/FInOpsApp.R',   '.'),
        ('lib/data/styles.css',    '.'),
        ('lib/data/aws.r',         'data'),
        ('lib/data/azure.r',       'data'),
        ('lib/data/GCP.r',         'data'),
        ('lib/data/forecast.r',    'data'),
        ('lib/data/mock.r',        'data'),
        ('lib/assets',        'assets'),  # bundles icon.ico + logo.png
    ],
    hiddenimports=['PIL', 'PIL.Image', 'PIL.ImageTk', 'PIL._tkinter_finder'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['PyQt5', 'PyQtWebEngine'],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='CloudPulse',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon='lib/assets/icon.ico',
)
