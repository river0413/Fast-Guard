@echo off
rem ============================================================================
rem FastGuard mobile (Flutter) - Android toolchain bootstrap (NO admin required)
rem
rem Installs under %LOCALAPPDATA%\AndroidToolchain so the git repo stays clean:
rem   flutter\      Flutter SDK            (also required by Flet)
rem   jdk17\        Eclipse Temurin JDK 17
rem   android-sdk\  platform-tools / platforms;android-35 / build-tools;35.0.0
rem
rem Afterwards an env.bat is written for build_apk.bat to call.
rem ASCII-only on purpose (see mobile/run_mobile.bat for the reason).
rem ============================================================================
setlocal EnableDelayedExpansion
set "ROOT=%LOCALAPPDATA%\AndroidToolchain"
set "DL=%ROOT%\dl"
set "LOG=%ROOT%\bootstrap.log"

rem Reuse an existing install that sits in the old folder name instead of
rem downloading ~2 GB again. env.bat is rewritten below with the new paths.
if not exist "%ROOT%" if exist "%LOCALAPPDATA%\FastGuardToolchain" (
  echo [%DATE% %TIME%] migrating old FastGuardToolchain folder to AndroidToolchain
  move "%LOCALAPPDATA%\FastGuardToolchain" "%ROOT%" >nul 2>&1
)

if not exist "%ROOT%" mkdir "%ROOT%"
if not exist "%DL%" mkdir "%DL%"

echo [%DATE% %TIME%] bootstrap start > "%LOG%"

call :fetch flutter "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.7-stable.zip" 1934624561
call :fetch jdk17   "https://api.adoptium.net/v3/binary/latest/17/ga/windows/x64/jdk/hotspot/normal/eclipse" 0
call :fetch cmdline "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip" 0

if not exist "%ROOT%\flutter\bin\flutter.bat" (
  echo [%DATE% %TIME%] extracting flutter >> "%LOG%"
  call :unzip "%DL%\flutter.zip" "%ROOT%"
)
if not exist "%ROOT%\jdk17\bin\java.exe" (
  echo [%DATE% %TIME%] extracting jdk17 >> "%LOG%"
  call :unzip "%DL%\jdk17.zip" "%ROOT%\jdk17_tmp"
  if exist "%ROOT%\jdk17_tmp" (
    for /d %%D in ("%ROOT%\jdk17_tmp\*") do (
      if not exist "%ROOT%\jdk17" move "%%D" "%ROOT%\jdk17" >nul
    )
    rmdir /s /q "%ROOT%\jdk17_tmp" 2>nul
  )
)
if not exist "%ROOT%\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat" (
  echo [%DATE% %TIME%] extracting cmdline-tools >> "%LOG%"
  call :unzip "%DL%\cmdline.zip" "%ROOT%\android-sdk\cmdline-tools\tmp"
  if exist "%ROOT%\android-sdk\cmdline-tools\tmp\cmdline-tools" (
    if not exist "%ROOT%\android-sdk\cmdline-tools" mkdir "%ROOT%\android-sdk\cmdline-tools"
    move "%ROOT%\android-sdk\cmdline-tools\tmp\cmdline-tools" "%ROOT%\android-sdk\cmdline-tools\latest" >nul
  )
  rmdir /s /q "%ROOT%\android-sdk\cmdline-tools\tmp" 2>nul
)

set "JAVA_HOME=%ROOT%\jdk17"
set "ANDROID_HOME=%ROOT%\android-sdk"
set "ANDROID_SDK_ROOT=%ROOT%\android-sdk"
set "PATH=%JAVA_HOME%\bin;%PATH%"

