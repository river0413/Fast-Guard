@echo off
rem ============================================================================
rem FastGuard mobile (Flutter) - build 64-bit release APK
rem
rem Prerequisites: run mobile_flutter\tools\setup_android_toolchain.bat once.
rem Produces: mobile_flutter\build\app\outputs\flutter-apk\app-release.apk
rem ASCII-only on purpose (see mobile/run_mobile.bat for the reason).
rem ============================================================================
setlocal
set "ROOT=%LOCALAPPDATA%\FastGuardToolchain"
set "PROJECT=%~dp0.."
pushd "%PROJECT%"

if not exist "%ROOT%\env.bat" (
  echo [error] toolchain not found. Run mobile_flutter\tools\setup_android_toolchain.bat first.
  popd
  exit /b 1
)
call "%ROOT%\env.bat"

echo [1/4] flutter pub get
call flutter pub get
if errorlevel 1 goto :fail

echo [2/4] flutter test ^(algorithm regression^)
call flutter test
if errorlevel 1 (
  echo [warn] tests failed, continuing to build anyway
)

echo [3/4] flutter build apk --release --target-platform android-arm64
call flutter build apk --release --target-platform android-arm64
if errorlevel 1 goto :fail

echo [4/4] done. artifact:
dir /b /s "build\app\outputs\flutter-apk\*.apk"
echo Install: adb install -r "<apk path>"
popd
exit /b 0

:fail
echo [error] build failed, see the output above.
popd
exit /b 1
