@echo off
:: 把 build_windows.bat 产出的 dist\FastGuard 目录重新打包成一个 Windows 安装程序
:: dist\FastGuard-<版本>-Setup.exe（Inno Setup）。本脚本不会重新执行 PyInstaller。
setlocal EnableDelayedExpansion
cd /d "%~dp0"

set "PAYLOAD=dist\FastGuard\FastGuard.exe"
if not exist "%PAYLOAD%" (
    echo [ERROR] %PAYLOAD% not found.
    echo         Run build_windows.bat first: the installer repacks its dist\FastGuard output.
    exit /b 1
)

:: ---- 定位 Inno Setup 编译器 ISCC.exe ----
set "ISCC="
if defined FASTGUARD_ISCC if exist "%FASTGUARD_ISCC%" set "ISCC=%FASTGUARD_ISCC%"

set "LAD=%LOCALAPPDATA%"
set "PF=%ProgramFiles%"
set "PF86=%ProgramFiles(x86)%"

if not defined ISCC if exist "%LAD%\Programs\Inno Setup 6\ISCC.exe" set "ISCC=%LAD%\Programs\Inno Setup 6\ISCC.exe"
if not defined ISCC if exist "%PF%\Inno Setup 6\ISCC.exe" set "ISCC=%PF%\Inno Setup 6\ISCC.exe"
if not defined ISCC if exist "%PF86%\Inno Setup 6\ISCC.exe" set "ISCC=%PF86%\Inno Setup 6\ISCC.exe"
if not defined ISCC call :find_iscc_in_registry
if not defined ISCC call :install_iscc
if not defined ISCC (
    echo [ERROR] Inno Setup 6 was not found. Install it, then run this script again:
    echo         winget install --id JRSoftware.InnoSetup --exact
    exit /b 1
)

set "VERSION=%FASTGUARD_VERSION%"
if not defined VERSION set "VERSION=1.0.0"

echo Compiling installer from dist\FastGuard ^(version %VERSION%^)...
echo Compiler: %ISCC%
:: 大体积资源用 LZMA2 固实压缩，耗时通常数分钟
"%ISCC%" /Qp /DAppVersion=%VERSION% "installer\FastGuard.iss"
if errorlevel 1 (
    echo.
    echo [ERROR] Installer build failed.
    exit /b 1
)

set "SETUP=dist\FastGuard-%VERSION%-Setup.exe"
for %%F in ("%SETUP%") do set "SETUP_BYTES=%%~zF"
for /f "usebackq" %%s in (`powershell -NoProfile -Command "[math]::Round(%SETUP_BYTES%/1MB)"`) do set "SETUP_MB=%%s"

echo.
echo Build complete: %SETUP% ^(about %SETUP_MB% MB^)
echo Run it to install FastGuard to %%LOCALAPPDATA%%\Programs\FastGuard ^(per-user, no admin^).
exit /b 0

:find_iscc_in_registry
for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1" /v InstallLocation 2^>nul ^| findstr /i "InstallLocation"') do set "ISCC_DIR=%%B"
if defined ISCC_DIR call :normalize_iscc_dir
if not defined ISCC for /f "tokens=2,*" %%A in ('reg query "HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1" /v InstallLocation 2^>nul ^| findstr /i "InstallLocation"') do set "ISCC_DIR=%%B"
if defined ISCC_DIR call :normalize_iscc_dir
exit /b 0

:normalize_iscc_dir
if "!ISCC_DIR:~-1!"=="\" set "ISCC_DIR=!ISCC_DIR:~0,-1!"
if exist "!ISCC_DIR!\ISCC.exe" set "ISCC=!ISCC_DIR!\ISCC.exe"
exit /b 0

:install_iscc
where winget >nul 2>nul
if errorlevel 1 exit /b 0
echo Inno Setup 6 was not found; installing it with winget...
winget install --id JRSoftware.InnoSetup --exact --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity
if exist "%LAD%\Programs\Inno Setup 6\ISCC.exe" set "ISCC=%LAD%\Programs\Inno Setup 6\ISCC.exe"
exit /b 0
