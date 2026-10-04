@echo off
setlocal
cd /d "%~dp0"

if exist "venv\Scripts\python.exe" (
    echo venv already exists at venv\ - delete it first if you want to recreate it.
    exit /b 0
)

where python >nul 2>nul
if errorlevel 1 (
    echo Python was not found. Install Python 3.10 or newer first.
    exit /b 1
)

echo Creating venv...
python -m venv venv
if errorlevel 1 exit /b 1

:: CPU-only PyTorch keeps the bundle ~3.5 GB smaller; the app runs inference on CPU
:: (device = 'cpu' in main.py and core\video_thread.py).
echo Installing CPU-only PyTorch 2.6.0 (matching the development stack, without CUDA)...
venv\Scripts\python.exe -m pip install --quiet --upgrade pip
venv\Scripts\python.exe -m pip install --index-url https://download.pytorch.org/whl/cpu torch==2.6.0 torchvision==0.21.0
if errorlevel 1 exit /b 1

echo Installing project dependencies and PyInstaller...
venv\Scripts\python.exe -m pip install -r requirements.txt "pyinstaller>=6"
if errorlevel 1 exit /b 1

echo.
echo Build environment ready. Next step: build_windows.bat
