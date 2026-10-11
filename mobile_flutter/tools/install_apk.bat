@echo off
rem ============================================================================
rem FastGuard mobile (Flutter) - install the built APK onto a connected phone
rem
rem Usage:
rem   1) On the phone: Settings - About phone - tap "Build number" 7 times to
rem      unlock Developer options, then enable "USB debugging".
rem   2) Connect the phone by USB and accept the "Allow USB debugging?" prompt.
rem   3) Run this script.
rem
rem ASCII-only on purpose (see mobile/run_mobile.bat for the reason).
rem ============================================================================
setlocal
set "ROOT=%LOCALAPPDATA%\AndroidToolchain"
set "PROJECT=%~dp0.."
set "APK=%PROJECT%\build\app\outputs\flutter-apk\app-release.apk"
rem Fall back to the copy kept in dist/ when flutter clean removed build output.
if not exist "%APK%" set "APK=%PROJECT%\..\dist\FastGuard-mobile-arm64-v1.1.1.apk"

if not exist "%ROOT%\env.bat" (
  echo [error] toolchain not found. Run setup_android_toolchain.bat first.
  exit /b 1
)
call "%ROOT%\env.bat"

where adb >nul 2>&1
if errorlevel 1 (
  echo [error] adb not found on PATH.
  echo         Add "%ROOT%\android-sdk\platform-tools" to PATH, or run:
  echo         "%ROOT%\android-sdk\platform-tools\adb.exe" install -r "%APK%"
  exit /b 1
)

if not exist "%APK%" (
  echo [error] APK not found: %APK%
  echo         Build it first: mobile_flutter\tools\build_apk.bat
  exit /b 1
)

echo === connected devices ===
adb devices
echo.

adb get-state >nul 2>&1
if errorlevel 1 (
  echo [error] no device detected. Checklist:
  echo         1. USB cable supports data transfer ^(not charge-only^).
  echo         2. Phone: Developer options -^> USB debugging = ON.
  echo         3. Accept the "Allow USB debugging?" dialog on the phone screen.
  echo         4. Try another USB port / cable, then re-run.
  echo         Wi-Fi alternative: adb tcpip 5555 and adb connect ^<phone-ip^>:5555
  exit /b 1
)

echo === installing %APK% ===
adb install -r "%APK%"
if errorlevel 1 (
  echo [warn] install failed. If it says INSTALL_FAILED_UPDATE_INCOMPATIBLE,
  echo        uninstall the old build first: adb uninstall com.fastguard.fastguard_mobile
  exit /b 1
)

echo.
echo [ok] installed. Launch it from the app drawer, or:
echo      adb shell monkey -p com.fastguard.fastguard_mobile -c android.intent.category.LAUNCHER 1
endlocal
exit /b 0
