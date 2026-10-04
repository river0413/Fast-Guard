@echo off
setlocal
cd /d "%~dp0"

if defined FASTGUARD_BUILD_PYTHON (
    set "PYTHON=%FASTGUARD_BUILD_PYTHON%"
) else if exist "venv\Scripts\python.exe" (
    set "PYTHON=venv\Scripts\python.exe"
) else if exist ".venv\Scripts\python.exe" (
    set "PYTHON=.venv\Scripts\python.exe"
) else (
    where python >nul 2>nul
    if errorlevel 1 (
        where py >nul 2>nul
        if errorlevel 1 (
            echo Python was not found. Install Python or create a project virtual environment.
            exit /b 1
        )
        set "PYTHON=py"
        set "PYTHON_ARGS=-3"
    ) else (
        set "PYTHON=python"
    )
)

"%PYTHON%" %PYTHON_ARGS% -c "import PyInstaller,sys; sys.exit(0 if int(PyInstaller.__version__.split('.')[0]) >= 6 else 1)" >nul 2>nul
if errorlevel 1 (
    echo PyInstaller 6 or newer is required. Install it with: "%PYTHON%" -m pip install "pyinstaller>=6"
    exit /b 1
)

"%PYTHON%" %PYTHON_ARGS% -c "import torch,sys; sys.exit(0 if getattr(torch.version, 'cuda', None) is None else 1)" >nul 2>nul
if errorlevel 1 (
    echo WARNING: this Python has a CUDA build of PyTorch installed.
    echo          The bundle will be roughly 3.5 GB larger than needed: the app runs inference
    echo          on CPU ^(device = 'cpu' in main.py and core\video_thread.py^).
    echo          Run setup_build_env.bat first and then this script again for a slim bundle.
)

:: Pulled in by --collect-all ultralytics, but never imported on this app's inference path
:: (verified with a CPU YOLO + ByteTrack run). Excluding them removes ~1.5 GB.
set "EXCLUDES="
set "EXCLUDES=%EXCLUDES% --exclude-module paddle --exclude-module paddleocr --exclude-module paddle2onnx"
set "EXCLUDES=%EXCLUDES% --exclude-module polars --exclude-module pyarrow --exclude-module pandas --exclude-module seaborn"
set "EXCLUDES=%EXCLUDES% --exclude-module sklearn --exclude-module scikit-learn --exclude-module transformers"
set "EXCLUDES=%EXCLUDES% --exclude-module tokenizers --exclude-module huggingface_hub --exclude-module hf_xet"
set "EXCLUDES=%EXCLUDES% --exclude-module safetensors --exclude-module torchaudio --exclude-module onnx"
set "EXCLUDES=%EXCLUDES% --exclude-module onnxruntime --exclude-module tensorflow --exclude-module tensorrt"
set "EXCLUDES=%EXCLUDES% --exclude-module tensorboard --exclude-module IPython --exclude-module jedi --exclude-module parso"
set "EXCLUDES=%EXCLUDES% --exclude-module pygame --exclude-module lxml --exclude-module pdfminer --exclude-module pypdfium2"
set "EXCLUDES=%EXCLUDES% --exclude-module cryptography --exclude-module tkinter --exclude-module _tkinter"

"%PYTHON%" %PYTHON_ARGS% -m PyInstaller ^
    --noconfirm ^
    --clean ^
    --onedir ^
    --windowed ^
    --name FastGuard ^
    --contents-directory "." ^
    --collect-all ultralytics ^
    --add-data "assets;assets" ^
    --add-data "data;data" ^
    --add-data "bytetrack.yaml;." ^
    --runtime-hook "%~dp0pyi_rth_fastguard.py" ^
    %EXCLUDES% ^
    main.py

if errorlevel 1 (
    echo Packaging failed.
    exit /b 1
)

for /f "usebackq" %%s in (`powershell -NoProfile -Command "[math]::Round((Get-ChildItem -Recurse -File '%~dp0dist\FastGuard' | Measure-Object Length -Sum).Sum/1MB)"`) do set "BUNDLE_MB=%%s"

echo.
echo Build complete: dist\FastGuard\FastGuard.exe ^(bundle size about %BUNDLE_MB% MB^)
echo Distribute the whole dist\FastGuard folder; do not re-zip it into the repo.
exit /b 0
