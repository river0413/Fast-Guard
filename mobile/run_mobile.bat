@echo off
rem ============================================================================
rem FastGuard mobile UI (Qt6 / PySide6) - desktop preview launcher
rem
rem NOTE: this file is intentionally ASCII-only. Chinese text inside a .bat is
rem decoded by cmd using the OEM/ANSI code page (e.g. GBK on zh-CN Windows), and
rem the resulting bytes can contain cmd metacharacters, which silently corrupts
rem the script. Keep this file ASCII-only.
rem
rem Interpreter selection:
rem   1) validate the repo venv first (a venv copied from another machine has a
rem      dangling python.exe and must not be used);
rem   2) prefer an interpreter that already has PySide6, so we never re-download
rem      several hundred MB of Qt;
rem   3) otherwise fall back to the first 64-bit interpreter and install deps.
rem ============================================================================
setlocal
cd /d "%~dp0.."

set "PYCMD="
set "PYARGS="
set "HAVE_PYSIDE="
set "FALLBACK_CMD="
set "FALLBACK_ARGS="

if exist "venv\Scripts\python.exe" (
    "venv\Scripts\python.exe" -c "import sys" >nul 2>&1
    if not errorlevel 1 (
        call :try_candidate "venv\Scripts\python.exe" ""
    ) else (
        echo [warn] repo venv is unusable ^(its interpreter path points to another machine^), skipped.
    )
)

if not defined PYCMD if exist ".venv\Scripts\python.exe" (
    ".venv\Scripts\python.exe" -c "import sys" >nul 2>&1
    if not errorlevel 1 call :try_candidate ".venv\Scripts\python.exe" ""
)

call :try_candidate "py" "-3.10"
call :try_candidate "py" "-3"
call :try_candidate "py" ""
call :try_candidate "python" ""

call :finalize

if not defined PYCMD (
    echo [error] no usable 64-bit Python interpreter found.
    echo         Install 64-bit Python 3.10+ and add it to PATH.
    echo         If a broken venv directory exists in the repo, delete it and retry.
    pause
    exit /b 1
)

echo interpreter: %PYCMD% %PYARGS%
"%PYCMD%" %PYARGS% --version

if not defined HAVE_PYSIDE (
    echo [info] PySide6 not found in any interpreter, installing mobile deps...
    echo        Installing PySide6-Essentials only ^(QtCore/QtGui/QtWidgets/QtNetwork/QtTest^).
    "%PYCMD%" %PYARGS% -m pip install -r mobile\requirements-mobile.txt
    if errorlevel 1 (
        echo [error] dependency install failed. Run manually:
        echo         "%PYCMD%" %PYARGS% -m pip install -r mobile\requirements-mobile.txt
        pause
        exit /b 1
    )
    "%PYCMD%" %PYARGS% -c "import PySide6" >nul 2>&1
    if errorlevel 1 (
        echo [error] PySide6 still cannot be imported, check the pip output above.
        pause
        exit /b 1
    )
)

echo starting FastGuard mobile UI...
"%PYCMD%" %PYARGS% -m mobile.app %*
if errorlevel 1 pause
endlocal
exit /b 0

rem ============================================================================
rem :try_candidate CMD ARGS
rem   Records the first 64-bit interpreter as fallback; selects it immediately if
rem   PySide6 is already importable (avoids unnecessary downloads).
rem ============================================================================
:try_candidate
if defined PYCMD goto :eof
set "_CMD=%~1"
set "_ARGS=%~2"
"%_CMD%" %_ARGS% -c "import struct,sys; sys.exit(0 if struct.calcsize('P')*8>=64 else 1)" >nul 2>&1
if errorlevel 1 goto :eof

if not defined FALLBACK_CMD (
    set "FALLBACK_CMD=%_CMD%"
    set "FALLBACK_ARGS=%_ARGS%"
)

"%_CMD%" %_ARGS% -c "import PySide6.QtWidgets" >nul 2>&1
if not errorlevel 1 (
    set "PYCMD=%_CMD%"
    set "PYARGS=%_ARGS%"
    set "HAVE_PYSIDE=1"
)
goto :eof

rem --- fallback: no interpreter has PySide6 yet, use the first 64-bit one ---
:finalize
if not defined PYCMD if defined FALLBACK_CMD (
    set "PYCMD=%FALLBACK_CMD%"
    set "PYARGS=%FALLBACK_ARGS%"
)
goto :eof
