@echo off
rem ============================================================================
rem FastGuard desktop launcher
rem
rem NOTE: this file is intentionally ASCII-only. Chinese text inside a .bat is
rem decoded by cmd using the OEM/ANSI code page (e.g. GBK on zh-CN Windows), and
rem the resulting bytes can contain cmd metacharacters, which silently corrupts
rem the script. Keep this file ASCII-only.
rem
rem Interpreter selection:
rem   1) validate the repo venv first (a venv copied from another machine has a
rem      dangling python.exe and must not be used);
rem   2) prefer an interpreter that already has both ultralytics and PyQt5;
rem   3) otherwise use the first 64-bit interpreter and warn about missing deps.
rem
rem ultralytics and PyQt5 are probed in two separate commands on purpose:
rem placing them in one "import PyQt5, ultralytics" statement loads PyQt5 before
rem torch, which fails with WinError 1114 (c10.dll). main.py already imports in
rem the safe order.
rem ============================================================================
setlocal
cd /d "%~dp0"

set "PYCMD="
set "PYARGS="
set "FALLBACK_CMD="
set "FALLBACK_ARGS="

if exist "venv\Scripts\python.exe" (
    "venv\Scripts\python.exe" -c "import sys" >nul 2>&1
    if not errorlevel 1 (
        call :try_candidate "venv\Scripts\python.exe" ""
    ) else (
        echo [warn] repo venv is unusable ^(its interpreter path points to another machine^), skipped.
    )
) else (
    echo Virtual environment not found. Using system python...
)

if not defined PYCMD if exist ".venv\Scripts\python.exe" (
    ".venv\Scripts\python.exe" -c "import sys" >nul 2>&1
    if not errorlevel 1 call :try_candidate ".venv\Scripts\python.exe" ""
)

call :try_candidate "python" ""
call :try_candidate "py" "-3.10"
call :try_candidate "py" "-3"
call :try_candidate "py" ""

call :finalize

if not defined PYCMD (
    echo [error] no usable 64-bit Python interpreter found. Install 64-bit Python 3.10+.
    pause
    exit /b 1
)

echo interpreter: %PYCMD% %PYARGS%
"%PYCMD%" %PYARGS% --version

set "DEPS_OK=1"
"%PYCMD%" %PYARGS% -c "import ultralytics" >nul 2>&1
if errorlevel 1 set "DEPS_OK="
"%PYCMD%" %PYARGS% -c "import PyQt5" >nul 2>&1
if errorlevel 1 set "DEPS_OK="
if not defined DEPS_OK (
    echo [warn] desktop dependencies are missing for this interpreter. Run:
    echo         "%PYCMD%" %PYARGS% -m pip install -r requirements.txt
)

"%PYCMD%" %PYARGS% main.py
if errorlevel 1 pause
endlocal
exit /b 0

rem ============================================================================
rem :try_candidate CMD ARGS
rem   Records the first 64-bit interpreter as fallback; selects it immediately if
rem   both ultralytics and PyQt5 are importable (probed separately, see header).
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

"%_CMD%" %_ARGS% -c "import ultralytics" >nul 2>&1
if errorlevel 1 goto :eof
"%_CMD%" %_ARGS% -c "import PyQt5" >nul 2>&1
if errorlevel 1 goto :eof

set "PYCMD=%_CMD%"
set "PYARGS=%_ARGS%"
goto :eof

rem --- fallback: use the first 64-bit interpreter even without deps ---
:finalize
if not defined PYCMD if defined FALLBACK_CMD (
    set "PYCMD=%FALLBACK_CMD%"
    set "PYARGS=%FALLBACK_ARGS%"
)
goto :eof