if exist "%ROOT%\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat" (
  echo [%DATE% %TIME%] accepting android licenses >> "%LOG%"
  call "%ROOT%\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat" --sdk_root="%ANDROID_HOME%" --licenses >> "%LOG%" 2>&1
  echo [%DATE% %TIME%] installing sdk packages >> "%LOG%"
  call "%ROOT%\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat" --sdk_root="%ANDROID_HOME%" "platform-tools" "platforms;android-35" "build-tools;35.0.0" >> "%LOG%" 2>&1
)

if exist "%ROOT%\flutter\bin\flutter.bat" (
  echo [%DATE% %TIME%] flutter config >> "%LOG%"
  call "%ROOT%\flutter\bin\flutter.bat" config --android-sdk "%ANDROID_HOME%" >> "%LOG%" 2>&1
  call "%ROOT%\flutter\bin\flutter.bat" config --jdk-dir "%JAVA_HOME%" >> "%LOG%" 2>&1
  call "%ROOT%\flutter\bin\flutter.bat" --version >> "%LOG%" 2>&1
)

rem write an env script that later build steps can call
> "%ROOT%\env.bat" echo @echo off
>> "%ROOT%\env.bat" echo set "JAVA_HOME=%ROOT%\jdk17"
>> "%ROOT%\env.bat" echo set "ANDROID_HOME=%ROOT%\android-sdk"
>> "%ROOT%\env.bat" echo set "ANDROID_SDK_ROOT=%ROOT%\android-sdk"
>> "%ROOT%\env.bat" echo set "PATH=%ROOT%\flutter\bin;%ROOT%\jdk17\bin;%ROOT%\android-sdk\platform-tools;%%PATH%%"

rem Also persist the toolchain in the user environment (HKCU, no admin needed) so
rem flutter/jdk/adb work in any new terminal without calling env.bat. The .NET API
rem is used instead of setx, which would truncate PATH at 1024 characters.
echo [%DATE% %TIME%] persisting user environment >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$r = '%ROOT%'; [Environment]::SetEnvironmentVariable('JAVA_HOME', $r + '\jdk17', 'User'); [Environment]::SetEnvironmentVariable('ANDROID_HOME', $r + '\android-sdk', 'User'); [Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $r + '\android-sdk', 'User'); $p = [Environment]::GetEnvironmentVariable('Path', 'User'); $keep = @(); foreach ($e in ($p -split ';')) { if ($e -and $e -notlike '*FastGuardToolchain*' -and $e -notlike '*AndroidToolchain*') { $keep += $e } }; foreach ($a in @($r + '\flutter\bin', $r + '\jdk17\bin', $r + '\android-sdk\platform-tools')) { if ($keep -notcontains $a) { $keep += $a } }; [Environment]::SetEnvironmentVariable('Path', ($keep -join ';'), 'User')" >> "%LOG%" 2>&1
echo [%DATE% %TIME%] user environment rc=%ERRORLEVEL% >> "%LOG%"

echo [%DATE% %TIME%] bootstrap finished >> "%LOG%"
endlocal
exit /b 0

:fetch
set "NAME=%~1"
set "URL=%~2"
set "EXPSIZE=%~3"
set "OUT=%DL%\%NAME%.zip"
if exist "%OUT%" (
  if not "%EXPSIZE%"=="0" (
    for %%A in ("%OUT%") do (
      if %%~zA GEQ %EXPSIZE% (
        echo [%DATE% %TIME%] %NAME% already complete >> "%LOG%"
        goto :eof
      )
    )
  )
)
echo [%DATE% %TIME%] downloading %NAME% >> "%LOG%"
curl.exe -L -C - --retry 8 --retry-delay 5 --retry-all-errors -o "%OUT%" "%URL%" >> "%LOG%" 2>&1
echo [%DATE% %TIME%] %NAME% download rc=%ERRORLEVEL% >> "%LOG%"
goto :eof

:unzip
echo [%DATE% %TIME%] Expand-Archive %~1 >> "%LOG%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Expand-Archive -LiteralPath '%~1' -DestinationPath '%~2' -Force" >> "%LOG%" 2>&1
goto :eof
